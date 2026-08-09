import Darwin
import Foundation

enum TerminalServiceMessage: Codable, Equatable {
    case attach
    case input(Data)
    case resize(columns: UInt16, rows: UInt16)
    case output(Data)
    case close
}

enum TerminalSessionPaths {
    private static let directoryName = "terminal-sessions"

    static func logURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString.lowercased()).log")
    }

    static func socketPath(for id: UUID) -> String {
        "/tmp/pinata-\(getuid())-\(id.uuidString.lowercased()).socket"
    }

    static func prepare() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    private static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(
                Bundle.main.bundleIdentifier ?? "dev.pinata.app",
                isDirectory: true
            )
            .appendingPathComponent(directoryName, isDirectory: true)
    }
}

final class TerminalSessionClient: @unchecked Sendable {
    private let id: UUID
    private let launchConfiguration: TerminalLaunchConfiguration
    private let queue: DispatchQueue
    private var socketFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var buffer = Data()
    private var pendingWrites: [Data] = []
    private var queuedMessages: [TerminalServiceMessage] = []
    private var latestSize: (columns: UInt16, rows: UInt16)?
    private var writeOffset = 0
    private var launchedService = false
    private var closed = false
    private var reportedConnectionFailure = false

    var onOutput: ((Data) -> Void)?
    init(id: UUID, launchConfiguration: TerminalLaunchConfiguration) {
        self.id = id
        self.launchConfiguration = launchConfiguration
        queue = DispatchQueue(label: "dev.pinata.terminal-client.\(id.uuidString)")
    }

    func start() {
        queue.async { [weak self] in
            self?.connect(attempt: 0)
        }
    }

    func send(_ message: TerminalServiceMessage) {
        queue.async { [weak self] in
            self?.sendWhenConnected(message)
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            self?.disconnectSocket()
        }
    }

    func close() {
        queue.async { [weak self] in
            guard let self else { return }
            closed = true
            guard socketFD >= 0 else {
                disconnectSocket()
                return
            }
            write(.close)
        }
    }

    private func connect(attempt: Int) {
        guard !closed else { return }
        if openSocket() {
            write(.attach)
            if let latestSize {
                write(.resize(columns: latestSize.columns, rows: latestSize.rows))
            }
            queuedMessages.forEach(write)
            queuedMessages.removeAll(keepingCapacity: true)
            return
        }
        if !launchedService {
            launchedService = true
            launchService()
        }
        guard attempt < 40 else {
            report("Could not connect to the terminal service.")
            return
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            self?.connect(attempt: attempt + 1)
        }
    }

    private func launchService() {
        guard let executableURL = Bundle.main.executableURL else {
            report("Could not find the terminal service executable.")
            return
        }
        let process = Process()
        process.executableURL = executableURL
        guard let launchData = try? JSONEncoder().encode(launchConfiguration) else {
            report("Could not encode the terminal launch configuration.")
            return
        }
        process.arguments = [
            "--pinata-terminal-service",
            id.uuidString,
            launchData.base64EncodedString(),
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-ghostty"
        if let terminfo = Bundle.main.url(forResource: "terminfo", withExtension: nil) {
            environment["TERMINFO"] = terminfo.path
        }
        process.environment = environment
        do {
            try process.run()
        } catch {
            report("Could not start the terminal service: \(error.localizedDescription)")
        }
    }

    private func openSocket() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var address = makeUnixAddress(TerminalSessionPaths.socketPath(for: id))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            return false
        }
        socketFD = fd
        reportedConnectionFailure = false
        setNonBlocking(fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source
        source.resume()
        return true
    }

