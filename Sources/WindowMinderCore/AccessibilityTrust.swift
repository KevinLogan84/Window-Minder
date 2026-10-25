import Foundation

/// When to keep asking macOS whether Accessibility access has been granted.
public enum AccessibilityTrustPolling {
    /// Poll while the process is untrusted. One second is short enough that the
    /// menu updates before the next time it is opened, without a tight loop.
    public static let interval: TimeInterval = 1

    public static func shouldPoll(isTrusted: Bool) -> Bool {
        !isTrusted
    }

    /// The denied banner stays up only while the latest check says untrusted.
    public static func showsAccessDenied(isTrusted: Bool) -> Bool {
        !isTrusted
    }

    /// Store and Restore stay disabled until the latest check says trusted.
    public static func menuAllowsWindowActions(isTrusted: Bool) -> Bool {
        isTrusted
    }
}
