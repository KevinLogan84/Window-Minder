import Foundation

public struct WindowMatch: Equatable, Sendable {
    public var saved: WindowRecord
    public var live: WindowRecord

    public init(saved: WindowRecord, live: WindowRecord) {
        self.saved = saved
        self.live = live
    }
}

/// A window that exists right now. Process id and the Accessibility window id are
/// recorded so callers can pass them through, and matching never reads them:
/// both change after a restart. `role` and `subrole` limit the match to standard windows.
public struct LiveWindow: Equatable, Sendable {
    public var record: WindowRecord
    public var processIdentifier: Int32
    public var accessibilityWindowID: UInt32?
    public var role: String?
    public var subrole: String?

    public init(
        record: WindowRecord,
        processIdentifier: Int32 = 0,
        accessibilityWindowID: UInt32? = nil,
        role: String? = nil,
        subrole: String? = nil
    ) {
        self.record = record
        self.processIdentifier = processIdentifier
        self.accessibilityWindowID = accessibilityWindowID
        self.role = role
        self.subrole = subrole
    }
}

/// Pairs saved windows with live windows of the same app.
///
/// Title plus bundle identifier wins. When several windows share a title, the
/// same window index is preferred. If the title no longer matches, the bundle
/// identifier and window index are the fallback. A live window is used at most
/// once. Ignored bundle identifiers, including Window Minder itself, are skipped.
public enum WindowMatcher {
    public static func match(
        saved: [WindowRecord],
        live: [LiveWindow],
        ignoredBundleIdentifiers: Set<String> = []
    ) -> [WindowMatch] {
        let records = live.filter(isStandard).map(\.record)
        return match(saved: saved, live: records, ignoredBundleIdentifiers: ignoredBundleIdentifiers)
    }

    public static func match(
        saved: [WindowRecord],
        live: [WindowRecord],
        ignoredBundleIdentifiers: Set<String> = []
    ) -> [WindowMatch] {
        let ignored = ignoredBundleIdentifiers.union([WindowMinderIdentity.bundleIdentifier])
        let savedWindows = saved.filter { isEligible($0, ignored: ignored) }
        let liveWindows = live.filter { isEligible($0, ignored: ignored) }
        let bundleIDs = Set(savedWindows.map(\.bundleIdentifier)).sorted()

        var matches: [WindowMatch] = []
        var usedLive = Set<Int>()

        for bundleID in bundleIDs {
            let savedIndexes = savedWindows.indices.filter { savedWindows[$0].bundleIdentifier == bundleID }
            let liveIndexes = liveWindows.indices.filter { liveWindows[$0].bundleIdentifier == bundleID }
            let orderedSaved = savedIndexes.sorted { lhs, rhs in
                let left = savedWindows[lhs]
                let right = savedWindows[rhs]
                if left.windowIndex != right.windowIndex {
                    return left.windowIndex < right.windowIndex
                }
                return left.windowTitle < right.windowTitle
            }

            var unmatchedSaved: [Int] = []
            for savedIndex in orderedSaved {
                let record = savedWindows[savedIndex]
                if let liveIndex = liveIndexes.first(where: { index in
                    !usedLive.contains(index)
                        && liveWindows[index].windowTitle == record.windowTitle
                        && liveWindows[index].windowIndex == record.windowIndex
                }) {
                    matches.append(WindowMatch(saved: record, live: liveWindows[liveIndex]))
                    usedLive.insert(liveIndex)
                } else {
                    unmatchedSaved.append(savedIndex)
                }
            }

            let titles = Set(unmatchedSaved.map { savedWindows[$0].windowTitle }).sorted()
            var matchedByTitle = Set<Int>()
            for title in titles {
                let savedGroup = unmatchedSaved
                    .filter { savedWindows[$0].windowTitle == title }
                    .sorted { savedWindows[$0].windowIndex < savedWindows[$1].windowIndex }
                let liveGroup = liveIndexes
                    .filter { !usedLive.contains($0) && liveWindows[$0].windowTitle == title }
                    .sorted { liveWindows[$0].windowIndex < liveWindows[$1].windowIndex }
                for (offset, savedIndex) in savedGroup.enumerated() where offset < liveGroup.count {
                    let liveIndex = liveGroup[offset]
                    matches.append(WindowMatch(saved: savedWindows[savedIndex], live: liveWindows[liveIndex]))
                    usedLive.insert(liveIndex)
                    matchedByTitle.insert(savedIndex)
                }
            }

            let stillUnmatched = unmatchedSaved.filter { !matchedByTitle.contains($0) }
            for savedIndex in stillUnmatched {
                let record = savedWindows[savedIndex]
                let candidates = liveIndexes
                    .filter { !usedLive.contains($0) && liveWindows[$0].windowIndex == record.windowIndex }
                    .sorted { liveWindows[$0].windowTitle < liveWindows[$1].windowTitle }
                guard let liveIndex = candidates.first else { continue }
                matches.append(WindowMatch(saved: record, live: liveWindows[liveIndex]))
                usedLive.insert(liveIndex)
            }
        }

        return matches
    }

