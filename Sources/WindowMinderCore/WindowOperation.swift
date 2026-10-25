import Foundation

public enum AppActivationKind: Equatable, Sendable {
    case regular
    case accessory
    case prohibited
    case unknown
}

public struct ScanCandidate: Equatable, Sendable {
    public var processIdentifier: Int32
    public var bundleIdentifier: String
    public var isHidden: Bool
    public var isTerminated: Bool
    public var activationPolicy: AppActivationKind

    public init(
        processIdentifier: Int32,
        bundleIdentifier: String,
        isHidden: Bool,
        isTerminated: Bool,
        activationPolicy: AppActivationKind
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.isHidden = isHidden
        self.isTerminated = isTerminated
        self.activationPolicy = activationPolicy
    }
}

public enum WindowScanFilter {
    public static func shouldScan(
        _ candidate: ScanCandidate,
        ignoredBundleIdentifiers: Set<String>,
        ownBundleIdentifier: String = WindowMinderIdentity.bundleIdentifier
    ) -> Bool {
        guard candidate.processIdentifier > 0 else { return false }
        guard !candidate.isTerminated else { return false }
        guard !candidate.isHidden else { return false }
        guard candidate.activationPolicy == .regular else { return false }
        let bundle = candidate.bundleIdentifier
        guard !bundle.isEmpty else { return false }
        if bundle == ownBundleIdentifier { return false }
        if ignoredBundleIdentifiers.contains(bundle) { return false }
        return true
    }

    /// One process per bundle. Hidden, accessory, and ignored apps are already dropped.
    public static func appsToScan(
        _ candidates: [ScanCandidate],
        ignoredBundleIdentifiers: Set<String>,
        ownBundleIdentifier: String = WindowMinderIdentity.bundleIdentifier
    ) -> [ScanCandidate] {
        var seen = Set<String>()
        var result: [ScanCandidate] = []
        for candidate in candidates
        where shouldScan(
            candidate,
            ignoredBundleIdentifiers: ignoredBundleIdentifiers,
            ownBundleIdentifier: ownBundleIdentifier
        ) {
            if seen.insert(candidate.bundleIdentifier).inserted {
                result.append(candidate)
            }
        }
        return result
    }
}

public enum WindowScanPlan {
    /// Unresponsive apps are abandoned instead of stalling the scan.
    public static let messagingTimeoutSeconds: Double = 0.25
    public static let maxConcurrentApps: Int = 4

    /// Bounded waves. Each wave is at most `limit` apps, and the waves cover every app once.
    public static func waveSizes(appCount: Int, limit: Int = maxConcurrentApps) -> [Int] {
        guard appCount > 0, limit > 0 else { return [] }
        var sizes: [Int] = []
        var remaining = appCount
        while remaining > 0 {
            let count = min(limit, remaining)
            sizes.append(count)
            remaining -= count
        }
        return sizes
    }
}

public struct ScannedWindowAttributes: Equatable, Sendable {
    public var role: String?
    public var subrole: String?
    public var title: String
    public var frame: WMRect?
    public var minimized: Bool
    public var fullscreen: Bool

    public init(
        role: String?,
        subrole: String?,
        title: String,
        frame: WMRect?,
        minimized: Bool,
        fullscreen: Bool
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.frame = frame
        self.minimized = minimized
        self.fullscreen = fullscreen
    }
}

public struct ClassifiedWindow: Equatable, Sendable {
    public var attributes: ScannedWindowAttributes
    /// Index among standard windows, including minimized ones that are not stored.
    public var windowIndex: Int?
    public var includeInStore: Bool
    public var includeInRestore: Bool

    public init(
        attributes: ScannedWindowAttributes,
        windowIndex: Int?,
        includeInStore: Bool,
        includeInRestore: Bool
    ) {
        self.attributes = attributes
        self.windowIndex = windowIndex
        self.includeInStore = includeInStore
        self.includeInRestore = includeInRestore
    }
}

public enum WindowCaptureRules {
    public static let standardSubrole = "AXStandardWindow"
    public static let windowRole = "AXWindow"

    public static func isStandardWindow(role: String?, subrole: String?) -> Bool {
        if let subrole, !subrole.isEmpty {
            return subrole == standardSubrole
        }
        return role == windowRole
    }

