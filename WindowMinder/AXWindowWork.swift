import ApplicationServices
import CoreGraphics
import Foundation
import os

private final class AXResultBox<T> {
    var values: [T?]
    init(count: Int) { values = [T?](repeating: nil, count: count) }
}

private let windowLogger = Logger(subsystem: WindowMinderIdentity.bundleIdentifier, category: "windows")
private let windowSignposter = OSSignposter(subsystem: WindowMinderIdentity.bundleIdentifier, category: "windows")

enum AXTrace: Sendable {
    case store
    case snapshot
}

struct AXCaptureReport: Sendable {
    var windows: [WindowRecord]
    var appsScanned: Int
    var appsTimedOut: Int
    var elapsedMilliseconds: Int
}

struct AXRestoreReport: Sendable {
    var summary: RestoreSummary
    var elapsedMilliseconds: Int
    var bundlesWithLiveWindows: [String]
    /// Saved windows that moved, or that were left minimized on purpose.
    /// A window that was found but could not be moved is not included, so the
    /// caller can retry it.
    var matchedSaved: [WindowRecord]
    /// Saved windows that were paired with a live window and could not be moved.
    var failedSaved: [WindowRecord]
}

/// Accessibility reads and writes. Each app element is used on one task.
/// Callers keep AppKit and menu updates on the main actor.
///
/// Accessibility only returns windows on the current Space, and a window that
/// belongs to an app that is not running is skipped. Window Minder does not
/// launch apps or switch Spaces to find the rest.
enum AXWindowWork {
    static func capture(
        targets: [ScanCandidate],
        primaryHeight: Double,
        trace: AXTrace
    ) async -> AXCaptureReport {
        let started = Date()
        let interval = trace == .store
            ? windowSignposter.beginInterval("Store Windows")
            : windowSignposter.beginInterval("Snapshot Windows")
        defer {
            if trace == .store {
                windowSignposter.endInterval("Store Windows", interval)
            } else {
                windowSignposter.endInterval("Snapshot Windows", interval)
            }
        }
        let timeout = Float(WindowScanPlan.timeout(interactive: trace == .store))
        await setSystemWideTimeout(timeout)
        let results = await mapApps(targets) { target in
            captureApp(target, primaryHeight: primaryHeight, timeout: timeout)
        }
        let windows = results.flatMap(\.windows).sorted { lhs, rhs in
            if lhs.bundleIdentifier != rhs.bundleIdentifier {
                return lhs.bundleIdentifier < rhs.bundleIdentifier
            }
            if lhs.windowIndex != rhs.windowIndex {
                return lhs.windowIndex < rhs.windowIndex
            }
            return lhs.windowTitle < rhs.windowTitle
        }
        let timedOut = results.reduce(0) { $0 + ($1.timedOut ? 1 : 0) }
        let elapsed = elapsedMilliseconds(since: started)
        let scanned = targets.count
        let stored = windows.count
        if trace == .store {
            windowLogger.info(
                "Store elapsedMs=\(elapsed, privacy: .public) appsScanned=\(scanned, privacy: .public) appsTimedOut=\(timedOut, privacy: .public) windowsStored=\(stored, privacy: .public)"
            )
        } else {
            windowLogger.debug(
                "Snapshot elapsedMs=\(elapsed, privacy: .public) appsScanned=\(scanned, privacy: .public) appsTimedOut=\(timedOut, privacy: .public) windowsStored=\(stored, privacy: .public)"
            )
        }
        return AXCaptureReport(
            windows: windows,
            appsScanned: targets.count,
            appsTimedOut: timedOut,
            elapsedMilliseconds: elapsed
        )
    }

