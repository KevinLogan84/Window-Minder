import XCTest
#if canImport(WindowMinderCore)
@testable import WindowMinderCore
#endif

final class DisplayConfigKeyTests: XCTestCase {
    func testScreenOrderDoesNotChangeTheKey() {
        let left = display(uuid: "UUID-A", x: 0, name: "Left")
        let right = display(uuid: "UUID-B", x: 1440, name: "Right")
        let third = display(uuid: "UUID-C", x: 0, y: 900, width: 1920, height: 1080, name: "Above")
        let forward = DisplayConfiguration(displays: [left, right, third])
        let reversed = DisplayConfiguration(displays: [
            display(uuid: "UUID-C", x: 0, y: 900, width: 1920, height: 1080, name: "Renamed"),
            display(uuid: "UUID-B", x: 1440, name: "Other"),
            display(uuid: "UUID-A", x: 0, name: "Built-in"),
        ])
        XCTAssertEqual(forward.key, reversed.key)
    }

    func testNameDoesNotChangeTheKey() {
        let named = DisplayConfiguration(displays: [display(name: "Studio Display")])
        let unnamed = DisplayConfiguration(displays: [display(name: nil)])
        let hostile = DisplayConfiguration(displays: [display(name: "a/../../b:\\c*? ")])
        XCTAssertEqual(named.key, unnamed.key)
        XCTAssertEqual(named.key, hostile.key)
        XCTAssertNotEqual(named.displays, unnamed.displays)
    }

    func testUUIDChangesTheKey() {
        XCTAssertNotEqual(
            DisplayConfiguration(displays: [display(uuid: "UUID-A")]).key,
            DisplayConfiguration(displays: [display(uuid: "UUID-B")]).key
        )
    }

    func testOriginJitterAndPrimaryDisplayShareAKey() {
        let laptop = display(
            uuid: "old-laptop",
            x: 0,
            y: 0,
            width: 1512,
            height: 982,
            pixelsWide: 3024,
            pixelsHigh: 1964,
            vendorID: 1552,
            productID: 41014,
            serialNumber: 7
        )
        let external = display(
            uuid: "old-external",
            x: -2560,
            y: -229,
            width: 2560,
            height: 1440,
            pixelsWide: 3840,
            pixelsHigh: 2160,
            vendorID: 4268,
            productID: 16823,
            serialNumber: 42
        )
        let jittered = DisplayConfiguration(displays: [
            display(
                uuid: "new-laptop",
                x: 1,
                y: -1,
                width: 1512,
                height: 982,
                pixelsWide: 3024,
                pixelsHigh: 1964,
                vendorID: 1552,
                productID: 41014,
                serialNumber: 7
            ),
            display(
                uuid: "new-external",
                x: -2559,
                y: -228,
                width: 2560,
                height: 1440,
                pixelsWide: 3840,
                pixelsHigh: 2160,
                vendorID: 4268,
                productID: 16823,
                serialNumber: 42
            ),
        ])
        let externalPrimary = DisplayConfiguration(displays: [
            display(
                uuid: "other-laptop",
                x: 2560,
                y: 120,
                width: 1512,
                height: 982,
                pixelsWide: 3024,
                pixelsHigh: 1964,
                vendorID: 1552,
                productID: 41014,
                serialNumber: 7
            ),
            display(
                uuid: "other-external",
                x: 0,
                y: 0,
                width: 2560,
                height: 1440,
                pixelsWide: 3840,
                pixelsHigh: 2160,
                vendorID: 4268,
                productID: 16823,
                serialNumber: 42
            ),
        ])
        let docked = DisplayConfiguration(displays: [laptop, external])
        XCTAssertEqual(docked.key, jittered.key)
        XCTAssertEqual(docked.key, externalPrimary.key)
    }

