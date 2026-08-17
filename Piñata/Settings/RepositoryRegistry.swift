import Foundation

struct RegisteredRepository: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let path: String
    let branches: [String]
    var defaultBranch: String
    let currentBranch: String?
    let remoteURL: String?
    let organization: String?
    var worktreeBasePath: String?
    var target: RepositoryTarget

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        branches: [String],
        defaultBranch: String,
        currentBranch: String?,
        remoteURL: String?,
        organization: String?,
        worktreeBasePath: String? = nil,
        target: RepositoryTarget = .local
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.branches = branches
        self.defaultBranch = defaultBranch
        self.currentBranch = currentBranch
        self.remoteURL = remoteURL
        self.organization = organization
        self.worktreeBasePath = worktreeBasePath
        self.target = target
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, path, branches, defaultBranch, currentBranch, remoteURL, organization
        case worktreeBasePath, target
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        branches = try container.decode([String].self, forKey: .branches)
        defaultBranch = try container.decode(String.self, forKey: .defaultBranch)
        currentBranch = try container.decodeIfPresent(String.self, forKey: .currentBranch)
        remoteURL = try container.decodeIfPresent(String.self, forKey: .remoteURL)
        organization = try container.decodeIfPresent(String.self, forKey: .organization)
        worktreeBasePath = try container.decodeIfPresent(String.self, forKey: .worktreeBasePath)
        target = try container.decodeIfPresent(RepositoryTarget.self, forKey: .target) ?? .local
    }
}

struct RepositoryWorktree: Equatable, Sendable {
    let path: String
    let branch: String?
}

struct RepositoryContext: Equatable, Sendable {
    let tags: [String]
    let worktrees: [RepositoryWorktree]
}

enum RepositoryInspectionError: LocalizedError {
    case invalidRepository
    case gitFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRepository:
            "The selected folder is not a Git repository."
        case .gitFailed(let message):
            message
        }
    }
}

private enum GitCommandError: Error {
    case timedOut
    case failed(String)
}

private struct GitCommandRunner {
    let connection: SSHConnection?

    func run(
        _ arguments: [String],
        timeout: TimeInterval? = 30,
        onOutput: (String) -> Void = { _ in }
    ) throws -> String {
        try Task.checkCancellation()

        let fileManager = FileManager.default
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("pinata-git-\(UUID().uuidString).stdout")
        guard fileManager.createFile(atPath: outputURL.path, contents: nil) else {
            throw GitCommandError.failed("Could not create command output file.")
        }
        defer { try? fileManager.removeItem(at: outputURL) }

        let errorURL = fileManager.temporaryDirectory
            .appendingPathComponent("pinata-git-\(UUID().uuidString).stderr")
        guard fileManager.createFile(atPath: errorURL.path, contents: nil) else {
            throw GitCommandError.failed("Could not create command error file.")
        }
        defer { try? fileManager.removeItem(at: errorURL) }

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer { try? errorHandle.close() }
        let outputReader = try FileHandle(forReadingFrom: outputURL)
        defer { try? outputReader.close() }
        let errorReader = try FileHandle(forReadingFrom: errorURL)
        defer { try? errorReader.close() }

        let process = Process()
        if let connection {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = SSHCommand.arguments(
                connection: connection,
                command: (["env", "GIT_TERMINAL_PROMPT=0", "git"] + arguments)
                    .map(SSHCommand.shellQuote)
                    .joined(separator: " "),
                reuseConnection: true
            )
        } else {
            process.executableURL = URL(fileURLWithPath: UserShell.loginPath)
            let gitCommand = (["git"] + arguments)
                .map(SSHCommand.shellQuote)
                .joined(separator: " ")
            process.arguments = ["-lc", "exec \(gitCommand)"]
        }
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        try process.run()

        let deadline = timeout.map { Date().addingTimeInterval($0) }
        var standardOutput = GitCommandOutput()
        var standardError = GitCommandOutput()
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                process.waitUntilExit()
                throw CancellationError()
            }
            if let deadline, Date() >= deadline {
                process.terminate()
                process.waitUntilExit()
                throw GitCommandError.timedOut
            }
            try standardOutput.append(
                readAvailable(from: outputReader),
                onOutput: onOutput
            )
            try standardError.append(
                readAvailable(from: errorReader),
                onOutput: onOutput
            )
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()

