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

struct RepositoryRemote: Equatable, Sendable {
    let name: String
    let url: String
    let kind: String
}

struct RepositoryWorktree: Equatable, Sendable {
    let path: String
    let branch: String?
}

struct GitHubCLIContext: Equatable, Sendable {
    let executablePath: String?
    let version: String?
    let account: String?
    let repositoryName: String?
    let repositoryURL: String?
    let description: String?
    let defaultBranch: String?

    var authenticationStatus: String {
        guard executablePath != nil else { return "Not installed" }
        return account.map { "Authenticated as \($0)" } ?? "Not authenticated"
    }
}

struct RepositoryContext: Equatable, Sendable {
    let remotes: [RepositoryRemote]
    let tags: [String]
    let worktrees: [RepositoryWorktree]
    let github: GitHubCLIContext
}

enum RepositoryInspectionError: LocalizedError {
    case invalidRepository
    case gitFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRepository:
            "The selected folder is not a Git repository."
        case let .gitFailed(message):
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

    func refresh(_ repository: RegisteredRepository) -> RegisteredRepository {
        guard let inspected = try? inspect(directory: URL(fileURLWithPath: repository.path)) else {
            return repository
        }
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

    func context(for repository: RegisteredRepository) -> RepositoryContext {
        let remotes = parseRemotes(
            try? gitOutput(["-C", repository.path, "remote", "-v"])
        )
        let tags = (try? gitOutput(["-C", repository.path, "tag", "--list", "--sort=-creatordate"]))?
            .split(whereSeparator: \.isNewline)
            .prefix(50)
            .map(String.init) ?? []
        let worktrees = parseWorktrees(
            try? gitOutput(["-C", repository.path, "worktree", "list", "--porcelain"])
        )
        return RepositoryContext(
            remotes: remotes,
            tags: tags,
            worktrees: worktrees,
            github: githubContext(repositoryPath: repository.path)
        )
    }

    private func gitOutput(_ arguments: [String]) throws -> String {
        try commandOutput(executableURL: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments)
    }

    private func commandOutput(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()

        let value = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            let error = String(
                decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            throw arguments.contains("rev-parse")
                ? RepositoryInspectionError.invalidRepository
                : RepositoryInspectionError.gitFailed(error.isEmpty ? "Command failed." : error)
        }
        return value
    }

    private func parseRemotes(_ output: String?) -> [RepositoryRemote] {
        var seen = Set<String>()
        return output?.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 3 else { return nil }
            let kind = fields[2].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            let key = "\(fields[0])\u{0}\(fields[1])\u{0}\(kind)"
            guard seen.insert(key).inserted else { return nil }
            return RepositoryRemote(name: fields[0], url: fields[1], kind: kind)
        } ?? []
    }

    private func parseWorktrees(_ output: String?) -> [RepositoryWorktree] {
        guard let output else { return [] }
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

    private func githubContext(repositoryPath: String) -> GitHubCLIContext {
        guard let executableURL = githubExecutableURL() else {
            return GitHubCLIContext(
                executablePath: nil,
                version: nil,
                account: nil,
                repositoryName: nil,
                repositoryURL: nil,
                description: nil,
                defaultBranch: nil
            )
        }
        let directoryURL = URL(fileURLWithPath: repositoryPath)
        let version = try? commandOutput(executableURL: executableURL, arguments: ["--version"])
            .split(whereSeparator: \.isNewline).first.map(String.init)
        let account = nonempty(try? commandOutput(
            executableURL: executableURL,
            arguments: ["api", "user", "--jq", ".login"]
        ))

        struct GHRepository: Decodable {
            struct Branch: Decodable { let name: String }
            let nameWithOwner: String
            let url: String
            let description: String?
            let defaultBranchRef: Branch?
        }

        let repository: GHRepository? = try? {
            let output = try commandOutput(
                executableURL: executableURL,
                arguments: [
                    "repo", "view", "--json",
                    "nameWithOwner,url,description,defaultBranchRef",
                ],
                currentDirectoryURL: directoryURL
            )
            return try JSONDecoder().decode(GHRepository.self, from: Data(output.utf8))
        }()

        return GitHubCLIContext(
            executablePath: executableURL.path,
            version: version,
            account: account,
            repositoryName: repository?.nameWithOwner,
            repositoryURL: repository?.url,
            description: nonempty(repository?.description),
            defaultBranch: repository?.defaultBranchRef?.name
        )
    }

    private func githubExecutableURL() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh",
        ]
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
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

    init(fileManager: FileManager = .default) {
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.pinata.app", isDirectory: true)
        fileURL = directory.appendingPathComponent("repositories.json")
    }

    func load() -> [RegisteredRepository] {
        guard
            let data = try? Data(contentsOf: fileURL),
            let repositories = try? JSONDecoder().decode([RegisteredRepository].self, from: data)
        else {
            return []
        }
        return repositories
    }

    func save(_ repositories: [RegisteredRepository]) throws {
        try FileManager.default.createDirectory(
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
