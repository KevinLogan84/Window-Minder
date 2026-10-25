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

    func testFrameOriginChangesTheKey() {
        XCTAssertNotEqual(
            DisplayConfiguration(displays: [display(x: 0)]).key,
            DisplayConfiguration(displays: [display(x: 1)]).key
        )
        XCTAssertNotEqual(
            DisplayConfiguration(displays: [display(y: 0)]).key,
            DisplayConfiguration(displays: [display(y: -100)]).key
        )
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
        name: String? = nil
    ) -> DisplayDescriptor {
        DisplayDescriptor(
            uuid: uuid,
            frame: WMRect(x: x, y: y, width: width, height: height),
            pixelWidth: pixelsWide,
            pixelHeight: pixelsHigh,
            name: name
        )
    }
}
