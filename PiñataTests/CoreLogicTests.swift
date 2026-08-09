import XCTest
import AppKit
@testable import Pinata

final class CoreLogicTests: XCTestCase {
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
            organization: nil
        )
        let repositoryStore = RepositoryRegistryStore(fileURL: repositoryFileURL)
        let task = WorkspaceTask(
            title: "Build task sidebar",
            repositories: [
                TaskRepositoryAttachment(repositoryID: repository.id, name: repository.name),
            ],
            isPinned: true
        )
        let taskStore = TaskRegistryStore(fileURL: taskFileURL)

        XCTAssertEqual(try repositoryStore.load(), [])
        XCTAssertEqual(try taskStore.load(), [])
        try repositoryStore.save([repository])
        try taskStore.save([task])

        XCTAssertEqual(try repositoryStore.load(), [repository])
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

        let process = SSHCommand.makeProcess(
            connection: SSHConnection(name: "Build", host: "build"),
            command: ["pwd"]
        )
        XCTAssertTrue(process.arguments?.contains("ClearAllForwardings=yes") == true)
    }

    func testOlderTasksDefaultToUnpinned() throws {
        let id = UUID()
        let data = Data(
            #"[{"id":"\#(id.uuidString)","title":"Legacy","repositories":[],"createdAt":0}]"#.utf8
        )

        let task = try XCTUnwrap(JSONDecoder().decode([WorkspaceTask].self, from: data).first)
        XCTAssertFalse(task.isPinned)
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
            ]
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

    func testTerminalServiceProtocolRoundTripsEveryMessage() throws {
        let messages: [TerminalServiceMessage] = [
            .attach,
            .input(Data("echo Piñata\n".utf8)),
            .resize(columns: 120, rows: 40),
            .output(Data("output\n".utf8)),
            .close,
        ]

        for message in messages {
            XCTAssertEqual(try JSONDecoder().decode(
                TerminalServiceMessage.self,
                from: JSONEncoder().encode(message)
            ), message)
        }
    }

    func testTerminalServicePathsArePerSessionAndSocketSafe() {
        let first = UUID(uuidString: "AAB1E84C-4BAE-4A15-82F1-775571891A81")!
        let second = UUID(uuidString: "3C7E4BFD-5A8B-49E5-8D8A-719EF01EB0CE")!

        XCTAssertNotEqual(TerminalSessionPaths.logURL(for: first), TerminalSessionPaths.logURL(for: second))
        XCTAssertNotEqual(TerminalSessionPaths.socketPath(for: first), TerminalSessionPaths.socketPath(for: second))
        XCTAssertLessThan(TerminalSessionPaths.socketPath(for: first).utf8.count, 104)
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
            terminalFontSize: .extraLarge
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
        repositoryDefaults.saveWorktreeBasePath("/tmp/worktrees")
        XCTAssertEqual(repositoryDefaults.loadWorktreeBasePath(), "/tmp/worktrees")
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
            globalBasePath: directoryURL.appendingPathComponent("worktrees").path
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
            from: repository
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
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
            isPinned: true
        )
        let controller = PanelViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 264, height: 700)
        var selectedTaskID: UUID?
        var selectedRepository: TaskRepositoryScope?
        controller.onSelectTask = { selectedTaskID = $0 }
        controller.onSelectRepository = { selectedRepository = $0 }
        controller.updateTasks(
            [task],
            selection: nil,
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

        try clickLabel(task.title)
        XCTAssertEqual(selectedTaskID, task.id)
        try clickLabel("clickable-repo")
        XCTAssertEqual(
            selectedRepository,
            TaskRepositoryScope(taskID: task.id, repositoryID: repositoryID)
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
