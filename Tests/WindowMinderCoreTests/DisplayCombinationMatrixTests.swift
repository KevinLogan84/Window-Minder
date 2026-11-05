import XCTest
#if canImport(WindowMinderCore)
@testable import WindowMinderCore
#endif

/// Every move between the real display setups this Mac has used: the built-in
/// screen, an LG LU28R55, and a Sony TV. Each pair is checked for a plug or
/// unplug while awake and for a sleep and wake, with and without a saved layout.
final class DisplayCombinationMatrixTests: XCTestCase {
    // Real identities, taken from the saved layout files.
    static let builtIn = DisplayDescriptor(
        uuid: "37D8832A-2D66-02CA-B9F7-8F30A301B230",
        frame: WMRect(x: 0, y: 0, width: 1512, height: 982),
        pixelWidth: 1512, pixelHeight: 982, name: "Built-in Retina Display",
        vendorID: 1552, productID: 41057, serialNumber: 4_251_086_178
    )
    static let lg = DisplayDescriptor(
        uuid: "14C9908E-8F1F-477D-A24F-7DBBDCF8DF05",
        frame: WMRect(x: 0, y: 0, width: 3008, height: 1692),
        pixelWidth: 3008, pixelHeight: 1692, name: "LU28R55",
        vendorID: 19501, productID: 4120, serialNumber: 809_056_085
    )
    static let sony = DisplayDescriptor(
        uuid: "23ADC171-ED71-44B9-92E5-2E3DDA02101E",
        frame: WMRect(x: 0, y: 0, width: 1920, height: 1080),
        pixelWidth: 1920, pixelHeight: 1080, name: "SONY TV  *02",
        vendorID: 19929, productID: 50179, serialNumber: 16_843_009
    )

    static func placed(_ display: DisplayDescriptor, x: Double, y: Double = 0) -> DisplayDescriptor {
        var copy = display
        copy.frame.x = x
        copy.frame.y = y
        return copy
    }

    struct Setup {
        var name: String
        var displays: [DisplayDescriptor]
        var configuration: DisplayConfiguration { DisplayConfiguration(displays: displays) }
        var key: String { configuration.key }
        var tokens: [String] { displays.map { DisplayIdentity.token(for: $0) } }
    }

    static let setups: [Setup] = [
        Setup(name: "built-in", displays: [builtIn]),
        Setup(name: "LU28R55", displays: [lg]),
        Setup(name: "LU28R55 + built-in", displays: [lg, placed(builtIn, x: 3008)]),
        Setup(name: "SONY TV", displays: [sony]),
        Setup(name: "SONY TV + built-in", displays: [sony, placed(builtIn, x: 1920)]),
    ]

    // MARK: Keys

    func testKeysMatchTheSavedFilesOnThisMac() {
        XCTAssertEqual(Self.setups[0].key, "ecbafddeea9fa12b1ef4662333486c03445c7780ac1edd144ac253b86f927eba")
        XCTAssertEqual(Self.setups[1].key, "a3c0043894ba9c956fa1b7bdc29cf93f0d8a4fcc27c74b7efa64cf3bdad889fd")
        XCTAssertEqual(Self.setups[2].key, "5ec5362c33133b10ac91bc50d19fbdef34cab9f3b83fd4fabd29a6a01acbf81c")
        XCTAssertEqual(Self.setups[3].key, "770e4671345cf1b15b2305df4291dff211d625990f50b1986a3215a698ef4b0c")
    }

    func testEverySetupHasItsOwnKey() {
        XCTAssertEqual(Set(Self.setups.map(\.key)).count, Self.setups.count)
    }

    func testKeyIgnoresOrderArrangementAndUUIDChanges() {
        for setup in Self.setups {
            let reversed = DisplayConfiguration(displays: setup.displays.reversed()).key
            XCTAssertEqual(reversed, setup.key, setup.name)
            // Same screens, rearranged: built-in to the left, above, or as primary.
            let moved = setup.displays.enumerated().map { index, display in
                Self.placed(display, x: Double(index) * -1700, y: Double(index) * 500)
            }
            XCTAssertEqual(DisplayConfiguration(displays: moved).key, setup.key, setup.name)
            // A new UUID after reboot does not matter when EDID is present.
            let renamed = setup.displays.map { display -> DisplayDescriptor in
                var copy = display
                copy.uuid = UUID().uuidString
                return copy
            }
            XCTAssertEqual(DisplayConfiguration(displays: renamed).key, setup.key, setup.name)
        }
    }

