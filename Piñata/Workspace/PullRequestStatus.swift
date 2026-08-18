import Foundation

enum PullRequestCheckStatus: String, Codable, Sendable {
    case passed
    case failed
    case pending
    case neutral
    case unknown

    var label: String {
        switch self {
        case .passed: "Passed"
        case .failed: "Failed"
        case .pending: "Pending"
        case .neutral: "Skipped"
        case .unknown: "Unknown"
        }
    }

}

enum PullRequestDisplayStatus: String, Sendable {
    case draft
    case ready
    case issue
    case merged

    var label: String {
        switch self {
        case .draft: "Draft"
        case .ready: "Ready"
        case .issue: "Issue"
        case .merged: "Merged"
        }
    }
}

struct PullRequestCheck: Codable, Equatable, Sendable {
    let name: String
    let status: PullRequestCheckStatus
}

struct PullRequestSummary: Codable, Equatable, Identifiable, Sendable {
    let number: Int
    let title: String
    let state: String
    let isDraft: Bool
    let baseBranch: String
    let headBranch: String
    let headRepositoryOwner: String?
    let mergeable: String?
    let mergeStateStatus: String?
    let reviewDecision: String?
    let checks: [PullRequestCheck]
    let url: String?

    var id: Int { number }

    var isSurfaced: Bool {
        let normalizedState = state.uppercased()
        return normalizedState == "OPEN" || normalizedState == "MERGED"
    }

    var displayStatus: PullRequestDisplayStatus {
        let normalizedState = state.uppercased()
        if normalizedState == "MERGED" {
            return .merged
        }
        if isDraft {
            return .draft
        }
        if normalizedState != "OPEN"
            || mergeable?.uppercased() == "CONFLICTING"
            || mergeStateStatus?.uppercased() == "DIRTY"
            || mergeStateStatus?.uppercased() == "BLOCKED"
            || mergeStateStatus?.uppercased() == "UNSTABLE"
            || reviewDecision?.uppercased() == "CHANGES_REQUESTED"
            || checks.contains(where: { $0.status == .failed })
        {
            return .issue
        }
        return .ready
    }

    var reviewLabel: String {
        switch reviewDecision {
        case "APPROVED": "Approved"
        case "CHANGES_REQUESTED": "Changes requested"
        case "REVIEW_REQUIRED": "Review required"
        default: "No review"
        }
    }

}

enum PullRequestLinkResolver {
    static func url(remoteURL: String?, number: Int) -> URL? {
        guard var value = remoteURL?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("git@"), let separator = value.firstIndex(of: ":") {
            let host = value.dropFirst(4).prefix { $0 != ":" }
            let path = value[value.index(after: separator)...]
            value = "https://\(host)/\(path)"
        } else if value.hasPrefix("ssh://git@") {
            value = "https://" + value.dropFirst("ssh://git@".count)
        } else if value.hasPrefix("git+ssh://git@") {
            value = "https://" + value.dropFirst("git+ssh://git@".count)
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        if value.hasSuffix(".git") {
            value.removeLast(4)
        }
        guard let baseURL = URL(string: value),
              baseURL.scheme == "https" || baseURL.scheme == "http",
              baseURL.host != nil,
              !baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
        else {
            return nil
        }
        return URL(string: "\(value)/pull/\(number)")
    }
}

enum PullRequestAvailability: String, Sendable {
    case idle
    case loading
    case loaded
    case unavailable
}

struct PullRequestRepositoryStatus: Equatable, Sendable {
    let availability: PullRequestAvailability
    let pullRequests: [PullRequestSummary]
    let failureMessage: String?

    static let idle = PullRequestRepositoryStatus(
        availability: .idle,
        pullRequests: [],
        failureMessage: nil
    )

