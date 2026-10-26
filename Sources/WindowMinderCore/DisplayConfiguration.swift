import Foundation

public struct DisplayDescriptor: Equatable, Codable, Sendable {
    public var uuid: String
    public var frame: WMRect
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var name: String?
    /// EDID vendor id. Nil when the display did not report one, including layouts saved before EDID identity.
    public var vendorID: UInt32?
    /// EDID product id.
    public var productID: UInt32?
    /// EDID serial. Zero is a real value on some panels and is kept when vendor and product are known.
    public var serialNumber: UInt32?

    public init(
        uuid: String,
        frame: WMRect,
        pixelWidth: Int,
        pixelHeight: Int,
        name: String? = nil,
        vendorID: UInt32? = nil,
        productID: UInt32? = nil,
        serialNumber: UInt32? = nil
    ) {
        self.uuid = uuid
        self.frame = frame
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
    }
}

public struct DisplayConfiguration: Equatable, Codable, Sendable {
    public var displays: [DisplayDescriptor]

    public init(displays: [DisplayDescriptor]) {
        self.displays = displays
    }

    /// Order-independent, filename-safe identity of this display setup.
    ///
    /// Each display contributes its stable identity and pixel size, plus the scaled
    /// point size so a resolution change is a different setup. Names, `CGDirectDisplayID`,
    /// and frame origins are not included. Origins move when the primary display or
    /// menu bar changes, and a dock replug often shifts them by a point.
    public var key: String {
        DisplayConfigKey.make(displays)
    }

    /// The integer is the live `CGDirectDisplayID`. It is accepted and ignored.
    /// Reordering the list does not change the key.
    public static func key(displays: [(DisplayDescriptor, UInt32)]) -> String {
        DisplayConfiguration(displays: displays.map(\.0)).key
    }
}

public enum PrimaryDisplayHeight {
    /// Height of the display at the Cocoa origin. If none is there, the first screen is the menu-bar display.
    public static func points(frames: [WMRect]) -> Double {
        if let primary = frames.first(where: { $0.x == 0 && $0.y == 0 && $0.height > 0 }) {
            return primary.height
        }
        return frames.first(where: { $0.height > 0 })?.height ?? 0
    }
}

public enum DisplayIdentity {
    /// EDID vendor and product when the panel reports them. A serial of zero still counts.
    /// `CGDisplayCreateUUIDFromDisplayID` is only the fallback: that UUID can change across a reboot.
    public static func token(
        vendorID: UInt32?,
        productID: UInt32?,
        serialNumber: UInt32?,
        uuid: String
    ) -> String {
        if usesEDID(vendorID: vendorID, productID: productID), let vendorID, let productID {
            return "edid:\(vendorID):\(productID):\(serialNumber ?? 0)"
        }
        let fallback = uuid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "uuid:\(fallback)"
    }

    public static func token(for display: DisplayDescriptor) -> String {
        token(
            vendorID: display.vendorID,
            productID: display.productID,
            serialNumber: display.serialNumber,
            uuid: display.uuid
        )
    }

    public static func usesEDID(vendorID: UInt32?, productID: UInt32?) -> Bool {
        guard let vendorID, let productID else { return false }
        return vendorID != 0 && productID != 0
    }

    public static func usesEDID(_ display: DisplayDescriptor) -> Bool {
        usesEDID(vendorID: display.vendorID, productID: display.productID)
    }
}

enum DisplayConfigKey {
    static func make(_ displays: [DisplayDescriptor]) -> String {
        SHA256.hex(displays.map(line).sorted().joined(separator: "\n"))
    }

    static func line(_ display: DisplayDescriptor) -> String {
        [
            DisplayIdentity.token(for: display),
            String(display.pixelWidth),
            String(display.pixelHeight),
            quantizedPoints(display.frame.width),
            quantizedPoints(display.frame.height),
        ].joined(separator: "|")
    }

    /// Pixel size and scaled point size, ignoring identity and origin.
    /// Layouts saved before EDID identity are matched with this.
    static func geometrySignature(_ displays: [DisplayDescriptor]) -> String {
        displays.map { display in
            [
                String(display.pixelWidth),
                String(display.pixelHeight),
                quantizedPoints(display.frame.width),
                quantizedPoints(display.frame.height),
            ].joined(separator: "x")
        }
        .sorted()
        .joined(separator: "\n")
    }

    /// Whole points. Sub-point frame noise is not a different display setup.
    static func quantizedPoints(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return String(Int64(value.rounded(.toNearestOrAwayFromZero)))
    }
}