    func testResolutionChangeIsADifferentSetup() {
        var scaled = Self.lg
        scaled.frame.width = 2560
        scaled.frame.height = 1440
        scaled.pixelWidth = 2560
        scaled.pixelHeight = 1440
        XCTAssertNotEqual(DisplayConfiguration(displays: [scaled]).key, Self.setups[1].key)
    }

    // MARK: Auto-restore decisions

    private func isStrictSubset(_ small: Setup, of large: Setup) -> Bool {
        let a = Set(small.tokens)
        let b = Set(large.tokens)
        return a.count < b.count && a.isSubset(of: b)
    }

    private func probe(
        _ setup: Setup?,
        hasLayout: Bool,
        keyChanged: Bool,
        now: TimeInterval,
        before: Setup,
        beforeHasLayout: Bool
    ) -> DisplayRestoreCoalescer.Probe {
        DisplayRestoreCoalescer.Probe(
            autoRestore: true,
            displayKey: setup?.key,
            hasSavedLayout: hasLayout,
            dragInProgress: false,
            keyChanged: keyChanged,
            now: now,
            currentDisplayTokens: setup?.tokens ?? [],
            preWakeDisplayTokens: before.tokens,
            preWakeHasSavedLayout: beforeHasLayout
        )
    }

    func testPlugAndUnplugWhileAwake() {
        for from in Self.setups {
            for to in Self.setups where to.key != from.key {
                for hasLayout in [true, false] {
                    var coalescer = DisplayRestoreCoalescer()
                    guard case .arm(let generation) = coalescer.note(.displayChange, at: 100) else {
                        return XCTFail("display change did not arm")
                    }
                    let decision = coalescer.evaluate(generation, probe(
                        to, hasLayout: hasLayout, keyChanged: true, now: 101.5,
                        before: from, beforeHasLayout: true
                    ))
                    let label = "\(from.name) -> \(to.name) layout=\(hasLayout)"
                    if hasLayout {
                        XCTAssertEqual(decision, .restore(key: to.key, generation: generation), label)
                    } else {
                        XCTAssertEqual(decision, .skip, label)
                    }
                }
            }
        }
    }

    func testFlickerToTheSameSetupDoesNotMoveWindows() {
        for setup in Self.setups {
            var coalescer = DisplayRestoreCoalescer()
            guard case .arm(let generation) = coalescer.note(.displayChange, at: 100) else {
                return XCTFail("display change did not arm")
            }
            let decision = coalescer.evaluate(generation, probe(
                setup, hasLayout: true, keyChanged: false, now: 101.5,
                before: setup, beforeHasLayout: true
            ))
            XCTAssertEqual(decision, .skip, setup.name)
        }
    }

    func testWakeIntoEverySetup() {
        for from in Self.setups {
            for to in Self.setups {
                for hasLayout in [true, false] {
                    let label = "wake \(from.name) -> \(to.name) layout=\(hasLayout)"
                    var coalescer = DisplayRestoreCoalescer()
                    guard case .arm(let generation) = coalescer.note(.wake, at: 100) else {
                        return XCTFail("wake did not arm")
                    }
                    let decision = coalescer.evaluate(generation, probe(
                        to, hasLayout: hasLayout, keyChanged: to.key != from.key, now: 101.5,
                        before: from, beforeHasLayout: true
                    ))
                    if isStrictSubset(to, of: from) {
                        // A screen is missing: wait for it instead of shrinking the layout.
                        guard case .waitForDisplays = decision else {
                            XCTFail("\(label): expected wait, got \(decision)")
                            continue
                        }
                    } else if hasLayout {
                        XCTAssertEqual(decision, .restore(key: to.key, generation: generation), label)
                    } else {
                        XCTAssertEqual(decision, .skip, label)
                    }
                }
            }
        }
    }

