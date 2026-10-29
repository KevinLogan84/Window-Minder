import AppKit
import Foundation
import os

private let layoutLogger = Logger(subsystem: WindowMinderIdentity.bundleIdentifier, category: "layout")

struct LayoutAutomationSettings: Equatable {
    var autoRestore: Bool
    var saveBeforeDisplayChange: Bool
    var periodicAutoSave: Bool
    var ignoredBundleIdentifiers: Set<String>
}

enum LayoutTiming {
    static let periodicSaveInterval: TimeInterval = 120
}

/// Saves and restores layouts. The in-memory snapshot is refreshed while the
/// display setup is stable. The screen-parameter notification arrives after the
/// change, so that earlier snapshot is what gets written for the previous setup.
///
/// Login, wake, screen wake, session unlock, and display reconfiguration share
/// one debounce in `DisplayRestoreCoalescer`. After a wake, a strict subset of
/// the pre-wake screens waits for the missing display instead of applying the
/// smaller layout. Restore reads the layout from disk for the settled display
/// key and retries windows that are not open yet. The snapshot taken at launch
/// is the saved layout, not the positions macOS used before those apps opened.
/// A pointer button that is held down defers that restore until the drag ends.
@MainActor
final class LayoutCoordinator {
    var onStatus: @MainActor (String) -> Void = { _ in }
    var onLayoutsChanged: @MainActor () -> Void = {}

    private let accessibility: AccessibilityClient
    private let displays: DisplayCatalog
    private let store: LayoutStore
    private let settings: @MainActor () -> LayoutAutomationSettings

    private var snapshot: Snapshot?
    private var acceptingSnapshots = true
    private var snapshotTimer: Timer?
    private var periodicTimer: Timer?
    private var screenWork: DispatchWorkItem?
    private var dragWatch: Timer?
    private var activityWork: DispatchWorkItem?
    private var lastSnapshotAt: Date?
    private var displayChangePending = false
    private var displayGeneration = 0
    private var observers: [NSObjectProtocol] = []
    private var snapshotTask: Task<Void, Never>?
    private var axLock = false
    private var axWaiters: [CheckedContinuation<Void, Never>] = []
    private var suppressDisplayReaction = false
    private var displayTask: Task<Void, Never>?
    private var launched = false
    private var coalescer = DisplayRestoreCoalescer()
    /// Screens that were connected when this wake started. Frozen so a partial
    /// restore cannot forget the setup we are waiting to complete.
    private var wakeBaselineTokens: [String] = []
    private var wakeBaselineHasLayout = false
    private var wakeBaselineReady = false
    private static let dragRecheckInterval: TimeInterval = 0.2
    private static let screenIsUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    private struct Snapshot {
        var configuration: DisplayConfiguration
        var windows: [WindowRecord]
        var capturedAt: Date
    }

    init(
        accessibility: AccessibilityClient,
        displays: DisplayCatalog,
        store: LayoutStore,
        settings: @escaping @MainActor () -> LayoutAutomationSettings
    ) {
        self.accessibility = accessibility
        self.displays = displays
        self.store = store
        self.settings = settings
    }

    func start() {
        guard !launched else { return }
        launched = true
        observeScreenChanges()
        observeDisplayReconfiguration()
        observeWake()
        acceptingSnapshots = false
        if accessibility.isTrusted {
            if settings().autoRestore {
                noteDisplaySignal(.launch)
            } else {
                acceptingSnapshots = true
                refreshSnapshot()
                startSnapshotTimer()
            }
        }
        startPeriodicTimer()
    }

    /// Accessibility was granted after launch. Restore now if that is still on.
    func accessibilityWasGranted() {
        guard launched, accessibility.isTrusted else { return }
        if settings().autoRestore {
            noteDisplaySignal(.launch)
        } else if !acceptingSnapshots {
            acceptingSnapshots = true
            refreshSnapshot()
            startSnapshotTimer()
        }
    }

    func savedLayouts() throws -> [SavedLayout] {
        try store.list()
    }

    func delete(key: String) throws {
        try store.delete(key: key)
    }

