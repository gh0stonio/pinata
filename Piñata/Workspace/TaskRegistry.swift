import Foundation

struct TaskRepositoryAttachment: Codable, Equatable, Identifiable, Sendable {
    let repositoryID: UUID
    let name: String
    let worktreePath: String?
    let worktreeProvisioning: WorktreeProvisioningReport?

    init(
        repositoryID: UUID,
        name: String,
        worktreePath: String? = nil,
        worktreeProvisioning: WorktreeProvisioningReport? = nil
    ) {
        self.repositoryID = repositoryID
        self.name = name
        self.worktreePath = worktreePath
        self.worktreeProvisioning = worktreeProvisioning
    }

    var id: UUID { repositoryID }
}

struct WorkspaceTask: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let repositories: [TaskRepositoryAttachment]
    let createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        repositories: [TaskRepositoryAttachment] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.repositories = repositories
        self.createdAt = createdAt
    }
}

struct TaskRepositoryScope: Hashable, Sendable {
    let taskID: UUID
    let repositoryID: UUID
}

enum WorkspaceScope: Equatable, Sendable {
    case task(UUID)
    case repository(TaskRepositoryScope)
}

struct TaskRegistryStore {
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
            self.fileURL = directory.appendingPathComponent("tasks.json")
        }
    }

    func load() throws -> [WorkspaceTask] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode(
            [WorkspaceTask].self,
            from: Data(contentsOf: fileURL)
        )
    }

    func save(_ tasks: [WorkspaceTask]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(tasks).write(to: fileURL, options: .atomic)
    }
}