    /// Standard windows keep a stable index. Minimized ones are not stored.
    /// Restore still sees them so a saved visible window can be un-minimized.
    public static func classify(_ windows: [ScannedWindowAttributes]) -> [ClassifiedWindow] {
        var index = 0
        return windows.map { window in
            let standard = isStandardWindow(role: window.role, subrole: window.subrole)
            let assigned = standard ? index : nil
            if standard { index += 1 }
            let includeInStore = standard && !window.minimized && window.frame != nil
            let includeInRestore = standard && (window.frame != nil || window.minimized)
            return ClassifiedWindow(
                attributes: window,
                windowIndex: assigned,
                includeInStore: includeInStore,
                includeInRestore: includeInRestore
            )
        }
    }
}

public enum FrameWriteStep: String, Equatable, Sendable {
    case position
    case size
}

public enum RestoreFramePlan {
    /// Position, then size, then position again. Accessibility often clamps size to the
    /// screen the window is currently on, so the second position lands the final origin.
    public static let writeOrder: [FrameWriteStep] = [.position, .size, .position]

    public enum Action: Equatable, Sendable {
        case skipMinimized
        case move(exitFullscreen: Bool, unminimize: Bool)
    }

    public static func action(
        savedMinimized: Bool,
        liveMinimized: Bool,
        liveFullscreen: Bool
    ) -> Action {
        if savedMinimized {
            return .skipMinimized
        }
        return .move(exitFullscreen: liveFullscreen, unminimize: liveMinimized)
    }
}

enum CountNoun {
    static func phrase(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}

public struct StoreSummary: Equatable, Sendable {
    public var windowCount: Int
    public var appCount: Int
    public var unresponsiveAppCount: Int

    public init(windowCount: Int, appCount: Int, unresponsiveAppCount: Int) {
        self.windowCount = windowCount
        self.appCount = appCount
        self.unresponsiveAppCount = unresponsiveAppCount
    }

    public var message: String {
        let windows = CountNoun.phrase(windowCount, singular: "window", plural: "windows")
        let apps = CountNoun.phrase(appCount, singular: "app", plural: "apps")
        var text = "Stored \(windows) from \(apps)"
        if unresponsiveAppCount > 0 {
            let skipped = CountNoun.phrase(
                unresponsiveAppCount,
                singular: "unresponsive app",
                plural: "unresponsive apps"
            )
            text += ". Skipped \(skipped)"
        }
        return text
    }
}

public enum StoreOutcome: Equatable, Sendable {
    case saved(StoreSummary)
    case allUnresponsive(appCount: Int)

    public var shouldSave: Bool {
        switch self {
        case .saved:
            return true
        case .allUnresponsive:
            return false
        }
    }

    public var message: String {
        switch self {
        case .saved(let summary):
            return summary.message
        case .allUnresponsive(let count):
            let apps = CountNoun.phrase(count, singular: "app", plural: "apps")
            return "Could not store windows. \(apps) did not respond"
        }
    }

    /// An empty result only replaces a layout when at least one app answered.
    public static func make(
        windowCount: Int,
        appCount: Int,
        appsScanned: Int,
        appsTimedOut: Int
    ) -> StoreOutcome {
        if windowCount == 0, appsScanned > 0, appsTimedOut == appsScanned {
            return .allUnresponsive(appCount: appsTimedOut)
        }
        return .saved(
            StoreSummary(
                windowCount: windowCount,
                appCount: appCount,
                unresponsiveAppCount: appsTimedOut
            )
        )
    }
}

public struct RestoreSummary: Equatable, Sendable {
    public var restored: Int
    public var skipped: Int
    public var failed: Int
    public var unresponsiveAppCount: Int

    public init(restored: Int, skipped: Int, failed: Int, unresponsiveAppCount: Int) {
        self.restored = restored
        self.skipped = skipped
        self.failed = failed
        self.unresponsiveAppCount = unresponsiveAppCount
    }

    public var message: String {
        var parts = ["Restored \(CountNoun.phrase(restored, singular: "window", plural: "windows"))"]
        if skipped > 0 {
            parts.append("Skipped \(skipped)")
        }
        if failed > 0 {
            parts.append(failed == 1 ? "1 could not be moved" : "\(failed) could not be moved")
        }
        if unresponsiveAppCount > 0 {
            let apps = CountNoun.phrase(
                unresponsiveAppCount,
                singular: "unresponsive app",
                plural: "unresponsive apps"
            )
            parts.append("Skipped \(apps)")
        }
        guard parts.count > 1 else { return parts[0] }
        return parts[0] + ". " + parts.dropFirst().joined(separator: ". ")
    }
}
