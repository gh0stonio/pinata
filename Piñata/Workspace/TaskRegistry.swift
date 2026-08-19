import Foundation

struct TaskRepositoryAttachment: Codable, Equatable, Identifiable, Sendable {
    let repositoryID: UUID
    let name: String
    let worktreePath: String?
    let worktreeProvisioning: WorktreeProvisioningReport?
    var branch: String?
    var pullRequests: [PullRequestSummary]
    var pullRequestNumbers: [Int]
    var pullRequestsFetchedAt: Date?

    init(
        repositoryID: UUID,
        name: String,
        worktreePath: String? = nil,
        worktreeProvisioning: WorktreeProvisioningReport? = nil,
        branch: String? = nil,
        pullRequests: [PullRequestSummary] = [],
        pullRequestNumbers: [Int]? = nil,
        pullRequestsFetchedAt: Date? = nil
    ) {
        self.repositoryID = repositoryID
        self.name = name
        self.worktreePath = worktreePath
        self.worktreeProvisioning = worktreeProvisioning
        self.branch = branch
        self.pullRequests = pullRequests
        self.pullRequestNumbers = pullRequestNumbers ?? pullRequests.map(\.number)
        self.pullRequestsFetchedAt = pullRequestsFetchedAt
    }

    var id: UUID { repositoryID }

    private enum CodingKeys: String, CodingKey {
        case repositoryID, name, worktreePath, worktreeProvisioning, branch
        case pullRequests, pullRequestNumbers, pullRequestsFetchedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        repositoryID = try values.decode(UUID.self, forKey: .repositoryID)
        name = try values.decode(String.self, forKey: .name)
        worktreePath = try values.decodeIfPresent(String.self, forKey: .worktreePath)
        worktreeProvisioning = try values.decodeIfPresent(
            WorktreeProvisioningReport.self,
            forKey: .worktreeProvisioning
        )
        branch = try values.decodeIfPresent(String.self, forKey: .branch)
        pullRequests = try values.decodeIfPresent([PullRequestSummary].self, forKey: .pullRequests) ?? []
        pullRequestNumbers = try values.decodeIfPresent([Int].self, forKey: .pullRequestNumbers)
            ?? pullRequests.map(\.number)
        pullRequestsFetchedAt = try values.decodeIfPresent(Date.self, forKey: .pullRequestsFetchedAt)
    }
}

struct WorkspaceTask: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let repositories: [TaskRepositoryAttachment]
    let createdAt: Date
    let isPinned: Bool

    init(
        id: UUID = UUID(),
        title: String,
        repositories: [TaskRepositoryAttachment] = [],
        createdAt: Date = Date(),
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.repositories = repositories
        self.createdAt = createdAt
        self.isPinned = isPinned
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, repositories, createdAt, isPinned
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        repositories = try values.decode([TaskRepositoryAttachment].self, forKey: .repositories)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}

func reorderTasks(
    _ tasks: [WorkspaceTask],
    moving sourceID: UUID,
    relativeTo targetID: UUID?,
    after: Bool,
    inPinnedSection isPinned: Bool
) -> [WorkspaceTask] {
    guard let sourceIndex = tasks.firstIndex(where: { $0.id == sourceID }) else { return tasks }
    if targetID == sourceID, tasks[sourceIndex].isPinned == isPinned { return tasks }

    var reordered = tasks
    let current = reordered.remove(at: sourceIndex)
    let source = WorkspaceTask(
        id: current.id,
        title: current.title,
        repositories: current.repositories,
        createdAt: current.createdAt,
        isPinned: isPinned
    )
    if let targetID {
        guard
            let targetIndex = reordered.firstIndex(where: { $0.id == targetID }),
            reordered[targetIndex].isPinned == isPinned
        else { return tasks }
        reordered.insert(source, at: targetIndex + (after ? 1 : 0))
    } else {
        let sectionStart = reordered.firstIndex(where: { $0.isPinned == isPinned })
            ?? reordered.endIndex
        reordered.insert(source, at: sectionStart)
    }
    return reordered
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
