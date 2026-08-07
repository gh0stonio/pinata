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

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        branches: [String],
        defaultBranch: String,
        currentBranch: String?,
        remoteURL: String?,
        organization: String?,
        worktreeBasePath: String? = nil
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

struct RepositoryInspector: Sendable {
    func inspect(directory: URL) throws -> RegisteredRepository {
        let root = try gitOutput(["-C", directory.path, "rev-parse", "--show-toplevel"])
        let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
        let name = rootURL.lastPathComponent
        guard !name.isEmpty else { throw RepositoryInspectionError.invalidRepository }

        let branches = try gitOutput(["-C", rootURL.path, "branch", "--format=%(refname:short)"])
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .sorted()
        let currentBranch = nonempty(try? gitOutput(["-C", rootURL.path, "branch", "--show-current"]))
        let remoteURL = nonempty(try? gitOutput(["-C", rootURL.path, "remote", "get-url", "origin"]))
        let remoteDefault = try? gitOutput([
            "-C", rootURL.path,
            "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD",
        ])
        let defaultBranch = nonempty(remoteDefault?.replacingOccurrences(of: "origin/", with: ""))
            ?? currentBranch
            ?? branches.first
            ?? "main"

        return RegisteredRepository(
            name: name,
            path: rootURL.path,
            branches: branches,
            defaultBranch: defaultBranch,
            currentBranch: currentBranch,
            remoteURL: remoteURL,
            organization: remoteURL.flatMap(RepositoryInspector.organization(from:))
        )
    }

    func refresh(_ repository: RegisteredRepository) throws -> RegisteredRepository {
        let inspected = try inspect(directory: URL(fileURLWithPath: repository.path))
        return RegisteredRepository(
            id: repository.id,
            name: repository.name,
            path: inspected.path,
            branches: inspected.branches,
            defaultBranch: repository.defaultBranch,
            currentBranch: inspected.currentBranch,
            remoteURL: inspected.remoteURL,
            organization: inspected.organization,
            worktreeBasePath: repository.worktreeBasePath
        )
    }

    func context(for repository: RegisteredRepository) throws -> RepositoryContext {
        let tags = try gitOutput(["-C", repository.path, "tag", "--list", "--sort=-creatordate"])
            .split(whereSeparator: \.isNewline)
            .prefix(50)
            .map(String.init)
        let worktrees = parseWorktrees(
            try gitOutput(["-C", repository.path, "worktree", "list", "--porcelain"])
        )
        return RepositoryContext(
            tags: tags,
            worktrees: worktrees
        )
    }

    private func gitOutput(_ arguments: [String]) throws -> String {
        try Task.checkCancellation()

        let fileManager = FileManager.default
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("pinata-git-\(UUID().uuidString).stdout")
        guard fileManager.createFile(atPath: outputURL.path, contents: nil) else {
            throw RepositoryInspectionError.gitFailed("Could not create command output file.")
        }
        defer { try? fileManager.removeItem(at: outputURL) }

        let errorURL = fileManager.temporaryDirectory
            .appendingPathComponent("pinata-git-\(UUID().uuidString).stderr")
        guard fileManager.createFile(atPath: errorURL.path, contents: nil) else {
            throw RepositoryInspectionError.gitFailed("Could not create command error file.")
        }
        defer { try? fileManager.removeItem(at: errorURL) }

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer { try? errorHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        try process.run()

        let deadline = Date().addingTimeInterval(30)
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                process.waitUntilExit()
                throw CancellationError()
            }
            if Date() >= deadline {
                process.terminate()
                process.waitUntilExit()
                throw RepositoryInspectionError.gitFailed("Git command timed out.")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        try outputHandle.synchronize()
        try errorHandle.synchronize()
        let output = String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let error = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw arguments.contains("rev-parse")
                ? RepositoryInspectionError.invalidRepository
                : RepositoryInspectionError.gitFailed(
                    error.isEmpty ? (output.isEmpty ? "Git command failed." : output) : error
                )
        }
        return output
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
            .replacingOccurrences(of: ".git", with: "")
        let repositoryPath: Substring?
        if let url = URL(string: trimmed), url.host != nil {
            repositoryPath = url.path.split(separator: "/").first
        } else if let separator = trimmed.lastIndex(of: ":") {
            repositoryPath = trimmed[trimmed.index(after: separator)...]
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
}

struct RepositoryDefaultsStore {
    static let defaultWorktreeBasePath = "~/.pinata/worktrees"
    private static let key = "pinata.repository-defaults.v1"
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
    private let fileManager: FileManager

    init(
        globalBasePath: String,
        fileManager: FileManager = .default
    ) {
        self.globalBasePath = globalBasePath
        self.fileManager = fileManager
    }

    func preparing(
        repository: RegisteredRepository,
        taskID: UUID,
        taskTitle: String
    ) -> WorktreeProvisioningReport {
        let root = WorktreePathResolver.root(
            for: repository,
            globalBasePath: globalBasePath,
            fileManager: fileManager
        )
        let destination = nextAvailableDestination(
            in: root,
            named: WorktreePathResolver.serializedTaskName(taskTitle)
        )
        let remoteBranch = "origin/\(repository.defaultBranch)"
        let branch = "pinata/\(WorktreePathResolver.serializedTaskName(taskTitle))-\(taskID.uuidString.prefix(8).lowercased())"
        return WorktreeProvisioningReport(
            path: destination.path,
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
            "refs/heads/\(repository.defaultBranch):refs/remotes/\(report.baseBranch)",
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
            try fileManager.createDirectory(
                at: URL(fileURLWithPath: report.path).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
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
            finishProgressSteps()
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
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        try pipe.fileHandleForWriting.close()

        var data = Data()
        var pending = ""
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 4_096), !chunk.isEmpty {
            data.append(chunk)
            pending += normalizedOutput(String(decoding: chunk, as: UTF8.self))
            let lines = pending.components(separatedBy: "\n")
            lines.dropLast().forEach(onOutput)
            pending = lines.last ?? ""
        }
        if !pending.isEmpty { onOutput(pending) }
        process.waitUntilExit()

        let result = normalizedOutput(String(decoding: data, as: UTF8.self))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            throw WorktreeProvisioningError.gitFailed(
                result.isEmpty ? "Could not create worktree." : result
            )
        }
        return result
    }

    private func normalizedOutput(_ output: String) -> String {
        output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
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
}
