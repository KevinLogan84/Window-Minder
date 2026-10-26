import XCTest
#if canImport(WindowMinderCore)
@testable import WindowMinderCore
#endif

final class LayoutStoreTests: XCTestCase {
    private var directory: URL!
    private var store: LayoutStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowMinderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = LayoutStore(directory: directory)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    func testSaveLoadRoundTrip() throws {
        let layout = sample(key: "alpha", title: "Documents", name: "Studio Display")
        try store.save(layout)
        let loaded = try XCTUnwrap(try store.load(key: "alpha"))
        XCTAssertEqual(loaded.version, SavedLayout.currentVersion)
        XCTAssertEqual(loaded.key, "alpha")
        XCTAssertEqual(loaded.savedAt.timeIntervalSince1970, layout.savedAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(loaded.displays, layout.displays)
        XCTAssertEqual(loaded.windows, layout.windows)

        let data = try Data(contentsOf: directory.appendingPathComponent("alpha.json"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["version"])
        XCTAssertNotNil(object["key"])
        XCTAssertNotNil(object["savedAt"])
        XCTAssertNotNil(object["displays"])
        XCTAssertNotNil(object["windows"])
    }

    func testOverwritePerKey() throws {
        try store.save(sample(key: "alpha", title: "First"))
        try store.save(sample(key: "alpha", title: "Second"))
        let loaded = try XCTUnwrap(try store.load(key: "alpha"))
        XCTAssertEqual(loaded.windows.map(\.windowTitle), ["Second"])
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names.filter { $0.hasSuffix(".json") }, ["alpha.json"])
    }

    func testListAndDelete() throws {
        try store.save(sample(key: "alpha", title: "A", savedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        try store.save(sample(key: "beta", title: "B", savedAt: Date(timeIntervalSince1970: 1_700_000_100)))
        let keys = try store.list().map(\.key)
        XCTAssertEqual(Set(keys), ["alpha", "beta"])
        try store.delete(key: "alpha")
        XCTAssertNil(try store.load(key: "alpha"))
        XCTAssertEqual(try store.list().map(\.key), ["beta"])
        try store.delete(key: "missing")
    }

    func testCorruptFileDoesNotDestroyOtherLayouts() throws {
        try store.save(sample(key: "alpha", title: "Keep Me"))
        try store.save(sample(key: "beta", title: "Also Fine"))
        let corruptURL = directory.appendingPathComponent("alpha.json")
        try Data("{".utf8).write(to: corruptURL)

        let listed = try store.list()
        XCTAssertEqual(listed.map(\.key), ["beta"])
        XCTAssertEqual(listed.first?.windows.first?.windowTitle, "Also Fine")
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptURL.path))
        XCTAssertThrowsError(try store.load(key: "alpha")) { error in
            XCTAssertEqual(error as? LayoutStoreError, .corrupt)
        }
        let survivor = try XCTUnwrap(try store.load(key: "beta"))
        XCTAssertEqual(survivor.windows.first?.windowTitle, "Also Fine")
    }

    func testAtomicWriteUsesTempFileThenRename() throws {
        try store.save(sample(key: "alpha", title: "Old"))
        let flag = CaptureFlag()
        let writer = AtomicFile(beforeRename: {
            let names = try FileManager.default.contentsOfDirectory(atPath: self.directory.path)
            let temps = names.filter { $0.contains(".tmp") }
            XCTAssertEqual(temps.count, 1)
            let existing = try String(contentsOf: self.directory.appendingPathComponent("alpha.json"), encoding: .utf8)
            XCTAssertTrue(existing.contains("Old"))
            let tempText = try String(
                contentsOf: self.directory.appendingPathComponent(temps[0]),
                encoding: .utf8
            )
            XCTAssertTrue(tempText.contains("New"))
            flag.sawTempBesideOriginal = true
        })
        let atomicStore = LayoutStore(directory: directory, writer: writer)
        try atomicStore.save(sample(key: "alpha", title: "New"))
        XCTAssertTrue(flag.sawTempBesideOriginal)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains { $0.contains(".tmp") })
        let loaded = try XCTUnwrap(try store.load(key: "alpha"))
        XCTAssertEqual(loaded.windows.first?.windowTitle, "New")
    }