        try outputHandle.synchronize()
        try errorHandle.synchronize()
        try standardOutput.append(
            readAvailable(from: outputReader),
            onOutput: onOutput
        )
        try standardError.append(
            readAvailable(from: errorReader),
            onOutput: onOutput
        )
        standardOutput.finish(onOutput: onOutput)
        standardError.finish(onOutput: onOutput)

        let output = standardOutput.text
        let error = standardError.text
        guard process.terminationStatus == 0 else {
            throw GitCommandError.failed(
                error.isEmpty ? (output.isEmpty ? "Git command failed." : output) : error
            )
        }
        return output
    }

    private func readAvailable(from handle: FileHandle) throws -> Data {
        let offset = try handle.offset()
        let end = try handle.seekToEnd()
        try handle.seek(toOffset: offset)
        guard end > offset else { return Data() }
        return try handle.read(upToCount: Int(end - offset)) ?? Data()
    }
}

private struct GitCommandOutput {
    private(set) var data = Data()
    private var pending = ""

    mutating func append(
        _ chunk: Data,
        onOutput: (String) -> Void
    ) {
        guard !chunk.isEmpty else { return }
        data.append(chunk)
        pending += normalized(String(decoding: chunk, as: UTF8.self))
        let lines = pending.components(separatedBy: "\n")
        lines.dropLast().forEach(onOutput)
        pending = lines.last ?? ""
    }

    mutating func finish(onOutput: (String) -> Void) {
        if !pending.isEmpty { onOutput(pending) }
    }

