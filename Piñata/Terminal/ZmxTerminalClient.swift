import Darwin
import Foundation

enum ZmxSession {
    static func name(for id: UUID) -> String {
        "pinata-\(id.uuidString.lowercased())"
    }
}

final class ZmxTerminalClient: @unchecked Sendable {
    private let id: UUID
    private let launchConfiguration: ZmxLaunchConfiguration
    private let queue: DispatchQueue
    private var ptyFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var pendingWrites: [Data] = []
    private var controlProcesses: [Process] = []
    private var writeOffset = 0
    private var closed = false
    private var started = false

    var onOutput: ((Data) -> Void)?

    init(id: UUID, workingDirectory: String, target: TerminalTarget) {
        self.id = id
        launchConfiguration = ZmxLaunchConfiguration(
            sessionName: ZmxSession.name(for: id),
            workingDirectory: workingDirectory,
            target: target
        )
        queue = DispatchQueue(label: "dev.pinata.zmx-client.\(id.uuidString)")
    }

    deinit {
        terminateAttachedClient()
    }

    func start() {
        queue.async { [weak self] in self?.startIfNeeded() }
    }

    func send(_ data: Data) {
        queue.async { [weak self] in
            guard let self, !closed, ptyFD >= 0 else { return }
            pendingWrites.append(data)
            flushWrites()
        }
    }

    func resize(columns: UInt16, rows: UInt16) {
        queue.async { [weak self] in
            guard let self, ptyFD >= 0 else { return }
            var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(ptyFD, TIOCSWINSZ, &size)
            if childPID > 0 { _ = kill(childPID, SIGWINCH) }
        }
    }

    func disconnect() {
        queue.async { [weak self] in self?.terminateAttachedClient() }
    }

    func close() {
        queue.async { [weak self] in
            guard let self, !closed else { return }
            closed = true
            killSession()
            terminateAttachedClient()
        }
    }

    private func killSession() {
        guard let process = ZmxControl.makeKill(
            sessionName: ZmxSession.name(for: id),
            target: launchConfiguration.target
        ) else {
            return
        }
        process.terminationHandler = { [weak self] process in
            process.terminationHandler = nil
            guard let client = self else { return }
            client.queue.async {
                client.controlProcesses.removeAll { $0 === process }
            }
        }
        do {
            try process.run()
            controlProcesses.append(process)
        } catch {
            report("Could not close the zmx session.")
        }
    }

    private func startIfNeeded() {
        guard !started, !closed else { return }
        started = true

        var masterFD: Int32 = -1
        let pid = forkpty(&masterFD, nil, nil, nil)
        guard pid >= 0 else {
            report("Could not start zmx.")
            return
        }
        if pid == 0 {
            launchConfiguration.exec()
        }

        childPID = pid
        ptyFD = masterFD
        setNonBlocking(masterFD)
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { Darwin.close(masterFD) }
        readSource = source
        source.resume()
    }

    private func readAvailable() {
        var bytes = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = read(ptyFD, &bytes, bytes.count)
            if count > 0 {
                let data = Data(bytes.prefix(Int(count)))
                DispatchQueue.main.async { [weak self] in self?.onOutput?(data) }
                continue
            }
            if count == 0 || errno == EIO {
                clientExited()
                return
            }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            clientExited()
            return
        }
    }

    private func flushWrites() {
        while let data = pendingWrites.first {
            let written = data.withUnsafeBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                return Darwin.write(
                    ptyFD,
                    baseAddress.advanced(by: writeOffset),
                    buffer.count - writeOffset
                )
            }
            if written > 0 {
                writeOffset += written
                if writeOffset == data.count {
                    pendingWrites.removeFirst()
                    writeOffset = 0
                }
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                waitForWritablePTY()
                return
            }
            pendingWrites.removeAll()
            writeOffset = 0
            return
        }
        writeSource?.cancel()
        writeSource = nil
    }

    private func waitForWritablePTY() {
        guard writeSource == nil, ptyFD >= 0 else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: ptyFD, queue: queue)
        source.setEventHandler { [weak self] in self?.flushWrites() }
        source.setCancelHandler {}
        writeSource = source
        source.resume()
    }

    private func clientExited() {
        let pid = childPID
        terminateAttachedClient()
        if pid > 0 {
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
        }
        // ponytail: reconnect on app relaunch; live retries need backoff and state.
        if !closed { report("Terminal connection closed.") }
    }

    private func terminateAttachedClient() {
        if childPID > 0 { _ = kill(-childPID, SIGHUP) }
        childPID = -1
        writeSource?.cancel()
        writeSource = nil
        readSource?.cancel()
        readSource = nil
        ptyFD = -1
        pendingWrites.removeAll()
        writeOffset = 0
    }

    private func report(_ message: String) {
        let data = Data("\r\n[Piñata] \(message)\r\n".utf8)
        DispatchQueue.main.async { [weak self] in self?.onOutput?(data) }
    }
}

