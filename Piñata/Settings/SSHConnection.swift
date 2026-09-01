import AppKit

enum SSHConnectionStatus: Equatable, Sendable {
    case disabled
    case checking
    case connected
    case disconnected

    var label: String {
        switch self {
        case .disabled: "Disabled"
        case .checking: "Checking…"
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        }
    }
}

@MainActor
private final class SSHStatusSpinnerView: NSView {
    var color: NSColor = .labelColor {
        didSet { ringLayer.strokeColor = color.cgColor }
    }

    private let ringLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        ringLayer.fillColor = NSColor.clear.cgColor
        ringLayer.lineCap = .round
        ringLayer.lineWidth = 1.5
        ringLayer.strokeStart = 0.08
        ringLayer.strokeEnd = 0.82
        layer?.addSublayer(ringLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layout() {
        super.layout()
        ringLayer.frame = bounds
        let inset = ringLayer.lineWidth / 2
        ringLayer.path = CGPath(
            ellipseIn: bounds.insetBy(dx: inset, dy: inset),
            transform: nil
        )
    }

    func startAnimating() {
        guard ringLayer.animation(forKey: "spin") == nil else { return }
        let animation = CABasicAnimation(keyPath: "transform.rotation")
        animation.fromValue = 0
        animation.toValue = 2 * Double.pi
        animation.duration = 0.8
        animation.repeatCount = .infinity
        ringLayer.add(animation, forKey: "spin")
    }

    func stopAnimating() {
        ringLayer.removeAnimation(forKey: "spin")
    }
}

@MainActor
final class SSHConnectionStatusIndicator: NSView {
    var status: SSHConnectionStatus {
        didSet { update() }
    }

    private let dot = NSView()
    private let spinner = SSHStatusSpinnerView(frame: .zero)

    init(status: SSHConnectionStatus) {
        self.status = status
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        addSubview(spinner)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 8),
            heightAnchor.constraint(equalToConstant: 8),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor),
            dot.topAnchor.constraint(equalTo: topAnchor),
            dot.bottomAnchor.constraint(equalTo: bottomAnchor),
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor),
            spinner.trailingAnchor.constraint(equalTo: trailingAnchor),
            spinner.topAnchor.constraint(equalTo: topAnchor),
            spinner.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel("SSH connection status")
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func update() {
        let color = AppTheme.connectionStatusColor(status)
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 4
        dot.isHidden = status == .checking
        spinner.color = AppTheme.tertiaryText
        spinner.isHidden = status != .checking
        if status == .checking {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        setAccessibilityValue(status.label)
        toolTip = status.label
    }
}

@MainActor
final class SSHConnectionStatusMonitor {
    private(set) var statuses: [UUID: SSHConnectionStatus] = [:]
    private var connections: [UUID: SSHConnection] = [:]
    private var checkTasks: [UUID: Task<Void, Never>] = [:]
    private var pollingTask: Task<Void, Never>?
    private var observers: [UUID: () -> Void] = [:]

    deinit {
        checkTasks.values.forEach { $0.cancel() }
        pollingTask?.cancel()
    }

