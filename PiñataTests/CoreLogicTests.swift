import XCTest
import AppKit
@testable import Pinata

final class CoreLogicTests: XCTestCase {
    func testGitHubCLIProfilesParseActiveAccount() {
        let profiles = GitHubCLIProfileInspector.parse("""
        github.com
          ✓ Logged in to github.com account antoine-leveque_ddog (/tmp/gh)
          - Active account: true
          ✓ Logged in to github.com account gh0stonio (/tmp/gh)
          - Active account: false
        """)

        XCTAssertEqual(profiles.map(\.login), ["antoine-leveque_ddog", "gh0stonio"])
        XCTAssertTrue(profiles[0].isActive)
        XCTAssertFalse(profiles[1].isActive)
    }

    func testPullRequestStatusSummarizesChecksAndIssues() {
        let pullRequest = PullRequestSummary(
            number: 42,
            title: "Ship sidebar PR status",
            state: "OPEN",
            isDraft: false,
            baseBranch: "main",
            headBranch: "feature/pr-status",
            headRepositoryOwner: "gh0stonio",
            mergeable: "CONFLICTING",
            mergeStateStatus: "DIRTY",
            reviewDecision: "APPROVED",
            checks: [
                PullRequestCheck(name: "Build", status: .passed),
                PullRequestCheck(name: "Lint", status: .failed),
                PullRequestCheck(name: "Tests", status: .pending),
            ],
            url: "https://github.com/gh0stonio/pinata/pull/42"
        )

        XCTAssertEqual(pullRequest.displayStatus, .issue)
        XCTAssertEqual(pullRequest.checks.map(\.status), [.passed, .failed, .pending])
    }

    func testLoadingPullRequestStatusKeepsCachedStackVisible() {
        let pullRequest = PullRequestSummary(
            number: 44,
            title: "Cached PR",
            state: "OPEN",
            isDraft: false,
            baseBranch: "main",
            headBranch: "feature/cached",
            headRepositoryOwner: "gh0stonio",
            mergeable: nil,
            mergeStateStatus: nil,
            reviewDecision: nil,
            checks: [],
            url: "https://github.com/gh0stonio/pinata/pull/44"
        )
        let status = PullRequestRepositoryStatus(
            availability: .loading,
            pullRequests: [pullRequest],
            failureMessage: nil
        )

        XCTAssertEqual(status.related(to: "feature/cached").map(\.number), [44])
    }

    func testPullRequestDisplayStatusNormalizesPersistedValues() {
        let mergedPullRequest = PullRequestSummary(
            number: 43,
            title: "Merged PR",
            state: "merged",
            isDraft: false,
            baseBranch: "main",
            headBranch: "feature/merged",
            headRepositoryOwner: nil,
            mergeable: nil,
            mergeStateStatus: nil,
            reviewDecision: nil,
            checks: [],
            url: nil
        )

        XCTAssertEqual(mergedPullRequest.displayStatus, .merged)
    }

    func testPullRequestLinkResolverSupportsSSHAndRejectsInvalidRemotes() {
        let url = PullRequestLinkResolver.url(
            remoteURL: "git@ddoghq.github.com:ddoghq/dd-source.git",
            number: 57509
        )

        XCTAssertEqual(url?.absoluteString, "https://ddoghq.github.com/ddoghq/dd-source/pull/57509")
        XCTAssertNil(PullRequestLinkResolver.url(remoteURL: "not-a-remote", number: 57509))
    }

    func testSidebarHoverCorridorProtectsDiagonalTravelOnly() {
        let popoverFrame = NSRect(x: 400, y: 100, width: 400, height: 300)
        let origin = NSPoint(x: 300, y: 250)

        XCTAssertTrue(
            SidebarHoverCorridor.contains(
                NSPoint(x: 356, y: 200),
                from: origin,
                to: popoverFrame
            )
        )
        XCTAssertTrue(
            SidebarHoverCorridor.contains(
                NSPoint(x: popoverFrame.minX, y: 200),
                from: origin,
                to: popoverFrame
            )
        )
        XCTAssertFalse(
            SidebarHoverCorridor.contains(
                NSPoint(x: 356, y: 100),
                from: origin,
                to: popoverFrame
            )
        )
        XCTAssertFalse(
            SidebarHoverCorridor.contains(
                NSPoint(x: 280, y: 250),
                from: origin,
                to: popoverFrame
            )
        )
    }

    @MainActor
    func testPullRequestViewRoutesEachStackedRowToItsOwnURL() {
        let summaries = [
            makeTestPullRequest(number: 57509, head: "feature/list", base: "main"),
            makeTestPullRequest(number: 57510, head: "feature/create", base: "feature/list"),
            makeTestPullRequest(number: 57511, head: "feature/crud", base: "feature/create"),
        ]
        let view = SidebarPullRequestInfoView(
            status: PullRequestRepositoryStatus(
                availability: .loaded,
                pullRequests: summaries,
                failureMessage: nil
            ),
            branch: "feature/crud",
            remoteURL: nil
        )
        view.frame = NSRect(x: 0, y: 0, width: 368, height: view.intrinsicContentSize.height)
        view.layoutSubtreeIfNeeded()

        var openedURLs: [URL] = []
        view.visiblePullRequestRows.forEach { row in
            row.onOpen = { openedURLs.append($0) }
            let rowRect = view.convert(row.frame, from: row.superview!)
            let point = NSPoint(x: rowRect.midX, y: rowRect.midY)
            let hitView = view.hitTest(point) as? SidebarPullRequestInfoRow
            XCTAssertTrue(hitView === row)
            XCTAssertTrue(hitView?.acceptsFirstMouse(for: nil) == true)
            hitView?.mouseDown(with: NSEvent())
        }

        let expectedURLs = summaries
            .compactMap(\.url)
            .compactMap(URL.init(string:))
            .map(\.absoluteString)
        XCTAssertEqual(openedURLs.map(\.absoluteString), expectedURLs)

        let firstRow = view.visiblePullRequestRows[0]
        firstRow.mouseDown(with: NSEvent())
        XCTAssertEqual(openedURLs.last?.absoluteString, expectedURLs[0])
    }

    @MainActor
    func testPullRequestViewShowsLoadingAndEmptyStates() {
        let emptyView = SidebarPullRequestInfoView(
            status: PullRequestRepositoryStatus(
                availability: .loaded,
                pullRequests: [],
                failureMessage: nil
            ),
            branch: "feature/none",
            remoteURL: nil
        )
        emptyView.frame = NSRect(x: 0, y: 0, width: 368, height: emptyView.intrinsicContentSize.height)
        emptyView.layoutSubtreeIfNeeded()

        XCTAssertEqual(emptyView.visibleMessage, "No pull request for this branch.")
        XCTAssertGreaterThan(emptyView.intrinsicContentSize.height, 0)

        let loadingView = SidebarPullRequestInfoView(
            status: PullRequestRepositoryStatus(
                availability: .loading,
                pullRequests: [],
                failureMessage: nil
            ),
            branch: "feature/loading",
            remoteURL: nil
        )
        loadingView.frame = NSRect(x: 0, y: 0, width: 368, height: loadingView.intrinsicContentSize.height)
        loadingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(loadingView.visibleMessage, "Loading GitHub…")
        XCTAssertEqual(loadingView.visibleMessageAlignment, .center)
        XCTAssertFalse(loadingView.isShowingBackgroundRefresh)
    }

    @MainActor
    func testPullRequestRowsStayVisibleAcrossLoadingRefresh() {
        let summaries = [
            makeTestPullRequest(number: 57509, head: "feature/list", base: "main"),
            makeTestPullRequest(number: 57510, head: "feature/create", base: "feature/list"),
            makeTestPullRequest(number: 57511, head: "feature/crud", base: "feature/create"),
        ]
        let loadingView = SidebarPullRequestInfoView(
            status: PullRequestRepositoryStatus(
                availability: .loading,
                pullRequests: summaries,
                failureMessage: nil
            ),
            branch: "feature/crud",
            remoteURL: nil
        )
        loadingView.frame = NSRect(x: 0, y: 0, width: 368, height: loadingView.intrinsicContentSize.height)
        loadingView.layoutSubtreeIfNeeded()

        XCTAssertNil(loadingView.visibleMessage)
        XCTAssertTrue(loadingView.isShowingBackgroundRefresh)
        XCTAssertEqual(loadingView.visiblePullRequestRows.map(\.frame.minY), [0, 48, 96])
        XCTAssertTrue(loadingView.visiblePullRequestRows.allSatisfy {
            $0.frame.size == NSSize(width: 368, height: 44)
        })

        loadingView.update(
            status: PullRequestRepositoryStatus(
                availability: .loaded,
                pullRequests: summaries,
                failureMessage: nil
            ),
            branch: "feature/crud"
        )
        loadingView.frame.size.height = loadingView.intrinsicContentSize.height
        loadingView.layoutSubtreeIfNeeded()

        let rowIDs = loadingView.visiblePullRequestRows.map(ObjectIdentifier.init)
        loadingView.update(
            status: PullRequestRepositoryStatus(
                availability: .loaded,
                pullRequests: summaries,
                failureMessage: nil
            ),
            branch: "feature/crud"
        )

        XCTAssertEqual(loadingView.visiblePullRequestRows.count, 3)
        XCTAssertEqual(loadingView.visiblePullRequestRows.map(ObjectIdentifier.init), rowIDs)
        XCTAssertFalse(loadingView.isShowingBackgroundRefresh)
        XCTAssertTrue(loadingView.visiblePullRequestRows.allSatisfy { $0.frame.height == 44 })
    }

