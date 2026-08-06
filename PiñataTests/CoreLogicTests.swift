import XCTest
@testable import Pinata

final class CoreLogicTests: XCTestCase {
    func testRepositoryRegistryRoundTripAndCorruption() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("repositories.json")
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
        let store = RepositoryRegistryStore(fileURL: fileURL)

        try store.save([repository])

        XCTAssertEqual(try store.load(), [repository])
        try Data("{".utf8).write(to: fileURL)
        XCTAssertThrowsError(try store.load())
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
}
