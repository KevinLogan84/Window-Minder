import Foundation

public struct WindowMatch: Equatable, Sendable {
    public var saved: WindowRecord
    public var live: WindowRecord

    public init(saved: WindowRecord, live: WindowRecord) {
        self.saved = saved
        self.live = live
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
}
