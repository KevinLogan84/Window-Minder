import XCTest
#if canImport(WindowMinderCore)
@testable import WindowMinderCore
#endif

final class WindowOperationTests: XCTestCase {
    func testScanSkipsHiddenIgnoredSelfAndNonRegularApps() {
        let ignored: Set<String> = ["com.example.skip"]
        XCTAssertTrue(WindowScanFilter.shouldScan(candidate("com.apple.finder"), ignoredBundleIdentifiers: ignored))
        XCTAssertFalse(WindowScanFilter.shouldScan(
            candidate("com.apple.finder", hidden: true),
            ignoredBundleIdentifiers: ignored
        ))
        XCTAssertFalse(WindowScanFilter.shouldScan(
            candidate("com.apple.finder", terminated: true),
            ignoredBundleIdentifiers: ignored
        ))
        XCTAssertFalse(WindowScanFilter.shouldScan(
            candidate("com.apple.finder", policy: .accessory),
            ignoredBundleIdentifiers: ignored
        ))
        XCTAssertFalse(WindowScanFilter.shouldScan(
            candidate("com.apple.finder", policy: .prohibited),
            ignoredBundleIdentifiers: ignored
        ))
        XCTAssertFalse(WindowScanFilter.shouldScan(
            candidate("com.apple.finder", policy: .unknown),
            ignoredBundleIdentifiers: ignored
        ))
        XCTAssertFalse(WindowScanFilter.shouldScan(
            candidate(WindowMinderIdentity.bundleIdentifier),
            ignoredBundleIdentifiers: ignored
        ))
        XCTAssertFalse(WindowScanFilter.shouldScan(candidate("com.example.skip"), ignoredBundleIdentifiers: ignored))
        XCTAssertFalse(WindowScanFilter.shouldScan(candidate(""), ignoredBundleIdentifiers: ignored))
        XCTAssertFalse(WindowScanFilter.shouldScan(
            candidate("com.apple.finder", pid: 0),
            ignoredBundleIdentifiers: ignored
        ))
    }

    func testDuplicateBundlesAreScannedOnce() {
        let apps = WindowScanFilter.appsToScan(
            [
                candidate("com.apple.finder", pid: 10),
                candidate("com.apple.finder", pid: 11),
                candidate("com.apple.Safari", pid: 12, hidden: true),
                candidate("com.apple.Terminal", pid: 13),
            ],
            ignoredBundleIdentifiers: []
        )
        XCTAssertEqual(apps.map(\.bundleIdentifier), ["com.apple.finder", "com.apple.Terminal"])
        XCTAssertEqual(apps.map(\.processIdentifier), [10, 13])
    }

