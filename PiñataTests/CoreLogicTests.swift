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

        try repositoryStore.save([repository])
        try taskStore.save([task])

        XCTAssertEqual(try repositoryStore.load(), [repository])
        XCTAssertEqual(try taskStore.load(), [task])
        try Data("{".utf8).write(to: taskFileURL)
        XCTAssertThrowsError(try taskStore.load())
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

    func testRepositoryMetadataAndWorktreePathValidation() {
        XCTAssertEqual(
            RepositoryInspector.organization(from: "git@github.com:DataDog/dd-source.git"),
            "DataDog"
        )
        XCTAssertEqual(
            RepositoryInspector.organization(from: "https://github.com/gh0stonio/pinata.git"),
            "gh0stonio"
        )
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
                for: "worktrees",
                allowRepositoryRelative: true
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
    }

    func testWorktreeProvisionerCreatesNamedCheckout() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repositoryURL = directoryURL.appendingPathComponent("source", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
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
        _ = try runGit(["-C", repositoryURL.path, "remote", "add", "origin", repositoryURL.path])
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

        func descendants(of view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants)
        }
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