    @discardableResult
    func storeCurrent() async -> String {
        guard accessibility.isTrusted else {
            return "Accessibility access is not granted."
        }
        await acquireAX()
        defer { releaseAX() }
        let configuration = displays.current()
        guard !configuration.displays.isEmpty else {
            return "No displays were found."
        }
        let height = displays.primaryHeight()
        guard height > 0 else {
            return "The primary display size is unavailable."
        }
        let targets = accessibility.scanTargets(ignoredBundleIdentifiers: settings().ignoredBundleIdentifiers)
        let report = await AXWindowWork.capture(targets: targets, primaryHeight: height, trace: .store)
        let appCount = Set(report.windows.map(\.bundleIdentifier)).count
        let existingLayout: SavedLayout?
        do {
            existingLayout = try savedLayout(for: configuration)
        } catch {
            layoutLogger.error(
                "Could not read saved layouts before store: \(error.localizedDescription, privacy: .public)"
            )
            if report.windows.isEmpty {
                return "No windows could be read. The saved layout was left unchanged."
            }
            existingLayout = nil
        }
        let existingCount = existingLayout?.windows.count
        let outcome = StoreOutcome.make(
            windowCount: report.windows.count,
            appCount: appCount,
            appsScanned: report.appsScanned,
            appsTimedOut: report.appsTimedOut,
            existingWindowCount: existingCount
        )
        if case .keptExistingLayout(let existing) = outcome {
            layoutLogger.error(
                "Refused empty store existingWindows=\(existing, privacy: .public) appsScanned=\(report.appsScanned, privacy: .public) appsTimedOut=\(report.appsTimedOut, privacy: .public) captured=\(report.windows.count, privacy: .public)"
            )
            return outcome.message
        }
        guard outcome.shouldSave else {
            layoutLogger.error(
                "Store skipped appsScanned=\(report.appsScanned, privacy: .public) appsTimedOut=\(report.appsTimedOut, privacy: .public) windows=\(report.windows.count, privacy: .public)"
            )
            return outcome.message
        }
        let prepared = LayoutOverwrite.prepareStore(
            existing: existingLayout?.windows,
            captured: report.windows
        )
        guard prepared.shouldSave else {
            layoutLogger.error(
                "Refused store that would replace \(existingCount ?? 0, privacy: .public) saved windows with \(report.windows.count, privacy: .public)"
            )
            return outcome.message
        }
        let summary = StoreSummary(
            windowCount: report.windows.count,
            appCount: appCount,
            unresponsiveAppCount: report.appsTimedOut,
            keptWindowCount: prepared.keptWindowCount
        )
        layoutLogger.info(
            "Store windows=\(report.windows.count, privacy: .public) apps=\(appCount, privacy: .public) appsScanned=\(report.appsScanned, privacy: .public) appsTimedOut=\(report.appsTimedOut, privacy: .public) kept=\(prepared.keptWindowCount, privacy: .public)"
        )
        let layout = SavedLayout(
            version: SavedLayout.currentVersion,
            key: configuration.key,
            savedAt: Date(),
            displays: configuration.displays,
            windows: prepared.windows
        )
        do {
            try store.save(layout)
        } catch {
            return error.localizedDescription
        }
        if acceptingSnapshots, displays.current().key == configuration.key {
            lastSnapshotAt = layout.savedAt
            snapshot = Snapshot(configuration: configuration, windows: layout.windows, capturedAt: layout.savedAt)
        }
        onLayoutsChanged()
        return summary.message
    }

    /// The layout already saved for this display setup, including a legacy file whose
    /// key no longer matches. Nil when nothing is saved. Throws only if the folder cannot be read.
    private func savedLayout(for configuration: DisplayConfiguration) throws -> SavedLayout? {
        LayoutCatalog.layout(for: configuration, in: try store.list())
    }