    private func readAvailable() {
        var bytes = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = read(socketFD, &bytes, bytes.count)
            if count > 0 {
                buffer.append(contentsOf: bytes.prefix(Int(count)))
                consumeMessages()
            } else if count == 0 {
                connectionLost()
                return
            } else if errno != EAGAIN && errno != EWOULDBLOCK {
                connectionLost()
                return
            } else {
                return
            }
        }
    }

    private func consumeMessages() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let frame = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let message = try? JSONDecoder().decode(TerminalServiceMessage.self, from: frame) else {
                continue
            }
            switch message {
            case .output(let data):
                DispatchQueue.main.async { [weak self] in self?.onOutput?(data) }
            default:
                break
            }
        }
    }

    private func write(_ message: TerminalServiceMessage) {
        guard socketFD >= 0,
              var data = try? JSONEncoder().encode(message)
        else { return }
        data.append(0x0A)
        pendingWrites.append(data)
        flushWrites()
    }

    private func sendWhenConnected(_ message: TerminalServiceMessage) {
        if case let .resize(columns, rows) = message {
            latestSize = (columns, rows)
        }
        guard socketFD >= 0 else {
            if case .resize = message { return }
            queuedMessages.append(message)
            return
        }
        write(message)
    }

    private func flushWrites() {
        while let data = pendingWrites.first {
            let written = data.withUnsafeBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                return Darwin.write(socketFD, baseAddress.advanced(by: writeOffset), buffer.count - writeOffset)
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
                waitForWritableSocket()
                return
            }
            connectionLost()
            return
        }
        writeSource?.cancel()
        writeSource = nil
    }

    private func waitForWritableSocket() {
        guard writeSource == nil, socketFD >= 0 else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in self?.flushWrites() }
        source.setCancelHandler {}
        writeSource = source
        source.resume()
    }

    private func connectionLost() {
        disconnectSocket()
        if !closed { report("Terminal service disconnected.") }
    }

    private func report(_ message: String) {
        guard !reportedConnectionFailure else { return }
        reportedConnectionFailure = true
        let data = Data("\r\n[Piñata] \(message)\r\n".utf8)
        DispatchQueue.main.async { [weak self] in self?.onOutput?(data) }
    }

    private func disconnectSocket() {
        writeSource?.cancel()
        writeSource = nil
        source?.cancel()
        source = nil
        socketFD = -1
        buffer.removeAll(keepingCapacity: true)
        pendingWrites.removeAll(keepingCapacity: true)
        writeOffset = 0
    }
}

private final class TerminalServiceClient {
    let fd: Int32
    var source: DispatchSourceRead?
    var writeSource: DispatchSourceWrite?
    var buffer = Data()
    var pendingWrites: [Data] = []
    var writeOffset = 0
    var attached = false

    init(fd: Int32) {
        self.fd = fd
    }
}

private final class ChildLaunchConfiguration {
    private let workingDirectory: UnsafeMutablePointer<CChar>
    private let shellPath: UnsafeMutablePointer<CChar>
    private let sshPath: UnsafeMutablePointer<CChar>?
    private let terminfoPath: UnsafeMutablePointer<CChar>?
    private let arguments: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let argumentCount: Int
    private let termKey = strdup("TERM")!
    private let termValue = strdup("xterm-ghostty")!
    private let terminfoKey = strdup("TERMINFO")!

    init(launchConfiguration: TerminalLaunchConfiguration) {
        let workingDirectory = launchConfiguration.workingDirectory
        self.workingDirectory = strdup(workingDirectory)!
        let shell = UserShell.loginPath
        shellPath = strdup(shell)!
        terminfoPath = Bundle.main.url(forResource: "terminfo", withExtension: nil).map {
            strdup($0.path)
        }
        switch launchConfiguration.target {
        case .local:
            sshPath = nil
            let shellName = URL(fileURLWithPath: shell).lastPathComponent
            arguments = .allocate(capacity: 3)
            argumentCount = 2
            arguments[0] = strdup(shellName)
            arguments[1] = strdup("-l")
            arguments[2] = nil
        case .ssh(let connection):
            sshPath = strdup("/usr/bin/ssh")!
            arguments = .allocate(capacity: 13)
            argumentCount = 12
            arguments[0] = strdup("ssh")
            arguments[1] = strdup("-A")
            arguments[2] = strdup("-S")
            arguments[3] = strdup("none")
            arguments[4] = strdup("-o")
            arguments[5] = strdup("ControlMaster=no")
            arguments[6] = strdup("-o")
            arguments[7] = strdup("ClearAllForwardings=yes")
            arguments[8] = strdup("-tt")
            arguments[9] = strdup("--")
            arguments[10] = strdup(connection.host)
            arguments[11] = strdup("cd -- \(SSHCommand.shellQuote(workingDirectory)) && exec ${SHELL:-/bin/sh} -l")
            arguments[12] = nil
        }
    }

    deinit {
        free(workingDirectory)
        free(shellPath)
        free(sshPath)
        free(terminfoPath)
        for index in 0..<argumentCount where arguments[index] != nil {
            free(arguments[index])
        }
        arguments.deallocate()
        free(termKey)
        free(termValue)
        free(terminfoKey)
    }

    func execLoginShell() -> Never {
        setenv(termKey, termValue, 1)
        if let terminfoPath {
            setenv(terminfoKey, terminfoPath, 1)
        }
        if let sshPath {
            execv(sshPath, arguments)
        } else {
            _ = chdir(workingDirectory)
            execv(shellPath, arguments)
        }
        _exit(127)
    }
}