    func testPointSizeChangesTheKey() {
        XCTAssertNotEqual(
            DisplayConfiguration(displays: [display(width: 1440)]).key,
            DisplayConfiguration(displays: [display(width: 1441)]).key
        )
        XCTAssertNotEqual(
            DisplayConfiguration(displays: [display(height: 900)]).key,
            DisplayConfiguration(displays: [display(height: 901)]).key
        )
    }

    func testPixelSizeChangesTheKey() {
        XCTAssertNotEqual(
            DisplayConfiguration(displays: [display(pixelsWide: 2880)]).key,
            DisplayConfiguration(displays: [display(pixelsWide: 2881)]).key
        )
        XCTAssertNotEqual(
            DisplayConfiguration(displays: [display(pixelsHigh: 1800)]).key,
            DisplayConfiguration(displays: [display(pixelsHigh: 1801)]).key
        )
    }

    func testPrimaryHeightUsesTheOriginDisplay() {
        let builtIn = WMRect(x: 0, y: 0, width: 1512, height: 982)
        let external = WMRect(x: 0, y: 982, width: 2560, height: 1440)
        XCTAssertEqual(PrimaryDisplayHeight.points(frames: [external, builtIn]), 982)
        XCTAssertEqual(PrimaryDisplayHeight.points(frames: [external]), 1440)
        XCTAssertEqual(PrimaryDisplayHeight.points(frames: []), 0)
    }

    func testRenamedExternalDisplayKeepsTheKeyAndScaleDoesNot() {
        let builtIn = display(
            uuid: "BUILT-IN",
            x: 0,
            y: 0,
            width: 1512,
            height: 982,
            pixelsWide: 3024,
            pixelsHigh: 1964,
            name: "Built-in Retina Display"
        )
        let external = display(
            uuid: "LU28R55",
            x: -2560,
            y: -229,
            width: 2560,
            height: 1440,
            pixelsWide: 3840,
            pixelsHigh: 2160,
            name: "LU28R55"
        )
        let renamed = display(
            uuid: "LU28R55",
            x: -2560,
            y: -229,
            width: 2560,
            height: 1440,
            pixelsWide: 3840,
            pixelsHigh: 2160,
            name: "Samsung"
        )
        let scaled = display(
            uuid: "LU28R55",
            x: -1920,
            y: -49,
            width: 1920,
            height: 1080,
            pixelsWide: 3840,
            pixelsHigh: 2160,
            name: "LU28R55"
        )
        let clamshell = DisplayConfiguration(displays: [external])
        let desk = DisplayConfiguration(displays: [builtIn, external])
        XCTAssertEqual(desk.key, DisplayConfiguration(displays: [renamed, builtIn]).key)
        XCTAssertNotEqual(desk.key, DisplayConfiguration(displays: [builtIn, scaled]).key)
        XCTAssertNotEqual(desk.key, clamshell.key)
    }

    func testSamePhysicalDisplaysIgnoreDisplayIDAndOrder() {
        let laptop = display(
            uuid: "session-a",
            width: 1512,
            height: 982,
            pixelsWide: 3024,
            pixelsHigh: 1964,
            vendorID: 1552,
            productID: 41014,
            serialNumber: 1
        )
        let external = display(
            uuid: "session-b",
            x: -2560,
            y: -229,
            width: 2560,
            height: 1440,
            pixelsWide: 3840,
            pixelsHigh: 2160,
            vendorID: 4268,
            productID: 16823,
            serialNumber: 99
        )
        let repluggedLaptop = display(
            uuid: "session-c",
            x: 4,
            width: 1512,
            height: 982,
            pixelsWide: 3024,
            pixelsHigh: 1964,
            vendorID: 1552,
            productID: 41014,
            serialNumber: 1
        )
        let repluggedExternal = display(
            uuid: "session-d",
            x: -2558,
            y: -230,
            width: 2560,
            height: 1440,
            pixelsWide: 3840,
            pixelsHigh: 2160,
            vendorID: 4268,
            productID: 16823,
            serialNumber: 99
        )
        XCTAssertEqual(
            DisplayConfiguration.key(displays: [(laptop, 1), (external, 2)]),
            DisplayConfiguration.key(displays: [(repluggedExternal, 700), (repluggedLaptop, 42)])
        )
    }

