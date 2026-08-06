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