    private func makeTestPullRequest(number: Int, head: String, base: String) -> PullRequestSummary {
        PullRequestSummary(
            number: number,
            title: "PR \(number)",
            state: "OPEN",
            isDraft: false,
            baseBranch: base,
            headBranch: head,
            headRepositoryOwner: "ddoghq",
            mergeable: "MERGEABLE",
            mergeStateStatus: "CLEAN",
            reviewDecision: nil,
            checks: [],
            url: "https://github.com/ddoghq/dd-source/pull/\(number)"
        )
    }

    func testPullRequestStackFindsParentChildAndSharedHeadPRs() {
        func makePR(
            _ number: Int,
            head: String,
            base: String,
            state: String = "OPEN"
        ) -> PullRequestSummary {
            PullRequestSummary(
                number: number,
                title: "PR \(number)",
                state: state,
                isDraft: false,
                baseBranch: base,
                headBranch: head,
                headRepositoryOwner: "gh0stonio",
                mergeable: "MERGEABLE",
                mergeStateStatus: "CLEAN",
                reviewDecision: "APPROVED",
                checks: [],
                url: nil
            )
        }

        let pullRequests = [
            makePR(2, head: "feature/base", base: "main"),
            makePR(3, head: "feature/stack", base: "feature/base"),
            makePR(4, head: "feature/stack", base: "main"),
            makePR(5, head: "feature/child", base: "feature/stack"),
            makePR(6, head: "feature/stack", base: "main", state: "CLOSED"),
            makePR(99, head: "unrelated", base: "main"),
        ]

        let related = PullRequestStack.related(to: "feature/stack", in: pullRequests)

        XCTAssertEqual(Set(related.map(\.number)), Set([2, 3, 4, 5]))
        XCTAssertFalse(related.contains { $0.number == 99 })
        XCTAssertFalse(related.contains { $0.number == 6 })

        let liftoffStack = [
            makePR(57509, head: "antoine.leveque/liftoff-add-v0-backend", base: "main"),
            makePR(
                57510,
                head: "antoine.leveque/liftoff-create",
                base: "antoine.leveque/liftoff-add-v0-backend"
            ),
            makePR(
                57511,
                head: "antoine.leveque/liftoff-crud",
                base: "antoine.leveque/liftoff-create"
            ),
        ]
        let liftoffRelated = PullRequestStack.related(
            to: "stack/liftoff-create",
            in: liftoffStack
        )
        XCTAssertEqual(liftoffRelated.map(\.number), [57509, 57510, 57511])
        XCTAssertEqual(Set(liftoffRelated.map(\.number)), Set([57509, 57510, 57511]))

        let retargetedStatus = PullRequestRepositoryStatus(
            availability: .loaded,
            pullRequests: [
                makePR(57509, head: "antoine.leveque/liftoff-add-v0-backend", base: "main", state: "MERGED"),
                makePR(57510, head: "antoine.leveque/liftoff-create", base: "main"),
                makePR(57511, head: "antoine.leveque/liftoff-crud", base: "main"),
            ],
            failureMessage: nil,
            stacks: [[57509, 57510, 57511]]
        )
        XCTAssertEqual(
            retargetedStatus.related(
                to: "stack/liftoff-create",
                preserving: [57510]
            ).map(\.number),
            [57509, 57510, 57511]
        )

        let body = """
        ## Stack
        - Base: #57509
        - This PR: #57510
        - Follow-up: #57511

        ## Testing
        See #99999 for unrelated coverage.
        """
        XCTAssertEqual(
            PullRequestStackReferences.numbers(in: body),
            [57509, 57510, 57511]
        )
    }

    func testEditorLanguageUsesFileExtension() {
        XCTAssertEqual(EditorLanguage(path: "/tmp/app.swift"), .swift)
        XCTAssertEqual(EditorLanguage(path: "/tmp/README.md"), .markdown)
        XCTAssertEqual(EditorLanguage(path: "/tmp/Dockerfile"), .dockerfile)
        XCTAssertEqual(EditorLanguage(path: "/tmp/config.toml"), .toml)
        XCTAssertEqual(EditorLanguage(path: "/tmp/schema.graphql"), .graphql)
        XCTAssertEqual(EditorLanguage(path: "/tmp/.env.local"), .ini)
        XCTAssertEqual(EditorLanguage(path: "/tmp/data.unknown"), .plain)
    }

    func testSyntaxTokenizerProtectsSwiftStringsAndComments() {
        let source = "let value = \"let\" // let"
        let tokens = SyntaxTokenizer.tokens(in: source, language: .swift)

        XCTAssertTrue(tokens.contains { $0.kind == .keyword && (source as NSString).substring(with: $0.range) == "let" })
        XCTAssertTrue(tokens.contains { $0.kind == .string && (source as NSString).substring(with: $0.range) == "\"let\"" })
        XCTAssertTrue(tokens.contains { $0.kind == .comment && (source as NSString).substring(with: $0.range) == "// let" })
        XCTAssertTrue(SyntaxTokenizer.tokens(in: "render(value)", language: .swift).contains { $0.kind == .function })

        let richerSource = "@MainActor\nlet enabled = true\nlet count = 0xFF + 1\nlet text = \"if (value) // not code\""
        let richerTokens = SyntaxTokenizer.tokens(in: richerSource, language: .swift)
        XCTAssertTrue(richerTokens.contains { $0.kind == .decorator })
        XCTAssertTrue(richerTokens.contains { $0.kind == .constant })
        XCTAssertTrue(richerTokens.contains { $0.kind == .number })
        XCTAssertTrue(richerTokens.contains { $0.kind == .operator })
        XCTAssertFalse(richerTokens.contains { token in
            token.kind == .keyword && (richerSource as NSString).substring(with: token.range) == "if"
        })
    }

    func testSyntaxTokenizerHighlightsMarkdownFencesAndInlineSyntax() {
        let markdown = "# Heading\n\n**bold** [link](https://example.com)\n\n```swift\nlet value = 1\n```"
        let tokens = SyntaxTokenizer.tokens(in: markdown, language: .markdown)

        XCTAssertTrue(tokens.contains { $0.kind == .heading })
        XCTAssertTrue(tokens.contains { $0.kind == .emphasis })
        XCTAssertTrue(tokens.contains { $0.kind == .link })
        XCTAssertTrue(tokens.contains { $0.kind == .keyword && (markdown as NSString).substring(with: $0.range) == "let" })
        XCTAssertTrue(tokens.contains { $0.kind == .code })
        XCTAssertTrue(SyntaxTokenizer.tokens(in: "- [x] shipped\n\n---\n", language: .markdown).contains { $0.kind == .markup })
    }

    func testSyntaxTokenizerHighlightsEmbeddedMarkupAndConfigFiles() {
        let document = "<script>const value = 42</script><style>.card { color: #fff }</style><!-- <fake> -->"
        let tokens = SyntaxTokenizer.tokens(in: document, language: .html)

        XCTAssertTrue(tokens.contains { $0.kind == .keyword && (document as NSString).substring(with: $0.range) == "const" }, "embedded JavaScript keyword")
        XCTAssertTrue(tokens.contains { $0.kind == .number && (document as NSString).substring(with: $0.range) == "42" }, "embedded JavaScript number")
        XCTAssertTrue(tokens.contains { $0.kind == .property && (document as NSString).substring(with: $0.range) == "color" }, "embedded CSS property")
        XCTAssertTrue(tokens.contains { $0.kind == .constant && (document as NSString).substring(with: $0.range) == "#fff" }, "embedded CSS color")
        XCTAssertTrue(tokens.contains { $0.kind == .comment }, "HTML comment")

        let toml = SyntaxTokenizer.tokens(in: "[server]\nport = 8080\nenabled = true", language: .toml)
        XCTAssertTrue(toml.contains { $0.kind == .attribute }, "TOML table")
        XCTAssertTrue(toml.contains { $0.kind == .property }, "TOML property")
        XCTAssertTrue(toml.contains { $0.kind == .constant }, "TOML constant")
    }

    func testRegistryStoresRoundTripAndCorruption() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repositoryFileURL = directoryURL.appendingPathComponent("repositories.json")
        let taskFileURL = directoryURL.appendingPathComponent("tasks.json")
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let repository = RegisteredRepository(
            name: "pinata",
            path: "/tmp/pinata",
            branches: ["main"],
            defaultBranch: "main",
            currentBranch: "main",
            remoteURL: nil,
            organization: nil,
            ghProfile: "antoine-leveque_ddog"
        )
        let repositoryStore = RepositoryRegistryStore(fileURL: repositoryFileURL)
        let cachedPullRequest = PullRequestSummary(
            number: 57510,
            title: "Add Liftoff creation endpoint",
            state: "OPEN",
            isDraft: true,
            baseBranch: "antoine.leveque/liftoff-add-v0-backend",
            headBranch: "antoine.leveque/liftoff-create",
            headRepositoryOwner: "antoine.leveque",
            mergeable: "MERGEABLE",
            mergeStateStatus: "CLEAN",
            reviewDecision: nil,
            checks: [PullRequestCheck(name: "ci", status: .passed)],
            url: "https://github.com/ddoghq/dd-source/pull/57510"
        )
        let cachedAt = Date(timeIntervalSince1970: 123)
        let task = WorkspaceTask(
            title: "Build task sidebar",
            repositories: [
                TaskRepositoryAttachment(
                    repositoryID: repository.id,
                    name: repository.name,
                    pullRequests: [cachedPullRequest],
                    pullRequestsFetchedAt: cachedAt
                ),
            ],
            isPinned: true
        )
        let taskStore = TaskRegistryStore(fileURL: taskFileURL)