final class TerminalSessionService {
    private let id: UUID
    private let launchConfiguration: TerminalLaunchConfiguration
    private let socketPath: String
    private let logURL: URL
    private let restoringInterruptedSession: Bool
    private let childLaunch: ChildLaunchConfiguration
    private let queue: DispatchQueue
    private var listenerFD: Int32 = -1
    private var ptyFD: Int32 = -1
    private var childPID: pid_t = -1
    private var listenerSource: DispatchSourceRead?
    private var ptySource: DispatchSourceRead?
    private var ptyWriteSource: DispatchSourceWrite?
    private var clients: [Int32: TerminalServiceClient] = [:]
    private var logHandle: FileHandle?
    private var pendingPTYWrites: [Data] = []
    private var ptyWriteOffset = 0
    private var restartingShell = false

    init(id: UUID, launchConfiguration: TerminalLaunchConfiguration) {
        self.id = id
        self.launchConfiguration = launchConfiguration
        socketPath = TerminalSessionPaths.socketPath(for: id)
        logURL = TerminalSessionPaths.logURL(for: id)
        restoringInterruptedSession = FileManager.default.fileExists(atPath: logURL.path)
        childLaunch = ChildLaunchConfiguration(launchConfiguration: launchConfiguration)
        queue = DispatchQueue(label: "dev.pinata.terminal-service.\(id.uuidString)")
    }

    func run() throws {
        _ = setsid()
        try TerminalSessionPaths.prepare()
        try startPTY()
        try startListener()
        dispatchMain()
    }

    private func startPTY() throws {
        if logHandle == nil {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            chmod(logURL.path, S_IRUSR | S_IWUSR)
            logHandle = try FileHandle(forWritingTo: logURL)
            try logHandle?.seekToEnd()
            if restoringInterruptedSession {
                let notice = Data("\r\n[Piñata] Previous terminal process was interrupted. A new login shell was started.\r\n\r\n".utf8)
                logHandle?.write(notice)
            }
        }

        var masterFD: Int32 = -1
        let pid = forkpty(&masterFD, nil, nil, nil)
        guard pid >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        if pid == 0 {
            childLaunch.execLoginShell()
        }
        childPID = pid
        ptyFD = masterFD
        setNonBlocking(masterFD)
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        source.setEventHandler { [weak self] in self?.readPTY() }
        source.setCancelHandler { Darwin.close(masterFD) }
        ptySource = source
        source.resume()
    }