    /// `announceWhenIdle` is for an explicit Restore. Automatic restore stays quiet when
    /// there is nothing to do, so a display change does not fill the menu with status text.
    @discardableResult
    func restoreCurrent(announceWhenIdle: Bool = true) async -> String {
        guard accessibility.isTrusted else {
            return announceWhenIdle ? "Accessibility access is not granted." : ""
        }
        let configuration = displays.current()
        guard !configuration.displays.isEmpty else {
            return announceWhenIdle ? "No displays were found." : ""
        }
        let height = displays.primaryHeight()
        guard height > 0 else {
            return "The primary display size is unavailable."
        }
        let layout: SavedLayout
        do {
            if let exact = try store.load(key: configuration.key) {
                layout = exact
            } else if let matched = LayoutCatalog.layout(for: configuration, in: try store.list()) {
                layout = matched
            } else {
                return announceWhenIdle ? "No saved layout for this display setup." : ""
            }
        } catch {
            return error.localizedDescription
        }
        let placed = WindowPlacement.placing(
            layout.windows,
            savedDisplays: layout.displays,
            currentDisplays: configuration.displays
        )
        layoutLogger.info(
            "Restore displays=\(configuration.displays.count, privacy: .public) key=\(configuration.key, privacy: .public) savedKey=\(layout.key, privacy: .public) windows=\(placed.count, privacy: .public)"
        )
        await acquireAX()
        defer { releaseAX() }
        let applyGeneration = displayGeneration
        suppressDisplayReaction = true
        defer {
            finishDisplaySuppression(
                restoredConfigurationKey: configuration.key,
                generation: applyGeneration
            )
        }
        let ignored = settings().ignoredBundleIdentifiers
        var restored = 0
        var failed = 0
        var unresponsive = 0
        var pending = placed
        let started = Date()
        while true {
            if Task.isCancelled { break }
            if displays.current().key != configuration.key {
                displayChangePending = true
                break
            }
            let passHeight = displays.primaryHeight()
            guard passHeight > 0 else { break }
            let targets = accessibility.scanTargets(ignoredBundleIdentifiers: ignored)
            let report = await AXWindowWork.restore(
                targets: targets,
                saved: pending,
                ignoredBundleIdentifiers: ignored,
                primaryHeight: passHeight
            )
            restored += report.summary.restored
            failed += report.summary.failed
            unresponsive = report.summary.unresponsiveAppCount
            let retry = LateWindowRetry.windowsToRetry(
                saved: pending,
                matched: report.matchedSaved,
                ignoredBundleIdentifiers: ignored
            )
            let elapsed = Date().timeIntervalSince(started)
            guard LateWindowRetry.shouldRetry(
                awaiting: retry.map(\.bundleIdentifier),
                elapsed: elapsed
            ) else { break }
            pending = retry
            if pending.isEmpty { break }
            layoutLogger.info(
                "Retrying \(pending.count, privacy: .public) skipped windows elapsed=\(elapsed, privacy: .public)"
            )
            do {
                try await Task.sleep(nanoseconds: UInt64(LateWindowRetry.interval * 1_000_000_000))
            } catch {
                break
            }
        }
        if !Task.isCancelled, displays.current().key == configuration.key {
            let capturedAt = Date()
            lastSnapshotAt = capturedAt
            snapshot = Snapshot(configuration: configuration, windows: placed, capturedAt: capturedAt)
        }
        let eligible = LateWindowRetry.eligibleWindowCount(saved: placed, ignoredBundleIdentifiers: ignored)
        let summary = RestoreSummary(
            restored: restored,
            skipped: max(eligible - restored - failed, 0),
            failed: failed,
            unresponsiveAppCount: unresponsive
        )
        if !announceWhenIdle, summary.restored == 0, summary.failed == 0 {
            return ""
        }
        return summary.message
    }

