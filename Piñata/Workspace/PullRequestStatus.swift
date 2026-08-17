import Foundation

enum PullRequestCheckStatus: String, Sendable {
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

    var compactSymbol: String {
        switch self {
        case .passed: "✓"
        case .failed: "✕"
        case .pending: "◷"
        case .neutral: "−"
        case .unknown: "?"
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

struct PullRequestCheck: Equatable, Sendable {
    let name: String
    let status: PullRequestCheckStatus

    var compactLabel: String {
        "\(status.compactSymbol) \(name)"
    }
}

struct PullRequestSummary: Equatable, Identifiable, Sendable {
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

    var displayStatus: PullRequestDisplayStatus {
        if state == "MERGED" {
            return .merged
        }
        if isDraft {
            return .draft
        }
        if state != "OPEN"
            || mergeable == "CONFLICTING"
            || mergeStateStatus == "DIRTY"
            || mergeStateStatus == "BLOCKED"
            || mergeStateStatus == "UNSTABLE"
            || reviewDecision == "CHANGES_REQUESTED"
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

    var checkSummary: String {
        guard !checks.isEmpty else { return "none" }
        return checks.map(\.compactLabel).joined(separator: ", ")
    }

    var checkCountsLabel: String {
        let passed = checks.count(where: { $0.status == .passed })
        let failed = checks.count(where: { $0.status == .failed })
        let pending = checks.count(where: { $0.status == .pending })
        let neutral = checks.count(where: { $0.status == .neutral })
        let unknown = checks.count(where: { $0.status == .unknown })
        var parts = ["\(checks.count) total"]
        if passed > 0 { parts.append("\(passed) passed") }
        if failed > 0 { parts.append("\(failed) failed") }
        if pending > 0 { parts.append("\(pending) pending") }
        if neutral > 0 { parts.append("\(neutral) skipped") }
        if unknown > 0 { parts.append("\(unknown) unknown") }
        return parts.joined(separator: ", ")
    }

    static func aggregateStatus(for pullRequests: [PullRequestSummary]) -> PullRequestDisplayStatus? {
        guard !pullRequests.isEmpty else { return nil }
        if pullRequests.contains(where: { $0.displayStatus == .issue }) {
            return .issue
        }
        if pullRequests.allSatisfy({ $0.displayStatus == .merged }) {
            return .merged
        }
        if pullRequests.allSatisfy({ $0.displayStatus == .draft }) {
            return .draft
        }
        return .ready
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
        guard availability == .loaded, let branch, !branch.isEmpty else { return [] }
        return PullRequestStack.related(to: branch, in: pullRequests)
    }
}

enum PullRequestStack {
    static func related(
        to branch: String,
        in pullRequests: [PullRequestSummary]
    ) -> [PullRequestSummary] {
        guard !branch.isEmpty else { return [] }

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
            for pullRequest in pullRequests where pullRequest.headBranch == currentBranch {
                append(pullRequest)
                parentBranches.append(pullRequest.baseBranch)
            }
        }

        guard !result.isEmpty else { return [] }

        var childBranches = Set(result.map(\.headBranch))
        var pendingChildBranches = Array(childBranches)
        while pendingChildBranches.popLast() != nil {
            for pullRequest in pullRequests
                where childBranches.contains(pullRequest.baseBranch)
                    && !included.contains(pullRequest.number)
            {
                append(pullRequest)
                if childBranches.insert(pullRequest.headBranch).inserted {
                    pendingChildBranches.append(pullRequest.headBranch)
                }
            }
        }

        return result
    }
}

struct PullRequestQueryContext: Equatable, Sendable {
    let path: String
    let target: TerminalTarget
}

@MainActor
final class PullRequestStatusStore {
    private struct Snapshot: Sendable {
        let context: PullRequestQueryContext
        let fetchedAt: Date
        let status: PullRequestRepositoryStatus
    }

    private static let cacheLifetime: TimeInterval = 60
    private var snapshots: [UUID: Snapshot] = [:]
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]

    private(set) var statuses: [UUID: PullRequestRepositoryStatus] = [:]
    var onChange: (() -> Void)?

    func refresh(_ contexts: [UUID: PullRequestQueryContext]) {
        for (repositoryID, context) in contexts {
            if refreshTasks[repositoryID] != nil {
                continue
            }
            if let snapshot = snapshots[repositoryID],
               snapshot.context == context,
               Date().timeIntervalSince(snapshot.fetchedAt) < Self.cacheLifetime
            {
                statuses[repositoryID] = snapshot.status
                continue
            }

            statuses[repositoryID] = PullRequestRepositoryStatus(
                availability: .loading,
                pullRequests: [],
                failureMessage: nil
            )
            refreshTasks[repositoryID] = Task { [weak self] in
                let status = await Task.detached(priority: .utility) {
                    PullRequestQuery.load(context: context)
                }.value
                guard let self else { return }
                self.snapshots[repositoryID] = Snapshot(
                    context: context,
                    fetchedAt: Date(),
                    status: status
                )
                self.statuses[repositoryID] = status
                self.refreshTasks[repositoryID] = nil
                self.onChange?()
            }
        }
    }
}

private enum PullRequestQuery {
    private static let fields = [
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
        "statusCheckRollup",
        "url",
    ].joined(separator: ",")

    static func load(context: PullRequestQueryContext) -> PullRequestRepositoryStatus {
        do {
            let output = try PullRequestCommandRunner.run(
                context: context,
                arguments: [
                    "gh",
                    "pr",
                    "list",
                    "--state",
                    "all",
                    "--limit",
                    "50",
                    "--json",
                    fields,
                ]
            )
            let values = try JSONDecoder().decode(
                [GitHubPullRequest].self,
                from: Data(output.utf8)
            )
            return PullRequestRepositoryStatus(
                availability: .loaded,
                pullRequests: values.compactMap(PullRequestSummary.init),
                failureMessage: nil
            )
        } catch {
            return PullRequestRepositoryStatus(
                availability: .unavailable,
                pullRequests: [],
                failureMessage: failureMessage(for: error)
            )
        }
    }

    private static func failureMessage(for error: Error) -> String {
        switch error {
        case PullRequestCommandError.timedOut:
            return "GitHub request timed out."
        case let PullRequestCommandError.failed(message):
            let lowercasedMessage = message.lowercased()
            if lowercasedMessage.contains("http 502") || lowercasedMessage.contains("bad gateway") {
                return "GitHub API returned HTTP 502 (Bad Gateway)."
            }
            if lowercasedMessage.contains("not logged in") || lowercasedMessage.contains("authentication") {
                return "gh is not authenticated on this machine."
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
        timeout: TimeInterval = 30
    ) throws -> String {
        try Task.checkCancellation()
        let script = "cd -- \(SSHCommand.shellQuote(context.path)) && exec env GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0 \(arguments.map(SSHCommand.shellQuote).joined(separator: " "))"
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
        return outputText
    }
}