    func related(to branch: String?) -> [PullRequestSummary] {
        guard availability == .loaded || availability == .loading,
              let branch,
              !branch.isEmpty
        else { return [] }
        return PullRequestStack.related(to: branch, in: pullRequests)
    }
}

enum PullRequestStack {
    static func related(
        to branch: String,
        in pullRequests: [PullRequestSummary]
    ) -> [PullRequestSummary] {
        guard !branch.isEmpty else { return [] }

        let pullRequests = pullRequests.filter(\.isSurfaced)

        var result: [PullRequestSummary] = []
        var included = Set<Int>()

        func append(_ pullRequest: PullRequestSummary) {
            guard included.insert(pullRequest.number).inserted else { return }
            result.append(pullRequest)
        }

        var parentBranches = [branch]
        var visitedParentBranches = Set<String>()
        while let currentBranch = parentBranches.popLast() {
            guard visitedParentBranches.insert(currentBranch).inserted else { continue }
            for pullRequest in pullRequests where branchesMatch(pullRequest.headBranch, currentBranch) {
                append(pullRequest)
                parentBranches.append(pullRequest.baseBranch)
            }
        }

        var childBranches = Set(result.map(\.headBranch))
        childBranches.insert(branch)
        var pendingChildBranches = Array(childBranches)
        while pendingChildBranches.popLast() != nil {
            for pullRequest in pullRequests
                where childBranches.contains(where: { branchesMatch(pullRequest.baseBranch, $0) })
                    && !included.contains(pullRequest.number)
            {
                append(pullRequest)
                if childBranches.insert(pullRequest.headBranch).inserted {
                    pendingChildBranches.append(pullRequest.headBranch)
                }
            }
        }

        return sourceToTargetOrder(result)
    }

    private static func sourceToTargetOrder(
        _ pullRequests: [PullRequestSummary]
    ) -> [PullRequestSummary] {
        var remaining = pullRequests
        var ordered: [PullRequestSummary] = []
        let originalOrder = Dictionary(
            uniqueKeysWithValues: pullRequests.enumerated().map { ($0.element.number, $0.offset) }
        )

        while !remaining.isEmpty {
            let candidates = remaining.filter { pullRequest in
                !remaining.contains { dependency in
                    dependency.number != pullRequest.number
                        && branchesMatch(pullRequest.baseBranch, dependency.headBranch)
                }
            }.sorted {
                originalOrder[$0.number, default: 0] < originalOrder[$1.number, default: 0]
            }
            guard !candidates.isEmpty else {
                ordered.append(contentsOf: remaining)
                break
            }
            ordered.append(contentsOf: candidates)
            let candidateNumbers = Set(candidates.map(\.number))
            remaining.removeAll { candidateNumbers.contains($0.number) }
        }
        return ordered
    }

    private static func branchesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedBranch(lhs)
        let right = normalizedBranch(rhs)
        guard left != right else { return true }

        let leftComponents = left.split(separator: "/")
        let rightComponents = right.split(separator: "/")
        guard leftComponents.count > 1, rightComponents.count > 1 else { return false }
        guard leftComponents.dropFirst().joined(separator: "/")
            == rightComponents.dropFirst().joined(separator: "/") else { return false }
        return ["stack", "pinata"].contains(String(leftComponents[0]))
            || ["stack", "pinata"].contains(String(rightComponents[0]))
    }

    private static func normalizedBranch(_ branch: String) -> String {
        var value = branch
        if value.hasPrefix("refs/heads/") {
            value.removeFirst("refs/heads/".count)
        }
        if value.hasPrefix("origin/") {
            value.removeFirst("origin/".count)
        }
        return value
    }
}

struct GitHubCLIProfile: Equatable, Identifiable, Sendable {
    let login: String
    let isActive: Bool

    var id: String { login }
}

struct GitHubCLIProfileResult: Equatable, Sendable {
    let profiles: [GitHubCLIProfile]
    let errorMessage: String?
}

struct PullRequestQueryContext: Equatable, Sendable {
    let path: String
    let target: TerminalTarget
    let branches: [String]
    let ghProfile: String?
}

enum GitHubCLIProfileInspector {
    static func inspect(context: PullRequestQueryContext) -> GitHubCLIProfileResult {
        do {
            let output = try PullRequestCommandRunner.run(
                context: context,
                arguments: ["gh", "auth", "status", "--hostname", "github.com"],
                timeout: 15,
                includeStandardError: true
            )
            let profiles = parse(output)
            return GitHubCLIProfileResult(
                profiles: profiles,
                errorMessage: profiles.isEmpty ? "No GitHub CLI profiles found." : nil
            )
        } catch {
            return GitHubCLIProfileResult(
                profiles: [],
                errorMessage: "GitHub CLI profiles unavailable."
            )
        }
    }