    @discardableResult
    func addObserver(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    func sync(_ values: [SSHConnection]) {
        let next = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        for id in connections.keys where next[id] == nil {
            checkTasks[id]?.cancel()
            checkTasks[id] = nil
            statuses[id] = nil
        }
        connections = next

        for connection in values {
            guard connection.isEnabled else {
                checkTasks[connection.id]?.cancel()
                checkTasks[connection.id] = nil
                setStatus(.disabled, for: connection.id)
                continue
            }
            if checkTasks[connection.id] == nil,
               statuses[connection.id] == nil || statuses[connection.id] == .disabled
            {
                startCheck(for: connection)
            }
        }

        if values.contains(where: \.isEnabled) {
            startPolling()
        } else {
            pollingTask?.cancel()
            pollingTask = nil
        }
    }

    func refresh() {
        connections.values.filter(\.isEnabled).forEach {
            guard checkTasks[$0.id] == nil else { return }
            startCheck(for: $0)
        }
    }

    func beginExternalCheck(for connection: SSHConnection) {
        guard connection.isEnabled, connections[connection.id] == connection else { return }
        checkTasks[connection.id]?.cancel()
        checkTasks[connection.id] = nil
        if statuses[connection.id] != .connected {
            setStatus(.checking, for: connection.id)
        }
    }

    func completeExternalCheck(
        for connection: SSHConnection,
        status: SSHConnectionStatus
    ) {
        guard connection.isEnabled, connections[connection.id] == connection else { return }
        checkTasks[connection.id] = nil
        setStatus(status, for: connection.id)
    }

    func status(for connectionID: UUID) -> SSHConnectionStatus {
        statuses[connectionID] ?? .disabled
    }

    func name(for connectionID: UUID) -> String? {
        connections[connectionID]?.name
    }

    private func startCheck(for connection: SSHConnection) {
        guard checkTasks[connection.id] == nil else { return }
        if statuses[connection.id] != .connected {
            setStatus(.checking, for: connection.id)
        }
        let task = Task { [weak self] in
            let status = await Task.detached(priority: .utility) {
                do {
                    try SSHCommand.test(connection: connection)
                    return SSHConnectionStatus.connected
                } catch is CancellationError {
                    return SSHConnectionStatus.checking
                } catch {
                    return SSHConnectionStatus.disconnected
                }
            }.value
            guard !Task.isCancelled,
                  status != .checking,
                  let self,
                  self.connections[connection.id] == connection,
                  connection.isEnabled
            else { return }
            self.checkTasks[connection.id] = nil
            self.setStatus(status, for: connection.id)
        }
        checkTasks[connection.id] = task
    }

    private func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
                guard !Task.isCancelled, let self, NSApp.isActive else { continue }
                self.refresh()
            }
        }
    }

    private func setStatus(_ status: SSHConnectionStatus, for connectionID: UUID) {
        guard statuses[connectionID] != status else { return }
        statuses[connectionID] = status
        observers.values.forEach { $0() }
    }
}

struct SSHConfigHost: Equatable, Sendable {
    let alias: String
    var aliases: [String]
    var hostName: String?
    var user: String?
    var port: String?
    var identityFile: String?

    init(
        alias: String,
        aliases: [String] = [],
        hostName: String?,
        user: String?,
        port: String? = nil,
        identityFile: String? = nil
    ) {
        self.alias = alias
        self.aliases = aliases.isEmpty ? [alias] : aliases
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
    }

    var detail: String {
        let host = hostName ?? alias
        guard let user, !user.isEmpty else { return host }
        return "\(user)@\(host)"
    }

    var isGitTransport: Bool {
        let values = aliases + [hostName ?? ""]
        return values.contains { value in
            let value = value.lowercased()
            return value == "github.com" || value.hasSuffix(".github.com")
                || value == "gitlab.com" || value.hasSuffix(".gitlab.com")
                || value == "bitbucket.org" || value.hasSuffix(".bitbucket.org")
        }
    }
}

struct SSHConfigReader {
    private let configURL: URL
    private let fileManager: FileManager

    init(configURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let resolvedURL = configURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        self.configURL = resolvedURL
    }

    func loadHosts() throws -> [SSHConfigHost] {
        var visited: Set<URL> = []
        return try loadHosts(from: configURL, visited: &visited)
    }

    private func loadHosts(from url: URL, visited: inout Set<URL>) throws -> [SSHConfigHost] {
        let url = url.standardizedFileURL
        guard fileManager.fileExists(atPath: url.path), visited.insert(url).inserted else { return [] }
        let configuration = try String(contentsOf: url, encoding: .utf8)
        var hosts = Self.parse(configuration)
        for pattern in Self.includePatterns(in: configuration) {
            for includedURL in includeURLs(for: pattern, relativeTo: url) {
                for host in try loadHosts(from: includedURL, visited: &visited) {
                    Self.merge(host, into: &hosts)
                }
            }
        }
        return hosts
    }

