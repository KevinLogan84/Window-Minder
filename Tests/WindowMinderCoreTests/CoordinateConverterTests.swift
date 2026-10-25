import XCTest
#if canImport(WindowMinderCore)
@testable import WindowMinderCore
#endif

final class CoordinateConverterTests: XCTestCase {
    func testPrimaryHeightConversionBothWays() {
        let primaryHeight = 900.0
        let accessibility = WMRect(x: 100, y: 80, width: 400, height: 300)
        let cocoa = CoordinateConverter.cocoaFrame(fromAccessibility: accessibility, primaryHeight: primaryHeight)
        XCTAssertEqual(cocoa, WMRect(x: 100, y: 520, width: 400, height: 300))
        XCTAssertEqual(
            CoordinateConverter.accessibilityFrame(fromCocoa: cocoa, primaryHeight: primaryHeight),
            accessibility
        )
    }

    func testWindowOnDisplayLeftOfPrimary() {
        let primaryHeight = 1080.0
        let accessibility = WMRect(x: -1720, y: 140, width: 1600, height: 900)
        let cocoa = CoordinateConverter.cocoaFrame(fromAccessibility: accessibility, primaryHeight: primaryHeight)
        XCTAssertEqual(cocoa, WMRect(x: -1720, y: 40, width: 1600, height: 900))
        XCTAssertEqual(
            CoordinateConverter.accessibilityFrame(fromCocoa: cocoa, primaryHeight: primaryHeight),
            accessibility
        )
    }

    func testWindowAbovePrimaryDisplay() {
        let primaryHeight = 800.0
        let accessibility = WMRect(x: 12, y: -240, width: 640, height: 200)
        let cocoa = CoordinateConverter.cocoaFrame(fromAccessibility: accessibility, primaryHeight: primaryHeight)
        XCTAssertEqual(cocoa, WMRect(x: 12, y: 840, width: 640, height: 200))
        XCTAssertEqual(
            CoordinateConverter.accessibilityFrame(fromCocoa: cocoa, primaryHeight: primaryHeight),
            accessibility
        )
    }
}