    static func parse(_ output: String) -> [GitHubCLIProfile] {
        let marker = "Logged in to github.com account "
        var profiles: [GitHubCLIProfile] = []
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            if let markerRange = line.range(of: marker) {
                let suffix = line[markerRange.upperBound...]
                let login = suffix.split(whereSeparator: { $0 == " " || $0 == "(" }).first
                if let login, !login.isEmpty {
                    profiles.append(GitHubCLIProfile(login: String(login), isActive: false))
                }
            } else if line.contains("Active account: true"), let index = profiles.indices.last {
                profiles[index] = GitHubCLIProfile(
                    login: profiles[index].login,
                    isActive: true
                )
            }
        }
        return profiles
    }
}

@MainActor
final class PullRequestStatusStore {
    private struct FetchKey: Hashable, Sendable {
        let path: String
        let targetID: String
        let ghProfile: String?

        init(context: PullRequestQueryContext) {
            path = context.path
            targetID = switch context.target {
            case .local: "local"
            case .ssh(let connection): "ssh:\(connection.id.uuidString)"
            }
            ghProfile = context.ghProfile
        }
    }

    private struct Snapshot: Sendable {
        let context: PullRequestQueryContext
        let fetchedAt: Date
        let status: PullRequestRepositoryStatus
    }

    private static let cacheLifetime: TimeInterval = 60
    private var snapshots: [FetchKey: Snapshot] = [:]
    private var refreshTasks: [FetchKey: Task<Void, Never>] = [:]
    private var activeContexts: [FetchKey: PullRequestQueryContext] = [:]

    private(set) var statuses: [UUID: PullRequestRepositoryStatus] = [:]
    var onChange: ((Set<UUID>) -> Void)?

    func seed(_ tasks: [WorkspaceTask]) {
        var cachedByRepository: [UUID: [PullRequestSummary]] = [:]
        var repositoriesWithCache = Set<UUID>()
        for task in tasks {
            for attachment in task.repositories where attachment.pullRequestsFetchedAt != nil {
                repositoriesWithCache.insert(attachment.repositoryID)
                cachedByRepository[attachment.repositoryID, default: []].append(contentsOf: attachment.pullRequests)
            }
        }
        for repositoryID in repositoriesWithCache {
            var pullRequestsByNumber: [Int: PullRequestSummary] = [:]
            for pullRequest in cachedByRepository[repositoryID] ?? [] where pullRequest.isSurfaced {
                pullRequestsByNumber[pullRequest.number] = pullRequest
            }
            let pullRequests = pullRequestsByNumber.values.sorted { $0.number < $1.number }
            statuses[repositoryID] = PullRequestRepositoryStatus(
                availability: .loaded,
                pullRequests: pullRequests,
                failureMessage: nil
            )
        }
    }

    func refresh(_ contexts: [UUID: PullRequestQueryContext]) {
        let groupedContexts = Dictionary(grouping: contexts) { FetchKey(context: $0.value) }
        let activeKeys = Set(groupedContexts.keys)
        for key in Array(refreshTasks.keys) where !activeKeys.contains(key) {
            refreshTasks[key]?.cancel()
            refreshTasks[key] = nil
            activeContexts[key] = nil
        }
        for (key, values) in groupedContexts {
            let repositoryIDs = values.map(\.key)
            let context = PullRequestQueryContext(
                path: values[0].value.path,
                target: values[0].value.target,
                branches: Set(values.flatMap { $0.value.branches }).sorted(),
                ghProfile: values[0].value.ghProfile
            )
            if let activeContext = activeContexts[key], activeContext != context {
                refreshTasks[key]?.cancel()
                refreshTasks[key] = nil
                activeContexts[key] = nil
            }
            if refreshTasks[key] != nil, activeContexts[key] == context {
                continue
            }
            if let snapshot = snapshots[key],
               snapshot.context == context,
               Date().timeIntervalSince(snapshot.fetchedAt) < Self.cacheLifetime
            {
                let hasCachedStatus = repositoryIDs.contains {
                    statuses[$0]?.availability == .loaded
                }
                if snapshot.status.availability == .loaded || !hasCachedStatus {
                    repositoryIDs.forEach { statuses[$0] = snapshot.status }
                }
                continue
            }

            let cachedStatus = repositoryIDs.compactMap { statuses[$0] }
                .first(where: { $0.availability == .loaded })
            let loading = PullRequestRepositoryStatus(
                availability: .loading,
                pullRequests: cachedStatus?.pullRequests ?? [],
                failureMessage: nil
            )
            let didChange = repositoryIDs.contains {
                statuses[$0] != loading
            }
            repositoryIDs.forEach { statuses[$0] = loading }
            if didChange {
                onChange?(Set(repositoryIDs))
            }
            activeContexts[key] = context
            refreshTasks[key] = Task { [weak self] in
                let queryTask = Task.detached(priority: .utility) {
                    PullRequestQuery.load(context: context)
                }
                let status = await withTaskCancellationHandler {
                    await queryTask.value
                } onCancel: {
                    queryTask.cancel()
                }
                guard !Task.isCancelled,
                      let self,
                      self.activeContexts[key] == context
                else { return }
                let cachedStatus = repositoryIDs.compactMap { self.statuses[$0] }
                    .first(where: {
                        $0.availability == .loaded
                            || ($0.availability == .loading && !$0.pullRequests.isEmpty)
                    })
                let displayStatus: PullRequestRepositoryStatus
                if status.availability == .unavailable,
                   let cachedStatus
                {
                    displayStatus = PullRequestRepositoryStatus(
                        availability: .loaded,
                        pullRequests: cachedStatus.pullRequests,
                        failureMessage: status.failureMessage
                    )
                } else {
                    displayStatus = status
                }
                let didChange = repositoryIDs.contains {
                    self.statuses[$0] != displayStatus
                }
                self.snapshots[key] = Snapshot(
                    context: context,
                    fetchedAt: Date(),
                    status: status
                )
                repositoryIDs.forEach { self.statuses[$0] = displayStatus }
                self.refreshTasks[key] = nil
                self.activeContexts[key] = nil
                if didChange {
                    self.onChange?(Set(repositoryIDs))
                }
            }
        }
    }
}

