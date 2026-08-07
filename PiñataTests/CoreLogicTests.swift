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
            ]
        )
        let taskStore = TaskRegistryStore(fileURL: taskFileURL)

        try repositoryStore.save([repository])
        try taskStore.save([task])

        XCTAssertEqual(try repositoryStore.load(), [repository])
        XCTAssertEqual(try taskStore.load(), [task])
        try Data("{".utf8).write(to: taskFileURL)
        XCTAssertThrowsError(try taskStore.load())
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
            ]
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

        try clickLabel(task.title)
        XCTAssertEqual(selectedTaskID, task.id)
        try clickLabel("clickable-repo")
        XCTAssertEqual(
            selectedRepository,
            TaskRepositoryScope(taskID: task.id, repositoryID: repositoryID)
        )
    }
}