    var text: String {
        normalized(String(decoding: data, as: UTF8.self))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalized(_ output: String) -> String {
        output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}

struct RepositoryInspector: Sendable {
    func inspect(directory: URL) throws -> RegisteredRepository {
        try inspect(path: directory.path)
    }

    func inspect(path: String, connection: SSHConnection? = nil) throws -> RegisteredRepository {
        let root = try gitOutput(["-C", path, "rev-parse", "--show-toplevel"], connection: connection)
        let localRoot = connection == nil
            ? URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
            : root
        let name = URL(fileURLWithPath: localRoot).lastPathComponent
        guard !name.isEmpty else { throw RepositoryInspectionError.invalidRepository }

        let branches = try gitOutput(["-C", localRoot, "branch", "--format=%(refname:short)"], connection: connection)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .sorted()
        let currentBranch = nonempty(try? gitOutput(["-C", localRoot, "branch", "--show-current"], connection: connection))
        let remoteURL = nonempty(try? gitOutput(["-C", localRoot, "remote", "get-url", "origin"], connection: connection))
        let remoteDefault = try? gitOutput([
            "-C", localRoot,
            "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD",
        ], connection: connection)
        let defaultBranch = nonempty(remoteDefault?.replacingOccurrences(of: "origin/", with: ""))
            ?? currentBranch
            ?? branches.first
            ?? "main"

        return RegisteredRepository(
            name: name,
            path: localRoot,
            branches: branches,
            defaultBranch: defaultBranch,
            currentBranch: currentBranch,
            remoteURL: remoteURL,
            organization: remoteURL.flatMap(RepositoryInspector.organization(from:)),
            target: connection.map { .ssh($0.id) } ?? .local
        )
    }

    func refresh(_ repository: RegisteredRepository, connection: SSHConnection? = nil) throws -> RegisteredRepository {
        let inspected = try inspect(path: repository.path, connection: connection)
        return RegisteredRepository(
            id: repository.id,
            name: repository.name,
            path: inspected.path,
            branches: inspected.branches,
            defaultBranch: repository.defaultBranch,
            currentBranch: inspected.currentBranch,
            remoteURL: inspected.remoteURL,
            organization: inspected.organization,
            worktreeBasePath: repository.worktreeBasePath,
            target: repository.target
        )
    }

    func context(for repository: RegisteredRepository, connection: SSHConnection? = nil) throws -> RepositoryContext {
        let tags = try gitOutput(["-C", repository.path, "tag", "--list", "--sort=-creatordate"], connection: connection)
            .split(whereSeparator: \.isNewline)
            .prefix(50)
            .map(String.init)
        let worktrees = parseWorktrees(
            try gitOutput(["-C", repository.path, "worktree", "list", "--porcelain"], connection: connection)
        )
        return RepositoryContext(
            tags: tags,
            worktrees: worktrees
        )
    }

    func currentBranch(at path: String, connection: SSHConnection? = nil) throws -> String {
        try gitOutput(["-C", path, "branch", "--show-current"], connection: connection)
    }

    func removeWorktree(
        at path: String,
        branchHint: String?,
        taskID: UUID? = nil,
        from repository: RegisteredRepository,
        connection: SSHConnection? = nil
    ) throws {
        let worktrees = parseWorktrees(
            try gitOutput(
                ["-C", repository.path, "worktree", "list", "--porcelain"],
                connection: connection
            )
        )
        let worktree = worktrees.first {
            let pathMatches = connection == nil
                ? URL(fileURLWithPath: $0.path).standardizedFileURL
                    == URL(fileURLWithPath: path).standardizedFileURL
                : $0.path == path
            return pathMatches
        }
            ?? ownedWorktree(in: worktrees, taskID: taskID, repository: repository, connection: connection)
        let branch = worktree?.branch ?? branchHint
        let pathExists = connection == nil && FileManager.default.fileExists(atPath: path)
        guard worktree != nil || !pathExists else {
            throw RepositoryInspectionError.gitFailed(
                "Could not verify that the path is a Git worktree."
            )
        }

        if let worktree {
            _ = try gitOutput(
                ["-C", repository.path, "worktree", "remove", "--force", worktree.path],
                timeout: 15 * 60,
                connection: connection
            )
            let remainingWorktrees = parseWorktrees(
                try gitOutput(
                    ["-C", repository.path, "worktree", "list", "--porcelain"],
                    connection: connection
                )
            )
            if remainingWorktrees.contains(where: {
                $0.path == worktree.path || $0.branch == branch
            }) {
                throw RepositoryInspectionError.gitFailed(
                    "Could not remove the worktree before deleting its branch."
                )
            }
        }

        if let branch, (taskID != nil || branch.hasPrefix(TaskBranchName.defaultPrefix)), !(try gitOutput(
            ["-C", repository.path, "branch", "--list", branch],
            connection: connection
        )).isEmpty {
            _ = try gitOutput(
                ["-C", repository.path, "branch", "-D", branch],
                connection: connection
            )
        }
    }

    private func ownedWorktree(
        in worktrees: [RepositoryWorktree],
        taskID: UUID?,
        repository: RegisteredRepository,
        connection: SSHConnection?
    ) -> RepositoryWorktree? {
        guard let taskID else { return nil }
        let taskValue = taskID.uuidString.lowercased()
        let repositoryValue = repository.id.uuidString.lowercased()
        return worktrees.first { worktree in
            let ownerTask = try? gitOutput(
                ["-C", worktree.path, "config", "--worktree", "--get", "pinata.task-id"],
                connection: connection
            ).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let ownerRepository = try? gitOutput(
                ["-C", worktree.path, "config", "--worktree", "--get", "pinata.repository-id"],
                connection: connection
            ).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ownerTask == taskValue && ownerRepository == repositoryValue
        }
    }

    private func gitOutput(
        _ arguments: [String],
        timeout: TimeInterval? = 30,
        connection: SSHConnection? = nil
    ) throws -> String {
        do {
            return try GitCommandRunner(connection: connection).run(
                arguments,
                timeout: timeout
            )
        } catch GitCommandError.timedOut {
            throw RepositoryInspectionError.gitFailed("Git command timed out.")
        } catch GitCommandError.failed(let message) {
            throw arguments.contains("rev-parse") && message.localizedCaseInsensitiveContains("not a git repository")
                ? RepositoryInspectionError.invalidRepository
                : RepositoryInspectionError.gitFailed(message)
        }
    }

    private func parseWorktrees(_ output: String) -> [RepositoryWorktree] {
        return output.components(separatedBy: "\n\n").compactMap { block in
            var path: String?
            var branch: String?
            for line in block.split(whereSeparator: \.isNewline).map(String.init) {
                if line.hasPrefix("worktree ") {
                    path = String(line.dropFirst("worktree ".count))
                } else if line.hasPrefix("branch refs/heads/") {
                    branch = String(line.dropFirst("branch refs/heads/".count))
                } else if line == "detached" {
                    branch = "Detached HEAD"
                }
            }
            return path.map { RepositoryWorktree(path: $0, branch: branch) }
        }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func organization(from remoteURL: String) -> String? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.hasSuffix(".git")
            ? String(trimmed.dropLast(4))
            : trimmed
        let repositoryPath: Substring?
        if let url = URL(string: normalized), url.host != nil {
            repositoryPath = url.path.split(separator: "/").first
        } else if let separator = normalized.lastIndex(of: ":") {
            repositoryPath = normalized[normalized.index(after: separator)...]
                .split(separator: "/")
                .first
        } else {
            repositoryPath = nil
        }
        return repositoryPath.map(String.init)
    }
}

struct RepositoryRegistryStore {
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.pinata.app", isDirectory: true)
            self.fileURL = directory.appendingPathComponent("repositories.json")
        }
    }