private enum PullRequestQuery {
    private static let branchFields = [
        "number",
        "baseRefName",
        "headRefName",
        "state",
        "mergedAt",
        "url",
    ].joined(separator: ",")

    private static let detailMetadataFields = [
        "number",
        "title",
        "state",
        "isDraft",
        "baseRefName",
        "headRefName",
        "headRepositoryOwner",
        "mergeable",
        "mergeStateStatus",
        "reviewDecision",
        "url",
    ].joined(separator: ",")

    private static let detailFields = [detailMetadataFields, "statusCheckRollup"].joined(separator: ",")

    static func load(context: PullRequestQueryContext) -> PullRequestRepositoryStatus {
        do {
            let references = try loadMetadata(context: context)
            let summaries = references.compactMap(\.summary)
            let relatedNumbers = Set(context.branches.flatMap {
                PullRequestStack.related(to: $0, in: summaries).map(\.number)
            })
            let relatedReferences = references.filter { relatedNumbers.contains($0.number) }
            let enrichedValues = try relatedReferences.map { value in
                let output = try run(
                    context: context,
                    arguments: [
                        "gh",
                        "pr",
                        "view",
                        String(value.number),
                        "--json",
                        detailFields,
                    ]
                )
                return try JSONDecoder().decode(
                    GitHubPullRequest.self,
                    from: Data(output.utf8)
                )
            }
            return PullRequestRepositoryStatus(
                availability: .loaded,
                pullRequests: enrichedValues.compactMap(PullRequestSummary.init),
                failureMessage: nil
            )
        } catch {
            return PullRequestRepositoryStatus(
                availability: .unavailable,
                pullRequests: [],
                failureMessage: failureMessage(for: error, profile: context.ghProfile)
            )
        }
    }

    private static func run(
        context: PullRequestQueryContext,
        arguments: [String],
        timeout: TimeInterval = 30
    ) throws -> String {
        var retry = 0
        while true {
            do {
                return try PullRequestCommandRunner.run(
                    context: context,
                    arguments: arguments,
                    timeout: timeout
                )
            } catch let PullRequestCommandError.failed(message)
                where retry < 2 && isGatewayFailure(message)
            {
                retry += 1
                Thread.sleep(forTimeInterval: Double(retry) * 0.5)
            }
        }
    }

    private static func isGatewayFailure(_ message: String) -> Bool {
        let lowercasedMessage = message.lowercased()
        return lowercasedMessage.contains("http 502")
            || lowercasedMessage.contains("bad gateway")
            || lowercasedMessage.contains("http 504")
            || lowercasedMessage.contains("gateway timeout")
    }

