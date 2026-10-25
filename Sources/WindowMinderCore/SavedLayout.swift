import Foundation

public enum WindowMinderIdentity {
    public static let bundleIdentifier = "com.kevinlogan.WindowMinder"
}

public struct WindowRecord: Equatable, Codable, Sendable {
    public var bundleIdentifier: String
    public var windowTitle: String
    public var windowIndex: Int
    public var frame: WMRect

    public init(
        bundleIdentifier: String,
        windowTitle: String,
        windowIndex: Int,
        frame: WMRect
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.windowIndex = windowIndex
        self.frame = frame
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