    private func includeURLs(for pattern: String, relativeTo configURL: URL) -> [URL] {
        let expanded = pattern.hasPrefix("~/")
            ? fileManager.homeDirectoryForCurrentUser.path + String(pattern.dropFirst())
            : pattern
        let url = URL(fileURLWithPath: expanded, relativeTo: configURL.deletingLastPathComponent())
            .standardizedFileURL
        guard url.lastPathComponent.contains("*") else { return [url] }
        let directory = url.deletingLastPathComponent()
        return (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    static func parse(_ configuration: String) -> [SSHConfigHost] {
        var hosts: [SSHConfigHost] = []
        var activeIndex: Int?

        for rawLine in configuration.split(whereSeparator: \.isNewline) {
            let line = rawLine
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let key = fields.first?.lowercased() else { continue }

            switch key {
            case "host":
                let aliases = fields.dropFirst().filter {
                    !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!")
                }
                guard let alias = aliases.first else {
                    activeIndex = nil
                    continue
                }
                let host = SSHConfigHost(alias: alias, aliases: aliases, hostName: nil, user: nil)
                if let index = hosts.firstIndex(where: { $0.alias == alias }) {
                    Self.merge(host, into: &hosts)
                    activeIndex = index
                } else {
                    hosts.append(host)
                    activeIndex = hosts.count - 1
                }
            case "hostname":
                guard let value = fields.dropFirst().first else { continue }
                if let activeIndex { hosts[activeIndex].hostName = value }
            case "user":
                guard let value = fields.dropFirst().first else { continue }
                if let activeIndex { hosts[activeIndex].user = value }
            case "port":
                guard let value = fields.dropFirst().first else { continue }
                if let activeIndex { hosts[activeIndex].port = value }
            case "identityfile":
                guard let value = fields.dropFirst().first else { continue }
                if let activeIndex { hosts[activeIndex].identityFile = value }
            default:
                continue
            }
        }
        return hosts
    }

    private static func merge(_ candidate: SSHConfigHost, into hosts: inout [SSHConfigHost]) {
        guard let index = hosts.firstIndex(where: { $0.alias == candidate.alias }) else {
            hosts.append(candidate)
            return
        }
        var current = hosts[index]
        current.aliases.append(contentsOf: candidate.aliases.filter { !current.aliases.contains($0) })
        current.hostName = current.hostName ?? candidate.hostName
        current.user = current.user ?? candidate.user
        current.port = current.port ?? candidate.port
        current.identityFile = current.identityFile ?? candidate.identityFile
        hosts[index] = current
    }

    private static func includePatterns(in configuration: String) -> [String] {
        var patterns: [String] = []
        for rawLine in configuration.split(whereSeparator: \.isNewline) {
            let line = rawLine
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.first?.lowercased() == "include" else { continue }
            patterns.append(contentsOf: fields.dropFirst())
        }
        return patterns
    }
}

struct SSHConnection: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var host: String
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String, host: String, isEnabled: Bool) {
        self.id = id
        self.name = name
        self.host = host
        self.isEnabled = isEnabled
    }

    init(id: UUID = UUID(), name: String, host: String) {
        self.init(id: id, name: name, host: host, isEnabled: true)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

enum RepositoryTarget: Codable, Equatable, Sendable {
    case local
    case ssh(UUID)

    private enum Kind: String, Codable {
        case local
        case ssh
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case connectionID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .local:
            self = .local
        case .ssh:
            self = .ssh(try container.decode(UUID.self, forKey: .connectionID))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local:
            try container.encode(Kind.local, forKey: .kind)
        case .ssh(let connectionID):
            try container.encode(Kind.ssh, forKey: .kind)
            try container.encode(connectionID, forKey: .connectionID)
        }
    }
}

struct SSHConnectionStore {
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.pinata.app", isDirectory: true)
            self.fileURL = directory.appendingPathComponent("ssh-connections.json")
        }
    }

    func load() throws -> [SSHConnection] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([SSHConnection].self, from: Data(contentsOf: fileURL))
    }

    func save(_ connections: [SSHConnection]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(connections).write(to: fileURL, options: .atomic)
    }
}

enum TerminalTarget: Codable, Equatable, Sendable {
    case local
    case ssh(SSHConnection)

    private enum Kind: String, Codable {
        case local
        case ssh
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case connection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .local:
            self = .local
        case .ssh:
            self = .ssh(try container.decode(SSHConnection.self, forKey: .connection))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local:
            try container.encode(Kind.local, forKey: .kind)
        case .ssh(let connection):
            try container.encode(Kind.ssh, forKey: .kind)
            try container.encode(connection, forKey: .connection)
        }
    }
}