        XCTAssertEqual(try repositoryStore.load(), [])
        XCTAssertEqual(try taskStore.load(), [])
        try repositoryStore.save([repository])
        try taskStore.save([task])

        XCTAssertEqual(try repositoryStore.load(), [repository])
        XCTAssertEqual(try repositoryStore.load().first?.ghProfile, "antoine-leveque_ddog")
        XCTAssertEqual(try taskStore.load(), [task])
        try Data("{".utf8).write(to: taskFileURL)
        XCTAssertThrowsError(try taskStore.load())
        try Data("{".utf8).write(to: repositoryFileURL)
        XCTAssertThrowsError(try repositoryStore.load())
    }

    func testRepositoryRemovalOnlyChangesTheRegistry() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = RepositoryRegistryStore(fileURL: directoryURL.appendingPathComponent("repos.json"))
        let removed = RegisteredRepository(
            name: "removed",
            path: "/tmp/removed",
            branches: ["main"],
            defaultBranch: "main",
            currentBranch: "main",
            remoteURL: nil,
            organization: nil
        )
        let retained = RegisteredRepository(
            name: "retained",
            path: "/tmp/retained",
            branches: ["main"],
            defaultBranch: "main",
            currentBranch: "main",
            remoteURL: nil,
            organization: nil
        )
        try store.save([removed, retained])

        XCTAssertEqual(try store.remove(id: removed.id), [retained])
        XCTAssertEqual(try store.load(), [retained])
        XCTAssertEqual(try store.remove(id: UUID()), [retained])
    }

    func testSSHConnectionsAndRemoteRepositoriesRoundTrip() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let connection = SSHConnection(name: "Build host", host: "build", isEnabled: false)
        let connectionStore = SSHConnectionStore(fileURL: directoryURL.appendingPathComponent("ssh.json"))
        let repository = RegisteredRepository(
            name: "pinata",
            path: "/srv/pinata",
            branches: ["main"],
            defaultBranch: "main",
            currentBranch: "main",
            remoteURL: "git@example.com:team/pinata.git",
            organization: "team",
            target: .ssh(connection.id)
        )
        let repositoryStore = RepositoryRegistryStore(fileURL: directoryURL.appendingPathComponent("repos.json"))

        try connectionStore.save([connection])
        try repositoryStore.save([repository])

        XCTAssertEqual(try connectionStore.load(), [connection])
        let legacyConnection = try JSONDecoder().decode(
            SSHConnection.self,
            from: Data("{\"id\":\"\(UUID())\",\"name\":\"Legacy\",\"host\":\"legacy\"}".utf8)
        )
        XCTAssertTrue(legacyConnection.isEnabled)
        XCTAssertEqual(try repositoryStore.load(), [repository])
        XCTAssertEqual(
            SSHConfigReader.parse("""
            Host build staging
                HostName ssh.example.com
                User deploy
                Port 2200
                IdentityFile ~/.ssh/deploy
            Host *
                ServerAliveInterval 30
            """),
            [
                SSHConfigHost(
                    alias: "build",
                    aliases: ["build", "staging"],
                    hostName: "ssh.example.com",
                    user: "deploy",
                    port: "2200",
                    identityFile: "~/.ssh/deploy"
                ),
            ]
        )
        XCTAssertTrue(SSHConfigHost(alias: "github.com", hostName: nil, user: nil).isGitTransport)
        let configDirectory = directoryURL.appendingPathComponent("config.d", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try "Include config.d/*\nHost primary\n  HostName primary.example.com\n".write(
            to: directoryURL.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )
        try "Host secondary\n  HostName secondary.example.com\n".write(
            to: configDirectory.appendingPathComponent("secondary"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(
            try SSHConfigReader(configURL: directoryURL.appendingPathComponent("config")).loadHosts().map(\.alias),
            ["primary", "secondary"]
        )
    }

    func testOlderRepositoriesAndTerminalPanesDefaultToLocal() throws {
        let repositoryID = UUID()
        let legacyRepository = Data("""
        {"id":"\(repositoryID.uuidString)","name":"pinata","path":"/tmp/pinata","branches":["main"],"defaultBranch":"main","currentBranch":"main"}
        """.utf8)
        let repository = try JSONDecoder().decode(RegisteredRepository.self, from: legacyRepository)
        XCTAssertEqual(repository.target, .local)

        let paneID = UUID()
        let legacyPane = Data("{\"id\":\"\(paneID.uuidString)\",\"workingDirectory\":\"/tmp\"}".utf8)
        let pane = try JSONDecoder().decode(TerminalPaneSnapshot.self, from: legacyPane)
        XCTAssertEqual(pane.target, .local)
    }

    func testRemoteWorktreePathUsesRemoteBaseWithoutExpandingHome() {
        let repository = RegisteredRepository(
            name: "pinata",
            path: "/srv/pinata",
            branches: ["main"],
            defaultBranch: "main",
            currentBranch: "main",
            remoteURL: nil,
            organization: nil
        )

        XCTAssertEqual(
            WorktreePathResolver.remoteRoot(for: repository, globalBasePath: "~/.pinata/worktrees"),
            "~/.pinata/worktrees/pinata"
        )
    }

    func testRemoteFolderBrowserParsesDirectoriesAndNavigatesParents() {
        XCTAssertEqual(
            RemoteDirectoryInspector.parseDirectories("/srv/.cache\n/srv/api\n/srv/Apps\n\n"),
            ["/srv/api", "/srv/Apps", "/srv/.cache"]
        )
        XCTAssertEqual(
            RemoteDirectoryInspector.parseDirectories("/srv/api\0/srv/Apps\0"),
            ["/srv/api", "/srv/Apps"]
        )
        XCTAssertEqual(
            RemoteDirectoryInspector.parseDirectories("/srv/name\nwith-newline\0"),
            ["/srv/name\nwith-newline"]
        )
        XCTAssertEqual(
            RemoteDirectoryInspector.parseDirectoryTree(
                "/srv/.cache\n/srv/api\n/srv/Apps\n",
                root: "/srv"
            ),
            [
                "/srv": ["/srv/api", "/srv/Apps", "/srv/.cache"],
            ]
        )
        XCTAssertEqual(RemoteDirectoryInspector.parent(of: "~/projects/api"), "~/projects")
        XCTAssertEqual(RemoteDirectoryInspector.parent(of: "~"), nil)
        XCTAssertEqual(RemoteDirectoryInspector.parent(of: "/"), nil)

        XCTAssertEqual(
            FileTreeEntry(path: "/tmp/task-slug", isDirectory: true, displayName: "web-ui").name,
            "web-ui"
        )
        XCTAssertEqual(FileTreeEntry(path: "/srv/Sources/", isDirectory: true).name, "Sources")
        XCTAssertEqual(
            FileTreeInspector.parseBatchEntries(
                "r\u{0}0\u{0}/srv\u{0}d\u{0}0\u{0}/srv/api\u{0}f\u{0}0\u{0}/srv/README.md\u{0}r\u{0}1\u{0}/srv/api\u{0}f\u{0}1\u{0}/srv/api/main\tfile.swift\u{0}r\u{0}2\u{0}/srv/empty\u{0}",
                paths: ["/srv", "/srv/api", "/srv/empty", "/srv/unavailable"]
            ),
            [
                "/srv": [
                    FileTreeEntry(path: "/srv/api", isDirectory: true),
                    FileTreeEntry(path: "/srv/README.md", isDirectory: false),
                ],
                "/srv/api": [
                    FileTreeEntry(path: "/srv/api/main\tfile.swift", isDirectory: false),
                ],
                "/srv/empty": [],
            ]
        )
        XCTAssertEqual(SSHCommand.shellQuote("it's here"), "'it'\"'\"'s here'")
        XCTAssertTrue(
            FileTreeInspector.remoteListingScript(paths: ["/srv"])
                .contains("printf 'r\\0%s\\0%s\\0' 0")
        )
        let remoteDirectoryScript = RemoteDirectoryInspector.directoryListingScript(path: "/srv")
        XCTAssertFalse(remoteDirectoryScript.contains("find"))
        XCTAssertTrue(remoteDirectoryScript.contains("\"$root\"/*"))

        let process = SSHCommand.makeProcess(
            connection: SSHConnection(name: "Build", host: "build"),
            command: ["pwd"]
        )
        XCTAssertTrue(process.arguments?.contains("ClearAllForwardings=yes") == true)
        XCTAssertTrue(process.arguments?.contains("BatchMode=yes") == true)
        XCTAssertTrue(process.arguments?.contains("ConnectTimeout=10") == true)
        XCTAssertNotEqual(process.arguments?.first, "ssh")
        XCTAssertEqual(
            SSHCommand.message(for: "Permission denied (publickey).", connection: .init(name: "Build", host: "build")),
            "Authentication failed for Build."
        )
    }

    func testOlderTasksDefaultToUnpinned() throws {
        let id = UUID()
        let data = Data(
            #"[{"id":"\#(id.uuidString)","title":"Legacy","repositories":[],"createdAt":0}]"#.utf8
        )

        let task = try XCTUnwrap(JSONDecoder().decode([WorkspaceTask].self, from: data).first)
        XCTAssertFalse(task.isPinned)
    }

    func testFileTreeCachePersistsEntriesAndExpansion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileTreeCacheStore(fileURL: directory.appendingPathComponent("cache.json"))
        let key = FileTreeCacheKey(path: "/srv/repo", target: .local)
        let cache = FileTreeCache(
            key: key,
            entries: [
                "/srv/repo": [FileTreeEntry(path: "/srv/repo/Sources", isDirectory: true)],
                "/srv/repo/Sources": [
                    FileTreeEntry(path: "/srv/repo/Sources/main.swift", isDirectory: false),
                ],
            ],
            expandedPaths: ["/srv/repo", "/srv/repo/Sources"],
            updatedAt: Date(timeIntervalSince1970: 1)
        )

        try store.save([key: cache])

        XCTAssertEqual(try store.load(), [key: cache])

        let caches = Dictionary(uniqueKeysWithValues: (0...FileTreeCacheStore.maximumCacheCount).map {
            let key = FileTreeCacheKey(path: "/srv/repo/\($0)", target: .local)
            return (
                key,
                FileTreeCache(
                    key: key,
                    entries: [:],
                    expandedPaths: [],
                    updatedAt: Date(timeIntervalSince1970: TimeInterval($0))
                )
            )
        })
        try JSONEncoder().encode(Array(caches.values)).write(
            to: directory.appendingPathComponent("cache.json")
        )
        XCTAssertEqual(try store.load().count, FileTreeCacheStore.maximumCacheCount)
    }

    @MainActor
    func testFileTreeIconsResolveNamesSuffixesFoldersAndFallbacks() {
        defer { AppTheme.configure(.defaults) }
        XCTAssertEqual(
            FileTreeIconResolver.descriptor(for: "package.json", isDirectory: false).kind,
            .package
        )
        XCTAssertEqual(
            FileTreeIconResolver.descriptor(for: "View.tsx", isDirectory: false).kind,
            .react
        )
        XCTAssertEqual(
            FileTreeIconResolver.descriptor(for: ".github", isDirectory: true).kind,
            .folder
        )
        XCTAssertEqual(
            ["infrastructure", "lib", "components"].map {
                FileTreeIconResolver.descriptor(for: $0, isDirectory: true).kind
            },
            [.folder, .folder, .folder]
        )
        XCTAssertEqual(
            FileTreeIconResolver.descriptor(for: "unknown.zzz", isDirectory: false).kind,
            .file
        )

        let swift = FileTreeIconResolver.descriptor(for: "main.swift", isDirectory: false)
        var settings = UserSettings.defaults
        settings.fileIconColor = .monochrome
        AppTheme.configure(settings)
        XCTAssertEqual(
            rgbHex(FileTreeIconResolver.tintColor(for: swift)),
            rgbHex(AppTheme.secondaryText)
        )
        settings.fileIconColor = .colored
        AppTheme.configure(settings)
        XCTAssertNotEqual(
            rgbHex(FileTreeIconResolver.tintColor(for: swift)),
            rgbHex(AppTheme.secondaryText)
        )
    }

    @MainActor
    func testFileTreeIconCoverageStaysBroad() {
        XCTAssertGreaterThanOrEqual(FileTreeIconKind.allCases.count, 60)
        XCTAssertGreaterThanOrEqual(FileTreeIconResolver.supportedSuffixCount, 200)
    }

    @MainActor
    func testWorkspaceFileOutlineLoadsAndExpandsIncrementally() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sources = directory.appendingPathComponent("Sources", isDirectory: true)
        let nested = sources.appendingPathComponent("Nested/Deep", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(
            atPath: directory.appendingPathComponent("README.md").path,
            contents: Data()
        )
        _ = FileManager.default.createFile(
            atPath: sources.appendingPathComponent("main.swift").path,
            contents: Data()
        )
        _ = FileManager.default.createFile(
            atPath: nested.appendingPathComponent("deep.swift").path,
            contents: Data()
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let batch = try FileTreeInspector().children(
            at: [directory.path, directory.appendingPathComponent("missing").path],
            target: .local
        )
        XCTAssertNotNil(batch[directory.path])
        XCTAssertNil(batch[directory.appendingPathComponent("missing").path])

        let controller = WorkspacePanelViewController(
            fileCacheStore: FileTreeCacheStore(
                fileURL: directory.appendingPathComponent("tree-cache.json")
            )
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        controller.view.layoutSubtreeIfNeeded()
        controller.setFileRoot(
            name: "repo",
            workingDirectory: directory.path,
            target: .local
        )
        let outline = try XCTUnwrap(
            descendants(of: controller.view).compactMap { $0 as? NSOutlineView }.first
        )
        let scrollView = try XCTUnwrap(outline.enclosingScrollView)
        XCTAssertEqual(
            outline.tableColumns[0].width,
            scrollView.contentView.bounds.width,
            accuracy: 0.5
        )
        scrollView.contentView.scroll(to: NSPoint(x: 40, y: 0))
        XCTAssertEqual(scrollView.contentView.bounds.origin.x, 0, accuracy: 0.5)

        for _ in 0..<100 where outline.numberOfRows < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(outline.numberOfRows, 3)
        let rootItem = try XCTUnwrap(outline.item(atRow: 0))
        outline.collapseItem(rootItem)
        XCTAssertFalse(outline.isItemExpanded(rootItem))
        controller.panelDidShow()
        XCTAssertTrue(outline.isItemExpanded(rootItem))
        let sourcesRow = try XCTUnwrap((0..<outline.numberOfRows).first { row in
            descendants(of: outline.view(atColumn: 0, row: row, makeIfNecessary: true) ?? NSView())
                .compactMap { $0 as? NSTextField }
                .contains { $0.stringValue == "Sources" }
        })

        outline.expandItem(outline.item(atRow: sourcesRow))
        XCTAssertTrue(outline.isItemExpanded(outline.item(atRow: sourcesRow)))
        for _ in 0..<100 where outline.numberOfRows < 5 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(outline.numberOfRows, 5)

        let rowNamed: (String) -> Int? = { name in
            (0..<outline.numberOfRows).first { row in
                descendants(
                    of: outline.view(atColumn: 0, row: row, makeIfNecessary: true) ?? NSView()
                )
                .compactMap { $0 as? NSTextField }
                .contains { $0.stringValue == name }
            }
        }
        let nestedRow = try XCTUnwrap(rowNamed("Nested"))
        outline.expandItem(outline.item(atRow: nestedRow))
        for _ in 0..<100 where rowNamed("Deep") == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let deepRow = try XCTUnwrap(rowNamed("Deep"))
        outline.expandItem(outline.item(atRow: deepRow))
        for _ in 0..<100 where outline.numberOfRows < 7 {
            try await Task.sleep(for: .milliseconds(10))
        }

        let sourcesCell = try XCTUnwrap(
            outline.view(atColumn: 0, row: sourcesRow, makeIfNecessary: true)
        )
        let commandClick = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
        sourcesCell.mouseDown(with: commandClick)
        XCTAssertFalse(outline.isItemExpanded(outline.item(atRow: sourcesRow)))

        outline.expandItem(outline.item(atRow: sourcesRow))
        XCTAssertEqual(outline.numberOfRows, 5)
        XCTAssertFalse(outline.isItemExpanded(outline.item(atRow: try XCTUnwrap(rowNamed("Nested")))))

        let createdName = String(repeating: "wide-file-", count: 20) + ".txt"
        _ = FileManager.default.createFile(
            atPath: directory.appendingPathComponent(createdName).path,
            contents: Data()
        )
        for _ in 0..<200 where rowNamed(createdName) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(rowNamed(createdName))
        XCTAssertGreaterThan(outline.tableColumns[0].width, scrollView.contentView.bounds.width)
        scrollView.contentView.scroll(to: NSPoint(x: 40, y: 0))
        XCTAssertGreaterThan(scrollView.contentView.bounds.origin.x, 0)
    }

    func testTaskReorderingMovesWithinAndAcrossSections() {
        let pinnedOne = WorkspaceTask(title: "Pinned one", isPinned: true)
        let regular = WorkspaceTask(title: "Regular")
        let pinnedTwo = WorkspaceTask(title: "Pinned two", isPinned: true)
        let tasks = [pinnedOne, regular, pinnedTwo]

        XCTAssertEqual(
            reorderTasks(
                tasks,
                moving: pinnedTwo.id,
                relativeTo: pinnedOne.id,
                after: false,
                inPinnedSection: true
            ).map(\.title),
            ["Pinned two", "Pinned one", "Regular"]
        )
        let unpinned = reorderTasks(
            tasks,
            moving: pinnedOne.id,
            relativeTo: regular.id,
            after: true,
            inPinnedSection: false
        )
        XCTAssertEqual(unpinned.map(\.title), ["Regular", "Pinned one", "Pinned two"])
        XCTAssertFalse(unpinned[1].isPinned)
    }

    func testTaskReorderingMovesIntoEmptySection() {
        let regular = WorkspaceTask(title: "Regular")
        let pinned = reorderTasks(
            [regular],
            moving: regular.id,
            relativeTo: nil,
            after: false,
            inPinnedSection: true
        )
        XCTAssertEqual(pinned.map(\.title), ["Regular"])
        XCTAssertTrue(pinned[0].isPinned)
    }

    func testTaskReorderingRejectsInvalidDrops() {
        let first = WorkspaceTask(title: "First")
        let second = WorkspaceTask(title: "Second")
        let tasks = [first, second]

        XCTAssertEqual(
            reorderTasks(
                tasks,
                moving: UUID(),
                relativeTo: second.id,
                after: false,
                inPinnedSection: false
            ),
            tasks
        )
        XCTAssertEqual(
            reorderTasks(
                tasks,
                moving: first.id,
                relativeTo: UUID(),
                after: false,
                inPinnedSection: false
            ),
            tasks
        )
    }

    func testAppSessionStoreRoundTripsTerminalLayout() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let taskID = UUID()
        let tabID = UUID()
        let paneID = UUID()
        let terminal = TerminalSessionSnapshot(
            root: .pane(paneID),
            activePaneID: paneID,
            panes: [
                TerminalPaneSnapshot(
                    id: paneID,
                    workingDirectory: "/tmp/pinata"
                ),
            ]
        )
        let session = AppSession(
            activeScope: .task(taskID),
            expandedTaskIDs: [taskID],
            terminalWorkspaces: [
                StoredTerminalWorkspace(
                    scope: .task(taskID),
                    title: "Terminal",
                    workingDirectory: "/tmp/pinata",
                    tabs: [StoredTerminalTab(id: tabID, title: "Terminal", terminal: terminal)],
                    activeTabID: tabID,
                    nextTabNumber: 2
                ),
            ],
            recentlyClosedTerminalTab: StoredClosedTerminalTab(
                scope: .task(taskID),
                index: 0,
                tab: StoredTerminalTab(id: tabID, title: "Terminal", terminal: terminal)
            )
        )
        let store = AppSessionStore(fileURL: directoryURL.appendingPathComponent("session.json"))

        try store.save(session)

        XCTAssertEqual(try store.load(), session)
    }

    func testTerminalSessionSnapshotRejectsMismatchedPanes() {
        let rootPaneID = UUID()
        let storedPaneID = UUID()
        let snapshot = TerminalSessionSnapshot(
            root: .pane(rootPaneID),
            activePaneID: rootPaneID,
            panes: [
                TerminalPaneSnapshot(
                    id: storedPaneID,
                    workingDirectory: "/tmp"
                ),
            ]
        )

        XCTAssertFalse(snapshot.isValid)
    }

    func testZmxSessionsAreStableAndUniquePerPane() {
        let first = UUID(uuidString: "AAB1E84C-4BAE-4A15-82F1-775571891A81")!
        let second = UUID(uuidString: "3C7E4BFD-5A8B-49E5-8D8A-719EF01EB0CE")!

        XCTAssertEqual(
            ZmxSession.name(for: first),
            "pinata-aab1e84c-4bae-4a15-82f1-775571891a81"
        )
        XCTAssertNotEqual(ZmxSession.name(for: first), ZmxSession.name(for: second))
    }

    func testZmxReconnectBackoffIsBounded() {
        XCTAssertEqual(
            (0...6).map { ZmxReconnectPolicy.delay(for: $0) },
            [1, 2, 4, 8, 16, 30, 30]
        )
    }

    func testZmxReconnectBackoffNormalizesNegativeAttempts() {
        XCTAssertEqual(ZmxReconnectPolicy.delay(for: -1), 1)
    }

    func testRemoteZmxInstallUsesPinnedArchives() {
        let script = RemoteZmxInstaller.installScript()

        XCTAssertTrue(script.contains("macos-aarch64"))
        XCTAssertTrue(script.contains("linux-x86_64"))
        XCTAssertTrue(script.contains("checksum verification failed"))
    }

    func testOlderSettingsKeepNewFieldDefaults() throws {
        let settings = try JSONDecoder().decode(
            UserSettings.self,
            from: Data(#"{"theme":"pinata-light"}"#.utf8)
        )

        XCTAssertEqual(settings.theme, .light)
        XCTAssertEqual(settings.accent, UserSettings.defaults.accent)
        XCTAssertEqual(settings.accentIntensity, UserSettings.defaults.accentIntensity)
        XCTAssertEqual(settings.appFontSize, UserSettings.defaults.appFontSize)
        XCTAssertEqual(settings.terminalFontSize, UserSettings.defaults.terminalFontSize)
        XCTAssertEqual(settings.editorFontSize, UserSettings.defaults.editorFontSize)
        XCTAssertEqual(settings.fileIconColor, .colored)
        XCTAssertTrue(settings.filePreviewsEnabled)
    }

    func testSettingsStoresRoundTripAndRecoverFromInvalidData() throws {
        let suiteName = "PiñataTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = UserSettingsStore(defaults: defaults)
        let repositoryDefaults = RepositoryDefaultsStore(defaults: defaults)
        let settings = UserSettings(
            theme: .light,
            accent: .azure,
            accentIntensity: .vibrant,
            appFontSize: .large,
            terminalFontSize: .extraLarge,
            editorFontSize: .small,
            fileIconColor: .monochrome,
            filePreviewsEnabled: true
        )

        XCTAssertEqual(settingsStore.load(), .defaults)
        try settingsStore.save(settings)
        XCTAssertEqual(settingsStore.load(), settings)
        defaults.set(Data("{".utf8), forKey: "pinata.settings.v1")
        XCTAssertEqual(settingsStore.load(), .defaults)

        XCTAssertEqual(
            repositoryDefaults.loadWorktreeBasePath(),
            RepositoryDefaultsStore.defaultWorktreeBasePath
        )
        XCTAssertEqual(
            repositoryDefaults.loadTaskBranchPrefix(),
            RepositoryDefaultsStore.defaultTaskBranchPrefix
        )
        repositoryDefaults.saveWorktreeBasePath("/tmp/worktrees")
        XCTAssertEqual(repositoryDefaults.loadWorktreeBasePath(), "/tmp/worktrees")
        repositoryDefaults.saveTaskBranchPrefix("antoine.leveque")
        XCTAssertEqual(repositoryDefaults.loadTaskBranchPrefix(), "antoine.leveque/")
    }

    @MainActor
    func testThemeConfigurationCoversEveryPreference() {
        defer { AppTheme.configure(.defaults) }

        for theme in ThemePreference.allCases {
            var settings = UserSettings.defaults
            settings.theme = theme
            AppTheme.configure(settings)
            XCTAssertEqual(rgbHex(AppTheme.background), theme.palette.background)
            XCTAssertEqual(rgbHex(AppTheme.primaryText), theme.palette.primaryText)
            XCTAssertEqual(
                rgbHex(AppTheme.error),
                theme == .dark ? 0xF25555 : 0xBC2C2C
            )
            XCTAssertEqual(
                rgbHex(AppTheme.success),
                theme == .dark ? 0x31C971 : 0x208A4F
            )
        }

        let fontSizes: [(AppFontSize, CGFloat, CGFloat)] = [
            (.small, 16.5, 12),
            (.regular, 17.5, 13),
            (.large, 18.5, 14),
        ]
        for (fontSize, title, body) in fontSizes {
            var settings = UserSettings.defaults
            settings.appFontSize = fontSize
            AppTheme.configure(settings)
            XCTAssertEqual(AppTheme.typography.title, title)
            XCTAssertEqual(AppTheme.typography.body, body)
        }

        for accent in AccentPreference.allCases {
            var settings = UserSettings.defaults
            settings.accent = accent
            AppTheme.configure(settings)
            XCTAssertGreaterThan(AppTheme.accent.alphaComponent, 0)
        }

        for intensity in AccentIntensity.allCases {
            var settings = UserSettings.defaults
            settings.accentIntensity = intensity
            AppTheme.configure(settings)
            let expectedAlpha: CGFloat = switch intensity {
            case .transparent: 0
            case .balanced: 0.14
            case .vibrant: 0.80
            }
            XCTAssertEqual(
                AppTheme.panelAccentBackground.alphaComponent,
                expectedAlpha,
                accuracy: 0.001
            )
        }

        let accent = AppTheme.buttonAppearance(role: .accent, hovered: false)
        let hoveredAccent = AppTheme.buttonAppearance(role: .accent, hovered: true)
        XCTAssertGreaterThan(
            hoveredAccent.background.alphaComponent,
            accent.background.alphaComponent
        )

        XCTAssertEqual(TerminalFontSize.allCases.map(\.points), [10, 11, 12, 13, 14, 15])
    }

    func testRepositoryMetadataAndWorktreePathValidation() {
        XCTAssertEqual(
            RepositoryInspector.organization(from: "git@github.com:DataDog/dd-source.git"),
            "DataDog"
        )
        XCTAssertEqual(
            RepositoryInspector.organization(from: "https://github.com/gh0stonio/pinata.git"),
            "gh0stonio"
        )
        XCTAssertEqual(
            RepositoryInspector.organization(from: "git@github.com:git-team/pinata.git"),
            "git-team"
        )
        XCTAssertNil(RepositoryInspector.organization(from: "not-a-remote"))
        XCTAssertNil(WorktreePathValidator.error(for: "   ", allowRepositoryRelative: false))
        XCTAssertNil(
            WorktreePathValidator.error(
                for: "~/.pinata/worktrees",
                allowRepositoryRelative: false
            )
        )
        XCTAssertNil(
            WorktreePathValidator.error(
                for: "./worktrees",
                allowRepositoryRelative: true
            )
        )
        XCTAssertNotNil(
            WorktreePathValidator.error(
                for: "./worktrees",
                allowRepositoryRelative: false
            )
        )
        XCTAssertNotNil(
            WorktreePathValidator.error(
                for: "worktrees",
                allowRepositoryRelative: true
            )
        )
        XCTAssertEqual(
            WorktreePathValidator.error(
                for: "/tmp/worktrees\nother",
                allowRepositoryRelative: false
            ),
            "Use a single-line path."
        )
        XCTAssertEqual(TaskBranchName.normalizedPrefix("antoine.leveque"), "antoine.leveque/")
        XCTAssertNil(TaskBranchName.error(for: "feature/team/"))
        XCTAssertNotNil(TaskBranchName.error(for: "feature//"))
        XCTAssertNotNil(TaskBranchName.error(for: "feature name"))
    }

    func testRepositoryInspectionRefreshAndContext() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let repositoryURL = try makeGitRepository(
            in: directoryURL,
            remoteURL: "git@github.com:DataDog/source.git"
        )
        _ = try runGit([
            "-C", repositoryURL.path,
            "-c", "tag.gpgSign=false",
            "tag", "-a", "-m", "Test tag", "v1.0.0",
        ])
        let inspector = RepositoryInspector()

        let inspected = try inspector.inspect(directory: repositoryURL)
        XCTAssertEqual(inspected.name, "source")
        XCTAssertEqual(inspected.branches, ["main"])
        XCTAssertEqual(inspected.defaultBranch, "main")
        XCTAssertEqual(inspected.organization, "DataDog")

        let saved = RegisteredRepository(
            name: "Display name",
            path: repositoryURL.path,
            branches: [],
            defaultBranch: "release",
            currentBranch: nil,
            remoteURL: nil,
            organization: nil,
            worktreeBasePath: "./trees"
        )
        let refreshed = try inspector.refresh(saved)
        XCTAssertEqual(refreshed.id, saved.id)
        XCTAssertEqual(refreshed.name, saved.name)
        XCTAssertEqual(refreshed.defaultBranch, saved.defaultBranch)
        XCTAssertEqual(refreshed.worktreeBasePath, saved.worktreeBasePath)

        let context = try inspector.context(for: inspected)
        XCTAssertEqual(context.tags, ["v1.0.0"])
        let canonicalRepositoryURL = repositoryURL.resolvingSymlinksInPath().standardizedFileURL
        XCTAssertTrue(context.worktrees.contains {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL
                == canonicalRepositoryURL
        })
        XCTAssertThrowsError(
            try inspector.inspect(directory: directoryURL.appendingPathComponent("missing"))
        )
    }

    func testRepositoryRemovalCleansVerifiedWorktreesAndProtectsOtherPaths() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let repositoryURL = try makeGitRepository(in: directoryURL)
        let worktreeURL = directoryURL.appendingPathComponent("task", isDirectory: true)
        let branch = "pinata/remove-test"
        _ = try runGit(["-C", repositoryURL.path, "branch", branch, "main"])
        _ = try runGit([
            "-C", repositoryURL.path,
            "worktree", "add", worktreeURL.path, branch,
        ])
        let inspector = RepositoryInspector()
        let repository = try inspector.inspect(directory: repositoryURL)

        XCTAssertEqual(try inspector.currentBranch(at: worktreeURL.path), branch)
        try inspector.removeWorktree(
            at: worktreeURL.path,
            branchHint: branch,
            from: repository
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreeURL.path))
        XCTAssertTrue(try runGit(["-C", repositoryURL.path, "branch", "--list", branch]).isEmpty)

        let secondWorktreeURL = directoryURL.appendingPathComponent("temporary-checkout", isDirectory: true)
        let ownedBranch = "pinata/temporary-checkout"
        let temporaryBranch = "temporary"
        _ = try runGit(["-C", repositoryURL.path, "branch", ownedBranch, "main"])
        _ = try runGit(["-C", repositoryURL.path, "branch", temporaryBranch, "main"])
        _ = try runGit([
            "-C", repositoryURL.path,
            "worktree", "add", secondWorktreeURL.path, ownedBranch,
        ])
        _ = try runGit(["-C", secondWorktreeURL.path, "checkout", temporaryBranch])
        XCTAssertNil(try inspector.renamedBranch(at: secondWorktreeURL.path, from: ownedBranch))
        try inspector.removeWorktree(
            at: secondWorktreeURL.path,
            branchHint: ownedBranch,
            taskID: UUID(),
            from: repository
        )
        XCTAssertTrue(try runGit(["-C", repositoryURL.path, "branch", "--list", ownedBranch]).isEmpty)
        XCTAssertFalse(try runGit(["-C", repositoryURL.path, "branch", "--list", temporaryBranch]).isEmpty)

        let unrelatedURL = directoryURL.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelatedURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(
            try inspector.removeWorktree(
                at: unrelatedURL.path,
                branchHint: "pinata/unverified",
                from: repository
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
        XCTAssertNoThrow(
            try inspector.removeWorktree(
                at: directoryURL.appendingPathComponent("missing").path,
                branchHint: nil,
                from: repository
            )
        )
    }

    func testRepositoryRemovalDeletesRenamedWorktreeBranch() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let repositoryURL = try makeGitRepository(in: directoryURL)
        let worktreeURL = directoryURL.appendingPathComponent("task", isDirectory: true)
        let pinataBranch = "pinata/remove-test"
        let renamedBranch = "antoine.leveque/remove-test"
        _ = try runGit(["-C", repositoryURL.path, "branch", pinataBranch, "main"])
        _ = try runGit(["-C", repositoryURL.path, "worktree", "add", worktreeURL.path, pinataBranch])
        _ = try runGit(["-C", repositoryURL.path, "branch", "-m", pinataBranch, renamedBranch])
        let inspector = RepositoryInspector()
        let repository = try inspector.inspect(directory: repositoryURL)

        XCTAssertEqual(
            try inspector.renamedBranch(at: worktreeURL.path, from: pinataBranch),
            renamedBranch
        )

        try inspector.removeWorktree(
            at: worktreeURL.path,
            branchHint: pinataBranch,
            taskID: UUID(),
            from: repository
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreeURL.path))
        XCTAssertTrue(try runGit(["-C", repositoryURL.path, "branch", "--list", renamedBranch]).isEmpty)
    }

    func testRepositoryRemovalFindsMovedOwnedWorktree() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let repositoryURL = try makeGitRepository(in: directoryURL)
        let originalURL = directoryURL.appendingPathComponent("task", isDirectory: true)
        let movedURL = directoryURL.appendingPathComponent("moved-task", isDirectory: true)
        let branch = "pinata/remove-test"
        let taskID = UUID()
        _ = try runGit(["-C", repositoryURL.path, "branch", branch, "main"])
        _ = try runGit(["-C", repositoryURL.path, "worktree", "add", originalURL.path, branch])
        let inspector = RepositoryInspector()
        let repository = try inspector.inspect(directory: repositoryURL)
        _ = try runGit(["-C", repositoryURL.path, "config", "extensions.worktreeConfig", "true"])
        _ = try runGit(["-C", originalURL.path, "config", "--worktree", "pinata.task-id", taskID.uuidString])
        _ = try runGit(["-C", originalURL.path, "config", "--worktree", "pinata.repository-id", repository.id.uuidString])
        _ = try runGit(["-C", repositoryURL.path, "worktree", "move", originalURL.path, movedURL.path])

        try inspector.removeWorktree(
            at: originalURL.path,
            branchHint: branch,
            taskID: taskID,
            from: repository
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: movedURL.path))
        XCTAssertTrue(try runGit(["-C", repositoryURL.path, "branch", "--list", branch]).isEmpty)
    }

    func testWorktreePathsUseTaskSlugAndConfiguredRoot() {
        let repository = RegisteredRepository(
            name: "Piñata App",
            path: "/code/pinata",
            branches: ["main"],
            defaultBranch: "main",
            currentBranch: "main",
            remoteURL: nil,
            organization: nil
        )

        XCTAssertEqual(WorktreePathResolver.serializedTaskName("Fix API & UI!"), "fix-api-ui")
        XCTAssertEqual(WorktreePathResolver.serializedTaskName("   !!!   "), "task")
        XCTAssertEqual(WorktreePathResolver.serializedTaskName("Crème brûlée"), "creme-brulee")
        XCTAssertEqual(
            WorktreePathResolver.root(
                for: repository,
                globalBasePath: "/worktrees"
            ).path,
            "/worktrees/pinata-app"
        )

        var overridden = repository
        overridden.worktreeBasePath = "./worktrees"
        XCTAssertEqual(
            WorktreePathResolver.root(
                for: overridden,
                globalBasePath: "/worktrees"
            ).path,
            "/code/pinata/worktrees"
        )
    }

    func testWorktreePreparationAvoidsDestinationCollisions() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let repository = RegisteredRepository(
            name: "source",
            path: "/code/source",
            branches: ["main"],
            defaultBranch: "main",
            currentBranch: "main",
            remoteURL: nil,
            organization: nil
        )
        let provisioner = WorktreeProvisioner(globalBasePath: directoryURL.path)
        let existing = directoryURL
            .appendingPathComponent("source", isDirectory: true)
            .appendingPathComponent("fix-api", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let taskID = UUID(uuidString: "12345678-0000-0000-0000-000000000000")!

        let report = provisioner.preparing(
            repository: repository,
            taskID: taskID,
            taskTitle: "Fix API"
        )
        XCTAssertEqual(URL(fileURLWithPath: report.path).lastPathComponent, "fix-api-2")
        XCTAssertEqual(report.branch, "pinata/fix-api-12345678")
        XCTAssertEqual(report.baseBranch, "origin/main")
        XCTAssertEqual(report.steps.map(\.status), [.pending, .pending, .pending])
    }

    func testWorktreeFailureSummaryDropsProgressOutput() {
        let progress = (1...80)
            .map { "Updating files: \($0)% (\($0)/100)" }
            .joined(separator: "\n")

        XCTAssertEqual(
            WorktreeProvisioningFailureSummary.summarize(
                progress + "\nfatal: Could not write new index file."
            ),
            "fatal: Could not write new index file."
        )
        XCTAssertEqual(
            WorktreeProvisioningFailureSummary.summarize(progress),
            "Worktree creation stopped before completion."
        )
        XCTAssertEqual(
            WorktreeProvisioningFailureSummary.summarize(""),
            "Worktree creation stopped before completion."
        )
        XCTAssertEqual(
            WorktreeProvisioningFailureSummary.summarize("\u{001B}[31mfatal: denied\u{001B}[0m"),
            "fatal: denied"
        )
        let longFailure = WorktreeProvisioningFailureSummary.summarize(
            "fatal: " + String(repeating: "x", count: 400)
        )
        XCTAssertEqual(longFailure.count, 320)
        XCTAssertTrue(longFailure.hasSuffix("…"))
    }

    func testWorktreeProvisioningStopsAfterFetchFailure() {
        let repository = RegisteredRepository(
            name: "missing",
            path: "/path/that/does/not/exist",
            branches: ["main"],
            defaultBranch: "main",
            currentBranch: nil,
            remoteURL: nil,
            organization: nil
        )
        let report = WorktreeProvisioner(globalBasePath: "/tmp")
            .provision(repository: repository, taskID: UUID(), taskTitle: "Failure")

        XCTAssertFalse(report.succeeded)
        XCTAssertEqual(report.steps.map(\.status), [.failed, .pending, .pending])
        XCTAssertNotNil(report.failureMessage)
    }

    func testWorktreeProvisionerCreatesNamedCheckout() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let repositoryURL = try makeGitRepository(in: directoryURL)
        let repository = RegisteredRepository(
            name: "source",
            path: repositoryURL.path,
            branches: ["main"],
            defaultBranch: "main",
            currentBranch: "main",
            remoteURL: nil,
            organization: nil
        )

        let updates = WorktreeUpdates()
        let taskID = UUID()
        let provisioner = WorktreeProvisioner(
            globalBasePath: directoryURL.appendingPathComponent("worktrees").path,
            branchPrefix: "antoine.leveque"
        )
        let report = provisioner.provision(
            repository: repository,
            taskID: taskID,
            taskTitle: "Fix API & UI!",
            onUpdate: { updates.values.append($0) }
        )
        let path = report.path

        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(
            Array(report.steps.map(\.title).prefix(3)),
            ["Fetch origin", "Create branch", "Create worktree"]
        )
        XCTAssertTrue(report.steps.contains { $0.title == "Preparing worktree" })
        XCTAssertEqual(updates.values.first?.steps.map(\.status), [.pending, .pending, .pending])
        XCTAssertTrue(updates.values.contains { $0.steps.contains { $0.status == .running } })
        XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, "fix-api-ui")
        XCTAssertEqual(
            URL(fileURLWithPath: try runGit(["-C", path, "rev-parse", "--show-toplevel"]))
                .resolvingSymlinksInPath(),
            URL(fileURLWithPath: path).resolvingSymlinksInPath()
        )

        let unrelatedURL = directoryURL.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelatedURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(
            try RepositoryInspector().removeWorktree(
                at: unrelatedURL.path,
                branchHint: report.branch,
                from: repository
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))

        try RepositoryInspector().removeWorktree(
            at: path,
            branchHint: report.branch,
            taskID: taskID,
            from: repository
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(
            report.branch,
            "antoine.leveque/fix-api-ui-" + String(taskID.uuidString.prefix(8).lowercased())
        )
        XCTAssertEqual(try runGit(["-C", repository.path, "branch", "--list", report.branch]), "")

        let retry = provisioner.provision(
            repository: repository,
            taskID: taskID,
            taskTitle: "Fix API & UI!"
        )
        XCTAssertTrue(retry.succeeded)
        try RepositoryInspector().removeWorktree(
            at: retry.path,
            branchHint: retry.branch,
            taskID: taskID,
            from: repository
        )
    }

    func testPaneTreeReplacementAndRatios() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let replacement = UUID()
        let nestedSplitID = UUID()
        let root = PaneNode.split(PaneNode.Split(
            id: UUID(),
            axis: .vertical,
            ratio: 0.4,
            first: .pane(first),
            second: .split(PaneNode.Split(
                id: nestedSplitID,
                axis: .horizontal,
                ratio: 0.5,
                first: .pane(second),
                second: .pane(third)
            ))
        ))

        XCTAssertEqual(root.paneIDs, [first, second, third])
        XCTAssertEqual(
            root.replacing(second, with: .pane(replacement)).paneIDs,
            [first, replacement, third]
        )

        let resized = root.settingRatio(splitID: nestedSplitID, ratio: 0.7)
        guard case .split(let top) = resized, case .split(let nested) = top.second else {
            return XCTFail("Expected nested split")
        }
        XCTAssertEqual(top.ratio, 0.4)
        XCTAssertEqual(nested.ratio, 0.7)
    }

    func testPaneTreeRemovalAndNearestSelection() throws {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let root = PaneNode.split(PaneNode.Split(
            id: UUID(),
            axis: .vertical,
            ratio: 0.5,
            first: .split(PaneNode.Split(
                id: UUID(),
                axis: .horizontal,
                ratio: 0.5,
                first: .pane(first),
                second: .pane(second)
            )),
            second: .pane(third)
        ))

        XCTAssertEqual(root.nearestPane(to: first), second)
        XCTAssertEqual(root.nearestPane(to: second), first)
        XCTAssertEqual(root.nearestPane(to: third), first)
        XCTAssertNil(root.nearestPane(to: UUID()))
        XCTAssertEqual(try XCTUnwrap(root.removing(second)).paneIDs, [first, third])
        XCTAssertEqual(try XCTUnwrap(root.removing(third)).paneIDs, [first, second])
    }

    @MainActor
    func testTaskModalValidationAndFirstRepositoryAttachment() throws {
        let repository = RegisteredRepository(
            name: "source",
            path: "/code/source",
            branches: ["main"],
            defaultBranch: "main",
            currentBranch: "main",
            remoteURL: nil,
            organization: nil
        )
        let editModal = NewTaskModalView(
            repositories: [repository],
            editingTask: WorkspaceTask(title: "Existing task")
        )
        let updateButton = try XCTUnwrap(
            descendants(of: editModal)
                .compactMap { $0 as? NSButton }
                .first { $0.title == "Update" }
        )
        let repositoryButton = try XCTUnwrap(
            descendants(of: editModal)
                .compactMap { $0 as? NSButton }
                .first { $0.title.isEmpty && $0.isEnabled }
        )
        XCTAssertFalse(updateButton.isEnabled)
        repositoryButton.performClick(nil)
        XCTAssertTrue(updateButton.isEnabled)

        var attached: [RegisteredRepository] = []
        editModal.onCreate = { _, repositories in attached = repositories }
        updateButton.performClick(nil)
        XCTAssertEqual(attached, [repository])

        let createModal = NewTaskModalView(repositories: [])
        let titleField = try XCTUnwrap(
            descendants(of: createModal).compactMap { $0 as? SettingsTextField }.first
        )
        let createButton = try XCTUnwrap(
            descendants(of: createModal)
                .compactMap { $0 as? NSButton }
                .first { $0.title == "Create task" }
        )
        XCTAssertFalse(createButton.isEnabled)
        titleField.stringValue = "  New task  "
        createModal.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertTrue(createButton.isEnabled)

        var createdTitle: String?
        createModal.onCreate = { title, _ in createdTitle = title }
        createButton.performClick(nil)
        XCTAssertEqual(createdTitle, "New task")
    }

    @MainActor
    func testDeleteModalRoutesBothActions() throws {
        let modal = DeleteTaskModalView(taskTitle: "Old task")
        let buttons = descendants(of: modal).compactMap { $0 as? NSButton }
        let cancel = try XCTUnwrap(buttons.first { $0.title == "Cancel" })
        let delete = try XCTUnwrap(buttons.first { $0.title == "Delete" })
        var cancelled = false
        var deleted = false
        modal.onCancel = { cancelled = true }
        modal.onDelete = { deleted = true }

        cancel.performClick(nil)
        delete.performClick(nil)
        XCTAssertTrue(cancelled)
        XCTAssertTrue(deleted)
    }

    @MainActor
    func testWorkspaceTabHitTargetsSelectAndClose() throws {
        let size = NSSize(width: 600, height: AppTheme.mainHeaderHeight)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        let header = WorkspaceHeaderView(frame: .zero)
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        root.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        let firstID = UUID()
        let secondID = UUID()
        var selectedID: UUID?
        var closedID: UUID?
        header.onSelectTab = { selectedID = $0 }
        header.onCloseTab = { closedID = $0 }
        header.setTabs(
            [(id: firstID, title: "Terminal"), (id: secondID, title: "Terminal 2")],
            activeID: firstID
        )
        root.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(header.subviews.compactMap { $0 as? NSScrollView }.first)
        let stack = try XCTUnwrap(scrollView.documentView as? NSStackView)
        XCTAssertTrue(stack.arrangedSubviews.last is PanelToggleButton)
        let workspacePanelToggle = try XCTUnwrap(
            header.subviews
                .compactMap { $0 as? PanelToggleButton }
                .first
        )
        header.setPanelVisible(true)
        XCTAssertTrue(workspacePanelToggle.isHidden)
        header.setPanelVisible(false)
        XCTAssertFalse(workspacePanelToggle.isHidden)
        let secondTab = try XCTUnwrap(stack.arrangedSubviews.dropLast().last)

        let tabButton = try XCTUnwrap(secondTab as? TabButton)
        let bodyLocation = tabButton.convert(
            NSPoint(x: 8, y: tabButton.bounds.midY),
            to: root
        )
        XCTAssertTrue(root.hitTest(bodyLocation) === tabButton)
        tabButton.performClick(nil)
        XCTAssertEqual(selectedID, secondID)

        let closeIcon = try XCTUnwrap(
            secondTab.subviews
                .compactMap { $0 as? NSImageView }
                .last
        )
        let closeLocation = closeIcon.convert(
            NSPoint(x: closeIcon.bounds.midX, y: closeIcon.bounds.midY),
            to: root
        )
        XCTAssertTrue(root.hitTest(closeLocation) === tabButton)
        tabButton.performPointerAction(
            at: tabButton.convert(closeLocation, from: root)
        )
        XCTAssertEqual(closedID, secondID)
        closedID = nil

        header.setTabs(
            [(id: firstID, title: "Terminal"), (id: secondID, title: "Terminal 2")],
            activeID: secondID
        )
        root.layoutSubtreeIfNeeded()
        let selectedTab = try XCTUnwrap(stack.arrangedSubviews.dropLast().last as? TabButton)
        let selectedCloseIcon = try XCTUnwrap(
            selectedTab.subviews
                .compactMap { $0 as? NSImageView }
                .last
        )
        selectedTab.performPointerAction(
            at: NSPoint(x: selectedCloseIcon.frame.midX, y: selectedCloseIcon.frame.midY)
        )
        XCTAssertEqual(closedID, secondID)
    }

    @MainActor
    func testSidebarLabelsRouteClicksToTheirRows() throws {
        let repositoryID = UUID()
        let task = WorkspaceTask(
            title: "Clickable task",
            repositories: [
                TaskRepositoryAttachment(repositoryID: repositoryID, name: "clickable-repo"),
            ],
            isPinned: false
        )
        let secondTask = WorkspaceTask(title: "Second task")
        let controller = PanelViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 264, height: 700)
        var selectedTaskID: UUID?
        var selectedRepository: TaskRepositoryScope?
        controller.onSelectTask = { selectedTaskID = $0 }
        controller.onSelectRepository = { selectedRepository = $0 }
        controller.updateTasks(
            [task, secondTask],
            selection: .repository(TaskRepositoryScope(taskID: task.id, repositoryID: repositoryID)),
            expandedTaskIDs: [task.id],
            taskErrors: [:],
            repositoryErrors: [:],
            loadError: nil
        )
        controller.view.layoutSubtreeIfNeeded()

        func clickLabel(_ value: String) throws {
            let label = try XCTUnwrap(
                descendants(of: controller.view)
                    .compactMap { $0 as? NSTextField }
                    .first { $0.stringValue == value }
            )
            let location = label.convert(
                NSPoint(x: label.bounds.midX, y: label.bounds.midY),
                to: controller.view
            )
            let button = try XCTUnwrap(controller.view.hitTest(location) as? NSButton)
            button.performClick(nil)
        }

        let labels = descendants(of: controller.view)
            .compactMap { $0 as? NSTextField }
            .map(\.stringValue)
        XCTAssertTrue(labels.contains("PINNED"))
        XCTAssertTrue(labels.contains("TASKS"))
        let taskLabelOrigins = [task.title, secondTask.title].map { title in
            descendants(of: controller.view)
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue == title }!
                .convert(.zero, to: controller.view).y
        }
        XCTAssertLessThan(
            abs(taskLabelOrigins[0] - taskLabelOrigins[1]),
            120,
            "task origins: \(taskLabelOrigins)"
        )
        let repositoryLabel = try XCTUnwrap(
            descendants(of: controller.view)
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue == "clickable-repo" }
        )
        let repositoryFrame = repositoryLabel.superview!.convert(
            repositoryLabel.superview!.bounds,
            to: controller.view
        )
        XCTAssertEqual(repositoryFrame.minX, AppTheme.sidebarItemInset)
        XCTAssertEqual(
            controller.view.bounds.width - repositoryFrame.maxX,
            AppTheme.sidebarItemInset
        )

        try clickLabel(task.title)
        XCTAssertEqual(selectedTaskID, task.id)
        try clickLabel("clickable-repo")
        XCTAssertEqual(
            selectedRepository,
            TaskRepositoryScope(taskID: task.id, repositoryID: repositoryID)
        )
    }

    @MainActor
    func testWorkspacePanelLayoutKeepsCenterWidthWhenLeftPanelCollapses() {
        let windowWidth: CGFloat = 1_200
        let dockedCenter = WorkspacePanelLayout.centerWidth(
            windowWidth: windowWidth,
            leftPanelVisible: true,
            rightPanelVisible: true
        )
        let collapsedCenter = WorkspacePanelLayout.centerWidth(
            windowWidth: windowWidth,
            leftPanelVisible: false,
            rightPanelVisible: true
        )

        XCTAssertEqual(collapsedCenter - dockedCenter, AppTheme.leftPanelWidth)
        XCTAssertGreaterThanOrEqual(dockedCenter, AppTheme.minimumCenterWidth)
        XCTAssertEqual(
            WorkspacePanelLayout.minimumWindowWidth(
                leftPanelVisible: true,
                rightPanelVisible: true
            )
                - WorkspacePanelLayout.minimumWindowWidth(
                    leftPanelVisible: false,
                    rightPanelVisible: true
                ),
            AppTheme.leftPanelWidth
        )
    }
}