public enum DisplayRestoreTiming {
    /// One restore after a burst of dock, wake, or login events goes quiet.
    /// Another signal restarts this wait, so displays that keep reconnecting
    /// do not get a restore in the middle of the burst.
    public static let debounce: TimeInterval = 1.5
    /// After a restore, the same display setup is not restored again until this
    /// long has passed. Wake and `screensDidWake` often both fire. A different
    /// display key is not held back.
    public static let sameSetupCoalesce: TimeInterval = 4
    /// If the screens are still empty when the first quiet period ends, a wake
    /// keeps its "restore even if the key is unchanged" status until this deadline.
    public static let wakeLayoutWindow: TimeInterval = 8
}

public enum DisplayRestorePolicy {
    /// Launch and wake restore even when the display key is unchanged, because macOS
    /// has put the windows back in their default places. A later screen event restores
    /// only when the connected set actually changed, so a stray notification does not
    /// yank windows the user just moved.
    public static func shouldRestore(
        autoRestore: Bool,
        hasDisplays: Bool,
        keyChanged: Bool,
        restoreEvenIfUnchanged: Bool
    ) -> Bool {
        guard autoRestore, hasDisplays else { return false }
        return restoreEvenIfUnchanged || keyChanged
    }
}

public enum PointerDrag {
    /// A window drag holds a mouse button down. `NSEvent.pressedMouseButtons` is the mask.
    public static func isInProgress(pressedMouseButtons: Int) -> Bool {
        pressedMouseButtons != 0
    }
}

/// One restore for a burst of wake, screen-wake, unlock, and display-change signals.
///
/// The app keeps a single quiet timer. `note` restarts it. `evaluate` runs once the
/// displays have been still for `DisplayRestoreTiming.debounce`. A second evaluation
/// for a restore that is already running or that just ran for the same display key
/// does not move windows again. A later key does.
public struct DisplayRestoreCoalescer: Equatable, Sendable {
    public enum Signal: Equatable, Sendable {
        /// Login or Accessibility granted after launch. Same rule as a wake.
        case launch
        /// `NSWorkspace.didWakeNotification`.
        case wake
        /// `NSWorkspace.screensDidWakeNotification`. Displays often come back here
        /// without a second system wake.
        case screensWake
        /// Distributed `com.apple.screenIsUnlocked`. Re-reads the setup when displays
        /// appear at unlock. On its own it does not restore an unchanged layout.
        case sessionUnlock
        /// `didChangeScreenParametersNotification` or `CGDisplayRegisterReconfigurationCallback`.
        case displayChange

        /// Launch, system wake, and screen wake put windows back where macOS left them,
        /// so the saved layout applies even when the display key did not change.
        public var restoresUnchangedLayout: Bool {
            switch self {
            case .launch, .wake, .screensWake:
                return true
            case .sessionUnlock, .displayChange:
                return false
            }
        }
    }

    public enum Schedule: Equatable, Sendable {
        /// Restart the quiet timer. The generation identifies this attempt.
        case arm(generation: Int)
        /// This signal is already covered by the quiet timer or the restore in flight.
        case coalesced(generation: Int)
    }

    public struct Probe: Equatable, Sendable {
        public var autoRestore: Bool
        public var displayKey: String?
        public var hasSavedLayout: Bool
        public var dragInProgress: Bool
        public var keyChanged: Bool
        public var now: TimeInterval

        public init(
            autoRestore: Bool,
            displayKey: String?,
            hasSavedLayout: Bool,
            dragInProgress: Bool,
            keyChanged: Bool,
            now: TimeInterval
        ) {
            self.autoRestore = autoRestore
            self.displayKey = displayKey
            self.hasSavedLayout = hasSavedLayout
            self.dragInProgress = dragInProgress
            self.keyChanged = keyChanged
            self.now = now
        }
    }

    public enum Decision: Equatable, Sendable {
        case restore(key: String, generation: Int)
        case deferUntilDragEnds(generation: Int)
        case waitForDisplays(generation: Int)
        case skip
    }

    /// What to do after a restore apply finishes.
    public enum Finished: Equatable, Sendable {
        case idle
        /// The display key changed while windows were moving. One more quiet wait.
        case arm(generation: Int)
    }

    public private(set) var generation: Int

    private enum Phase: Equatable, Sendable {
        case idle
        case waiting(wakeLike: Bool)
        case deferred(wakeLike: Bool)
        case restoring(key: String)
    }

    private var phase: Phase = .idle
    private var followUp = false
    private var satisfiedKey: String?
    private var satisfiedUntil: TimeInterval = -1
    private var restoreUnchangedUntil: TimeInterval = -1

    public init() {
        generation = 0
    }