    func testWakeWithMissingScreenThatComesBack() {
        for from in Self.setups {
            for to in Self.setups where isStrictSubset(to, of: from) {
                let label = "wake \(from.name) -> \(to.name) -> \(from.name)"
                var coalescer = DisplayRestoreCoalescer()
                guard case .arm(let first) = coalescer.note(.wake, at: 100) else {
                    return XCTFail("wake did not arm")
                }
                guard case .waitForDisplays = coalescer.evaluate(first, probe(
                    to, hasLayout: true, keyChanged: true, now: 101.5,
                    before: from, beforeHasLayout: true
                )) else {
                    XCTFail("\(label): did not wait")
                    continue
                }
                // The missing screen shows up 20 seconds later.
                guard case .arm(let second) = coalescer.note(.displayChange, at: 120) else {
                    XCTFail("\(label): return did not arm")
                    continue
                }
                let decision = coalescer.evaluate(second, probe(
                    from, hasLayout: true, keyChanged: false, now: 121.5,
                    before: from, beforeHasLayout: true
                ))
                XCTAssertEqual(decision, .restore(key: from.key, generation: second), label)
            }
        }
    }

    func testWakeWithMissingScreenThatNeverComesBack() {
        for from in Self.setups {
            for to in Self.setups where isStrictSubset(to, of: from) {
                for hasLayout in [true, false] {
                    let label = "wake \(from.name) -> \(to.name) forever layout=\(hasLayout)"
                    var coalescer = DisplayRestoreCoalescer()
                    guard case .arm(var generation) = coalescer.note(.wake, at: 100) else {
                        return XCTFail("wake did not arm")
                    }
                    var now: TimeInterval = 101.5
                    var decision = DisplayRestoreCoalescer.Decision.skip
                    var waits = 0
                    while true {
                        decision = coalescer.evaluate(generation, probe(
                            to, hasLayout: hasLayout, keyChanged: true, now: now,
                            before: from, beforeHasLayout: true
                        ))
                        guard case .waitForDisplays(let next) = decision else { break }
                        waits += 1
                        generation = next
                        now += DisplayRestoreTiming.debounce
                        if waits > 1_000 { break }
                    }
                    XCTAssertGreaterThan(waits, 0, label)
                    XCTAssertLessThanOrEqual(now - 100, DisplayRestoreTiming.wakeLayoutWindow + 2 * DisplayRestoreTiming.debounce, label)
                    if hasLayout {
                        XCTAssertEqual(decision, .restore(key: to.key, generation: generation), label)
                    } else {
                        XCTAssertEqual(decision, .skip, label)
                    }
                }
            }
        }
    }

    // MARK: Placement across arrangements

    /// A window saved on each screen lands on the same screen, at the same offset,
    /// whatever the arrangement or primary display is now.
    func testWindowsFollowTheirScreenInEveryArrangement() {
        let multi = Self.setups.filter { $0.displays.count > 1 }
        for setup in multi {
            let saved = setup.displays
            let big = saved[0]
            let laptop = saved[1]
            let arrangements: [(String, [DisplayDescriptor])] = [
                ("laptop right", [Self.placed(big, x: 0), Self.placed(laptop, x: big.frame.width)]),
                ("laptop left", [Self.placed(big, x: 0), Self.placed(laptop, x: -laptop.frame.width)]),
                ("laptop below", [Self.placed(big, x: 0), Self.placed(laptop, x: 400, y: -laptop.frame.height)]),
                ("laptop above", [Self.placed(big, x: 0), Self.placed(laptop, x: 200, y: big.frame.height)]),
                ("laptop primary", [Self.placed(laptop, x: 0), Self.placed(big, x: -big.frame.width, y: -300)]),
            ]
            for display in saved {
                let window = WindowRecord(
                    bundleIdentifier: "com.apple.Safari",
                    windowTitle: "T",
                    windowIndex: 0,
                    frame: WMRect(x: display.frame.x + 50, y: display.frame.y + 40, width: 800, height: 600),
                    minimized: false
                )
                for (name, current) in arrangements {
                    let result = WindowPlacement.placing([window], savedDisplays: saved, currentDisplays: current)[0]
                    let target = current.first { DisplayIdentity.token(for: $0) == DisplayIdentity.token(for: display) }!
                    let label = "\(setup.name), window on \(display.name ?? "?"), \(name)"
                    XCTAssertEqual(result.frame.x, target.frame.x + 50, accuracy: 0.001, label)
                    XCTAssertEqual(result.frame.y, target.frame.y + 40, accuracy: 0.001, label)
                    XCTAssertEqual(result.frame.width, 800, label)
                    XCTAssertEqual(result.frame.height, 600, label)
                }
            }
        }
    }