    private func observeScreenChanges() {
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let coordinator = self else { return }
            MainActor.assumeIsolated {
                coordinator.screenParametersChanged()
            }
        }
        observers.append(token)
    }

    private func observeDisplayReconfiguration() {
        DisplayReconfigurationMonitor.shared.onReconfigure = { [weak self] in
            guard let coordinator = self else { return }
            coordinator.screenParametersChanged()
        }
        DisplayReconfigurationMonitor.shared.start()
    }

    /// System wake, display wake, and unlock share the display-change debounce.
    /// Each one restarts that wait. `DisplayRestoreCoalescer` keeps them from
    /// moving windows twice for the same setup.
    private func observeWake() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let coordinator = self else { return }
            MainActor.assumeIsolated {
                coordinator.noteDisplaySignal(.wake)
            }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let coordinator = self else { return }
            MainActor.assumeIsolated {
                coordinator.noteDisplaySignal(.screensWake)
            }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Self.screenIsUnlocked,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let coordinator = self else { return }
            MainActor.assumeIsolated {
                coordinator.noteDisplaySignal(.sessionUnlock)
            }
        })
    }

    func noteUserActivity() {
        guard acceptingSnapshots, accessibility.isTrusted else { return }
        activityWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let coordinator = self else { return }
            MainActor.assumeIsolated {
                coordinator.refreshSnapshot()
            }
        }
        activityWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + SnapshotSchedule.activityDelay, execute: work)
    }

    private func screenParametersChanged() {
        guard !suppressDisplayReaction else {
            displayChangePending = true
            acceptingSnapshots = false
            snapshotTimer?.invalidate()
            snapshotTimer = nil
            return
        }
        noteDisplaySignal(.displayChange)
    }

    private func noteDisplaySignal(_ signal: DisplayRestoreCoalescer.Signal) {
        if signal.waitsForMissingDisplays, !wakeBaselineReady, let snapshot, !snapshot.configuration.displays.isEmpty {
            wakeBaselineTokens = snapshot.configuration.displays.map { DisplayIdentity.token(for: $0) }
            wakeBaselineHasLayout = hasSavedLayout(for: snapshot.configuration)
            wakeBaselineReady = true
            layoutLogger.info(
                "Pre-wake setup displays=\(self.wakeBaselineTokens.count, privacy: .public) hasLayout=\(self.wakeBaselineHasLayout, privacy: .public)"
            )
        }
        let name = signal.logName
        switch coalescer.note(signal, at: monotonicNow()) {
        case .arm(let generation):
            layoutLogger.info(
                "Observed \(name, privacy: .public) armed generation=\(generation, privacy: .public)"
            )
            beginQuietWait(generation: generation)
        case .coalesced(let generation):
            layoutLogger.info(
                "Observed \(name, privacy: .public) coalesced generation=\(generation, privacy: .public)"
            )
        }
    }

    /// A layout apply finished. A display key that changed during the apply gets
    /// one more quiet wait. The same key does not restore again.
    private func finishDisplaySuppression(restoredConfigurationKey: String, generation: Int) {
        guard self.displayGeneration == generation else {
            // A newer quiet wait owns the next decision. Drop this apply's
            // suppression so later display events still reach that wait.
            suppressDisplayReaction = false
            displayChangePending = false
            return
        }
        suppressDisplayReaction = false
        let pending = displayChangePending
        displayChangePending = false
        let current = displays.current()
        // Empty means the displays have not come back yet, so keep waiting.
        // The same key is not a second restore.
        let keyChanged = pending && (current.displays.isEmpty || current.key != restoredConfigurationKey)
        var armedFollowUp = false
        if keyChanged {
            switch coalescer.note(.displayChange, at: monotonicNow()) {
            case .arm(let quietGeneration):
                beginQuietWait(generation: quietGeneration)
                armedFollowUp = true
            case .coalesced:
                break
            }
        } else {
            coalescer.cancelFollowUp()
        }
        if !armedFollowUp {
            switch coalescer.restoreFinished() {
            case .arm(let quietGeneration):
                beginQuietWait(generation: quietGeneration)
                armedFollowUp = true
            case .idle:
                break
            }
        }
        if !armedFollowUp, !keyChanged, !acceptingSnapshots {
            resumeSnapshots(for: current)
        }
    }

    private func beginQuietWait(generation: Int) {
        acceptingSnapshots = false
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        activityWork?.cancel()
        activityWork = nil
        dragWatch?.invalidate()
        dragWatch = nil
        screenWork?.cancel()
        displayGeneration += 1
        let work = DispatchWorkItem { [weak self] in
            guard let coordinator = self else { return }
            MainActor.assumeIsolated {
                coordinator.commitSettledConfiguration(generation: generation)
            }
        }
        screenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DisplayRestoreTiming.debounce, execute: work)
    }

    private func commitSettledConfiguration(generation: Int) {
        guard coalescer.accepts(generation) else { return }
        let newConfiguration = displays.current()
        let previous = snapshot
        let keyChanged = previous?.configuration.key != newConfiguration.key
        let autoRestore = settings().autoRestore
        let currentTokens = newConfiguration.displays.map { DisplayIdentity.token(for: $0) }
        let preWakeTokens: [String]
        let preWakeHasLayout: Bool
        if wakeBaselineReady {
            preWakeTokens = wakeBaselineTokens
            preWakeHasLayout = wakeBaselineHasLayout
        } else if let previous, !previous.configuration.displays.isEmpty {
            preWakeTokens = previous.configuration.displays.map { DisplayIdentity.token(for: $0) }
            preWakeHasLayout = hasSavedLayout(for: previous.configuration)
        } else {
            preWakeTokens = []
            preWakeHasLayout = false
        }
        let decision = coalescer.evaluate(
            generation,
            DisplayRestoreCoalescer.Probe(
                autoRestore: autoRestore,
                displayKey: newConfiguration.displays.isEmpty ? nil : newConfiguration.key,
                hasSavedLayout: autoRestore && hasSavedLayout(for: newConfiguration),
                dragInProgress: PointerDrag.isInProgress(pressedMouseButtons: NSEvent.pressedMouseButtons),
                keyChanged: keyChanged,
                now: monotonicNow(),
                currentDisplayTokens: currentTokens,
                preWakeDisplayTokens: preWakeTokens,
                preWakeHasSavedLayout: preWakeHasLayout
            )
        )
        logDecision(decision)
        switch decision {
        case .waitForDisplays(let generation):
            beginQuietWait(generation: generation)
        case .deferUntilDragEnds(let generation):
            watchForDragEnd(generation: generation)
        case .skip:
            clearWakeBaseline()
            let notes = savePreviousLayoutIfNeeded(previous: previous, current: newConfiguration)
            if !notes.isEmpty {
                onStatus(notes.joined(separator: " "))
            }
            resumeSnapshots(for: newConfiguration)
        case .restore:
            clearWakeBaseline()
            let notes = savePreviousLayoutIfNeeded(previous: previous, current: newConfiguration)
            if !notes.isEmpty {
                onStatus(notes.joined(separator: " "))
            }
            startSettledRestore(configuration: newConfiguration, notes: notes)
        }
    }

    private func logDecision(_ decision: DisplayRestoreCoalescer.Decision) {
        let action: String
        switch decision {
        case .restore(let key, let generation):
            action = "restore key=\(key) generation=\(generation)"
        case .deferUntilDragEnds(let generation):
            action = "defer generation=\(generation)"
        case .waitForDisplays(let generation):
            action = "wait generation=\(generation)"
        case .skip:
            action = "skip"
        }
        let reason = coalescer.lastDecisionReason.description
        layoutLogger.info(
            "Decision \(action, privacy: .public) reason=\(reason, privacy: .public)"
        )
    }

    private func clearWakeBaseline() {
        wakeBaselineReady = false
        wakeBaselineTokens = []
        wakeBaselineHasLayout = false
    }

    private func watchForDragEnd(generation: Int) {
        dragWatch?.invalidate()
        let timer = Timer(timeInterval: Self.dragRecheckInterval, repeats: true) { [weak self] timer in
            guard let coordinator = self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated {
                guard coordinator.coalescer.accepts(generation) else {
                    timer.invalidate()
                    if coordinator.dragWatch === timer {
                        coordinator.dragWatch = nil
                    }
                    return
                }
                guard !PointerDrag.isInProgress(pressedMouseButtons: NSEvent.pressedMouseButtons) else { return }
                timer.invalidate()
                coordinator.dragWatch = nil
                coordinator.commitSettledConfiguration(generation: generation)
            }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        dragWatch = timer
    }

    private func startSettledRestore(configuration: DisplayConfiguration, notes: [String]) {
        displayGeneration += 1
        let generation = displayGeneration
        displayTask?.cancel()
        displayTask = Task { @MainActor in
            defer {
                if self.displayGeneration == generation {
                    self.displayTask = nil
                }
            }
            let message = await self.restoreCurrent(announceWhenIdle: false)
            guard !Task.isCancelled, self.displayGeneration == generation else { return }
            if !message.isEmpty {
                let combined = (notes + [message]).joined(separator: " ")
                self.onStatus(combined)
            }
            guard !Task.isCancelled, self.displayGeneration == generation else { return }
            guard self.displays.current().key == configuration.key else {
                self.screenParametersChanged()
                return
            }
            self.resumeSnapshots(for: configuration)
        }
    }

    private func resumeSnapshots(for configuration: DisplayConfiguration) {
        acceptingSnapshots = true
        if snapshot?.configuration.key != configuration.key {
            refreshSnapshot()
        }
        startSnapshotTimer()
    }

    /// Windows already saved for this display setup, including a legacy file the catalog
    /// still matches. A store that cannot be read is treated as present so the restore
    /// path can report the error instead of looking like an empty setup.
    private func hasSavedLayout(for configuration: DisplayConfiguration) -> Bool {
        guard !configuration.displays.isEmpty else { return false }
        do {
            if try store.load(key: configuration.key) != nil {
                return true
            }
            return LayoutCatalog.layout(for: configuration, in: try store.list()) != nil
        } catch {
            layoutLogger.error(
                "Could not read saved layouts before auto-restore: \(error.localizedDescription, privacy: .public)"
            )
            return true
        }
    }

    private func savePreviousLayoutIfNeeded(previous: Snapshot?, current: DisplayConfiguration) -> [String] {
        guard settings().saveBeforeDisplayChange,
              let previous,
              !previous.configuration.displays.isEmpty,
              previous.configuration.key != current.key
        else {
            return []
        }
        let layouts = (try? store.list()) ?? []
        let existing = LayoutCatalog.layout(for: previous.configuration, in: layouts)
        let prepared = LayoutOverwrite.prepareStore(
            existing: existing?.windows,
            captured: previous.windows
        )
        guard prepared.shouldSave else {
            return []
        }
        let layout = SavedLayout(
            version: SavedLayout.currentVersion,
            key: previous.configuration.key,
            savedAt: previous.capturedAt,
            displays: previous.configuration.displays,
            windows: prepared.windows
        )
        do {
            try store.save(layout)
            onLayoutsChanged()
            return ["Saved the previous display setup."]
        } catch {
            return ["Could not save the previous display setup."]
        }
    }

    private func monotonicNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func refreshSnapshot() {
        guard acceptingSnapshots, accessibility.isTrusted, snapshotTask == nil else { return }
        guard SnapshotSchedule.shouldCapture(lastCapture: lastSnapshotAt, now: Date()) else { return }
        snapshotTask = Task { @MainActor in
            defer { self.snapshotTask = nil }
            await self.writeSnapshot()
        }
    }

    private func writeSnapshot() async {
        guard acceptingSnapshots, accessibility.isTrusted else { return }
        await acquireAX()
        defer { releaseAX() }
        guard acceptingSnapshots else { return }
        let configuration = displays.current()
        guard !configuration.displays.isEmpty else { return }
        let height = displays.primaryHeight()
        guard height > 0 else { return }
        let targets = accessibility.scanTargets(ignoredBundleIdentifiers: settings().ignoredBundleIdentifiers)
        let report = await AXWindowWork.capture(targets: targets, primaryHeight: height, trace: .snapshot)
        guard acceptingSnapshots, displays.current().key == configuration.key else { return }
        let outcome = StoreOutcome.make(
            windowCount: report.windows.count,
            appCount: Set(report.windows.map(\.bundleIdentifier)).count,
            appsScanned: report.appsScanned,
            appsTimedOut: report.appsTimedOut
        )
        guard outcome.shouldSave else { return }
        let windows: [WindowRecord]
        if let previous = snapshot, previous.configuration.key == configuration.key {
            windows = SnapshotMerge.merging(saved: previous.windows, captured: report.windows)
        } else {
            windows = report.windows
        }
        let capturedAt = Date()
        lastSnapshotAt = capturedAt
        snapshot = Snapshot(configuration: configuration, windows: windows, capturedAt: capturedAt)
    }

    private func startSnapshotTimer() {
        snapshotTimer?.invalidate()
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: SnapshotSchedule.backstopInterval, repeats: true) { [weak self] _ in
            guard let coordinator = self else { return }
            MainActor.assumeIsolated {
                coordinator.refreshSnapshot()
            }
        }
    }

    private func startPeriodicTimer() {
        periodicTimer?.invalidate()
        periodicTimer = Timer.scheduledTimer(withTimeInterval: LayoutTiming.periodicSaveInterval, repeats: true) { [weak self] _ in
            guard let coordinator = self else { return }
            MainActor.assumeIsolated {
                coordinator.periodicSave()
            }
        }
    }

    private func periodicSave() {
        guard acceptingSnapshots, settings().periodicAutoSave else { return }
        Task { @MainActor in
            let message = await self.storeCurrent()
            if !message.isEmpty {
                self.onStatus(message)
            }
        }
    }

    private func acquireAX() async {
        if !axLock {
            axLock = true
            return
        }
        await withCheckedContinuation { continuation in
            axWaiters.append(continuation)
        }
    }

    private func releaseAX() {
        if axWaiters.isEmpty {
            axLock = false
            return
        }
        let next = axWaiters.removeFirst()
        next.resume()
    }
}