    private static func isEligible(_ record: WindowRecord, ignored: Set<String>) -> Bool {
        !record.bundleIdentifier.isEmpty && !ignored.contains(record.bundleIdentifier)
    }

    /// A live window with no role information stays eligible. Callers that know the
    /// Accessibility role must pass a standard window; dialogs and sheets are not restored.
    private static func isStandard(_ window: LiveWindow) -> Bool {
        if window.role == nil && window.subrole == nil { return true }
        return WindowCaptureRules.isStandardWindow(role: window.role, subrole: window.subrole)
    }
}

public enum LateWindowRetry {
    public static let interval: TimeInterval = 1
    public static let duration: TimeInterval = 30

    /// Saved windows that were not matched on this pass. An app that already has
    /// other windows still retries the ones that are not open yet. A matched
    /// window, including one that could not be moved, is not returned.
    public static func windowsToRetry(
        saved: [WindowRecord],
        matched: [WindowRecord],
        ignoredBundleIdentifiers: Set<String> = []
    ) -> [WindowRecord] {
        let ignored = ignoredBundleIdentifiers.union([WindowMinderIdentity.bundleIdentifier])
        var pool = matched
        var retry: [WindowRecord] = []
        for record in saved {
            guard !record.bundleIdentifier.isEmpty, !ignored.contains(record.bundleIdentifier) else { continue }
            if let index = pool.firstIndex(of: record) {
                pool.remove(at: index)
            } else {
                retry.append(record)
            }
        }
        return retry
    }

    /// Saved apps that do not have a live window yet. Window Minder waits for these
    /// bundle ids to appear. It does not launch the apps, and a missing app is not a failed restore.
    public static func bundlesAwaitingWindows(
        saved: [WindowRecord],
        liveBundleIdentifiers: Set<String>,
        ignoredBundleIdentifiers: Set<String> = []
    ) -> [String] {
        let ignored = ignoredBundleIdentifiers.union([WindowMinderIdentity.bundleIdentifier])
        let bundles = Set(saved.map(\.bundleIdentifier)).subtracting(ignored).subtracting([""])
        return bundles.filter { !liveBundleIdentifiers.contains($0) }.sorted()
    }

    public static func shouldRetry(awaiting: [String], elapsed: TimeInterval) -> Bool {
        !awaiting.isEmpty && elapsed < duration
    }

    /// Missing apps are skipped and retried. A restore fails only when a window was
    /// found and could not be moved, and nothing is left to wait for.
    public static func isFailedRestore(
        restored: Int,
        failed: Int,
        awaitingBundleIdentifiers: [String]
    ) -> Bool {
        awaitingBundleIdentifiers.isEmpty && restored == 0 && failed > 0
    }

    public static func eligibleWindowCount(
        saved: [WindowRecord],
        ignoredBundleIdentifiers: Set<String> = []
    ) -> Int {
        let ignored = ignoredBundleIdentifiers.union([WindowMinderIdentity.bundleIdentifier])
        return saved.filter { record in
            !record.bundleIdentifier.isEmpty && !ignored.contains(record.bundleIdentifier)
        }.count
    }
}