    func testEDIDIdentityBeatsAVolatileUUID() {
        let panel = display(uuid: "UUID-FROM-BOOT-1", vendorID: 1552, productID: 41014, serialNumber: 5)
        let replugged = display(uuid: "UUID-FROM-BOOT-2", vendorID: 1552, productID: 41014, serialNumber: 5)
        XCTAssertEqual(
            DisplayConfiguration(displays: [panel]).key,
            DisplayConfiguration(displays: [replugged]).key
        )
        XCTAssertTrue(DisplayIdentity.token(for: panel).hasPrefix("edid:1552:41014:5"))
        XCTAssertNotEqual(
            DisplayConfiguration(displays: [panel]).key,
            DisplayConfiguration(displays: [display(uuid: "UUID-FROM-BOOT-1", vendorID: 1552, productID: 41014, serialNumber: 6)]).key
        )
        let withoutEDID = display(uuid: "UUID-A")
        let otherUUID = display(uuid: "UUID-B")
        XCTAssertNotEqual(
            DisplayConfiguration(displays: [withoutEDID]).key,
            DisplayConfiguration(displays: [otherUUID]).key
        )
        XCTAssertTrue(DisplayIdentity.token(for: withoutEDID).hasPrefix("uuid:"))
        let zeroSerial = display(uuid: "UUID-A", vendorID: 1552, productID: 41014, serialNumber: 0)
        XCTAssertTrue(DisplayIdentity.usesEDID(zeroSerial))
        XCTAssertEqual(
            DisplayConfiguration(displays: [zeroSerial]).key,
            DisplayConfiguration(displays: [display(uuid: "OTHER", vendorID: 1552, productID: 41014, serialNumber: 0)]).key
        )
    }

    func testAddingRemovingOrPixelSizeChangesTheKey() {
        let laptop = display(
            uuid: "laptop",
            width: 1512,
            height: 982,
            pixelsWide: 3024,
            pixelsHigh: 1964,
            vendorID: 1552,
            productID: 41014,
            serialNumber: 1
        )
        let external = display(
            uuid: "external",
            x: -2560,
            width: 2560,
            height: 1440,
            pixelsWide: 3840,
            pixelsHigh: 2160,
            vendorID: 4268,
            productID: 16823,
            serialNumber: 99
        )
        let docked = DisplayConfiguration(displays: [laptop, external])
        XCTAssertNotEqual(docked.key, DisplayConfiguration(displays: [laptop]).key)
        XCTAssertNotEqual(docked.key, DisplayConfiguration(displays: [external]).key)
        let higher = display(
            uuid: "external",
            x: -2560,
            width: 2560,
            height: 1440,
            pixelsWide: 3840,
            pixelsHigh: 2400,
            vendorID: 4268,
            productID: 16823,
            serialNumber: 99
        )
        XCTAssertNotEqual(docked.key, DisplayConfiguration(displays: [laptop, higher]).key)
    }

    func testSubPointSizeDoesNotChangeTheKey() {
        XCTAssertEqual(
            DisplayConfiguration(displays: [display(width: 1440.2)]).key,
            DisplayConfiguration(displays: [display(width: 1440.4)]).key
        )
    }