private final class ZmxLaunchConfiguration {
    let target: TerminalTarget
    private let executable: UnsafeMutablePointer<CChar>
    private let arguments: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let argumentCount: Int
    private let terminfoPath: UnsafeMutablePointer<CChar>?

    init(sessionName: String, workingDirectory: String, target: TerminalTarget) {
        self.target = target
        terminfoPath = Bundle.main.url(forResource: "terminfo", withExtension: nil).map {
            strdup($0.path)
        }

        switch target {
        case .local:
            executable = strdup(Self.localZmxPath())!
            let shell = UserShell.loginPath
            let command = "cd -- \(SSHCommand.shellQuote(workingDirectory)) && exec \(SSHCommand.shellQuote(shell)) -l"
            let values = ["zmx", "attach", sessionName, shell, "-lc", command]
            arguments = Self.makeArguments(values)
            argumentCount = values.count
        case .ssh(let connection):
            executable = strdup("/usr/bin/ssh")!
            let command = "cd -- \(SSHCommand.shellQuote(workingDirectory)) && if [ -x \"$HOME/.local/bin/zmx\" ]; then exec \"$HOME/.local/bin/zmx\" attach \(SSHCommand.shellQuote(sessionName)); else exec zmx attach \(SSHCommand.shellQuote(sessionName)); fi"
            let values = SSHCommand.arguments(
                connection: connection,
                command: command,
                allocateTTY: true,
                includeExecutableName: true
            )
            arguments = Self.makeArguments(values)
            argumentCount = values.count
        }
    }

    deinit {
        free(executable)
        free(terminfoPath)
        for index in 0..<argumentCount where arguments[index] != nil {
            free(arguments[index])
        }
        arguments.deallocate()
    }

    func exec() -> Never {
        setenv("TERM", "xterm-ghostty", 1)
        if let terminfoPath { setenv("TERMINFO", terminfoPath, 1) }
        execv(executable, arguments)
        _exit(127)
    }

    private static func localZmxPath() -> String {
        Bundle.main.url(forResource: "zmx", withExtension: nil)!.path
    }

    private static func makeArguments(
        _ values: [String]
    ) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let arguments = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(
            capacity: values.count + 1
        )
        for (index, value) in values.enumerated() {
            arguments[index] = strdup(value)
        }
        arguments[values.count] = nil
        return arguments
    }
}

private enum ZmxControl {
    static func makeKill(sessionName: String, target: TerminalTarget) -> Process? {
        let process = Process()
        switch target {
        case .local:
            guard let executable = Bundle.main.url(forResource: "zmx", withExtension: nil) else { return nil }
            process.executableURL = executable
            process.arguments = ["kill", sessionName, "--force"]
        case .ssh(let connection):
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = SSHCommand.arguments(
                connection: connection,
                command: "if [ -x \"$HOME/.local/bin/zmx\" ]; then exec \"$HOME/.local/bin/zmx\" kill \(SSHCommand.shellQuote(sessionName)) --force; else exec zmx kill \(SSHCommand.shellQuote(sessionName)) --force; fi"
            )
        }
        return process
    }
}

private func setNonBlocking(_ fd: Int32) {
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
}
