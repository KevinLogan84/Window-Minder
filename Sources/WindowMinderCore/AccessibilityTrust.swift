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
    /// `kAXErrorCannotComplete`. A short probe treats this as a timeout.
    public static let cannotComplete: Int32 = -25204
}

/// Menu item shown when a live Accessibility read is not actually working.
/// Opens the Accessibility pane.
public enum AccessibilityMenuCopy {
    public static let accessNeeded = "Accessibility access needed. Open Settings…"
}

/// `AXIsProcessTrusted` can stay cached for the life of the process, and a stale
/// TCC grant keeps that cache `true` after an ad-hoc rebuild changes the cdhash.
/// A live read that returns API disabled is not trusted, even when the cache is true.
/// Any other probe result counts as trusted so a real grant shows up without relaunch.
public enum AccessibilityTrustDecision {
    /// Cached process trust cannot override API disabled.
    /// `processTrusted` is recorded in the log line and is not itself a grant.
    public static func isTrusted(processTrusted: Bool, probeError: Int32) -> Bool {
        _ = processTrusted
        return probeError != AccessibilityAPIErrorCode.apiDisabled
    }

    /// Running apps that already have on-screen windows are the real check.
    /// If an AX read of those apps fails, or succeeds and returns no windows,
    /// Accessibility is not effective. Windows from that read count as effective
    /// even when `AXIsProcessTrusted` is still false.
    /// When nothing on screen has a window, the attribute probe decides.
    public static func isEffective(
        processTrusted: Bool,
        probeError: Int32,
        onscreenAppsWithWindows: Int,
        axWindowCount: Int,
        axReadFailed: Bool
    ) -> Bool {
        if onscreenAppsWithWindows > 0 {
            if axWindowCount > 0 {
                return true
            }
            // A hard error, or a successful read that came back empty.
            // A timeout (`cannotComplete`) is inconclusive and falls through.
            if axReadFailed {
                return false
            }
            if probeError == AccessibilityAPIErrorCode.success
                || probeError == AccessibilityAPIErrorCode.noValue {
                return false
            }
        }
        return isTrusted(processTrusted: processTrusted, probeError: probeError)
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