enum SSHCommand {
    static let connectionTimeout = 10
    static let controlPersistSeconds = 1

    static func makeProcess(
        connection: SSHConnection,
        command: [String],
        controlPath: String? = nil,
        reuseConnection: Bool = false
    ) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments(
            connection: connection,
            command: command.map(shellQuote).joined(separator: " "),
            controlPath: controlPath,
            reuseConnection: reuseConnection
        )
        process.standardInput = FileHandle.nullDevice
        return process
    }

    static func arguments(
        connection: SSHConnection,
        command: String,
        allocateTTY: Bool = false,
        includeExecutableName: Bool = false,
        controlPath: String? = nil,
        reuseConnection: Bool = false
    ) -> [String] {
        let multiplexingArguments: [String]
        if let controlPath {
            multiplexingArguments = [
                "-S", controlPath,
                "-o", "ControlMaster=no",
            ]
        } else if reuseConnection {
            multiplexingArguments = [
                "-o", "ControlMaster=auto",
                "-o", "ControlPersist=60",
            ]
        } else {
            multiplexingArguments = ["-S", "none", "-o", "ControlMaster=no"]
        }

        return (includeExecutableName ? ["ssh"] : []) + [
            "-A",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(connectionTimeout)",
            "-o", "ConnectionAttempts=1",
            "-o", "ClearAllForwardings=yes",
        ]
            + multiplexingArguments
            + (allocateTTY ? ["-tt"] : [])
            + ["--", connection.host, command]
    }

    static func controlMasterArguments(
        connection: SSHConnection,
        controlPath: String
    ) -> [String] {
        [
            "-A",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(connectionTimeout)",
            "-o", "ConnectionAttempts=1",
            "-o", "ClearAllForwardings=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-S", controlPath,
            "-o", "ControlMaster=yes",
            "-o", "ControlPersist=\(controlPersistSeconds)",
            "--", connection.host, "exit",
        ]
    }

    static func controlCommandArguments(
        connection: SSHConnection,
        controlPath: String,
        command: String
    ) -> [String] {
        [
            "-S", controlPath,
            "-O", command,
            "--", connection.host,
        ]
    }

    static func test(connection: SSHConnection, reuseConnection: Bool = false) throws {
        let process = makeProcess(
            connection: connection,
            command: ["exit"],
            reuseConnection: reuseConnection
        )
        let error = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(
                decoding: error.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw SSHConnectionError.failed(message(for: output, connection: connection))
        }
    }

    static func message(for output: String, connection: SSHConnection) -> String {
        let output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.localizedCaseInsensitiveContains("permission denied") {
            return "Authentication failed for \(connection.name)."
        }
        if output.localizedCaseInsensitiveContains("host key verification") {
            return "Host key verification failed for \(connection.name)."
        }
        if output.localizedCaseInsensitiveContains("could not resolve hostname") {
            return "Could not resolve \(connection.host)."
        }
        if output.localizedCaseInsensitiveContains("connection timed out") {
            return "Connection to \(connection.name) timed out."
        }
        return output.isEmpty ? "Could not connect to \(connection.name)." : output
    }

    static func shellQuote(_ value: String) -> String {
        if value == "~" { return "\"$HOME\"" }
        if value.hasPrefix("~/") {
            return "\"$HOME\"/\(shellQuote(String(value.dropFirst(2))))"
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}

final class SSHWorkspaceControlMaster: @unchecked Sendable {
    let connection: SSHConnection
    let controlPath: String

    private let lock = NSLock()

    init(connection: SSHConnection, id: UUID = UUID()) {
        self.connection = connection
        controlPath = "/tmp/pinata-\(id.uuidString.lowercased()).socket"
    }

    deinit {
        stop()
    }

    func ensureConnected() throws {
        lock.lock()
        defer { lock.unlock() }

        if isRunning() { return }
        try? FileManager.default.removeItem(atPath: controlPath)

        let process = Process()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = SSHCommand.controlMasterArguments(
            connection: connection,
            controlPath: controlPath
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = error
        do {
            try process.run()
        } catch {
            throw SSHConnectionError.failed(
                "Could not connect to \(connection.name): \(error.localizedDescription)"
            )
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(
                decoding: error.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw SSHConnectionError.failed(
                SSHCommand.message(for: output, connection: connection)
            )
        }
        guard isRunning() else {
            throw SSHConnectionError.failed("Could not connect to \(connection.name).")
        }
    }

    private func isRunning() -> Bool {
        let process = controlProcess(command: "check")
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func stop() {
        lock.lock()
        defer { lock.unlock() }

        let process = controlProcess(command: "exit")
        if (try? process.run()) != nil {
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(atPath: controlPath)
    }

    private func controlProcess(command: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = SSHCommand.controlCommandArguments(
            connection: connection,
            controlPath: controlPath,
            command: command
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }
}

@MainActor
final class SSHControlMasterPool {
    private var controlMasters: [UUID: SSHWorkspaceControlMaster] = [:]

    func controlMaster(for target: TerminalTarget) -> SSHWorkspaceControlMaster? {
        guard case .ssh(let connection) = target else { return nil }
        if let controlMaster = controlMasters[connection.id] {
            return controlMaster
        }
        let controlMaster = SSHWorkspaceControlMaster(
            connection: connection,
            id: connection.id
        )
        controlMasters[connection.id] = controlMaster
        return controlMaster
    }
}

enum SSHConnectionError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}

enum RemoteZmxInstallerError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}

struct RemoteZmxInstaller: Sendable {
    func isInstalled(on connection: SSHConnection, controlPath: String? = nil) -> Bool {
        (try? run(
            connection: connection,
            controlPath: controlPath,
            script: "command -v zmx >/dev/null 2>&1 || [ -x \"$HOME/.local/bin/zmx\" ]"
        )) ?? false
    }

    func install(on connection: SSHConnection, controlPath: String? = nil) throws {
        _ = try run(
            connection: connection,
            controlPath: controlPath,
            script: Self.installScript()
        )
    }

    static func installScript() -> String {
        """
        set -eu
        case "$(uname -s)-$(uname -m)" in
          Darwin-arm64) asset=macos-aarch64; checksum=a63d6f3edd6d4b38240f8f81513e60e35a898ca520211112d7bc67f610f1f3eb ;;
          Darwin-x86_64) asset=macos-x86_64; checksum=66c57e7963c84881266f9f3acfdb36945c340c016a57061948517f3b303ca7d3 ;;
          Linux-aarch64|Linux-arm64) asset=linux-aarch64; checksum=77599f66124694fae80bbb1d2fa0eafdb8c648b427a048cad90513ecf6136fc9 ;;
          Linux-x86_64|Linux-amd64) asset=linux-x86_64; checksum=8b8783d7b120c9ffd0acf4aee37969054dc0dfef3c4f3a4728d2efd35f2e97a0 ;;
          *) echo "Unsupported remote platform: $(uname -s) $(uname -m)" >&2; exit 1 ;;
        esac
        command -v curl >/dev/null || { echo "curl is required to install zmx." >&2; exit 1; }
        temp="$(mktemp -d)"
        trap "rm -rf \"$temp\"" EXIT
        curl --fail --location --silent --show-error "https://zmx.sh/a/zmx-0.7.0-$asset.tar.gz" -o "$temp/zmx.tar.gz"
        if command -v shasum >/dev/null; then set -- $(shasum -a 256 "$temp/zmx.tar.gz"); else set -- $(sha256sum "$temp/zmx.tar.gz"); fi
        actual="$1"
        [ "$actual" = "$checksum" ] || { echo "zmx checksum verification failed." >&2; exit 1; }
        tar -xzf "$temp/zmx.tar.gz" -C "$temp"
        mkdir -p "$HOME/.local/bin"
        install -m 755 "$temp/zmx" "$HOME/.local/bin/zmx"
        "$HOME/.local/bin/zmx" version
        """
    }

    private func run(
        connection: SSHConnection,
        controlPath: String?,
        script: String
    ) throws -> Bool {
        let process = SSHCommand.makeProcess(
            connection: connection,
            command: ["sh", "-lc", script],
            controlPath: controlPath
        )
        let error = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteZmxInstallerError.failed(message.isEmpty ? "Could not reach \(connection.name)." : message)
        }
        return true
    }
}

enum RemoteDirectoryInspectionError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}

struct FileTreeEntry: Codable, Equatable, Sendable {
    let path: String
    let isDirectory: Bool
    let displayName: String?

    init(path: String, isDirectory: Bool, displayName: String? = nil) {
        self.path = path
        self.isDirectory = isDirectory
        self.displayName = displayName
    }

    var name: String {
        if let displayName { return displayName }
        var end = path.endIndex
        while end > path.startIndex, path[path.index(before: end)] == "/" {
            end = path.index(before: end)
        }
        guard end > path.startIndex else { return path }
        let trimmed = path[..<end]
        guard let separator = trimmed.lastIndex(of: "/") else { return String(trimmed) }
        return String(trimmed[trimmed.index(after: separator)...])
    }
}

struct FileTreeCacheKey: Codable, Hashable, Sendable {
    enum Target: Codable, Hashable, Sendable {
        case local
        case ssh(UUID, String)
    }

    let target: Target
    let path: String

    init(path: String, target: TerminalTarget) {
        self.path = path
        self.target = switch target {
        case .local: .local
        case .ssh(let connection): .ssh(connection.id, connection.host)
        }
    }
}

struct FileTreeCache: Codable, Equatable, Sendable {
    let key: FileTreeCacheKey
    let entries: [String: [FileTreeEntry]]
    let expandedPaths: Set<String>
    let updatedAt: Date
}

struct FileTreeCacheStore: Sendable {
    static let maximumCacheCount = 24

    private let fileURL: URL

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            let directory = isTesting
                ? fileManager.temporaryDirectory.appendingPathComponent(
                    "dev.pinata.app-tests",
                    isDirectory: true
                )
                : fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent(
                        Bundle.main.bundleIdentifier ?? "dev.pinata.app",
                        isDirectory: true
                    )
            self.fileURL = directory.appendingPathComponent("file-tree-cache-v2.json")
        }
    }

    func load() throws -> [FileTreeCacheKey: FileTreeCache] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return [:] }
        let caches = try JSONDecoder().decode([FileTreeCache].self, from: Data(contentsOf: fileURL))
        let deduplicated = caches.reduce(
            into: [FileTreeCacheKey: FileTreeCache]()
        ) { result, cache in
            if result[cache.key]?.updatedAt ?? .distantPast < cache.updatedAt {
                result[cache.key] = cache
            }
        }
        let retainedKeys = Set(
            deduplicated.values
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(Self.maximumCacheCount)
                .map(\.key)
        )
        return deduplicated.filter { retainedKeys.contains($0.key) }
    }

    func save(_ caches: [FileTreeCacheKey: FileTreeCache]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let retained = caches.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(Self.maximumCacheCount)
        try JSONEncoder().encode(Array(retained)).write(to: fileURL, options: .atomic)
    }
}