    func testSnapshotBackstopDoesNotRunAgainImmediately() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(SnapshotSchedule.shouldCapture(lastCapture: nil, now: now))
        XCTAssertFalse(SnapshotSchedule.shouldCapture(lastCapture: now.addingTimeInterval(-1), now: now))
        XCTAssertTrue(SnapshotSchedule.shouldCapture(lastCapture: now.addingTimeInterval(-4), now: now))
        XCTAssertEqual(SnapshotSchedule.backstopInterval, 12)
        XCTAssertGreaterThan(SnapshotSchedule.backstopInterval, SnapshotSchedule.minimumGap)
    }

    func testTimeoutAndConcurrencyPlan() {
        XCTAssertEqual(WindowScanPlan.messagingTimeoutSeconds, 0.25)
        XCTAssertEqual(WindowScanPlan.maxConcurrentApps, 4)
        XCTAssertEqual(WindowScanPlan.waveSizes(appCount: 0), [])
        XCTAssertEqual(WindowScanPlan.waveSizes(appCount: 3), [3])
        XCTAssertEqual(WindowScanPlan.waveSizes(appCount: 10), [4, 4, 2])
        XCTAssertEqual(WindowScanPlan.waveSizes(appCount: 10).reduce(0, +), 10)
    }

    func testClassifySkipsMinimizedAndKeepsIndexesStable() {
        let classified = WindowCaptureRules.classify([
            window(subrole: "AXStandardWindow", title: "Documents"),
            window(subrole: "AXStandardWindow", title: "Downloads", minimized: true),
            window(subrole: "AXDialog", title: "Open", role: "AXWindow"),
            window(subrole: nil, title: "Untitled", role: "AXWindow"),
            window(subrole: "AXStandardWindow", title: "No Frame", frame: nil),
        ])
        XCTAssertEqual(classified.map(\.windowIndex), [0, 1, nil, 2, 3])
        XCTAssertEqual(classified.map(\.includeInStore), [true, false, false, true, false])
        XCTAssertEqual(classified.map(\.includeInRestore), [true, true, false, true, false])
    }

    func testFrameWriteOrderAndRestoreActions() {
        XCTAssertEqual(RestoreFramePlan.writeOrder, [.position, .size, .position])
        XCTAssertEqual(
            RestoreFramePlan.action(savedMinimized: true, liveMinimized: true, liveFullscreen: true),
            .skipMinimized
        )
        XCTAssertEqual(
            RestoreFramePlan.action(savedMinimized: false, liveMinimized: true, liveFullscreen: false),
            .move(exitFullscreen: false, unminimize: true)
        )
        XCTAssertEqual(
            RestoreFramePlan.action(savedMinimized: false, liveMinimized: false, liveFullscreen: true),
            .move(exitFullscreen: true, unminimize: false)
        )
        XCTAssertEqual(
            RestoreFramePlan.action(savedMinimized: false, liveMinimized: false, liveFullscreen: false),
            .move(exitFullscreen: false, unminimize: false)
        )
    }

    func testStoreSummaryMentionsUnresponsiveApps() {
        XCTAssertEqual(
            StoreSummary(windowCount: 14, appCount: 6, unresponsiveAppCount: 0).message,
            "Stored 14 windows from 6 apps"
        )
        XCTAssertEqual(
            StoreSummary(windowCount: 14, appCount: 6, unresponsiveAppCount: 2).message,
            "Stored 14 windows from 6 apps. Skipped 2 unresponsive apps"
        )
        XCTAssertEqual(
            StoreSummary(windowCount: 1, appCount: 1, unresponsiveAppCount: 1).message,
            "Stored 1 window from 1 app. Skipped 1 unresponsive app"
        )
    }

    func testAllUnresponsiveScanDoesNotSave() {
        let outcome = StoreOutcome.make(windowCount: 0, appCount: 0, appsScanned: 3, appsTimedOut: 3)
        XCTAssertFalse(outcome.shouldSave)
        XCTAssertEqual(outcome.message, "Could not store windows. 3 apps did not respond")

        let partial = StoreOutcome.make(windowCount: 4, appCount: 2, appsScanned: 3, appsTimedOut: 1)
        XCTAssertTrue(partial.shouldSave)
        XCTAssertEqual(partial.message, "Stored 4 windows from 2 apps. Skipped 1 unresponsive app")

        let quietDesk = StoreOutcome.make(windowCount: 0, appCount: 0, appsScanned: 2, appsTimedOut: 0)
        XCTAssertTrue(quietDesk.shouldSave)
        XCTAssertEqual(quietDesk.message, "Stored 0 windows from 0 apps")
    }

    func testEmptySaveDoesNotReplaceANonEmptyLayout() {
        let blocked = StoreOutcome.make(
            windowCount: 0,
            appCount: 0,
            appsScanned: 2,
            appsTimedOut: 0,
            existingWindowCount: 6
        )
        XCTAssertFalse(blocked.shouldSave)
        XCTAssertFalse(blocked.message.hasPrefix("Stored "))
        XCTAssertEqual(blocked.message, "No windows could be read. The saved layout was left unchanged.")

        let timedOutOverLayout = StoreOutcome.make(
            windowCount: 0,
            appCount: 0,
            appsScanned: 3,
            appsTimedOut: 3,
            existingWindowCount: 4
        )
        XCTAssertFalse(timedOutOverLayout.shouldSave)
        XCTAssertEqual(timedOutOverLayout.message, "No windows could be read. The saved layout was left unchanged.")

        let fresh = StoreOutcome.make(
            windowCount: 0,
            appCount: 0,
            appsScanned: 2,
            appsTimedOut: 0,
            existingWindowCount: nil
        )
        XCTAssertTrue(fresh.shouldSave)

        let replaceEmpty = StoreOutcome.make(
            windowCount: 0,
            appCount: 0,
            appsScanned: 1,
            appsTimedOut: 0,
            existingWindowCount: 0
        )
        XCTAssertTrue(replaceEmpty.shouldSave)

        let realWindows = StoreOutcome.make(
            windowCount: 3,
            appCount: 1,
            appsScanned: 1,
            appsTimedOut: 0,
            existingWindowCount: 6
        )
        XCTAssertTrue(realWindows.shouldSave)
        XCTAssertEqual(realWindows.message, "Stored 3 windows from 1 app")
    }

    func testSnapshotKeepsWindowsForAppsThatAreNotRunningYet() {
        let saved = [
            WindowRecord(
                bundleIdentifier: "com.apple.finder",
                windowTitle: "Documents",
                windowIndex: 0,
                frame: WMRect(x: 1, y: 2, width: 3, height: 4)
            ),
            WindowRecord(
                bundleIdentifier: "com.apple.Safari",
                windowTitle: "Start Page",
                windowIndex: 0,
                frame: WMRect(x: 5, y: 6, width: 7, height: 8)
            ),
        ]
        let captured = [
            WindowRecord(
                bundleIdentifier: "com.apple.finder",
                windowTitle: "Documents",
                windowIndex: 0,
                frame: WMRect(x: 9, y: 9, width: 9, height: 9)
            ),
        ]
        let merged = SnapshotMerge.merging(saved: saved, captured: captured)
        XCTAssertEqual(merged.map(\.bundleIdentifier).sorted(), ["com.apple.Safari", "com.apple.finder"])
        XCTAssertEqual(merged.first { $0.bundleIdentifier == "com.apple.finder" }?.frame.x, 9)
        XCTAssertEqual(merged.first { $0.bundleIdentifier == "com.apple.Safari" }?.frame.x, 5)
        XCTAssertEqual(SnapshotMerge.merging(saved: saved, captured: []).map(\.bundleIdentifier).sorted(), [
            "com.apple.Safari",
            "com.apple.finder",
        ])
    }

    func testEmptyAutomaticCaptureDoesNotEraseASavedLayout() {
        XCTAssertFalse(LayoutOverwrite.shouldReplaceSavedLayout(existingWindowCount: 4, capturedWindowCount: 0))
        XCTAssertFalse(LayoutOverwrite.shouldReplaceSavedLayout(existingWindowCount: 4, capturedWindowCount: 2))
        XCTAssertTrue(LayoutOverwrite.shouldReplaceSavedLayout(existingWindowCount: 4, capturedWindowCount: 4))
        XCTAssertTrue(LayoutOverwrite.shouldReplaceSavedLayout(existingWindowCount: 4, capturedWindowCount: 5))
        XCTAssertTrue(LayoutOverwrite.shouldReplaceSavedLayout(existingWindowCount: nil, capturedWindowCount: 0))
        XCTAssertTrue(LayoutOverwrite.shouldReplaceSavedLayout(existingWindowCount: 0, capturedWindowCount: 0))
    }

    func testFewerWindowsStoreKeepsClosedWindows() {
        let saved = [
            record("com.apple.finder", "Documents", 0, x: 10),
            record("com.apple.finder", "Downloads", 1, x: 20),
            record("com.apple.Safari", "Start Page", 0, x: 30),
        ]
        let captured = [
            record("com.apple.finder", "Documents", 0, x: 99),
        ]
        XCTAssertFalse(LayoutOverwrite.shouldReplaceSavedLayout(existingWindowCount: saved.count, capturedWindowCount: captured.count))
        let prepared = LayoutOverwrite.prepareStore(existing: saved, captured: captured)
        XCTAssertTrue(prepared.shouldSave)
        XCTAssertEqual(prepared.keptWindowCount, 2)
        XCTAssertEqual(prepared.windows.count, 3)
        XCTAssertEqual(prepared.windows.first { $0.windowTitle == "Documents" }?.frame.x, 99)
        XCTAssertEqual(prepared.windows.first { $0.windowTitle == "Downloads" }?.frame.x, 20)
        XCTAssertEqual(prepared.windows.first { $0.windowTitle == "Start Page" }?.frame.x, 30)
        XCTAssertFalse(LayoutOverwrite.prepareStore(existing: saved, captured: []).shouldSave)

        let summary = StoreSummary(windowCount: 1, appCount: 1, unresponsiveAppCount: 0, keptWindowCount: 2)
        XCTAssertEqual(summary.message, "Stored 1 window from 1 app. Kept 2 windows that were not open")
    }

    func testRestoreSummaryCounts() {
        XCTAssertEqual(
            RestoreSummary(restored: 12, skipped: 0, failed: 0, unresponsiveAppCount: 0).message,
            "Restored 12 windows"
        )
        XCTAssertEqual(
            RestoreSummary(restored: 1, skipped: 0, failed: 0, unresponsiveAppCount: 0).message,
            "Restored 1 window"
        )
        XCTAssertEqual(
            RestoreSummary(restored: 12, skipped: 3, failed: 2, unresponsiveAppCount: 1).message,
            "Restored 12 windows. Skipped 3. 2 could not be moved. Skipped 1 unresponsive app"
        )
    }

    func testMixedDisplayFramesRoundTrip() {
        let primaryHeight = 982.0
        let onExternal = WMRect(x: 100, y: -900, width: 1200, height: 800)
        let cocoa = CoordinateConverter.cocoaFrame(fromAccessibility: onExternal, primaryHeight: primaryHeight)
        XCTAssertEqual(cocoa, WMRect(x: 100, y: 1082, width: 1200, height: 800))
        XCTAssertEqual(
            CoordinateConverter.accessibilityFrame(fromCocoa: cocoa, primaryHeight: primaryHeight),
            onExternal
        )

        let leftAndTaller = WMRect(x: -2000, y: 482, width: 800, height: 600)
        let leftCocoa = CoordinateConverter.cocoaFrame(fromAccessibility: leftAndTaller, primaryHeight: primaryHeight)
        XCTAssertEqual(leftCocoa, WMRect(x: -2000, y: -100, width: 800, height: 600))
        XCTAssertEqual(
            CoordinateConverter.accessibilityFrame(fromCocoa: leftCocoa, primaryHeight: primaryHeight),
            leftAndTaller
        )
    }

    func testOldLayoutWithoutMinimizedFlagStillLoads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowMinderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = """
        {
          "displays": [],
          "key": "alpha",
          "savedAt": "2023-11-14T22:13:20Z",
          "version": 1,
          "windows": [
            {
              "bundleIdentifier": "com.apple.finder",
              "frame": {"height": 480, "width": 640, "x": 80, "y": 120},
              "windowIndex": 0,
              "windowTitle": "Documents"
            }
          ]
        }
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("alpha.json"))
        let loaded = try XCTUnwrap(try LayoutStore(directory: directory).load(key: "alpha"))
        XCTAssertEqual(loaded.windows.first?.minimized, false)
        XCTAssertEqual(loaded.windows.first?.windowTitle, "Documents")
    }

    private func record(_ bundle: String, _ title: String, _ index: Int, x: Double) -> WindowRecord {
        WindowRecord(
            bundleIdentifier: bundle,
            windowTitle: title,
            windowIndex: index,
            frame: WMRect(x: x, y: 0, width: 100, height: 80)
        )
    }

    private func candidate(
        _ bundle: String,
        pid: Int32 = 42,
        hidden: Bool = false,
        terminated: Bool = false,
        policy: AppActivationKind = .regular
    ) -> ScanCandidate {
        ScanCandidate(
            processIdentifier: pid,
            bundleIdentifier: bundle,
            isHidden: hidden,
            isTerminated: terminated,
            activationPolicy: policy
        )
    }

    private func window(
        subrole: String?,
        title: String,
        role: String? = "AXWindow",
        minimized: Bool = false,
        frame: WMRect? = WMRect(x: 0, y: 0, width: 10, height: 10)
    ) -> ScannedWindowAttributes {
        ScannedWindowAttributes(
            role: role,
            subrole: subrole,
            title: title,
            frame: frame,
            minimized: minimized,
            fullscreen: false
        )
    }
}