    func load() throws -> [RegisteredRepository] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode(
            [RegisteredRepository].self,
            from: Data(contentsOf: fileURL)
        )
    }

    func save(_ repositories: [RegisteredRepository]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(repositories).write(to: fileURL, options: .atomic)
    }

    @discardableResult
    func remove(id: UUID) throws -> [RegisteredRepository] {
        let repositories = try load()
        let updated = repositories.filter { $0.id != id }
        guard updated.count != repositories.count else { return repositories }
        try save(updated)
        return updated
    }
}

enum TaskBranchName {
    static let defaultPrefix = "pinata/"

    static func normalizedPrefix(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard error(for: trimmed) == nil else { return nil }
        return trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
    }

    static func error(for value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Enter a branch prefix."
        }
        guard !trimmed.contains("\n"), !trimmed.contains("\r"), !trimmed.contains("\0") else {
            return "Use a single-line branch prefix."
        }

        let prefix = trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
        let namespace = String(prefix.dropLast())
        guard !namespace.isEmpty, !namespace.hasPrefix("/"), !namespace.contains("//") else {
            return "Use a valid Git branch prefix."
        }
        guard !namespace.contains(".."), !namespace.contains("@{") else {
            return "Use a valid Git branch prefix."
        }

        let invalidCharacters = CharacterSet(charactersIn: " ~^:?*[\\\\")
        guard !namespace.unicodeScalars.contains(where: {
            $0.value < 0x20 || $0.value == 0x7F || invalidCharacters.contains($0)
        }) else {
            return "Use a valid Git branch prefix."
        }

        let components = namespace.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ component in
            let value = String(component)
            return !value.isEmpty
                && value != "."
                && value != ".."
                && !value.hasPrefix(".")
                && !value.hasSuffix(".")
                && !value.hasSuffix(".lock")
                && !value.hasPrefix("-")
        }) else {
            return "Use a valid Git branch prefix."
        }
        return nil
    }

    static func branch(
        prefix: String,
        taskTitle: String,
        taskID: UUID
    ) -> String {
        let normalized = normalizedPrefix(prefix) ?? defaultPrefix
        return "\(normalized)\(WorktreePathResolver.serializedTaskName(taskTitle))-\(taskID.uuidString.prefix(8).lowercased())"
    }
}

struct RepositoryDefaultsStore {
    static let defaultWorktreeBasePath = "~/.pinata/worktrees"
    static let defaultTaskBranchPrefix = TaskBranchName.defaultPrefix
    private static let key = "pinata.repository-defaults.v1"
    private static let branchPrefixKey = "pinata.repository-branch-prefix.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadWorktreeBasePath() -> String {
        defaults.string(forKey: Self.key) ?? Self.defaultWorktreeBasePath
    }

    func saveWorktreeBasePath(_ path: String) {
        defaults.set(path, forKey: Self.key)
    }

    func loadTaskBranchPrefix() -> String {
        guard let value = defaults.string(forKey: Self.branchPrefixKey) else {
            return Self.defaultTaskBranchPrefix
        }
        return TaskBranchName.normalizedPrefix(value) ?? Self.defaultTaskBranchPrefix
    }

    func saveTaskBranchPrefix(_ prefix: String) {
        defaults.set(
            TaskBranchName.normalizedPrefix(prefix) ?? Self.defaultTaskBranchPrefix,
            forKey: Self.branchPrefixKey
        )
    }
}