enum FileTreeInspectionError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}

struct FileTreeInspector: Sendable {
    func children(at path: String, target: TerminalTarget) throws -> [FileTreeEntry] {
        switch target {
        case .local:
            return try localChildren(at: path)
        case .ssh(let connection):
            guard let entries = try remoteChildren(at: [path], connection: connection)[path] else {
                throw FileTreeInspectionError.failed("Remote folder is unavailable.")
            }
            return entries
        }
    }

    func children(
        at paths: [String],
        target: TerminalTarget
    ) throws -> [String: [FileTreeEntry]] {
        guard !paths.isEmpty else { return [:] }
        switch target {
        case .local:
            return paths.reduce(into: [:]) { entries, path in
                entries[path] = try? localChildren(at: path)
            }
        case .ssh(let connection):
            return try remoteChildren(at: paths, connection: connection)
        }
    }

    func directorySignatures(
        at paths: [String],
        connection: SSHConnection
    ) throws -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        let script = paths.enumerated().map { index, path in
            let root = SSHCommand.shellQuote(path)
            return "value=$(stat -c '%Y:%Z:%s' \(root) 2>/dev/null || stat -f '%m:%c:%z' \(root) 2>/dev/null || printf missing); printf '\(index)\\0%s\\0' \"$value\""
        }.joined(separator: "; ")
        let fields = try remoteOutput(script: script, connection: connection)
            .split(separator: "\0", omittingEmptySubsequences: true)
        var signatures: [String: String] = [:]
        var index = fields.startIndex
        while index < fields.endIndex {
            let signatureIndex = fields.index(after: index)
            guard signatureIndex < fields.endIndex,
                  let pathIndex = Int(fields[index]),
                  paths.indices.contains(pathIndex)
            else { break }
            signatures[paths[pathIndex]] = String(fields[signatureIndex])
            index = fields.index(after: signatureIndex)
        }
        return signatures
    }

    private func localChildren(at path: String) throws -> [FileTreeEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: Array(keys),
            options: []
        )
        return Self.sort(urls.map { url in
            let values = try? url.resourceValues(forKeys: keys)
            return FileTreeEntry(
                path: url.path,
                isDirectory: values?.isDirectory == true && values?.isSymbolicLink != true
            )
        })
    }

    private func remoteChildren(
        at paths: [String],
        connection: SSHConnection
    ) throws -> [String: [FileTreeEntry]] {
        let output = try remoteOutput(
            script: Self.remoteListingScript(paths: paths),
            connection: connection
        )
        return Self.parseBatchEntries(output, paths: paths)
    }

    private func remoteOutput(
        script: String,
        connection: SSHConnection
    ) throws -> String {
        let fileManager = FileManager.default
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("pinata-file-tree-\(UUID().uuidString).out")
        let errorURL = fileManager.temporaryDirectory
            .appendingPathComponent("pinata-file-tree-\(UUID().uuidString).err")
        defer {
            try? fileManager.removeItem(at: outputURL)
            try? fileManager.removeItem(at: errorURL)
        }

        guard fileManager.createFile(atPath: outputURL.path, contents: nil),
              fileManager.createFile(atPath: errorURL.path, contents: nil) else {
            throw FileTreeInspectionError.failed("Could not prepare file browser.")
        }

        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        defer {
            try? output.close()
            try? error.close()
        }

        let process = SSHCommand.makeProcess(connection: connection, command: ["sh", "-lc", script])
        process.standardOutput = output
        process.standardError = error
        try process.run()

        let deadline = Date().addingTimeInterval(20)
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                process.waitUntilExit()
                throw CancellationError()
            }
            if Date() >= deadline {
                process.terminate()
                process.waitUntilExit()
                throw FileTreeInspectionError.failed("Remote file listing timed out.")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        try output.synchronize()
        try error.synchronize()
        let stdout = String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
        let stderr = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw FileTreeInspectionError.failed(stderr.isEmpty ? "Could not read remote files." : stderr)
        }
        return stdout
    }

    static func remoteListingScript(paths: [String]) -> String {
        paths.enumerated().map { index, path in
            let root = SSHCommand.shellQuote(path)
            return "root=\(root); if [ -d \"$root\" ]; then printf 'r\\0%s\\0%s\\0' \(index) \"$root\"; for entry in \"$root\"/* \"$root\"/.[!.]* \"$root\"/..?*; do [ -e \"$entry\" ] || [ -L \"$entry\" ] || continue; if [ -d \"$entry\" ] && [ ! -L \"$entry\" ]; then printf 'd\\0%s\\0%s\\0' \(index) \"$entry\"; else printf 'f\\0%s\\0%s\\0' \(index) \"$entry\"; fi; done; fi"
        }.joined(separator: "; ")
    }

    static func parseBatchEntries(
        _ output: String,
        paths: [String]
    ) -> [String: [FileTreeEntry]] {
        var entries: [String: [FileTreeEntry]] = [:]
        let fields = output.split(separator: "\0", omittingEmptySubsequences: true)
        var fieldIndex = fields.startIndex
        while fieldIndex < fields.endIndex {
            let indexField = fields.index(after: fieldIndex)
            let pathField = fields.index(indexField, offsetBy: 1, limitedBy: fields.endIndex)
            guard indexField < fields.endIndex,
                  let pathField,
                  pathField < fields.endIndex,
                  fields[fieldIndex] == "r"
                    || fields[fieldIndex] == "d"
                    || fields[fieldIndex] == "f",
                  let index = Int(fields[indexField]),
                  paths.indices.contains(index)
            else { break }
            let root = paths[index]
            if fields[fieldIndex] == "r" {
                entries[root] = []
            } else if entries[root] != nil {
                entries[root]?.append(
                    FileTreeEntry(
                        path: String(fields[pathField]),
                        isDirectory: fields[fieldIndex] == "d"
                    )
                )
            }
            fieldIndex = fields.index(after: pathField)
        }
        return entries.mapValues(sort)
    }

    private static func sort(_ entries: [FileTreeEntry]) -> [FileTreeEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

struct RemoteDirectoryInspector: Sendable {
    func directories(at path: String, connection: SSHConnection) throws -> [String] {
        try directoryTree(at: path, connection: connection)[path] ?? []
    }

    func directoryTree(at path: String, connection: SSHConnection) throws -> [String: [String]] {
        let fileManager = FileManager.default
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("pinata-remote-directories-\(UUID().uuidString).out")
        let errorURL = fileManager.temporaryDirectory
            .appendingPathComponent("pinata-remote-directories-\(UUID().uuidString).err")
        defer {
            try? fileManager.removeItem(at: outputURL)
            try? fileManager.removeItem(at: errorURL)
        }

        guard fileManager.createFile(atPath: outputURL.path, contents: nil),
              fileManager.createFile(atPath: errorURL.path, contents: nil) else {
            throw RemoteDirectoryInspectionError.failed("Could not prepare remote folder browser.")
        }

        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        defer {
            try? output.close()
            try? error.close()
        }

        let process = SSHCommand.makeProcess(
            connection: connection,
            command: ["sh", "-lc", Self.directoryListingScript(path: path)],
            reuseConnection: true
        )
        process.standardOutput = output
        process.standardError = error
        try process.run()

        let deadline = Date().addingTimeInterval(20)
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                process.waitUntilExit()
                throw CancellationError()
            }
            if Date() >= deadline {
                process.terminate()
                process.waitUntilExit()
                throw RemoteDirectoryInspectionError.failed("Remote folder listing timed out.")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        try output.synchronize()
        try error.synchronize()
        let stdout = String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
        let stderr = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw RemoteDirectoryInspectionError.failed(
                stderr.isEmpty ? "Could not read remote folders." : stderr
            )
        }
        let directories = Self.parseDirectories(stdout)
        if directories.isEmpty, !stderr.isEmpty {
            throw RemoteDirectoryInspectionError.failed(stderr)
        }
        return [path: directories]
    }

    static func directoryListingScript(path: String) -> String {
        let root = SSHCommand.shellQuote(path)
        return "root=\(root); if [ ! -d \"$root\" ]; then printf 'Remote folder is unavailable.\\n' >&2; exit 1; fi; for entry in \"$root\"/* \"$root\"/.[!.]* \"$root\"/..?*; do [ -d \"$entry\" ] && [ ! -L \"$entry\" ] || continue; printf '%s\\0' \"$entry\"; done"
    }

    static func parseDirectories(_ output: String) -> [String] {
        let paths = output.contains("\0")
            ? output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
            : output.split(whereSeparator: \.isNewline).map(String.init)
        return sortDirectories(paths.filter { !$0.isEmpty })
    }

    static func parseDirectoryTree(_ output: String, root: String) -> [String: [String]] {
        [root: parseDirectories(output)]
    }

    private static func sortDirectories(_ paths: [String]) -> [String] {
        paths.sorted { lhs, rhs in
            let leftName = URL(fileURLWithPath: lhs).lastPathComponent
            let rightName = URL(fileURLWithPath: rhs).lastPathComponent
            let leftHidden = leftName.hasPrefix(".")
            let rightHidden = rightName.hasPrefix(".")
            if leftHidden != rightHidden { return !leftHidden }
            return leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
        }
    }

    static func parent(of path: String) -> String? {
        guard path != "~", path != "/" else { return nil }
        if path.hasPrefix("~/") {
            let components = path.dropFirst(2).split(separator: "/")
            return components.count <= 1 ? "~" : "~/" + components.dropLast().joined(separator: "/")
        }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }
}
