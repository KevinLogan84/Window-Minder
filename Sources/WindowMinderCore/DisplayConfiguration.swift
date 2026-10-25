import Foundation

public struct DisplayDescriptor: Equatable, Codable, Sendable {
    public var uuid: String
    public var frame: WMRect
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var name: String?

    public init(
        uuid: String,
        frame: WMRect,
        pixelWidth: Int,
        pixelHeight: Int,
        name: String? = nil
    ) {
        self.uuid = uuid
        self.frame = frame
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.name = name
    }
}

public struct DisplayConfiguration: Equatable, Codable, Sendable {
    public var displays: [DisplayDescriptor]

    public init(displays: [DisplayDescriptor]) {
        self.displays = displays
    }

    /// Order-independent, filename-safe identity of this display setup.
    /// Localized names are ignored. UUID, frame origin, point size, and pixel size are included.
    public var key: String {
        DisplayConfigKey.make(displays)
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

enum DisplayConfigKey {
    static func make(_ displays: [DisplayDescriptor]) -> String {
        let lines = displays.map { display in
            [
                display.uuid,
                decimal(display.frame.x),
                decimal(display.frame.y),
                decimal(display.frame.width),
                decimal(display.frame.height),
                String(display.pixelWidth),
                String(display.pixelHeight),
            ].joined(separator: "|")
        }
        .sorted()
        return SHA256.hex(lines.joined(separator: "\n"))
    }

    /// Locale-independent fixed-point text so the key does not depend on the user's region.
    static func decimal(_ value: Double) -> String {
        guard value.isFinite else {
            if value.isNaN { return "nan" }
            return value > 0 ? "inf" : "-inf"
        }
        let negative = value < 0
        let scaled = (abs(value) * 10_000).rounded(.toNearestOrAwayFromZero)
        let units = Int64(scaled)
        let whole = units / 10_000
        let fraction = units % 10_000
        let fractionText = String(format: "%04d", Int(fraction))
        return "\(negative ? "-" : "")\(whole).\(fractionText)"
    }
}
