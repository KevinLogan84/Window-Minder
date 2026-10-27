import XCTest
#if canImport(WindowMinderCore)
@testable import WindowMinderCore
#endif

final class SettingsWindowPlannerTests: XCTestCase {
    func testMenuAndWindowShareTheSettingsName() {
        XCTAssertEqual(SettingsWindowPlanner.windowTitle, "Settings")
        XCTAssertEqual(SettingsWindowPlanner.menuTitle, "Settings\u{2026}")
        XCTAssertTrue(SettingsWindowPlanner.menuTitle.hasPrefix(SettingsWindowPlanner.windowTitle))
        XCTAssertEqual(SettingsWindowPlanner.settingsTitles, Set(["Settings", "Preferences"]))
    }

    func testNoWindowOpensSettings() {
        XCTAssertEqual(SettingsWindowPlanner.presentation(for: []), .openNew)
        XCTAssertEqual(
            SettingsWindowPlanner.presentation(for: [candidate(title: "Documents", isVisible: true)]),
            .openNew
        )
    }

    func testVisibleOrMinimizedSettingsWindowIsOrderedFront() {
        for identifier in SettingsWindowPlanner.settingsIdentifiers {
            let visible = candidate(identifier: identifier, title: "", isVisible: true)
            XCTAssertEqual(SettingsWindowPlanner.presentation(for: [visible]), .orderFront)
        }

        let titled = candidate(title: "Settings", isVisible: true)
        let padded = candidate(title: "  Settings  ", isVisible: true)
        let legacy = candidate(title: "Preferences", isVisible: true)
        let minimized = candidate(identifier: "com_apple_SwiftUI_Settings_window", title: "Settings", isMiniaturized: true)
        XCTAssertEqual(SettingsWindowPlanner.presentation(for: [titled]), .orderFront)
        XCTAssertEqual(SettingsWindowPlanner.presentation(for: [padded]), .orderFront)
        XCTAssertEqual(SettingsWindowPlanner.presentation(for: [legacy]), .orderFront)
        XCTAssertEqual(SettingsWindowPlanner.presentation(for: [minimized]), .orderFront)
        XCTAssertEqual(
            SettingsWindowPlanner.presentation(for: [
                candidate(title: "Documents", isVisible: true),
                titled,
            ]),
            .orderFront
        )
    }

    func testClosedSettingsWindowOpensAgain() {
        let closed = candidate(
            identifier: "com_apple_SwiftUI_Settings_window",
            title: "Settings",
            isVisible: false,
            isMiniaturized: false
        )
        XCTAssertTrue(SettingsWindowPlanner.isSettingsWindow(closed))
        XCTAssertEqual(SettingsWindowPlanner.presentation(for: [closed]), .openNew)
        XCTAssertEqual(
            SettingsWindowPlanner.presentation(for: [
                closed,
                candidate(title: "Preferences", isVisible: false),
            ]),
            .openNew
        )
    }

    func testActionHostIsNeverTheSettingsWindow() {
        let host = candidate(
            identifier: "com.apple.SwiftUI.Settings",
            title: "Settings",
            isVisible: true,
            isActionHost: true
        )
        XCTAssertFalse(SettingsWindowPlanner.isSettingsWindow(host))
        XCTAssertEqual(SettingsWindowPlanner.presentation(for: [host]), .openNew)
        XCTAssertEqual(
            SettingsWindowPlanner.presentation(for: [
                host,
                candidate(title: "Settings", isVisible: true),
            ]),
            .orderFront
        )
    }

    private func candidate(
        identifier: String? = nil,
        title: String,
        isVisible: Bool = false,
        isMiniaturized: Bool = false,
        isActionHost: Bool = false
    ) -> SettingsWindowCandidate {
        SettingsWindowCandidate(
            identifier: identifier,
            title: title,
            isVisible: isVisible,
            isMiniaturized: isMiniaturized,
            isActionHost: isActionHost
        )
    }
}