    /// Record one observer signal. Wake, screen wake, unlock, and display change
    /// all come through here so they share one timer.
    public mutating func note(_ signal: Signal, at now: TimeInterval) -> Schedule {
        if signal.restoresUnchangedLayout {
            if case .idle = phase, now > satisfiedUntil {
                satisfiedKey = nil
            }
            restoreUnchangedUntil = max(restoreUnchangedUntil, now + DisplayRestoreTiming.wakeLayoutWindow)
        }
        switch phase {
        case .restoring:
            // A display event during the apply is remembered. Wake notifications
            // for the same cycle are not a second restore. `restoreFinished`
            // starts the follow-up only if the key actually changed.
            if signal == .displayChange || signal == .sessionUnlock {
                followUp = true
            }
            return .coalesced(generation: generation)
        case .waiting(let wakeLike), .deferred(let wakeLike):
            generation += 1
            phase = .waiting(wakeLike: wakeLike || signal.restoresUnchangedLayout)
            return .arm(generation: generation)
        case .idle:
            generation += 1
            phase = .waiting(wakeLike: signal.restoresUnchangedLayout)
            return .arm(generation: generation)
        }
    }

    /// True when `evaluate` for this quiet-timer generation would change state.
    public func accepts(_ generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        switch phase {
        case .waiting, .deferred:
            return true
        case .idle, .restoring:
            return false
        }
    }

    /// Decide once the displays have been quiet. A mismatched generation is ignored.
    public mutating func evaluate(_ generation: Int, _ probe: Probe) -> Decision {
        guard generation == self.generation else { return .skip }
        let phaseWake: Bool
        switch phase {
        case .waiting(let wakeLike), .deferred(let wakeLike):
            phaseWake = wakeLike
        case .idle, .restoring:
            return .skip
        }
        let wakeLike = phaseWake || (satisfiedKey == nil && probe.now <= restoreUnchangedUntil)

        guard probe.autoRestore else {
            phase = .idle
            return .skip
        }
        guard let key = probe.displayKey, !key.isEmpty else {
            if probe.now <= restoreUnchangedUntil {
                self.generation += 1
                phase = .waiting(wakeLike: true)
                return .waitForDisplays(generation: self.generation)
            }
            phase = .idle
            return .skip
        }
        guard probe.hasSavedLayout else {
            phase = .idle
            return .skip
        }
        if satisfiedKey == key, probe.now <= satisfiedUntil {
            phase = .idle
            return .skip
        }
        let allowed = DisplayRestorePolicy.shouldRestore(
            autoRestore: true,
            hasDisplays: true,
            keyChanged: probe.keyChanged,
            restoreEvenIfUnchanged: wakeLike
        )
        guard allowed else {
            phase = .idle
            return .skip
        }
        if probe.dragInProgress {
            phase = .deferred(wakeLike: wakeLike)
            return .deferUntilDragEnds(generation: generation)
        }
        phase = .restoring(key: key)
        satisfiedKey = key
        satisfiedUntil = probe.now + DisplayRestoreTiming.sameSetupCoalesce
        return .restore(key: key, generation: generation)
    }

    /// Drop a display-change follow-up when the settled key matches the restore
    /// that just finished, so a flicker does not schedule a second pass.
    public mutating func cancelFollowUp() {
        followUp = false
    }

    /// The apply finished. A display change recorded while it ran, or a key that
    /// no longer matches, becomes one new quiet wait. The same key stays put.
    public mutating func restoreFinished() -> Finished {
        let follow = followUp
        followUp = false
        guard case .restoring = phase else { return .idle }
        guard follow else {
            phase = .idle
            return .idle
        }
        generation += 1
        phase = .waiting(wakeLike: false)
        return .arm(generation: generation)
    }
}

public enum LayoutCatalog {
    /// The layout to apply for the displays that are connected now.
    ///
    /// The file stored under the current key wins. A file whose saved displays recompute
    /// to that key is next: older keys included the frame origin, which moves on replug.
    /// Files written before EDID identity are chosen by pixel size and scaled point size
    /// when the UUID no longer matches. The newest save wins when several files describe
    /// the same setup.
    public static func layout(for configuration: DisplayConfiguration, in layouts: [SavedLayout]) -> SavedLayout? {
        guard !configuration.displays.isEmpty else { return nil }
        let key = configuration.key
        if let exact = newest(layouts.filter { $0.key == key }) {
            return exact
        }
        let recomputed = layouts.filter { candidate in
            !candidate.displays.isEmpty && DisplayConfiguration(displays: candidate.displays).key == key
        }
        if let match = newest(recomputed) {
            return match
        }
        let geometry = DisplayConfigKey.geometrySignature(configuration.displays)
        let currentUUIDs = Set(
            configuration.displays.map {
                $0.uuid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty }
        )
        let legacy = layouts.filter { candidate in
            guard !candidate.displays.isEmpty else { return false }
            guard candidate.displays.allSatisfy({ !DisplayIdentity.usesEDID($0) }) else { return false }
            return DisplayConfigKey.geometrySignature(candidate.displays) == geometry
        }
        let overlapping = legacy.filter { candidate in
            candidate.displays.contains { display in
                let uuid = display.uuid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return !uuid.isEmpty && currentUUIDs.contains(uuid)
            }
        }
        return newest(overlapping.isEmpty ? legacy : overlapping)
    }