private final class WorktreeUpdates: @unchecked Sendable {
    var values: [WorktreeProvisioningReport] = []
}

@MainActor
private func descendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(descendants)
}

private func rgbHex(_ color: NSColor) -> UInt32 {
    guard let color = color.usingColorSpace(.sRGB) else { return 0 }
    return UInt32((color.redComponent * 255).rounded()) << 16
        | UInt32((color.greenComponent * 255).rounded()) << 8
        | UInt32((color.blueComponent * 255).rounded())
}

private func makeGitRepository(
    in directoryURL: URL,
    remoteURL: String? = nil
) throws -> URL {
    let repositoryURL = directoryURL.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
    _ = try runGit(["init", "-b", "main", repositoryURL.path])
    try Data("initial".utf8).write(to: repositoryURL.appendingPathComponent("README.md"))
    _ = try runGit(["-C", repositoryURL.path, "add", "."])
    _ = try runGit([
        "-C", repositoryURL.path,
        "-c", "user.name=Test", "-c", "user.email=test@example.com",
        "-c", "commit.gpgsign=false",
        "commit", "-m", "Initial",
    ])
    _ = try runGit([
        "-C", repositoryURL.path,
        "remote", "add", "origin", remoteURL ?? repositoryURL.path,
    ])
    return repositoryURL
}

private func runGit(_ arguments: [String]) throws -> String {
    let output = Pipe()
    let error = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()
    let result = String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "CoreLogicTests",
            code: Int(process.terminationStatus),
            userInfo: [
                NSLocalizedDescriptionKey: String(
                    decoding: error.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self
                ),
            ]
        )
    }
    return result
}
