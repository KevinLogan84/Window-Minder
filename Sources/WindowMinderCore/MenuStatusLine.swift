import Foundation

/// The menu's status line.
///
/// Click results — stored, restored, deleted, and warnings that came from that
/// click — stay for `displayInterval`, then yield to the real current state.
/// The Accessibility warning stays while access is denied. An in-progress
/// store or restore stays until that work finishes. Idle and ready is no line.
public enum MenuStatusLine {
    /// How long a transient action result remains before the menu returns
    /// to the current state.
    public static let displayInterval: TimeInterval = 4

    public static let accessibilityNeeded = "Accessibility access is not granted."
    public static let storing = "Storing windows…"
    public static let restoring = "Restoring windows…"

    /// `isTransient` means `message` is an action result still inside
    /// `displayInterval`. `replacement` is what should take its place: the
    /// Accessibility warning, the in-progress store or restore, or nil when
    /// idle and ready. A message that is already the current state is not
    /// transient, and opening the menu keeps it.
    public struct Resolution: Equatable, Sendable {
        public var isTransient: Bool
        public var message: String?
        public var replacement: String?

        public init(isTransient: Bool, message: String?, replacement: String?) {
            self.isTransient = isTransient
            self.message = message
            self.replacement = replacement
        }
    }

    /// Decide whether `message` is still worth showing at `now`.
    ///
    /// A nil `postedAt` means the transient timer has already fired, so a
    /// leftover action result resolves to the current state. The Accessibility
    /// warning is not leftover while access is denied, even without a timestamp.
    public static func resolve(
        message: String?,
        postedAt: Date?,
        now: Date,
        accessibilityTrusted: Bool,
        inProgressMessage: String?
    ) -> Resolution {
        let current = normalized(message)
        let progress = normalized(inProgressMessage)
        let steady = steadyState(accessibilityTrusted: accessibilityTrusted, progress: progress)

        if current == accessibilityNeeded, !accessibilityTrusted {
            return Resolution(isTransient: false, message: current, replacement: current)
        }

        if let progress, current == progress {
            return Resolution(isTransient: false, message: progress, replacement: progress)
        }

        if current == nil {
            if progress != nil {
                return Resolution(isTransient: false, message: steady, replacement: steady)
            }
            return Resolution(isTransient: false, message: nil, replacement: steady)
        }

        // Work in progress is the current state. A different line is a leftover
        // from the previous click, including one whose timer has not fired yet.
        if progress != nil {
            return Resolution(isTransient: false, message: progress, replacement: progress)
        }

        // Access was granted. The warning is no longer the current state.
        if current == accessibilityNeeded, accessibilityTrusted {
            return Resolution(isTransient: false, message: steady, replacement: steady)
        }

        let elapsed = postedAt.map { now.timeIntervalSince($0) } ?? displayInterval
        if elapsed >= displayInterval {
            return Resolution(isTransient: false, message: steady, replacement: steady)
        }
        return Resolution(isTransient: true, message: current, replacement: steady)
    }

    private static func steadyState(accessibilityTrusted: Bool, progress: String?) -> String? {
        if let progress {
            return progress
        }
        if !accessibilityTrusted {
            return accessibilityNeeded
        }
        return nil
    }

    private static func normalized(_ message: String?) -> String? {
        guard let raw = message?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }
}