    func testLegacyLayoutIsChosenWhenTheUUIDAndOriginChange() {
        let savedDisplays = [
            display(uuid: "OLD-LAPTOP", x: 0, y: 0, width: 1512, height: 982, pixelsWide: 3024, pixelsHigh: 1964),
            display(uuid: "OLD-EXTERNAL", x: -2560, y: -229, width: 2560, height: 1440, pixelsWide: 3840, pixelsHigh: 2160),
        ]
        let older = layout(
            key: "legacy-older",
            savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            displays: savedDisplays,
            title: "Older"
        )
        let newer = layout(
            key: "legacy-newer",
            savedAt: Date(timeIntervalSince1970: 1_700_000_100),
            displays: savedDisplays,
            title: "Newer"
        )
        let current = DisplayConfiguration(displays: [
            display(
                uuid: "NEW-LAPTOP",
                x: 3,
                y: 2,
                width: 1512,
                height: 982,
                pixelsWide: 3024,
                pixelsHigh: 1964,
                vendorID: 1552,
                productID: 41014,
                serialNumber: 1
            ),
            display(
                uuid: "NEW-EXTERNAL",
                x: -2557,
                y: -220,
                width: 2560,
                height: 1440,
                pixelsWide: 3840,
                pixelsHigh: 2160,
                vendorID: 4268,
                productID: 16823,
                serialNumber: 99
            ),
        ])
        XCTAssertNotEqual(current.key, older.key)
        XCTAssertEqual(LayoutCatalog.layout(for: current, in: [older, newer])?.windows.first?.windowTitle, "Newer")

        let exact = layout(
            key: current.key,
            savedAt: Date(timeIntervalSince1970: 1_600_000_000),
            displays: current.displays,
            title: "Exact"
        )
        XCTAssertEqual(LayoutCatalog.layout(for: current, in: [newer, exact])?.windows.first?.windowTitle, "Exact")

        let lid = DisplayConfiguration(displays: [current.displays[0]])
        XCTAssertNil(LayoutCatalog.layout(for: lid, in: [newer]))
        XCTAssertNil(LayoutCatalog.layout(for: DisplayConfiguration(displays: []), in: [newer]))
    }

    func testPrimarySwapRebasesTheWindowOntoTheSameDisplay() {
        let savedLaptop = display(
            uuid: "laptop",
            x: 0,
            y: 0,
            width: 1512,
            height: 982,
            pixelsWide: 3024,
            pixelsHigh: 1964,
            vendorID: 1552,
            productID: 41014,
            serialNumber: 1
        )
        let savedExternal = display(
            uuid: "external",
            x: -2560,
            y: -229,
            width: 2560,
            height: 1440,
            pixelsWide: 3840,
            pixelsHigh: 2160,
            vendorID: 4268,
            productID: 16823,
            serialNumber: 99
        )
        let currentLaptop = display(
            uuid: "laptop-now",
            x: 2560,
            y: 0,
            width: 1512,
            height: 982,
            pixelsWide: 3024,
            pixelsHigh: 1964,
            vendorID: 1552,
            productID: 41014,
            serialNumber: 1
        )
        let currentExternal = display(
            uuid: "external-now",
            x: 0,
            y: 0,
            width: 2560,
            height: 1440,
            pixelsWide: 3840,
            pixelsHigh: 2160,
            vendorID: 4268,
            productID: 16823,
            serialNumber: 99
        )
        let onExternal = WMRect(x: -2400, y: -100, width: 800, height: 600)
        let placed = WindowPlacement.frame(
            onExternal,
            savedDisplays: [savedLaptop, savedExternal],
            currentDisplays: [currentLaptop, currentExternal]
        )
        XCTAssertEqual(placed, WMRect(x: 160, y: 129, width: 800, height: 600))

        let onLaptop = WMRect(x: 100, y: 80, width: 400, height: 300)
        let laptopPlaced = WindowPlacement.frame(
            onLaptop,
            savedDisplays: [savedLaptop, savedExternal],
            currentDisplays: [currentExternal, currentLaptop]
        )
        XCTAssertEqual(laptopPlaced, WMRect(x: 2660, y: 80, width: 400, height: 300))
    }

