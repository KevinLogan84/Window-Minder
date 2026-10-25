import Foundation

/// When to keep asking macOS whether Accessibility access has been granted.
public enum AccessibilityTrustPolling {
    /// Poll while the process is untrusted. One second is short enough that the
    /// menu updates before the next time it is opened, without a tight loop.
    public static let interval: TimeInterval = 1

    /// Cap a live trust probe so a stuck Accessibility server cannot sit on the
    /// default multi-second timeout. API-disabled returns immediately.
    public static let probeTimeout: TimeInterval = 0.25

    /// `com.apple.accessibility.api` can arrive before the grant is visible,
    /// and sometimes on a delay. Recheck on the main actor at these offsets
    /// after the immediate check.
    public static let notificationFollowUpDelays: [TimeInterval] = [0.5, 2]

    public static func shouldPoll(isTrusted: Bool) -> Bool {
        !isTrusted
    }

    /// Start the timer only while untrusted, and only if it is not already scheduled.
    /// A trusted result must not invalidate the timer before its first fire.
    public static func shouldStartPolling(isTrusted: Bool, timerAlreadyRunning: Bool) -> Bool {
        shouldPoll(isTrusted: isTrusted) && !timerAlreadyRunning
    }

    /// Stop only after a combined check says trusted. An untrusted result keeps the timer.
    public static func shouldStopPolling(isTrusted: Bool) -> Bool {
        isTrusted
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

/// Where a trust check was triggered. Raw values are the Console log tokens.
public enum AccessibilityTrustCheckSource: String, Sendable, Equatable {
    case poll
    case activation
    case notification
    case menuOpen = "menu-open"
    case launch
    case action
    case frontmost
}

/// AXError values Window Minder cares about. These match the HIServices codes
/// so the mapping can be tested without ApplicationServices.
public enum AccessibilityAPIErrorCode {
    public static let success: Int32 = 0
    public static let apiDisabled: Int32 = -25211
    public static let noValue: Int32 = -25212
}

/// `AXIsProcessTrusted` can stay cached for the life of the process.
/// A live attribute copy is trusted unless it returns API disabled.
/// Either signal is enough.
public enum AccessibilityTrustDecision {
    public static func isTrusted(processTrusted: Bool, probeError: Int32) -> Bool {
        processTrusted || probeError != AccessibilityAPIErrorCode.apiDisabled
    }

    /// Prefer any result that is not API disabled. An empty list fails closed.
    public static func preferredProbeError(_ errors: [Int32]) -> Int32 {
        errors.first { $0 != AccessibilityAPIErrorCode.apiDisabled } ?? AccessibilityAPIErrorCode.apiDisabled
    }

    public static func probeDescription(_ code: Int32) -> String {
        switch code {
        case AccessibilityAPIErrorCode.success:
            return "success(0)"
        case AccessibilityAPIErrorCode.apiDisabled:
            return "apiDisabled(-25211)"
        case AccessibilityAPIErrorCode.noValue:
            return "noValue(-25212)"
        default:
            return "other(\(code))"
        }
    }

    public static func logLine(source: AccessibilityTrustCheckSource, processTrusted: Bool, probeError: Int32) -> String {
        let trusted = isTrusted(processTrusted: processTrusted, probeError: probeError)
        return "Trust check source=\(source.rawValue) AXIsProcessTrusted=\(processTrusted) probe=\(probeDescription(probeError)) trusted=\(trusted)"
    }
}
