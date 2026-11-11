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
/// smaller layout. A manual Restore does not join that wait: it moves the windows
/// that are open for the displays connected now, then the wait can continue.
/// Restore reads the layout from disk for that display key and retries windows
/// that were not moved. The snapshot taken at launch is the saved layout, not
/// the positions macOS used before those apps opened. A pointer button that is
/// held down defers an automatic restore until the drag ends.
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
    private var lateRetryTask: Task<Void, Never>?
    /// The real screens went away, or the stand-in screen showed, since the last
    /// settled decision. macOS squeezes windows when that happens, so the layout is
    /// applied again even when the same setup comes back.
    private var displaysDisturbed = false
    /// The snapshot before the newest one, for the same setup.
    private var priorSnapshot: Snapshot?
    private var launched = false
    private var coalescer = DisplayRestoreCoalescer()
    /// Bumped when a manual Restore cancels the quiet timer, so that timer's
    /// callback cannot start an automatic restore.
    private var automaticEpoch = 0
    /// True while a user Restore is in progress. Wake and display signals are
    /// remembered and applied after it, not instead of it.
    private var manualRestoreActive = false
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

    /// Layouts written for the stand-in screen by earlier versions are not listed.
    func savedLayouts() throws -> [SavedLayout] {
        try store.list().filter { layout in
            layout.displays.isEmpty || !layout.displays.allSatisfy { DisplayIdentity.isPlaceholder($0) }
        }
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
            priorSnapshot = nil
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
    /// `trustConfirmed` means the caller just probed Accessibility and it worked, so a
    /// later probe must not turn this Restore into a no-op.
    @discardableResult
    func restoreCurrent(announceWhenIdle: Bool = true, trustConfirmed: Bool = false) async -> String {
        let resumeAutomaticWait = announceWhenIdle
            && coalescer.hasPendingAutomaticWait
            && coalescer.missingDisplayWaitIsOpen(at: monotonicNow())
        if announceWhenIdle {
            preemptAutomaticRestore()
        }
        defer {
            if announceWhenIdle {
                manualRestoreActive = false
                if resumeAutomaticWait {
                    noteDisplaySignal(.wake)
                }
            }
        }
        guard trustConfirmed || accessibility.isTrusted else {
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
            guard let matched = try savedLayout(for: configuration) else {
                return announceWhenIdle ? "No saved layout for this display setup." : ""
            }
            layout = matched
        } catch {
            return error.localizedDescription
        }
        let placed = WindowPlacement.placing(
            layout.windows,
            savedDisplays: layout.displays,
            currentDisplays: configuration.displays,
            visibleFrames: displays.visibleFrames()
        )
        layoutLogger.notice(
            "Restore displays=\(configuration.displays.count, privacy: .public) key=\(configuration.key, privacy: .public) savedKey=\(layout.key, privacy: .public) windows=\(placed.count, privacy: .public)"
        )
        lateRetryTask?.cancel()
        lateRetryTask = nil
        await acquireAX()
        if Task.isCancelled {
            releaseAX()
            return announceWhenIdle ? MenuStatusLine.couldNotRestore : ""
        }
        let applyGeneration = displayGeneration
        suppressDisplayReaction = true
        let ignored = settings().ignoredBundleIdentifiers
        var report: AXRestoreReport?
        // A manual Restore always moves the windows that are open now, even if the
        // display key flickered; an automatic one waits for the next settled setup.
        let keyChanged = displays.current().key != configuration.key
        let passHeight = displays.primaryHeight()
        let heightForPass = passHeight > 0 ? passHeight : height
        if !Task.isCancelled, announceWhenIdle || !keyChanged, heightForPass > 0 {
            report = await AXWindowWork.restore(
                targets: accessibility.scanTargets(ignoredBundleIdentifiers: ignored),
                saved: placed,
                ignoredBundleIdentifiers: ignored,
                primaryHeight: heightForPass
            )
        }
        if keyChanged {
            displayChangePending = true
        }
        releaseAX()
        finishDisplaySuppression(restoredConfigurationKey: configuration.key, generation: applyGeneration)
        if !Task.isCancelled, displays.current().key == configuration.key {
            let capturedAt = Date()
            lastSnapshotAt = capturedAt
            priorSnapshot = nil
            snapshot = Snapshot(configuration: configuration, windows: placed, capturedAt: capturedAt)
        }
        guard let report else { return announceWhenIdle ? "The displays changed. Restore will run again." : "" }
        let pending = LateWindowRetry.windowsToRetry(
            saved: placed,
            matched: report.matchedSaved,
            ignoredBundleIdentifiers: ignored
        )
        // A display change during the apply already armed a new wait; that wait owns what happens next.
        if !pending.isEmpty, displayGeneration == applyGeneration {
            startLateRetries(pending, configurationKey: configuration.key)
        }
        let summary = RestoreSummary(
            restored: report.summary.restored,
            skipped: report.summary.skipped,
            failed: report.summary.failed,
            unresponsiveAppCount: report.summary.unresponsiveAppCount
        )
        if !announceWhenIdle, summary.restored == 0, summary.failed == 0 {
            return ""
        }
        return summary.message
    }

    /// Windows that were not open yet, or that missed, are tried again about once a
    /// second for `LateWindowRetry.duration`. This runs after Restore has reported, so it
    /// does not hold up the menu, Store, or the next display event. The Accessibility lock
    /// is taken only for each pass. A display event or another Restore cancels it.
    private func startLateRetries(_ windows: [WindowRecord], configurationKey: String) {
        lateRetryTask?.cancel()
        let started = Date()
        lateRetryTask = Task { @MainActor in
            var pending = windows
            var restored = 0
            while !pending.isEmpty {
                let elapsed = Date().timeIntervalSince(started)
                guard LateWindowRetry.shouldRetry(awaiting: pending.map(\.bundleIdentifier), elapsed: elapsed) else { break }
                do {
                    try await Task.sleep(nanoseconds: UInt64(LateWindowRetry.interval * 1_000_000_000))
                } catch {
                    return
                }
                guard !Task.isCancelled, displays.current().key == configurationKey else { return }
                let height = displays.primaryHeight()
                guard height > 0 else { return }
                let ignored = settings().ignoredBundleIdentifiers
                await acquireAX()
                guard !Task.isCancelled, displays.current().key == configurationKey else {
                    releaseAX()
                    return
                }
                let report = await AXWindowWork.restore(
                    targets: accessibility.scanTargets(ignoredBundleIdentifiers: ignored),
                    saved: pending,
                    ignoredBundleIdentifiers: ignored,
                    primaryHeight: height
                )
                releaseAX()
                restored += report.summary.restored
                pending = LateWindowRetry.windowsToRetry(
                    saved: pending,
                    matched: report.matchedSaved,
                    ignoredBundleIdentifiers: ignored
                )
            }
            if restored > 0 {
                layoutLogger.notice("Late retry restored=\(restored, privacy: .public) stillMissing=\(pending.count, privacy: .public)")
                onStatus("Restored \(restored) more \(restored == 1 ? "window" : "windows") as \(restored == 1 ? "it" : "they") opened.")
            }
        }
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

    /// Called on every display or wake signal, before anything else reacts to it.
    private func noteDisturbance() {
        if displays.isDisturbed(), !displaysDisturbed {
            displaysDisturbed = true
            layoutLogger.notice("Displays went away or the stand-in screen appeared")
        }
        guard displaysDisturbed else { return }
        // A snapshot taken in the last moments may hold windows that macOS has squeezed
        // onto the stand-in screen, or is still putting back. Use the one before it.
        if let snapshot, !SnapshotSchedule.isSettled(capturedAt: snapshot.capturedAt, now: Date()),
           let priorSnapshot, priorSnapshot.configuration.key == snapshot.configuration.key {
            layoutLogger.notice("Dropped a snapshot taken as the displays changed")
            self.snapshot = priorSnapshot
            self.priorSnapshot = nil
        }
    }

    private func screenParametersChanged() {
        noteDisturbance()
        guard !suppressDisplayReaction else {
            displayChangePending = true
            acceptingSnapshots = false
            snapshotTimer?.invalidate()
            snapshotTimer = nil
            return
        }
        noteDisplaySignal(.displayChange)
    }

    /// Stop the quiet timer and any automatic restore that is holding Accessibility.
    /// A manual Restore then moves the current setup immediately. The subset wait
    /// is not deleted: `restoreCurrent` arms it again after the move when it is
    /// still inside the wake window.
    private func preemptAutomaticRestore() {
        manualRestoreActive = true
        automaticEpoch += 1
        screenWork?.cancel()
        screenWork = nil
        dragWatch?.invalidate()
        dragWatch = nil
        displayTask?.cancel()
        displayGeneration += 1
        coalescer.beginManualRestore()
    }

    private func noteDisplaySignal(_ signal: DisplayRestoreCoalescer.Signal) {
        noteDisturbance()
        if manualRestoreActive {
            displayChangePending = true
            return
        }
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
            layoutLogger.notice(
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
            // A manual Restore that superseded this apply keeps its own suppression.
            if !manualRestoreActive {
                suppressDisplayReaction = false
                displayChangePending = false
            }
            return
        }
        suppressDisplayReaction = false
        let pending = displayChangePending
        displayChangePending = false
        let current = displays.current()
        // Empty means the displays have not come back yet, so keep waiting.
        // The same key is not a second restore.
        let keyChanged = pending
            && (current.displays.isEmpty || current.key != restoredConfigurationKey || displaysDisturbed)
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
        lateRetryTask?.cancel()
        lateRetryTask = nil
        let epoch = automaticEpoch
        displayGeneration += 1
        let work = DispatchWorkItem { [weak self] in
            guard let coordinator = self else { return }
            MainActor.assumeIsolated {
                guard coordinator.automaticEpoch == epoch, !coordinator.manualRestoreActive else { return }
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
        if displays.isDisturbed() { displaysDisturbed = true }
        let settledOnRealDisplays = !newConfiguration.displays.isEmpty
        // The same setup coming back after the screens went away still needs a restore.
        let keyChanged = previous?.configuration.key != newConfiguration.key
            || (displaysDisturbed && settledOnRealDisplays)
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
            if settledOnRealDisplays { displaysDisturbed = false }
            let notes = savePreviousLayoutIfNeeded(previous: previous, current: newConfiguration)
            if !notes.isEmpty {
                onStatus(notes.joined(separator: " "))
            }
            resumeSnapshots(for: newConfiguration)
        case .restore:
            clearWakeBaseline()
            displaysDisturbed = false
            // The same setup is back. Write where the windows were just before it went
            // away, so the restore uses those positions and not an older saved file.
            _ = savePreviousLayoutIfNeeded(previous: previous, current: newConfiguration, sameSetup: true)
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
        layoutLogger.notice(
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
        let epoch = automaticEpoch
        displayTask?.cancel()
        displayTask = Task { @MainActor in
            defer {
                if self.displayGeneration == generation {
                    self.displayTask = nil
                }
            }
            guard self.automaticEpoch == epoch, !self.manualRestoreActive else { return }
            let message = await self.restoreCurrent(announceWhenIdle: false)
            if self.coalescer.isRestoring, self.automaticEpoch == epoch, self.displayGeneration == generation {
                // The restore returned before it moved anything (Accessibility not granted
                // yet, no screens ready, nothing saved). Release it so later signals count.
                layoutLogger.notice("Restore did not start: \(message, privacy: .public)")
                if self.displays.isDisturbed() { self.displaysDisturbed = true }
                switch self.coalescer.restoreFinished() {
                case .arm(let quietGeneration):
                    self.beginQuietWait(generation: quietGeneration)
                    return
                case .idle:
                    break
                }
            }
            guard !Task.isCancelled, self.automaticEpoch == epoch, self.displayGeneration == generation else { return }
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
            return try savedLayout(for: configuration) != nil
        } catch {
            layoutLogger.error(
                "Could not read saved layouts before auto-restore: \(error.localizedDescription, privacy: .public)"
            )
            return true
        }
    }

    private func savePreviousLayoutIfNeeded(
        previous: Snapshot?,
        current: DisplayConfiguration,
        sameSetup: Bool = false
    ) -> [String] {
        guard settings().saveBeforeDisplayChange,
              let previous,
              !previous.configuration.displays.isEmpty,
              (previous.configuration.key == current.key) == sameSetup
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
        if let previous = snapshot, previous.configuration.key == configuration.key {
            priorSnapshot = previous
        } else {
            priorSnapshot = nil
        }
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
            accessibility.beginWindowWork()
            return
        }
        await withCheckedContinuation { continuation in
            axWaiters.append(continuation)
        }
    }

    private func releaseAX() {
        if axWaiters.isEmpty {
            axLock = false
            accessibility.endWindowWork()
            return
        }
        let next = axWaiters.removeFirst()
        next.resume()
    }
}
