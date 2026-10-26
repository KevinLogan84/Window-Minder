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
    public static let debounce: TimeInterval = 1.5
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