    private func startListener() throws {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        listenerFD = fd
        var address = makeUnixAddress(socketPath)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            Darwin.close(fd)
            throw error
        }
        chmod(socketPath, S_IRUSR | S_IWUSR)
        setNonBlocking(fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients() }
        source.setCancelHandler { Darwin.close(fd) }
        listenerSource = source
        source.resume()
    }

    private func acceptClients() {
        while true {
            let clientFD = accept(listenerFD, nil, nil)
            guard clientFD >= 0 else { return }
            setNonBlocking(clientFD)
            let client = TerminalServiceClient(fd: clientFD)
            let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
            source.setEventHandler { [weak self, weak client] in
                guard let self, let client else { return }
                self.readClient(client)
            }
            source.setCancelHandler { Darwin.close(clientFD) }
            client.source = source
            clients[clientFD] = client
            source.resume()
        }
    }

    private func readClient(_ client: TerminalServiceClient) {
        var bytes = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = read(client.fd, &bytes, bytes.count)
            if count > 0 {
                client.buffer.append(contentsOf: bytes.prefix(Int(count)))
                consumeClientMessages(client)
            } else if count == 0 {
                remove(client)
                return
            } else if errno != EAGAIN && errno != EWOULDBLOCK {
                remove(client)
                return
            } else {
                return
            }
        }
    }

    private func consumeClientMessages(_ client: TerminalServiceClient) {
        while let newline = client.buffer.firstIndex(of: 0x0A) {
            let frame = client.buffer.prefix(upTo: newline)
            client.buffer.removeSubrange(...newline)
            guard let message = try? JSONDecoder().decode(TerminalServiceMessage.self, from: frame) else {
                continue
            }
            switch message {
            case .attach:
                client.attached = true
                replayLog(to: client)
            case .input(let data):
                writeToPTY(data)
            case .resize(let columns, let rows):
                resizePTY(columns: columns, rows: rows)
            case .close:
                shutdown()
            case .output:
                break
            }
        }
    }

    private func readPTY() {
        var bytes = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = read(ptyFD, &bytes, bytes.count)
            if count > 0 {
                let data = Data(bytes.prefix(Int(count)))
                logHandle?.write(data)
                broadcast(.output(data))
            } else if count == 0 || errno == EIO {
                finishProcess()
                return
            } else if errno != EAGAIN && errno != EWOULDBLOCK {
                finishProcess()
                return
            } else {
                return
            }
        }
    }

    private func writeToPTY(_ data: Data) {
        pendingPTYWrites.append(data)
        flushPTYWrites()
    }

    private func flushPTYWrites() {
        while let data = pendingPTYWrites.first {
            let written = data.withUnsafeBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                return Darwin.write(ptyFD, baseAddress.advanced(by: ptyWriteOffset), buffer.count - ptyWriteOffset)
            }
            if written > 0 {
                ptyWriteOffset += written
                if ptyWriteOffset == data.count {
                    pendingPTYWrites.removeFirst()
                    ptyWriteOffset = 0
                }
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                waitForWritablePTY()
                return
            }
            pendingPTYWrites.removeAll()
            ptyWriteOffset = 0
            return
        }
        ptyWriteSource?.cancel()
        ptyWriteSource = nil
    }

    private func waitForWritablePTY() {
        guard ptyWriteSource == nil, ptyFD >= 0 else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: ptyFD, queue: queue)
        source.setEventHandler { [weak self] in self?.flushPTYWrites() }
        source.setCancelHandler {}
        ptyWriteSource = source
        source.resume()
    }

    private func resizePTY(columns: UInt16, rows: UInt16) {
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(ptyFD, TIOCSWINSZ, &size)
        if childPID > 0 { _ = kill(childPID, SIGWINCH) }
    }

    private func replayLog(to client: TerminalServiceClient) {
        guard let data = try? Data(contentsOf: logURL) else { return }
        for offset in stride(from: 0, to: data.count, by: 24 * 1024) {
            let end = min(offset + 24 * 1024, data.count)
            send(.output(data.subdata(in: offset..<end)), to: client)
        }
    }

    private func finishProcess() {
        guard !restartingShell else { return }
        restartingShell = true
        ptySource?.cancel()
        ptySource = nil
        ptyWriteSource?.cancel()
        ptyWriteSource = nil
        var status: Int32 = 0
        _ = waitpid(childPID, &status, 0)
        do {
            try startPTY()
        } catch {
            shutdown()
        }
        restartingShell = false
    }

    private func broadcast(_ message: TerminalServiceMessage) {
        clients.values.filter(\.attached).forEach { send(message, to: $0) }
    }

    private func send(_ message: TerminalServiceMessage, to client: TerminalServiceClient) {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        client.pendingWrites.append(data)
        flushWrites(to: client)
    }

    private func flushWrites(to client: TerminalServiceClient) {
        while let data = client.pendingWrites.first {
            let written = data.withUnsafeBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                return Darwin.write(client.fd, baseAddress.advanced(by: client.writeOffset), buffer.count - client.writeOffset)
            }
            if written > 0 {
                client.writeOffset += written
                if client.writeOffset == data.count {
                    client.pendingWrites.removeFirst()
                    client.writeOffset = 0
                }
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                waitForWritableSocket(for: client)
                return
            }
            remove(client)
            return
        }
        client.writeSource?.cancel()
        client.writeSource = nil
    }

    private func waitForWritableSocket(for client: TerminalServiceClient) {
        guard client.writeSource == nil else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: client.fd, queue: queue)
        source.setEventHandler { [weak self, weak client] in
            guard let self, let client else { return }
            self.flushWrites(to: client)
        }
        source.setCancelHandler {}
        client.writeSource = source
        source.resume()
    }

    private func remove(_ client: TerminalServiceClient) {
        clients.removeValue(forKey: client.fd)
        client.writeSource?.cancel()
        client.source?.cancel()
    }

    private func shutdown() {
        if childPID > 0 { _ = kill(-childPID, SIGHUP) }
        clients.values.forEach {
            $0.writeSource?.cancel()
            $0.source?.cancel()
        }
        clients.removeAll()
        ptySource?.cancel()
        ptyWriteSource?.cancel()
        listenerSource?.cancel()
        try? logHandle?.close()
        try? FileManager.default.removeItem(at: logURL)
        unlink(socketPath)
        exit(0)
    }
}

private func makeUnixAddress(_ path: String) -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        path.utf8CString.withUnsafeBytes { source in
            destination.copyBytes(from: source)
        }
    }
    return address
}

private func setNonBlocking(_ fd: Int32) {
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
}

enum TerminalServiceEntryPoint {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, arguments[1] == "--pinata-terminal-service",
              let id = UUID(uuidString: arguments[2]),
              let data = Data(base64Encoded: arguments[3]),
              let launchConfiguration = try? JSONDecoder().decode(TerminalLaunchConfiguration.self, from: data)
        else { return false }
        do {
            let service = TerminalSessionService(id: id, launchConfiguration: launchConfiguration)
            try service.run()
        } catch {
            fputs("Piñata terminal service failed: \(error)\n", stderr)
        }
        return true
    }
}