    func testFailedAtomicWriteDoesNotDestroyExistingLayout() throws {
        try store.save(sample(key: "alpha", title: "Old"))
        let writer = AtomicFile(beforeRename: {
            throw LayoutStoreError.writeFailed("boom")
        })
        let failingStore = LayoutStore(directory: directory, writer: writer)
        XCTAssertThrowsError(try failingStore.save(sample(key: "alpha", title: "New"))) { error in
            XCTAssertEqual(error as? LayoutStoreError, .writeFailed("boom"))
        }
        let loaded = try XCTUnwrap(try store.load(key: "alpha"))
        XCTAssertEqual(loaded.windows.first?.windowTitle, "Old")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains { $0.contains(".tmp") })
    }

    func testInvalidKeyDoesNotEscapeTheDirectory() throws {
        let layout = sample(key: "../nope", title: "Escape")
        XCTAssertThrowsError(try store.save(layout)) { error in
            XCTAssertEqual(error as? LayoutStoreError, .invalidKey)
        }
        let escaped = directory.deletingLastPathComponent().appendingPathComponent("nope.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))
    }

    func testSaveCreatesMissingDirectory() throws {
        let nested = directory.appendingPathComponent("Window Minder/layouts", isDirectory: true)
        let nestedStore = LayoutStore(directory: nested)
        try nestedStore.save(sample(key: "alpha", title: "Nested"))
        XCTAssertEqual(try nestedStore.load(key: "alpha")?.windows.first?.windowTitle, "Nested")
    }

    func testUnsupportedVersionIsRejectedAndDoesNotHideOtherLayouts() throws {
        try store.save(sample(key: "beta", title: "Keep"))
        let stale = """
        {"displays":[],"key":"alpha","savedAt":"2023-11-14T22:13:20Z","version":2,"windows":[]}
        """
        try Data(stale.utf8).write(to: directory.appendingPathComponent("alpha.json"))
        XCTAssertThrowsError(try store.load(key: "alpha")) { error in
            XCTAssertEqual(error as? LayoutStoreError, .unsupportedVersion)
        }
        XCTAssertEqual(try store.list().map(\.key), ["beta"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("alpha.json").path))
    }

    func testDiskRoundTripKeepsTheLayoutWhenOriginsAndUUIDChange() throws {
        let savedDisplay = DisplayDescriptor(
            uuid: "OLD-UUID",
            frame: WMRect(x: -2560, y: -229, width: 2560, height: 1440),
            pixelWidth: 3840,
            pixelHeight: 2160,
            name: "LU28R55"
        )
        let legacy = SavedLayout(
            version: SavedLayout.currentVersion,
            key: "legacy-origin-key",
            savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            displays: [savedDisplay],
            windows: [
                WindowRecord(
                    bundleIdentifier: "com.apple.finder",
                    windowTitle: "Documents",
                    windowIndex: 0,
                    frame: WMRect(x: -2400, y: -100, width: 800, height: 600)
                ),
            ]
        )
        try store.save(legacy)
        let loadedLegacy = try XCTUnwrap(try store.load(key: "legacy-origin-key"))
        XCTAssertEqual(loadedLegacy.windows, legacy.windows)
        XCTAssertNil(loadedLegacy.displays.first?.vendorID)

        let currentDisplay = DisplayDescriptor(
            uuid: "NEW-UUID",
            frame: WMRect(x: 1, y: -2, width: 2560, height: 1440),
            pixelWidth: 3840,
            pixelHeight: 2160,
            name: "LU28R55",
            vendorID: 4268,
            productID: 16823,
            serialNumber: 99
        )
        let current = DisplayConfiguration(displays: [currentDisplay])
        XCTAssertNotEqual(current.key, legacy.key)
        let chosen = LayoutCatalog.layout(for: current, in: try store.list())
        XCTAssertEqual(chosen?.windows.first?.windowTitle, "Documents")

        let exact = SavedLayout(
            version: SavedLayout.currentVersion,
            key: current.key,
            savedAt: Date(timeIntervalSince1970: 1_700_000_500),
            displays: [currentDisplay],
            windows: [
                WindowRecord(
                    bundleIdentifier: "com.apple.Safari",
                    windowTitle: "Start Page",
                    windowIndex: 0,
                    frame: WMRect(x: 40, y: 50, width: 900, height: 700)
                ),
            ]
        )
        try store.save(exact)
        let roundTrip = try XCTUnwrap(try store.load(key: current.key))
        XCTAssertEqual(roundTrip.displays.first?.vendorID, 4268)
        XCTAssertEqual(roundTrip.displays.first?.productID, 16823)
        XCTAssertEqual(roundTrip.displays.first?.serialNumber, 99)
        XCTAssertEqual(roundTrip.windows.first?.windowTitle, "Start Page")
        let jittered = DisplayConfiguration(displays: [
            DisplayDescriptor(
                uuid: "YET-ANOTHER-UUID",
                frame: WMRect(x: 12, y: 40, width: 2560, height: 1440),
                pixelWidth: 3840,
                pixelHeight: 2160,
                vendorID: 4268,
                productID: 16823,
                serialNumber: 99
            ),
        ])
        XCTAssertEqual(jittered.key, current.key)
        XCTAssertEqual(LayoutCatalog.layout(for: jittered, in: try store.list())?.key, current.key)
    }

    func testLayoutSavedBeforeEDIDStillDecodes() throws {
        let json = """
        {
          "displays": [
            {
              "frame": {"height": 900, "width": 1440, "x": 0, "y": 0},
              "name": "Built-in",
              "pixelHeight": 1800,
              "pixelWidth": 2880,
              "uuid": "UUID-A"
            }
          ],
          "key": "alpha",
          "savedAt": "2023-11-14T22:13:20Z",
          "version": 1,
          "windows": []
        }
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("alpha.json"))
        let loaded = try XCTUnwrap(try store.load(key: "alpha"))
        XCTAssertNil(loaded.displays.first?.vendorID)
        XCTAssertNil(loaded.displays.first?.productID)
        XCTAssertNil(loaded.displays.first?.serialNumber)
        XCTAssertEqual(loaded.displays.first?.uuid, "UUID-A")
    }

    func testLayoutsDirectoryPath() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let url = LayoutLocation.layoutsDirectory(homeDirectory: home)
        XCTAssertEqual(url.path, "/Users/example/Library/Application Support/Window Minder/layouts")
    }

    private func sample(
        key: String,
        title: String,
        name: String? = "Built-in",
        savedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> SavedLayout {
        SavedLayout(
            version: SavedLayout.currentVersion,
            key: key,
            savedAt: savedAt,
            displays: [
                DisplayDescriptor(
                    uuid: "UUID-A",
                    frame: WMRect(x: 0, y: 0, width: 1440, height: 900),
                    pixelWidth: 2880,
                    pixelHeight: 1800,
                    name: name
                ),
                DisplayDescriptor(
                    uuid: "UUID-B",
                    frame: WMRect(x: -1720, y: 40, width: 1600, height: 900),
                    pixelWidth: 3200,
                    pixelHeight: 1800,
                    name: nil
                ),
            ],
            windows: [
                WindowRecord(
                    bundleIdentifier: "com.apple.finder",
                    windowTitle: title,
                    windowIndex: 0,
                    frame: WMRect(x: 80, y: 120, width: 640, height: 480)
                ),
            ]
        )
    }
}

private final class CaptureFlag {
    var sawTempBesideOriginal = false
}