    private static func newest(_ layouts: [SavedLayout]) -> SavedLayout? {
        layouts.max { lhs, rhs in
            if lhs.savedAt != rhs.savedAt { return lhs.savedAt < rhs.savedAt }
            return lhs.key < rhs.key
        }
    }
}

public enum WindowPlacement {
    /// Moves a saved Cocoa frame onto the same physical display in the current arrangement.
    /// The saved and current origins can disagree after a reboot or a change of which display is primary.
    public static func frame(
        _ saved: WMRect,
        savedDisplays: [DisplayDescriptor],
        currentDisplays: [DisplayDescriptor]
    ) -> WMRect {
        guard let source = display(containingCenterOf: saved, among: savedDisplays) ?? nearest(to: saved, among: savedDisplays),
              let target = counterpart(of: source, among: savedDisplays, in: currentDisplays)
        else {
            return saved
        }
        return WMRect(
            x: saved.x + (target.frame.x - source.frame.x),
            y: saved.y + (target.frame.y - source.frame.y),
            width: saved.width,
            height: saved.height
        )
    }

    public static func placing(
        _ windows: [WindowRecord],
        savedDisplays: [DisplayDescriptor],
        currentDisplays: [DisplayDescriptor]
    ) -> [WindowRecord] {
        windows.map { window in
            var placed = window
            placed.frame = frame(window.frame, savedDisplays: savedDisplays, currentDisplays: currentDisplays)
            return placed
        }
    }

    private static func display(containingCenterOf rect: WMRect, among displays: [DisplayDescriptor]) -> DisplayDescriptor? {
        let centerX = rect.x + rect.width / 2
        let centerY = rect.y + rect.height / 2
        return displays.first { display in
            let frame = display.frame
            return centerX >= frame.x
                && centerX < frame.x + frame.width
                && centerY >= frame.y
                && centerY < frame.y + frame.height
        }
    }

    private static func nearest(to rect: WMRect, among displays: [DisplayDescriptor]) -> DisplayDescriptor? {
        let centerX = rect.x + rect.width / 2
        let centerY = rect.y + rect.height / 2
        return displays.min { lhs, rhs in
            let left = distanceSquared(centerX, centerY, lhs.frame)
            let right = distanceSquared(centerX, centerY, rhs.frame)
            if left != right { return left < right }
            return DisplayIdentity.token(for: lhs) < DisplayIdentity.token(for: rhs)
        }
    }

    private static func distanceSquared(_ x: Double, _ y: Double, _ frame: WMRect) -> Double {
        let dx = x - (frame.x + frame.width / 2)
        let dy = y - (frame.y + frame.height / 2)
        return dx * dx + dy * dy
    }

    private static func counterpart(
        of source: DisplayDescriptor,
        among saved: [DisplayDescriptor],
        in current: [DisplayDescriptor]
    ) -> DisplayDescriptor? {
        let token = DisplayIdentity.token(for: source)
        if let matched = aligned(source, saved: saved, current: current, matches: { DisplayIdentity.token(for: $0) == token }) {
            return matched
        }
        return aligned(source, saved: saved, current: current, matches: { sameGeometry($0, source) })
    }

    private static func aligned(
        _ source: DisplayDescriptor,
        saved: [DisplayDescriptor],
        current: [DisplayDescriptor],
        matches: (DisplayDescriptor) -> Bool
    ) -> DisplayDescriptor? {
        let savedGroup = saved.filter(matches).sorted(by: leftToRight)
        let currentGroup = current.filter(matches).sorted(by: leftToRight)
        guard let index = savedGroup.firstIndex(of: source), index < currentGroup.count else { return nil }
        return currentGroup[index]
    }

    private static func sameGeometry(_ candidate: DisplayDescriptor, _ source: DisplayDescriptor) -> Bool {
        candidate.pixelWidth == source.pixelWidth
            && candidate.pixelHeight == source.pixelHeight
            && DisplayConfigKey.quantizedPoints(candidate.frame.width) == DisplayConfigKey.quantizedPoints(source.frame.width)
            && DisplayConfigKey.quantizedPoints(candidate.frame.height) == DisplayConfigKey.quantizedPoints(source.frame.height)
    }

    private static func leftToRight(_ lhs: DisplayDescriptor, _ rhs: DisplayDescriptor) -> Bool {
        if lhs.frame.x != rhs.frame.x { return lhs.frame.x < rhs.frame.x }
        if lhs.frame.y != rhs.frame.y { return lhs.frame.y < rhs.frame.y }
        return DisplayIdentity.token(for: lhs) < DisplayIdentity.token(for: rhs)
    }
}