enum WorktreePathValidator {
    static func error(for path: String, allowRepositoryRelative: Bool) -> String? {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        guard !path.contains("\n"), !path.contains("\r"), !path.contains("\0") else {
            return "Use a single-line path."
        }
        if path == "~" || path.hasPrefix("~/") || path.hasPrefix("/") {
            return nil
        }
        if allowRepositoryRelative, path.hasPrefix("./") {
            return nil
        }
        return allowRepositoryRelative
            ? "Use an absolute path, ~/ path, or ./ path."
            : "Use an absolute path or ~/ path."
    }
}

enum WorktreeProvisioningStepStatus: String, Codable, Equatable, Sendable {
    case completed
    case failed
    case running
    case pending
}

struct WorktreeProvisioningStep: Codable, Equatable, Sendable {
    let title: String
    let status: WorktreeProvisioningStepStatus
    let detail: String
}

enum WorktreeProvisioningFailureSummary {
    static func summarize(_ message: String) -> String {
        let cleaned = message
            .replacingOccurrences(
                of: "\u{001B}\\[[0-9;]*[A-Za-z]",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = cleaned
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            return "Worktree creation stopped before completion."
        }
        if lines.count <= 3, cleaned.count <= 360 {
            return lines.joined(separator: "\n")
        }

        let failures = lines.filter { line in
            let value = line.lowercased()
            return value.hasPrefix("fatal:")
                || value.hasPrefix("error:")
                || value.contains("command not found")
                || value.contains("permission denied")
                || value.contains("could not")
                || value.contains("failed")
                || value.contains("exited ")
                || value.contains("exited with")
        }
        guard let failure = failures.last else {
            return "Worktree creation stopped before completion."
        }
        return failure.count > 320
            ? String(failure.prefix(319)) + "…"
            : failure
    }
}

struct WorktreeProvisioningReport: Codable, Equatable, Sendable {
    let path: String
    let branch: String
    let baseBranch: String
    let steps: [WorktreeProvisioningStep]

    var succeeded: Bool {
        steps.allSatisfy { $0.status == .completed }
    }

    var failureMessage: String? {
        steps.first(where: { $0.status == .failed })
            .map { WorktreeProvisioningFailureSummary.summarize($0.detail) }
    }
}

enum WorktreeProvisioningError: LocalizedError {
    case gitFailed(String)

    var errorDescription: String? {
        switch self {
        case .gitFailed(let message): message
        }
    }
}

struct WorktreeProvisioner {
    let globalBasePath: String
    let branchPrefix: String
    let connection: SSHConnection?
    private let fileManager: FileManager

    init(
        globalBasePath: String,
        branchPrefix: String = RepositoryDefaultsStore.defaultTaskBranchPrefix,
        connection: SSHConnection? = nil,
        fileManager: FileManager = .default
    ) {
        self.globalBasePath = globalBasePath
        self.branchPrefix = TaskBranchName.normalizedPrefix(branchPrefix)
            ?? RepositoryDefaultsStore.defaultTaskBranchPrefix
        self.connection = connection
        self.fileManager = fileManager
    }

    func preparing(
        repository: RegisteredRepository,
        taskID: UUID,
        taskTitle: String
    ) -> WorktreeProvisioningReport {
        let name = WorktreePathResolver.serializedTaskName(taskTitle)
        let destination: String
        if connection == nil {
            let root = WorktreePathResolver.root(
                for: repository,
                globalBasePath: globalBasePath,
                fileManager: fileManager
            )
            destination = nextAvailableDestination(in: root, named: name).path
        } else {
            destination = WorktreePathResolver.remoteRoot(
                for: repository,
                globalBasePath: globalBasePath
            ) + "/\(name)"
        }
        let remoteBranch = "origin/\(repository.defaultBranch)"
        let branch = TaskBranchName.branch(
            prefix: branchPrefix,
            taskTitle: taskTitle,
            taskID: taskID
        )
        return WorktreeProvisioningReport(
            path: destination,
            branch: branch,
            baseBranch: remoteBranch,
            steps: [
                pendingStep("Fetch origin"),
                pendingStep("Create branch"),
                pendingStep("Create worktree"),
            ]
        )
    }

