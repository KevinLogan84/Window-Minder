import Foundation

/// What to do when the menu bar asks for Settings.
public enum SettingsPresentation: Equatable, Sendable {
    /// A Settings window is already on screen or minimized.
    /// Activate the app and order that window front. Do not open another one.
    case orderFront
    /// Nothing is open. Open the Settings scene, then order its window front.
    case openNew
}

/// A window described without AppKit, so the open-or-raise decision can be tested.
public struct SettingsWindowCandidate: Equatable, Sendable {
    public var identifier: String?
    public var title: String
    public var isVisible: Bool
    public var isMiniaturized: Bool
    /// The hidden view that only exists to capture `openSettings`. Never Settings.
    public var isActionHost: Bool

    public init(
        identifier: String?,
        title: String,
        isVisible: Bool,
        isMiniaturized: Bool,
        isActionHost: Bool
    ) {
        self.identifier = identifier
        self.title = title
        self.isVisible = isVisible
        self.isMiniaturized = isMiniaturized
        self.isActionHost = isActionHost
    }
}

/// Decides whether the menu should raise the existing Settings window or open one.
///
/// A visible window and a minimized window are already open. A window that was
/// closed is not, even if its title is still around, so the next click opens
/// Settings again instead of raising a dead window. The hidden action host is
/// never Settings, including when its title happens to match.
public enum SettingsWindowPlanner {
    public static let windowTitle = "Settings"
    public static let menuTitle = "Settings\u{2026}"

    /// Identifiers SwiftUI has used for the Settings scene window.
    public static let settingsIdentifiers: Set<String> = [
        "com.apple.SwiftUI.Settings",
        "com_apple_SwiftUI_Settings_window",
    ]

    /// Titles the scene uses before this app renames the window to `windowTitle`.
    public static let settingsTitles: Set<String> = [
        windowTitle,
        "Preferences",
    ]

    public static func presentation(for windows: [SettingsWindowCandidate]) -> SettingsPresentation {
        let alreadyOpen = windows.contains { window in
            Self.isSettingsWindow(window) && (window.isVisible || window.isMiniaturized)
        }
        return alreadyOpen ? .orderFront : .openNew
    }

    public static func isSettingsWindow(_ window: SettingsWindowCandidate) -> Bool {
        if window.isActionHost {
            return false
        }
        if let identifier = window.identifier, Self.settingsIdentifiers.contains(identifier) {
            return true
        }
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.settingsTitles.contains(title)
    }
}