    private static func failureMessage(for error: Error, profile: String?) -> String {
        switch error {
        case PullRequestCommandError.timedOut:
            return "GitHub request timed out."
        case let PullRequestCommandError.failed(message):
            let lowercasedMessage = message.lowercased()
            if lowercasedMessage.contains("http 502") || lowercasedMessage.contains("bad gateway") {
                return "GitHub API returned HTTP 502 (Bad Gateway)."
            }
            if lowercasedMessage.contains("http 504") || lowercasedMessage.contains("gateway timeout") {
                return "GitHub API returned HTTP 504 (Gateway Timeout)."
            }
            if lowercasedMessage.contains("not logged in") || lowercasedMessage.contains("authentication") {
                return profile.map {
                    "gh profile \($0) is not authenticated on this machine."
                } ?? "gh is not authenticated on this machine."
            }
            if lowercasedMessage.contains("http 403") || lowercasedMessage.contains("forbidden")
                || lowercasedMessage.contains("http 404")
                || lowercasedMessage.contains("not found")
            {
                return profile.map {
                    "gh profile \($0) cannot access this repository."
                } ?? "gh profile cannot access this repository."
            }
            if lowercasedMessage.contains("command not found") || lowercasedMessage.contains("no such file") {
                return "gh is not installed on this machine."
            }
            return message.split(whereSeparator: \.isNewline).first.map(String.init)
                ?? "GitHub PR query failed."
        default:
            return "GitHub PR data could not be read."
        }
    }

    private static func loadMetadata(
        context: PullRequestQueryContext
    ) throws -> [GitHubPullRequestReference] {
        let output = try run(
            context: context,
            arguments: [
                "gh",
                "pr",
                "list",
                "--state",
                "all",
                "--author",
                "@me",
                "--limit",
                "2000",
                "--json",
                branchFields,
            ],
            timeout: 120
        )
        return try JSONDecoder().decode(
            [GitHubPullRequestReference].self,
            from: Data(output.utf8)
        )
    }
}

private struct GitHubPullRequestReference: Decodable {
    let number: Int
    let baseRefName: String?
    let headRefName: String?
    let state: String?
    let mergedAt: String?
    let url: String?

    var summary: PullRequestSummary? {
        guard let baseRefName,
              let headRefName,
              let state,
              state.uppercased() == "OPEN" || mergedAt != nil
        else { return nil }
        return PullRequestSummary(
            number: number,
            title: "",
            state: mergedAt == nil ? "OPEN" : "MERGED",
            isDraft: false,
            baseBranch: baseRefName,
            headBranch: headRefName,
            headRepositoryOwner: nil,
            mergeable: nil,
            mergeStateStatus: nil,
            reviewDecision: nil,
            checks: [],
            url: url
        )
    }
}

private struct GitHubPullRequest: Decodable {
    let number: Int
    let title: String
    let state: String
    let isDraft: Bool
    let baseRefName: String?
    let headRefName: String?
    let headRepositoryOwner: GitHubRepositoryOwner?
    let mergeable: String?
    let mergeStateStatus: String?
    let reviewDecision: String?
    let statusCheckRollup: [GitHubCheck]?
    let url: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int.self, forKey: .number)
        title = try container.decode(String.self, forKey: .title)
        state = try container.decode(String.self, forKey: .state).uppercased()
        isDraft = try container.decode(Bool.self, forKey: .isDraft)
        baseRefName = try container.decodeIfPresent(String.self, forKey: .baseRefName)
        headRefName = try container.decodeIfPresent(String.self, forKey: .headRefName)
        headRepositoryOwner = try container.decodeIfPresent(
            GitHubRepositoryOwner.self,
            forKey: .headRepositoryOwner
        )
        mergeable = try container.decodeIfPresent(String.self, forKey: .mergeable)?.uppercased()
        mergeStateStatus = try container.decodeIfPresent(String.self, forKey: .mergeStateStatus)?.uppercased()
        reviewDecision = try container.decodeIfPresent(String.self, forKey: .reviewDecision)?.uppercased()
        statusCheckRollup = try container.decodeIfPresent([GitHubCheck].self, forKey: .statusCheckRollup)
        url = try container.decodeIfPresent(String.self, forKey: .url)
    }

    private enum CodingKeys: String, CodingKey {
        case number, title, state, isDraft, baseRefName, headRefName
        case headRepositoryOwner, mergeable, mergeStateStatus, reviewDecision
        case statusCheckRollup, url
    }
}

private struct GitHubRepositoryOwner: Decodable {
    let login: String?
}

