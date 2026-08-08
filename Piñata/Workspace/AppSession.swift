import Foundation

struct AppSession: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    var activeScope: StoredWorkspaceScope?
    var expandedTaskIDs: Set<UUID>
    var terminalWorkspaces: [StoredTerminalWorkspace]

    init(
        version: Int = Self.currentVersion,
        activeScope: StoredWorkspaceScope? = nil,
        expandedTaskIDs: Set<UUID> = [],
        terminalWorkspaces: [StoredTerminalWorkspace] = []
    ) {
        self.version = version
        self.activeScope = activeScope
        self.expandedTaskIDs = expandedTaskIDs
        self.terminalWorkspaces = terminalWorkspaces
    }
}

enum StoredWorkspaceScope: Codable, Equatable, Sendable {
    case task(UUID)
    case repository(taskID: UUID, repositoryID: UUID)
}

struct StoredTerminalWorkspace: Codable, Equatable, Sendable {
    var scope: StoredWorkspaceScope
    var title: String
    var workingDirectory: String
    var tabs: [StoredTerminalTab]
    var activeTabID: UUID?
    var nextTabNumber: Int
}

struct StoredTerminalTab: Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var terminal: TerminalSessionSnapshot
}

struct AppSessionStore {
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(
                    Bundle.main.bundleIdentifier ?? "dev.pinata.app",
                    isDirectory: true
                )
            self.fileURL = directory.appendingPathComponent("app-session.json")
        }
    }

    func load() throws -> AppSession? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let session = try JSONDecoder().decode(AppSession.self, from: Data(contentsOf: fileURL))
        return session.version == AppSession.currentVersion ? session : nil
    }

    func save(_ session: AppSession) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(session).write(to: fileURL, options: .atomic)
    }
}