    func provision(
        repository: RegisteredRepository,
        taskID: UUID,
        taskTitle: String,
        onUpdate: @escaping @Sendable (WorktreeProvisioningReport) -> Void = { _ in }
    ) -> WorktreeProvisioningReport {
        var report = preparing(
            repository: repository,
            taskID: taskID,
            taskTitle: taskTitle
        )
        onUpdate(report)
        func update(
            _ index: Int,
            status: WorktreeProvisioningStepStatus,
            detail: String
        ) {
            let step = report.steps[index]
            var steps = report.steps
            steps[index] = WorktreeProvisioningStep(
                title: step.title,
                status: status,
                detail: detail
            )
            report = WorktreeProvisioningReport(
                path: report.path,
                branch: report.branch,
                baseBranch: report.baseBranch,
                steps: steps
            )
            onUpdate(report)
        }
        func completeActiveProgressStep() {
            guard let index = report.steps.indices.last(where: {
                $0 >= 3 && report.steps[$0].status == .running
            }) else { return }
            var steps = report.steps
            let step = steps[index]
            steps[index] = WorktreeProvisioningStep(
                title: step.title,
                status: .completed,
                detail: ""
            )
            report = WorktreeProvisioningReport(
                path: report.path,
                branch: report.branch,
                baseBranch: report.baseBranch,
                steps: steps
            )
            onUpdate(report)
        }
        func updateProgress(_ output: String) {
            for title in progressTitles(for: output) {
                guard !report.steps.contains(where: { $0.title == title }) else { continue }
                completeActiveProgressStep()
                var steps = report.steps
                steps.append(WorktreeProvisioningStep(
                    title: title,
                    status: .running,
                    detail: ""
                ))
                report = WorktreeProvisioningReport(
                    path: report.path,
                    branch: report.branch,
                    baseBranch: report.baseBranch,
                    steps: steps
                )
                onUpdate(report)
            }
        }
        func finishProgressSteps() {
            var steps = report.steps
            for index in 3..<steps.count where steps[index].status == .running {
                let step = steps[index]
                steps[index] = WorktreeProvisioningStep(
                    title: step.title,
                    status: .completed,
                    detail: ""
                )
            }
            report = WorktreeProvisioningReport(
                path: report.path,
                branch: report.branch,
                baseBranch: report.baseBranch,
                steps: steps
            )
            onUpdate(report)
        }

        let fetchArguments = [
            "-C", repository.path,
            "fetch", "origin",
            "refs/heads/\(repository.defaultBranch):refs/remotes/origin/\(repository.defaultBranch)",
        ]
        update(0, status: .running, detail: "Running…")
        let fetch = runStep(
            report.steps[0].title,
            arguments: fetchArguments,
            onOutput: { _ in }
        )
        update(0, status: fetch.status, detail: fetch.detail)
        guard fetch.status == .completed else { return report }

        update(1, status: .running, detail: "Running…")
        let createBranch = runStep(
            report.steps[1].title,
            arguments: ["-C", repository.path, "branch", report.branch, report.baseBranch],
            onOutput: { _ in }
        )
        update(1, status: createBranch.status, detail: createBranch.detail)
        guard createBranch.status == .completed else { return report }

        update(2, status: .running, detail: "Running…")
        do {
            try prepareDestinationParent(for: report.path)
        } catch {
            update(2, status: .failed, detail: error.localizedDescription)
            return report
        }
        let addWorktree = runStep(
            report.steps[2].title,
            arguments: ["-C", repository.path, "worktree", "add", report.path, report.branch],
            onOutput: { output in
                updateProgress(output)
            }
        )
        update(2, status: addWorktree.status, detail: addWorktree.detail)
        if addWorktree.status == .completed {
            do {
                update(2, status: .running, detail: "Recording ownership…")
                _ = try runGit(
                    ["-C", repository.path, "config", "extensions.worktreeConfig", "true"],
                    onOutput: { _ in }
                )
                _ = try runGit(
                    ["-C", report.path, "config", "--worktree", "pinata.task-id", taskID.uuidString],
                    onOutput: { _ in }
                )
                _ = try runGit(
                    ["-C", report.path, "config", "--worktree", "pinata.repository-id", repository.id.uuidString],
                    onOutput: { _ in }
                )
                finishProgressSteps()
                update(2, status: .completed, detail: "")
            } catch {
                update(2, status: .failed, detail: error.localizedDescription)
            }
        }
        return report
    }

    private func nextAvailableDestination(in root: URL, named name: String) -> URL {
        var suffix = 1
        var destination = root.appendingPathComponent(name, isDirectory: true)
        while fileManager.fileExists(atPath: destination.path) {
            suffix += 1
            destination = root.appendingPathComponent("\(name)-\(suffix)", isDirectory: true)
        }
        return destination
    }