private struct GitHubCheck: Decodable {
    let name: String?
    let context: String?
    let status: String?
    let conclusion: String?
    let state: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        context = try container.decodeIfPresent(String.self, forKey: .context)
        status = try container.decodeIfPresent(String.self, forKey: .status)?.uppercased()
        conclusion = try container.decodeIfPresent(String.self, forKey: .conclusion)?.uppercased()
        state = try container.decodeIfPresent(String.self, forKey: .state)?.uppercased()
    }

    var summary: PullRequestCheck? {
        let value = name ?? context ?? "Check"
        let status: PullRequestCheckStatus
        if let conclusion {
            switch conclusion {
            case "SUCCESS": status = .passed
            case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": status = .failed
            case "SKIPPED", "NEUTRAL": status = .neutral
            default: status = .unknown
            }
        } else if let state {
            switch state {
            case "SUCCESS": status = .passed
            case "FAILURE", "ERROR": status = .failed
            case "PENDING", "EXPECTED": status = .pending
            default: status = .unknown
            }
        } else if self.status == "COMPLETED" {
            status = .unknown
        } else {
            status = .pending
        }
        return PullRequestCheck(name: value, status: status)
    }

    private enum CodingKeys: String, CodingKey {
        case name, context, status, conclusion, state
    }
}

extension PullRequestSummary {
    fileprivate init?(_ value: GitHubPullRequest) {
        guard let baseRefName = value.baseRefName,
              let headRefName = value.headRefName else { return nil }
        self.init(
            number: value.number,
            title: value.title,
            state: value.state,
            isDraft: value.isDraft,
            baseBranch: baseRefName,
            headBranch: headRefName,
            headRepositoryOwner: value.headRepositoryOwner?.login,
            mergeable: value.mergeable,
            mergeStateStatus: value.mergeStateStatus,
            reviewDecision: value.reviewDecision,
            checks: value.statusCheckRollup?.compactMap(\.summary) ?? [],
            url: value.url
        )
    }
}

private enum PullRequestCommandError: Error {
    case timedOut
    case failed(String)
}

private enum PullRequestCommandRunner {
    static func run(
        context: PullRequestQueryContext,
        arguments: [String],
        timeout: TimeInterval = 30,
        includeStandardError: Bool = false
    ) throws -> String {
        try Task.checkCancellation()
        let profileSetup: String
        if let ghProfile = context.ghProfile, !ghProfile.isEmpty {
            profileSetup = "GH_TOKEN=$(gh auth token --hostname github.com --user \(SSHCommand.shellQuote(ghProfile))) && export GH_TOKEN && "
        } else {
            profileSetup = ""
        }
        let script = "cd -- \(SSHCommand.shellQuote(context.path)) && \(profileSetup)exec env GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0 \(arguments.map(SSHCommand.shellQuote).joined(separator: " "))"
        let process: Process
        switch context.target {
        case .local:
            process = Process()
            process.executableURL = URL(fileURLWithPath: UserShell.loginPath)
            process.arguments = ["-lc", script]
        case .ssh(let connection):
            process = SSHCommand.makeProcess(
                connection: connection,
                command: ["sh", "-lc", script],
                reuseConnection: true
            )
        }

        let fileManager = FileManager.default
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("pinata-gh-\(UUID().uuidString).stdout")
        let errorURL = fileManager.temporaryDirectory
            .appendingPathComponent("pinata-gh-\(UUID().uuidString).stderr")
        defer {
            try? fileManager.removeItem(at: outputURL)
            try? fileManager.removeItem(at: errorURL)
        }
        guard fileManager.createFile(atPath: outputURL.path, contents: nil),
              fileManager.createFile(atPath: errorURL.path, contents: nil) else {
            throw PullRequestCommandError.failed("Could not prepare GitHub command.")
        }
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        defer {
            try? output.close()
            try? error.close()
        }
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            try Task.checkCancellation()
            if Date() >= deadline {
                process.terminate()
                process.waitUntilExit()
                throw PullRequestCommandError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        try output.synchronize()
        try error.synchronize()

        let outputText = String(
            decoding: try Data(contentsOf: outputURL),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let errorText = String(
            decoding: try Data(contentsOf: errorURL),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw PullRequestCommandError.failed(
                errorText.isEmpty ? (outputText.isEmpty ? "GitHub command failed." : outputText) : errorText
            )
        }
        guard includeStandardError else { return outputText }
        if outputText.isEmpty { return errorText }
        if errorText.isEmpty { return outputText }
        return "\(outputText)\n\(errorText)"
    }
}
