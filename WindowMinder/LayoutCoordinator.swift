import AppKit
import Foundation

struct LayoutAutomationSettings: Equatable {
    var autoRestore: Bool
    var saveBeforeDisplayChange: Bool
    var periodicAutoSave: Bool
    var ignoredBundleIdentifiers: Set<String>
}

enum LayoutTiming {
    static let screenChangeDebounce: TimeInterval = 0.8
    static let wakeDelay: TimeInterval = 1.0
    static let periodicSaveInterval: TimeInterval = 120
}

/// Saves and restores layouts. The in-memory snapshot is refreshed while the
/// display setup is stable. The screen-parameter notification arrives after the
/// change, so that earlier snapshot is what gets written for the previous setup.
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
    private var wakeWork: DispatchWorkItem?
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
        observeScreenChanges()
        observeWake()
        refreshSnapshot()
        startSnapshotTimer()
        startPeriodicTimer()
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
        let outcome = StoreOutcome.make(
            windowCount: report.windows.count,
            appCount: appCount,
            appsScanned: report.appsScanned,
            appsTimedOut: report.appsTimedOut
        )
        guard outcome.shouldSave else { return outcome.message }
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
            guard let loaded = try store.load(key: configuration.key) else {
                return announceWhenIdle ? "No saved layout for this display setup." : ""
            }
            layout = loaded
        } catch {
            return error.localizedDescription
        }
        await acquireAX()
        defer { releaseAX() }
        suppressDisplayReaction = true
        defer { finishDisplaySuppression() }
        let targets = accessibility.scanTargets(ignoredBundleIdentifiers: settings().ignoredBundleIdentifiers)
        let report = await AXWindowWork.restore(
            targets: targets,
            saved: layout.windows,
            ignoredBundleIdentifiers: settings().ignoredBundleIdentifiers,
            primaryHeight: height
        )
        if !announceWhenIdle, report.summary.restored == 0, report.summary.failed == 0 {
            return ""
        }
        return report.summary.message
    }

    private func observeScreenChanges() {
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenParametersChanged()
            }
        }
        observers.append(token)
    }

    private func observeWake() {
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.wake()
            }
        }
        observers.append(token)
    }

    func noteUserActivity() {
        guard acceptingSnapshots, accessibility.isTrusted else { return }
        activityWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshSnapshot()
            }
        }
        activityWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + SnapshotSchedule.activityDelay, execute: work)
    }

    private func screenParametersChanged() {
        acceptingSnapshots = false
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        activityWork?.cancel()
        activityWork = nil
        guard !suppressDisplayReaction else {
            displayChangePending = true
            return
        }
        scheduleScreenCommit()
    }

    private func finishDisplaySuppression() {
        suppressDisplayReaction = false
        guard displayChangePending else { return }
        displayChangePending = false
        scheduleScreenCommit()
    }

    private func scheduleScreenCommit() {
        screenWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.commitScreenChange()
            }
        }
        screenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + LayoutTiming.screenChangeDebounce, execute: work)
    }

    private func commitScreenChange() {
        let newConfiguration = displays.current()
        let previous = snapshot
        let keyChanged = previous?.configuration.key != newConfiguration.key
        var notes: [String] = []
        if settings().saveBeforeDisplayChange,
           let previous,
           !previous.configuration.displays.isEmpty,
           previous.configuration.key != newConfiguration.key {
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
        let shouldRestore = settings().autoRestore && keyChanged && !newConfiguration.displays.isEmpty
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
            self.refreshSnapshot()
            self.startSnapshotTimer()
        }
    }

    private func wake() {
        acceptingSnapshots = false
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        wakeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.commitWake()
            }
        }
        wakeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + LayoutTiming.wakeDelay, execute: work)
    }

    private func commitWake() {
        let shouldRestore = settings().autoRestore
        Task { @MainActor in
            if shouldRestore {
                let message = await self.restoreCurrent(announceWhenIdle: false)
                if !message.isEmpty {
                    self.onStatus(message)
                }
            }
            self.acceptingSnapshots = true
            self.refreshSnapshot()
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
        let capturedAt = Date()
        lastSnapshotAt = capturedAt
        snapshot = Snapshot(configuration: configuration, windows: report.windows, capturedAt: capturedAt)
    }

    private func startSnapshotTimer() {
        snapshotTimer?.invalidate()
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: SnapshotSchedule.backstopInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshSnapshot()
            }
        }
    }

    private func startPeriodicTimer() {
        periodicTimer?.invalidate()
        periodicTimer = Timer.scheduledTimer(withTimeInterval: LayoutTiming.periodicSaveInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.periodicSave()
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
