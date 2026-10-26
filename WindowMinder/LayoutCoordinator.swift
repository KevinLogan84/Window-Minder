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
/// Login, wake, and display reconfiguration share one debounce. Restore reads the
/// layout from disk for the settled display key and retries apps that are not
/// running yet. The snapshot taken at launch is the saved layout, not the positions
/// macOS used before those apps opened.
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
    private var restoreEvenIfUnchanged = false

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
                scheduleSettledRestore(evenIfUnchanged: true)
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
            scheduleSettledRestore(evenIfUnchanged: true)
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
        let existingCount: Int?
        do {
            existingCount = try savedWindowCount(for: configuration)
        } catch {
            layoutLogger.error(
                "Could not read saved layouts before store: \(error.localizedDescription, privacy: .public)"
            )
            if report.windows.isEmpty {
                return "No windows could be read. The saved layout was left unchanged."
            }
            existingCount = nil
        }
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
        layoutLogger.info(
            "Store windows=\(report.windows.count, privacy: .public) apps=\(appCount, privacy: .public) appsScanned=\(report.appsScanned, privacy: .public) appsTimedOut=\(report.appsTimedOut, privacy: .public)"
        )
        let layout = SavedLayout(
            version: SavedLayout.currentVersion,
            key: configuration.key,
            savedAt: Date(),
            displays: configuration.displays,
            windows: report.windows
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
        return outcome.message
    }

    /// Windows already saved for this display setup, including a legacy file whose key
    /// no longer matches. Nil when nothing is saved. Throws only if the folder cannot be read.
    private func savedWindowCount(for configuration: DisplayConfiguration) throws -> Int? {
        let layouts = try store.list()
        return LayoutCatalog.layout(for: configuration, in: layouts)?.windows.count
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
        suppressDisplayReaction = true
        defer { finishDisplaySuppression() }
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
            let awaiting = LateWindowRetry.bundlesAwaitingWindows(
                saved: placed,
                liveBundleIdentifiers: Set(report.bundlesWithLiveWindows),
                ignoredBundleIdentifiers: ignored
            )
            let elapsed = Date().timeIntervalSince(started)
            guard LateWindowRetry.shouldRetry(awaiting: awaiting, elapsed: elapsed) else { break }
            pending = placed.filter { awaiting.contains($0.bundleIdentifier) }
            if pending.isEmpty { break }
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

    private func observeWake() {
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let coordinator = self else { return }
            MainActor.assumeIsolated {
                coordinator.wake()
            }
        }
        observers.append(token)
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
        scheduleSettledRestore(evenIfUnchanged: false)
    }

    private func wake() {
        scheduleSettledRestore(evenIfUnchanged: true)
    }

    private func finishDisplaySuppression() {
        suppressDisplayReaction = false
        guard displayChangePending else { return }
        displayChangePending = false
        scheduleSettledRestore(evenIfUnchanged: false)
    }

    private func scheduleSettledRestore(evenIfUnchanged: Bool) {
        acceptingSnapshots = false
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        activityWork?.cancel()
        activityWork = nil
        if evenIfUnchanged {
            restoreEvenIfUnchanged = true
        }
        screenWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let coordinator = self else { return }
            MainActor.assumeIsolated {
                coordinator.commitSettledConfiguration()
            }
        }
        screenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DisplayRestoreTiming.debounce, execute: work)
    }

    private func commitSettledConfiguration() {
        let always = restoreEvenIfUnchanged
        restoreEvenIfUnchanged = false
        let newConfiguration = displays.current()
        let previous = snapshot
        let keyChanged = previous?.configuration.key != newConfiguration.key
        var notes: [String] = []
        if settings().saveBeforeDisplayChange,
           let previous,
           !previous.configuration.displays.isEmpty,
           previous.configuration.key != newConfiguration.key {
            let layouts = (try? store.list()) ?? []
            let existingCount = LayoutCatalog.layout(for: previous.configuration, in: layouts)?.windows.count
            if LayoutOverwrite.shouldReplaceSavedLayout(
                existingWindowCount: existingCount,
                capturedWindowCount: previous.windows.count
            ) {
                let layout = SavedLayout(
                    version: SavedLayout.currentVersion,
                    key: previous.configuration.key,
                    savedAt: previous.capturedAt,
                    displays: previous.configuration.displays,
                    windows: previous.windows
                )
                do {
                    try store.save(layout)
                    onLayoutsChanged()
                    notes.append("Saved the previous display setup.")
                } catch {
                    notes.append("Could not save the previous display setup.")
                }
            }
        }
        let shouldRestore = DisplayRestorePolicy.shouldRestore(
            autoRestore: settings().autoRestore,
            hasDisplays: !newConfiguration.displays.isEmpty,
            keyChanged: keyChanged,
            restoreEvenIfUnchanged: always
        )
        if !notes.isEmpty {
            onStatus(notes.joined(separator: " "))
        }
        displayGeneration += 1
        let generation = displayGeneration
        displayTask?.cancel()
        displayTask = Task { @MainActor in
            defer {
                if self.displayGeneration == generation {
                    self.displayTask = nil
                }
            }
            if shouldRestore {
                let message = await self.restoreCurrent(announceWhenIdle: false)
                guard !Task.isCancelled, self.displayGeneration == generation else { return }
                if !message.isEmpty {
                    let combined = (notes + [message]).joined(separator: " ")
                    self.onStatus(combined)
                }
            }
            guard !Task.isCancelled, self.displayGeneration == generation else { return }
            guard self.displays.current().key == newConfiguration.key else {
                self.screenParametersChanged()
                return
            }
            self.acceptingSnapshots = true
            if self.snapshot?.configuration.key != newConfiguration.key {
                self.refreshSnapshot()
            }
            self.startSnapshotTimer()
        }
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