    private func runStep(
        _ title: String,
        arguments: [String],
        onOutput: (String) -> Void = { _ in }
    ) -> WorktreeProvisioningStep {
        do {
            _ = try runGit(arguments, onOutput: onOutput)
            return WorktreeProvisioningStep(
                title: title,
                status: .completed,
                detail: ""
            )
        } catch {
            return WorktreeProvisioningStep(
                title: title,
                status: .failed,
                detail: WorktreeProvisioningFailureSummary.summarize(error.localizedDescription)
            )
        }
    }

    private func pendingStep(_ title: String) -> WorktreeProvisioningStep {
        WorktreeProvisioningStep(
            title: title,
            status: .pending,
            detail: ""
        )
    }

    private func runGit(
        _ arguments: [String],
        onOutput: (String) -> Void
    ) throws -> String {
        do {
            return try GitCommandRunner(connection: connection).run(
                arguments,
                timeout: 15 * 60,
                onOutput: onOutput
            )
        } catch GitCommandError.timedOut {
            throw WorktreeProvisioningError.gitFailed("Git command timed out.")
        } catch GitCommandError.failed(let message) {
            throw WorktreeProvisioningError.gitFailed(
                message.isEmpty ? "Could not create worktree." : message
            )
        }
    }

    private func prepareDestinationParent(for path: String) throws {
        if let connection {
            let process = SSHCommand.makeProcess(
                connection: connection,
                command: ["mkdir", "-p", remoteParentPath(of: path)]
            )
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            try pipe.fileHandleForWriting.close()
            let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
            try pipe.fileHandleForReading.close()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw WorktreeProvisioningError.gitFailed(
                    String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        } else {
            try fileManager.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
    }

    private func progressTitles(for output: String) -> [String] {
        var titles: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let value = line.lowercased()
            if value.contains("preparing worktree") { titles.append("Preparing worktree") }
            if value.contains("updating files") { titles.append("Copying files") }
            if value.contains("checking out files") { titles.append("Checking out files") }
            if value.contains("receiving objects") { titles.append("Receiving changes") }
            if value.contains("resolving deltas") { titles.append("Resolving changes") }
            if value.contains("post-worktree") { titles.append("Run post-worktree hook") }
            if value.contains("post-checkout") { titles.append("Run post-checkout hook") }
            if value.contains("setup.sh") || value.contains("post-install") {
                titles.append("Run setup script")
            }
        }
        return titles
    }

    private func remoteParentPath(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        let parent = String(path[..<slash])
        return parent.isEmpty ? "/" : parent
    }
}

enum WorktreePathResolver {
    static func serializedTaskName(_ title: String) -> String {
        let normalized = title.folding(
            options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive],
            locale: .current
        ).lowercased()
        let words = normalized.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let value = words.filter { !$0.isEmpty }.joined(separator: "-")
        return value.isEmpty ? "task" : value
    }

    static func root(
        for repository: RegisteredRepository,
        globalBasePath: String,
        fileManager: FileManager = .default
    ) -> URL {
        let usesRepositoryOverride = repository.worktreeBasePath != nil
        let path = repository.worktreeBasePath ?? globalBasePath
        let root: URL
        if path == "~" {
            root = fileManager.homeDirectoryForCurrentUser
        } else if path.hasPrefix("~/") {
            root = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2)))
        } else if path.hasPrefix("./") {
            root = URL(fileURLWithPath: repository.path)
                .appendingPathComponent(String(path.dropFirst(2)))
        } else {
            root = URL(fileURLWithPath: path)
        }
        let standardizedRoot = root.standardizedFileURL
        return usesRepositoryOverride
            ? standardizedRoot
            : standardizedRoot.appendingPathComponent(serializedTaskName(repository.name))
    }

    static func remoteRoot(
        for repository: RegisteredRepository,
        globalBasePath: String
    ) -> String {
        let base = repository.worktreeBasePath ?? globalBasePath
        let root: String
        if base.hasPrefix("./") {
            root = repository.path + "/" + String(base.dropFirst(2))
        } else {
            root = base
        }
        return repository.worktreeBasePath == nil
            ? root + "/" + serializedTaskName(repository.name)
            : root
    }
}