    func testLegacyDisplayMatchesByGeometryWhenTheUUIDChanged() {
        let saved = display(uuid: "OLD", x: -2560, y: -229, width: 2560, height: 1440, pixelsWide: 3840, pixelsHigh: 2160)
        let current = display(
            uuid: "NEW",
            x: 0,
            y: 0,
            width: 2560,
            height: 1440,
            pixelsWide: 3840,
            pixelsHigh: 2160,
            vendorID: 4268,
            productID: 16823,
            serialNumber: 99
        )
        let window = WMRect(x: -2400, y: -100, width: 800, height: 600)
        let placed = WindowPlacement.frame(window, savedDisplays: [saved], currentDisplays: [current])
        XCTAssertEqual(placed, WMRect(x: 160, y: 129, width: 800, height: 600))
    }

    func testAutoRestoreRunsForLoginAndForADisplayChange() {
        XCTAssertGreaterThanOrEqual(DisplayRestoreTiming.debounce, 1)
        XCTAssertLessThanOrEqual(DisplayRestoreTiming.debounce, 2)
        XCTAssertEqual(DisplayRestoreTiming.debounce, 1.5)
        XCTAssertTrue(DisplayRestorePolicy.shouldRestore(
            autoRestore: true,
            hasDisplays: true,
            keyChanged: false,
            restoreEvenIfUnchanged: true
        ))
        XCTAssertTrue(DisplayRestorePolicy.shouldRestore(
            autoRestore: true,
            hasDisplays: true,
            keyChanged: true,
            restoreEvenIfUnchanged: false
        ))
        XCTAssertFalse(DisplayRestorePolicy.shouldRestore(
            autoRestore: true,
            hasDisplays: true,
            keyChanged: false,
            restoreEvenIfUnchanged: false
        ))
        XCTAssertFalse(DisplayRestorePolicy.shouldRestore(
            autoRestore: false,
            hasDisplays: true,
            keyChanged: true,
            restoreEvenIfUnchanged: true
        ))
        XCTAssertFalse(DisplayRestorePolicy.shouldRestore(
            autoRestore: true,
            hasDisplays: false,
            keyChanged: true,
            restoreEvenIfUnchanged: true
        ))
    }

    func testKeyIsStableAndFilesystemSafe() {
        let configuration = DisplayConfiguration(displays: [
            display(uuid: "37D8832A-2D66-02CA-B9F7-8F30A301B230", x: -1728.5, y: 0, name: "Left"),
            display(uuid: "UUID/not/a/filename", x: 0, y: -50.25, name: "Primary"),
        ])
        let key = configuration.key
        XCTAssertEqual(key, configuration.key)
        XCTAssertEqual(key.count, 64)
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(key.unicodeScalars.allSatisfy { allowed.contains($0) })
        XCTAssertFalse(key.contains("/"))
        XCTAssertFalse(key.contains(" "))
        XCTAssertFalse(key.contains(":"))
    }

    private func display(
        uuid: String = "UUID-A",
        x: Double = 0,
        y: Double = 0,
        width: Double = 1440,
        height: Double = 900,
        pixelsWide: Int = 2880,
        pixelsHigh: Int = 1800,
        name: String? = nil,
        vendorID: UInt32? = nil,
        productID: UInt32? = nil,
        serialNumber: UInt32? = nil
    ) -> DisplayDescriptor {
        DisplayDescriptor(
            uuid: uuid,
            frame: WMRect(x: x, y: y, width: width, height: height),
            pixelWidth: pixelsWide,
            pixelHeight: pixelsHigh,
            name: name,
            vendorID: vendorID,
            productID: productID,
            serialNumber: serialNumber
        )
    }

    private func layout(
        key: String,
        savedAt: Date,
        displays: [DisplayDescriptor],
        title: String
    ) -> SavedLayout {
        SavedLayout(
            version: SavedLayout.currentVersion,
            key: key,
            savedAt: savedAt,
            displays: displays,
            windows: [
                WindowRecord(
                    bundleIdentifier: "com.apple.finder",
                    windowTitle: title,
                    windowIndex: 0,
                    frame: WMRect(x: 10, y: 20, width: 300, height: 200)
                ),
            ]
        )
    }
}