    static func restore(
        targets: [ScanCandidate],
        saved: [WindowRecord],
        ignoredBundleIdentifiers: Set<String>,
        primaryHeight: Double
    ) async -> AXRestoreReport {
        // Accessibility calls block. Keep them off the main thread so a trust
        // probe or the menu cannot sit behind them, and so a stuck call cannot
        // freeze the hourglass timer.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let report = restoreOffMain(
                    targets: targets,
                    saved: saved,
                    ignoredBundleIdentifiers: ignoredBundleIdentifiers,
                    primaryHeight: primaryHeight
                )
                continuation.resume(returning: report)
            }
        }
    }

    private static func restoreOffMain(
        targets: [ScanCandidate],
        saved: [WindowRecord],
        ignoredBundleIdentifiers: Set<String>,
        primaryHeight: Double
    ) -> AXRestoreReport {
        let started = Date()
        let interval = windowSignposter.beginInterval("Restore Windows")
        defer { windowSignposter.endInterval("Restore Windows", interval) }
        let timeout = Float(WindowScanPlan.interactiveTimeoutSeconds)
        setSystemWideTimeoutSync(timeout)
        let ignored = ignoredBundleIdentifiers.union([WindowMinderIdentity.bundleIdentifier])
        let results = mapAppsSync(targets) { target in
            restoreApp(
                target,
                saved: saved,
                ignoredBundleIdentifiers: ignored,
                primaryHeight: primaryHeight,
                timeout: timeout
            )
        }
        let scanned = Set(targets.map(\.bundleIdentifier))
        let notRunning = saved.filter { record in
            !record.bundleIdentifier.isEmpty
                && !ignored.contains(record.bundleIdentifier)
                && !scanned.contains(record.bundleIdentifier)
        }.count
        let summary = RestoreSummary(
            restored: results.reduce(0) { $0 + $1.restored },
            skipped: results.reduce(0) { $0 + $1.skipped } + notRunning,
            failed: results.reduce(0) { $0 + $1.failed },
            unresponsiveAppCount: results.reduce(0) { $0 + ($1.timedOut ? 1 : 0) }
        )
        let elapsed = elapsedMilliseconds(since: started)
        let bundlesWithLiveWindows = results.filter(\.sawWindows).map(\.bundleIdentifier).sorted()
        let matchedSaved = results.flatMap(\.matchedSaved)
        let failedSaved = results.flatMap(\.failedSaved)
        windowLogger.notice(
            "Restore elapsedMs=\(elapsed, privacy: .public) appsScanned=\(targets.count, privacy: .public) appsTimedOut=\(summary.unresponsiveAppCount, privacy: .public) restored=\(summary.restored, privacy: .public) skipped=\(summary.skipped, privacy: .public) failed=\(summary.failed, privacy: .public) matched=\(matchedSaved.count, privacy: .public)"
        )
        return AXRestoreReport(
            summary: summary,
            elapsedMilliseconds: elapsed,
            bundlesWithLiveWindows: bundlesWithLiveWindows,
            matchedSaved: matchedSaved,
            failedSaved: failedSaved
        )
    }

    private struct AppCapture: Sendable {
        var windows: [WindowRecord]
        var timedOut: Bool
    }

    private struct AppRestore: Sendable {
        var bundleIdentifier: String
        var restored: Int
        var skipped: Int
        var failed: Int
        var timedOut: Bool
        var sawWindows: Bool
        var matchedSaved: [WindowRecord]
        var failedSaved: [WindowRecord]
    }

    private static func captureApp(_ target: ScanCandidate, primaryHeight: Double, timeout: Float) -> AppCapture {
        let app = AXUIElementCreateApplication(target.processIdentifier)
        setTimeout(app, timeout)
        switch copyWindows(of: app) {
        case .timedOut:
            windowLogger.error(
                "Accessibility timed out bundle=\(target.bundleIdentifier, privacy: .public) pid=\(target.processIdentifier, privacy: .public)"
            )
            return AppCapture(windows: [], timedOut: true)
        case .windows(let elements):
            let attributes = elements.map { copyWindowAttributes($0, timeout: timeout) }
            let classified = WindowCaptureRules.classify(attributes)
            var windows: [WindowRecord] = []
            for item in classified where item.includeInStore {
                guard let index = item.windowIndex, let frame = item.attributes.frame else { continue }
                let cocoa = CoordinateConverter.cocoaFrame(fromAccessibility: frame, primaryHeight: primaryHeight)
                windows.append(
                    WindowRecord(
                        bundleIdentifier: target.bundleIdentifier,
                        windowTitle: item.attributes.title,
                        windowIndex: index,
                        frame: cocoa,
                        minimized: false
                    )
                )
            }
            return AppCapture(windows: windows, timedOut: false)
        }
    }

    private static func restoreApp(
        _ target: ScanCandidate,
        saved: [WindowRecord],
        ignoredBundleIdentifiers: Set<String>,
        primaryHeight: Double,
        timeout: Float
    ) -> AppRestore {
        let savedForApp = saved.filter { $0.bundleIdentifier == target.bundleIdentifier }
        let app = AXUIElementCreateApplication(target.processIdentifier)
        setTimeout(app, timeout)
        // With AXEnhancedUserInterface on (VoiceOver, some window tools, Chromium and
        // Electron apps), the app animates moves and answers with stale frames, so the
        // window lands short of its target. Turn it off for the move and put it back.
        let enhancedUI = boolAttribute("AXEnhancedUserInterface", of: app)
        if enhancedUI == true {
            _ = setBoolean(false, attribute: "AXEnhancedUserInterface", on: app)
        }
        defer {
            if enhancedUI == true {
                _ = setBoolean(true, attribute: "AXEnhancedUserInterface", on: app)
            }
        }
        switch copyWindows(of: app) {
        case .timedOut:
            windowLogger.error(
                "Accessibility timed out bundle=\(target.bundleIdentifier, privacy: .public) pid=\(target.processIdentifier, privacy: .public)"
            )
            let skipped = savedForApp.filter { !ignoredBundleIdentifiers.contains($0.bundleIdentifier) }.count
            return AppRestore(
                bundleIdentifier: target.bundleIdentifier,
                restored: 0,
                skipped: skipped,
                failed: 0,
                timedOut: true,
                sawWindows: false,
                matchedSaved: [],
                failedSaved: []
            )
        case .windows(let elements):
            let attributes = elements.map { copyWindowAttributes($0, timeout: timeout) }
            let classified = WindowCaptureRules.classify(attributes)
            var live: [(window: LiveWindow, element: AXUIElement, fullscreen: Bool)] = []
            for (offset, item) in classified.enumerated() where item.includeInRestore {
                guard let index = item.windowIndex, offset < elements.count else { continue }
                let frame = item.attributes.frame ?? WMRect(x: 0, y: 0, width: 0, height: 0)
                let cocoa = CoordinateConverter.cocoaFrame(fromAccessibility: frame, primaryHeight: primaryHeight)
                let record = WindowRecord(
                    bundleIdentifier: target.bundleIdentifier,
                    windowTitle: item.attributes.title,
                    windowIndex: index,
                    frame: cocoa,
                    minimized: item.attributes.minimized
                )
                let window = LiveWindow(
                    record: record,
                    processIdentifier: target.processIdentifier,
                    role: item.attributes.role,
                    subrole: item.attributes.subrole
                )
                live.append((window: window, element: elements[offset], fullscreen: item.attributes.fullscreen))
            }
            let matches = WindowMatcher.match(
                saved: savedForApp,
                live: live.map(\.window),
                ignoredBundleIdentifiers: ignoredBundleIdentifiers
            )
            var pool = live
            var restored = 0
            var failed = 0
            var skipped = 0
            // Only windows that landed are done. One that could not be moved, or that
            // ended up somewhere else, stays pending so the next pass tries it again.
            var settled: [WindowRecord] = []
            var failedSaved: [WindowRecord] = []
            for match in matches {
                guard let found = pool.firstIndex(where: { candidate in
                    candidate.window.record.bundleIdentifier == match.live.bundleIdentifier
                        && candidate.window.record.windowIndex == match.live.windowIndex
                        && candidate.window.record.windowTitle == match.live.windowTitle
                        && candidate.window.record.minimized == match.live.minimized
                }) else {
                    failed += 1
                    failedSaved.append(match.saved)
                    continue
                }
                let liveWindow = pool.remove(at: found)
                let action = RestoreFramePlan.action(
                    savedMinimized: match.saved.minimized,
                    liveMinimized: match.live.minimized,
                    liveFullscreen: liveWindow.fullscreen
                )
                switch action {
                case .skipMinimized:
                    skipped += 1
                    settled.append(match.saved)
                case .move(let exitFullscreen, let unminimize):
                    let landing = apply(
                        frame: match.saved.frame,
                        to: liveWindow.element,
                        primaryHeight: primaryHeight,
                        exitFullscreen: exitFullscreen,
                        unminimize: unminimize
                    )
                    switch landing {
                    case .exact, .positionOnly:
                        restored += 1
                        settled.append(match.saved)
                    case .missed:
                        failed += 1
                        failedSaved.append(match.saved)
                        windowLogger.error(
                            "Could not move \(match.live.bundleIdentifier, privacy: .public) window \(match.live.windowIndex, privacy: .public)"
                        )
                    }
                }
            }
            let eligible = savedForApp.filter { !ignoredBundleIdentifiers.contains($0.bundleIdentifier) }.count
            let notPresent = max(eligible - matches.count, 0)
            if notPresent > 0 {
                windowLogger.info(
                    "Skipped \(notPresent, privacy: .public) windows not present yet bundle=\(target.bundleIdentifier, privacy: .public)"
                )
            }
            skipped += notPresent
            return AppRestore(
                bundleIdentifier: target.bundleIdentifier,
                restored: restored,
                skipped: skipped,
                failed: failed,
                timedOut: false,
                sawWindows: !live.isEmpty,
                matchedSaved: settled,
                failedSaved: failedSaved
            )
        }
    }

    /// Writes the frame, reads it back, and writes again while it is off.
    private static func apply(
        frame: WMRect,
        to element: AXUIElement,
        primaryHeight: Double,
        exitFullscreen: Bool,
        unminimize: Bool
    ) -> RestoreFramePlan.Landing {
        if exitFullscreen {
            _ = setBoolean(false, attribute: "AXFullScreen", on: element)
        }
        if unminimize, !setBoolean(false, attribute: "AXMinimized", on: element) {
            return .missed
        }
        let axFrame = CoordinateConverter.accessibilityFrame(fromCocoa: frame, primaryHeight: primaryHeight)
        var landing = RestoreFramePlan.Landing.missed
        for _ in 0...RestoreFramePlan.maxCorrectionPasses {
            for step in RestoreFramePlan.writeOrder {
                switch step {
                case .position:
                    _ = setPoint(CGPoint(x: axFrame.x, y: axFrame.y), on: element)
                case .size:
                    _ = setSize(CGSize(width: axFrame.width, height: axFrame.height), on: element)
                }
            }
            landing = RestoreFramePlan.landing(target: axFrame, actual: readFrame(of: element))
            if landing == .exact { break }
        }
        return landing
    }

    private static func readFrame(of element: AXUIElement) -> WMRect? {
        let values = copyMultiple(element, names: ["AXPosition", "AXSize"])
        guard let position = pointValue(values[0]), let size = sizeValue(values[1]) else { return nil }
        return WMRect(
            x: Double(position.x),
            y: Double(position.y),
            width: Double(size.width),
            height: Double(size.height)
        )
    }

    private static func boolAttribute(_ name: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else {
            return nil
        }
        return boolValue(value)
    }

    private static func mapAppsSync<T>(
        _ targets: [ScanCandidate],
        _ body: @escaping (ScanCandidate) -> T
    ) -> [T] {
        guard !targets.isEmpty else { return [] }
        let queue = DispatchQueue(label: "com.kevinlogan.WindowMinder.ax", attributes: .concurrent)
        let group = DispatchGroup()
        let lock = NSLock()
        let slots = DispatchSemaphore(value: WindowScanPlan.maxConcurrentApps)
        let results = AXResultBox<T>(count: targets.count)
        for (index, target) in targets.enumerated() {
            slots.wait()
            group.enter()
            queue.async {
                let value = body(target)
                lock.lock()
                results.values[index] = value
                lock.unlock()
                slots.signal()
                group.leave()
            }
        }
        group.wait()
        return results.values.compactMap { $0 }
    }

    private static func mapApps<T: Sendable>(
        _ targets: [ScanCandidate],
        _ body: @escaping @Sendable (ScanCandidate) -> T
    ) async -> [T] {
        await withTaskGroup(of: T.self) { group in
            var iterator = targets.makeIterator()
            var started = 0
            while started < WindowScanPlan.maxConcurrentApps, let target = iterator.next() {
                group.addTask { body(target) }
                started += 1
            }
            var collected: [T] = []
            while let value = await group.next() {
                collected.append(value)
                if let target = iterator.next() {
                    group.addTask { body(target) }
                }
            }
            return collected
        }
    }

    private static func setSystemWideTimeoutSync(_ timeout: Float) {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
    }

    private static func setSystemWideTimeout(_ timeout: Float) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let system = AXUIElementCreateSystemWide()
                AXUIElementSetMessagingTimeout(system, timeout)
                continuation.resume()
            }
        }
    }

    private static func setTimeout(_ element: AXUIElement, _ timeout: Float) {
        AXUIElementSetMessagingTimeout(element, timeout)
    }

    private enum WindowList {
        case timedOut
        case windows([AXUIElement])
    }

    private static func copyWindows(of app: AXUIElement) -> WindowList {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        if error == .cannotComplete {
            return .timedOut
        }
        guard error == .success, let value else {
            windowLogger.error(
                "AX windows copy failed error=\(error.rawValue, privacy: .public)"
            )
            return .windows([])
        }
        return .windows(elements(from: value))
    }

    private static func elements(from value: CFTypeRef) -> [AXUIElement] {
        if let elements = value as? [AXUIElement] {
            return elements
        }
        guard CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = value as! CFArray
        return (0..<CFArrayGetCount(array)).compactMap { index in
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { return nil }
            return Unmanaged<AXUIElement>.fromOpaque(pointer).takeUnretainedValue()
        }
    }

    private static let attributeNames = [
        "AXRole",
        "AXSubrole",
        "AXTitle",
        "AXPosition",
        "AXSize",
        "AXMinimized",
        "AXFullScreen",
    ]

    private static func copyWindowAttributes(_ element: AXUIElement, timeout: Float) -> ScannedWindowAttributes {
        setTimeout(element, timeout)
        let values = copyMultiple(element, names: attributeNames)
        let role = stringValue(values[0])
        let subrole = stringValue(values[1])
        let title = stringValue(values[2]) ?? ""
        let position = pointValue(values[3])
        let size = sizeValue(values[4])
        let frame: WMRect?
        if let position, let size {
            frame = WMRect(
                x: Double(position.x),
                y: Double(position.y),
                width: Double(size.width),
                height: Double(size.height)
            )
        } else {
            frame = nil
        }
        return ScannedWindowAttributes(
            role: role,
            subrole: subrole,
            title: title,
            frame: frame,
            minimized: boolValue(values[5]),
            fullscreen: boolValue(values[6])
        )
    }

    private static func copyMultiple(_ element: AXUIElement, names: [String]) -> [CFTypeRef?] {
        let list = names as CFArray
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element,
            list,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &values
        )
        if error == .cannotComplete {
            return Array(repeating: nil, count: names.count)
        }
        guard let values else { return Array(repeating: nil, count: names.count) }
        return (0..<names.count).map { value(at: $0, in: values) }
    }

    private static func value(at index: Int, in array: CFArray) -> CFTypeRef? {
        guard index < CFArrayGetCount(array) else { return nil }
        guard let pointer = CFArrayGetValueAtIndex(array, index) else { return nil }
        let value = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
        if CFGetTypeID(value) == CFNullGetTypeID() { return nil }
        if CFGetTypeID(value) == AXValueGetTypeID() {
            let ax = value as! AXValue
            if AXValueGetType(ax) == .axError { return nil }
        }
        return value
    }

    private static func stringValue(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as! CFString as String
    }

    private static func boolValue(_ value: CFTypeRef?) -> Bool {
        guard let value else { return false }
        if let bool = value as? Bool { return bool }
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return CFBooleanGetValue(value as! CFBoolean)
    }

    private static func pointValue(_ value: CFTypeRef?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeValue(_ value: CFTypeRef?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func setPoint(_ point: CGPoint, on element: AXUIElement) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    private static func setSize(_ size: CGSize, on element: AXUIElement) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
    }

    private static func setBoolean(_ bool: Bool, attribute: String, on element: AXUIElement) -> Bool {
        let value: CFBoolean = bool ? kCFBooleanTrue : kCFBooleanFalse
        return AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }

    private static func elapsedMilliseconds(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1_000).rounded())
    }
}
