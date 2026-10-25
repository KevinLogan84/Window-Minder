import XCTest
#if canImport(WindowMinderCore)
@testable import WindowMinderCore
#endif

final class WindowMatcherTests: XCTestCase {
    func testTitleMatch() {
        let saved = [window("com.apple.finder", "Documents", 0, x: 10)]
        let live = [window("com.apple.finder", "Documents", 3, x: 90)]
        let matches = WindowMatcher.match(saved: saved, live: live)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].saved.frame.x, 10)
        XCTAssertEqual(matches[0].live.windowIndex, 3)
        XCTAssertEqual(matches[0].live.windowTitle, "Documents")
    }

    func testSameTitleIsDisambiguatedByIndex() {
        let saved = [
            window("com.apple.TextEdit", "Untitled", 0, x: 1),
            window("com.apple.TextEdit", "Untitled", 1, x: 2),
        ]
        let live = [
            window("com.apple.TextEdit", "Untitled", 1, x: 20),
            window("com.apple.TextEdit", "Untitled", 0, x: 10),
        ]
        let matches = WindowMatcher.match(saved: saved, live: live)
        XCTAssertEqual(identityPairs(matches), [
            "com.apple.TextEdit#0#Untitled->0",
            "com.apple.TextEdit#1#Untitled->1",
        ])
        let first = try? XCTUnwrap(matches.first { $0.saved.windowIndex == 0 })
        XCTAssertEqual(first?.saved.frame.x, 1)
        XCTAssertEqual(first?.live.frame.x, 10)
    }

    func testTitleChangeFallsBackToIndex() {
        let saved = [window("com.apple.TextEdit", "Report", 0)]
        let live = [
            window("com.apple.TextEdit", "Other", 1),
            window("com.apple.TextEdit", "Report Final", 0),
        ]
        let matches = WindowMatcher.match(saved: saved, live: live)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].saved.windowTitle, "Report")
        XCTAssertEqual(matches[0].live.windowTitle, "Report Final")
        XCTAssertEqual(matches[0].live.windowIndex, 0)
    }

    func testTitleMatchIsPreferredOverIndexFallback() {
        let saved = [
            window("com.example.Editor", "X", 0),
            window("com.example.Editor", "Y", 1),
        ]
        let live = [
            window("com.example.Editor", "Y", 0),
            window("com.example.Editor", "X", 1),
        ]
        let matches = WindowMatcher.match(saved: saved, live: live)
        XCTAssertEqual(identityPairs(matches), [
            "com.example.Editor#0#X->1",
            "com.example.Editor#1#Y->0",
        ])
    }

    func testNoCrossAppMatch() {
        let saved = [window("com.alpha.App", "Hello", 0)]
        let live = [
            window("com.beta.App", "Hello", 0),
            window("com.beta.App", "Hello Renamed", 0),
        ]
        XCTAssertTrue(WindowMatcher.match(saved: saved, live: live).isEmpty)
    }

    func testNoDoubleAssignment() {
        let saved = [
            window("com.apple.finder", "Keep", 0),
            window("com.apple.finder", "Other", 0),
        ]
        let live = [window("com.apple.finder", "Keep", 0)]
        let matches = WindowMatcher.match(saved: saved, live: live)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].saved.windowTitle, "Keep")
        XCTAssertEqual(matches[0].live.windowTitle, "Keep")
    }

    func testIgnoredBundleIdentifiersAreSkipped() {
        let saved = [
            window("com.skip.App", "A", 0),
            window("com.keep.App", "B", 1),
        ]
        let live = [
            window("com.skip.App", "A", 0),
            window("com.keep.App", "B", 1),
        ]
        let matches = WindowMatcher.match(
            saved: saved,
            live: live,
            ignoredBundleIdentifiers: ["com.skip.App"]
        )
        XCTAssertEqual(matches.map(\.saved.bundleIdentifier), ["com.keep.App"])
    }

    func testOwnBundleIdentifierIsAlwaysIgnored() {
        let saved = [
            window(WindowMinderIdentity.bundleIdentifier, "Preferences", 0),
            window("com.apple.finder", "Desktop", 0),
        ]
        let live = [
            window(WindowMinderIdentity.bundleIdentifier, "Preferences", 0),
            window("com.apple.finder", "Desktop", 0),
        ]
        let matches = WindowMatcher.match(saved: saved, live: live)
        XCTAssertEqual(matches.map(\.saved.bundleIdentifier), ["com.apple.finder"])
    }

    func testMissingWindowsAreSkipped() {
        let saved = [
            window("com.apple.finder", "A", 0),
            window("com.apple.finder", "Gone", 1),
        ]
        let live = [
            window("com.apple.finder", "A", 0),
            window("com.apple.finder", "Extra", 2),
        ]
        let matches = WindowMatcher.match(saved: saved, live: live)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].saved.windowTitle, "A")
        XCTAssertEqual(matches[0].live.windowTitle, "A")
    }

    private func window(_ bundle: String, _ title: String, _ index: Int, x: Double = 0) -> WindowRecord {
        WindowRecord(
            bundleIdentifier: bundle,
            windowTitle: title,
            windowIndex: index,
            frame: WMRect(x: x, y: 0, width: 100, height: 80)
        )
    }

    private func identityPairs(_ matches: [WindowMatch]) -> [String] {
        matches.map {
            "\($0.saved.bundleIdentifier)#\($0.saved.windowIndex)#\($0.saved.windowTitle)->\($0.live.windowIndex)"
        }
        .sorted()
    }
}