    /// Accessibility and Cocoa coordinates round-trip for a window on each screen.
    func testCoordinatesRoundTripOnEveryScreen() {
        for setup in Self.setups {
            let primaryHeight = setup.displays[0].frame.height
            for display in setup.displays {
                let cocoa = WMRect(x: display.frame.x + 10, y: display.frame.y + 20, width: 700, height: 500)
                let ax = CoordinateConverter.accessibilityFrame(fromCocoa: cocoa, primaryHeight: primaryHeight)
                XCTAssertEqual(CoordinateConverter.cocoaFrame(fromAccessibility: ax, primaryHeight: primaryHeight), cocoa, setup.name)
            }
        }
    }

    // MARK: Unplug after a wake has been handled

    /// Your 12:17 test: launch (or unlock) restores the full setup, then the monitor is
    /// unplugged 30 seconds later. That is a real unplug and must not wait 90 seconds.
    func testUnplugAfterWakeWasHandledDoesNotWait() {
        for signal in [DisplayRestoreCoalescer.Signal.launch, .wake, .screensWake, .sessionUnlock] {
            for from in Self.setups {
                for to in Self.setups where isStrictSubset(to, of: from) {
                    let label = "\(signal) on \(from.name), then unplug to \(to.name)"
                    var coalescer = DisplayRestoreCoalescer()
                    guard case .arm(let first) = coalescer.note(signal, at: 100) else {
                        return XCTFail("signal did not arm")
                    }
                    _ = coalescer.evaluate(first, probe(
                        from, hasLayout: true, keyChanged: true, now: 101.5,
                        before: from, beforeHasLayout: true
                    ))
                    _ = coalescer.restoreFinished()
                    guard case .arm(let second) = coalescer.note(.displayChange, at: 130) else {
                        XCTFail("\(label): unplug did not arm")
                        continue
                    }
                    let decision = coalescer.evaluate(second, probe(
                        to, hasLayout: true, keyChanged: true, now: 131.5,
                        before: from, beforeHasLayout: true
                    ))
                    XCTAssertEqual(decision, .restore(key: to.key, generation: second), label)
                }
            }
        }
    }

    /// The wait still applies to a screen that is missing at the wake itself.
    func testScreenMissingAtWakeStillWaitsAfterEarlierUnplug() {
        let both = Self.setups[2]
        let laptop = Self.setups[0]
        var coalescer = DisplayRestoreCoalescer()
        guard case .arm(let first) = coalescer.note(.launch, at: 0) else { return XCTFail() }
        _ = coalescer.evaluate(first, probe(both, hasLayout: true, keyChanged: true, now: 1.5, before: both, beforeHasLayout: true))
        _ = coalescer.restoreFinished()
        // Much later: sleep with both, wake with only the laptop.
        guard case .arm(let wake) = coalescer.note(.wake, at: 5_000) else { return XCTFail() }
        let decision = coalescer.evaluate(wake, probe(laptop, hasLayout: true, keyChanged: true, now: 5_001.5, before: both, beforeHasLayout: true))
        guard case .waitForDisplays = decision else { return XCTFail("expected wait, got \(decision)") }
    }

    // MARK: Windows larger than the screen

    func testWindowTooBigForTheScreenIsFitted() {
        let laptopArea = WMRect(x: 3008, y: 0, width: 1512, height: 950)
        let lgArea = WMRect(x: 0, y: 0, width: 3008, height: 1661)
        let areas = [lgArea, laptopArea]
        let huge = WMRect(x: 3008, y: 0, width: 2400, height: 1500)
        XCTAssertEqual(WindowPlacement.fitting(huge, into: areas), laptopArea)
        let tall = WMRect(x: 3100, y: 100, width: 800, height: 1200)
        XCTAssertEqual(WindowPlacement.fitting(tall, into: areas), WMRect(x: 3100, y: 0, width: 800, height: 950))
        // Windows that fit are left alone, even when they hang off an edge.
        let fits = WMRect(x: 3008 + 1000, y: 100, width: 800, height: 600)
        XCTAssertEqual(WindowPlacement.fitting(fits, into: areas), fits)
        let onLG = WMRect(x: 10, y: 10, width: 3000, height: 1600)
        XCTAssertEqual(WindowPlacement.fitting(onLG, into: areas), onLG)
        XCTAssertEqual(WindowPlacement.fitting(huge, into: []), huge)
    }
}
