import Foundation

public enum WindowMinderIdentity {
    public static let bundleIdentifier = "com.kevinlogan.WindowMinder"
}

public struct WindowRecord: Equatable, Codable, Sendable {
    public var bundleIdentifier: String
    public var windowTitle: String
    public var windowIndex: Int
    public var frame: WMRect
    /// When true, restore leaves the window minimized instead of pulling it back on screen.
    public var minimized: Bool

    public init(
        bundleIdentifier: String,
        windowTitle: String,
        windowIndex: Int,
        frame: WMRect,
        minimized: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.windowIndex = windowIndex
        self.frame = frame
        self.minimized = minimized
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier
        case windowTitle
        case windowIndex
        case frame
        case minimized
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        windowTitle = try container.decode(String.self, forKey: .windowTitle)
        windowIndex = try container.decode(Int.self, forKey: .windowIndex)
        frame = try container.decode(WMRect.self, forKey: .frame)
        minimized = try container.decodeIfPresent(Bool.self, forKey: .minimized) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(windowTitle, forKey: .windowTitle)
        try container.encode(windowIndex, forKey: .windowIndex)
        try container.encode(frame, forKey: .frame)
        try container.encode(minimized, forKey: .minimized)
    }
}

public struct SavedLayout: Equatable, Codable, Sendable, Identifiable {
    public static let currentVersion = 1

    public var version: Int
    public var key: String
    public var savedAt: Date
    public var displays: [DisplayDescriptor]
    public var windows: [WindowRecord]

    public var id: String { key }

    public init(
        version: Int,
        key: String,
        savedAt: Date,
        displays: [DisplayDescriptor],
        windows: [WindowRecord]
    ) {
        self.version = version
        self.key = key
        self.savedAt = savedAt
        self.displays = displays
        self.windows = windows
    }
}

public enum LayoutLocation {
    public static let applicationSupportFolderName = "Window Minder"
    public static let layoutsFolderName = "layouts"

    public static func layoutsDirectory(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(applicationSupportFolderName, isDirectory: true)
            .appendingPathComponent(layoutsFolderName, isDirectory: true)
    }
}
