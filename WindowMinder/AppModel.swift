import AppKit
import Foundation
import Observation
import os

private let accessibilityLogger = Logger(subsystem: WindowMinderIdentity.bundleIdentifier, category: "accessibility")

@MainActor
@Observable
final class AppModel {
    private let defaults: UserDefaults
    private let accessibility = AccessibilityClient()
    private let displays = DisplayCatalog()
    private let hotkeys = HotkeyCenter()
    private let loginItems = LoginItemController()
    private var coordinator: LayoutCoordinator?
    private var didStart = false
    private var externalFrontmostBundleID: String?
    private var frontmostObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var trustPollTimer: Timer?
    private var notificationRecheckGeneration = 0
    private var lastActivationCheckUptime: TimeInterval = -1
    private let accessibilityChanges = AccessibilityChangeObserver()
    private static weak var trustRefreshTarget: AppModel?
    var onAccessibilityTrustChange: (@MainActor () -> Void)?
    private var windowOperation: Task<Void, Never>?
    private var menuBarGeneration = 0
    /// Status text that belongs to a store or restore that has not finished.
    private var inProgressStatus: String?
    private var statusPostedAt: Date?
    private var statusExpiryGeneration = 0

    var autoRestore: Bool {
        didSet { defaults.set(autoRestore, forKey: Keys.autoRestore) }
    }

    var saveBeforeDisplayChange: Bool {
        didSet { defaults.set(saveBeforeDisplayChange, forKey: Keys.saveBeforeDisplayChange) }
    }

    var periodicAutoSave: Bool {
        didSet { defaults.set(periodicAutoSave, forKey: Keys.periodicAutoSave) }
    }

    var storeHotkey: StoredHotkey {
        didSet {
            persist(storeHotkey, codeKey: Keys.storeHotkeyKeyCode, modifierKey: Keys.storeHotkeyModifiers)
            registerHotkeys()
        }
    }

    var restoreHotkey: StoredHotkey {
        didSet {
            persist(restoreHotkey, codeKey: Keys.restoreHotkeyKeyCode, modifierKey: Keys.restoreHotkeyModifiers)
            registerHotkeys()
        }
    }

    var ignoredBundleIDs: [String] {
        didSet { defaults.set(ignoredBundleIDs, forKey: Keys.ignoredBundleIDs) }
    }

    var accessibilityTrusted = false
    var menuBarActivity: MenuBarActivity = .idle
    var layouts: [SavedLayout] = []
    var currentConfigurationKey: String?
    var displaySummary = "Displays"
    var loginState: LoginItemState = .notRegistered
    var loginMessage: String?
    var hotkeyMessage: String?
    var statusMessage: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: Self.registration)
        autoRestore = defaults.bool(forKey: Keys.autoRestore)
        saveBeforeDisplayChange = defaults.bool(forKey: Keys.saveBeforeDisplayChange)
        periodicAutoSave = defaults.bool(forKey: Keys.periodicAutoSave)
        storeHotkey = Self.hotkey(defaults, codeKey: Keys.storeHotkeyKeyCode, modifierKey: Keys.storeHotkeyModifiers)
        restoreHotkey = Self.hotkey(defaults, codeKey: Keys.restoreHotkeyKeyCode, modifierKey: Keys.restoreHotkeyModifiers)
        ignoredBundleIDs = Array(Set(defaults.stringArray(forKey: Keys.ignoredBundleIDs) ?? [])).sorted()
        Self.trustRefreshTarget = self
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        registerLoginItemOnFirstLaunch()
        let directory = LayoutLocation.layoutsDirectory(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let coordinator = LayoutCoordinator(
            accessibility: accessibility,
            displays: displays,
            store: LayoutStore(directory: directory),
            settings: { [weak self] in
                self?.automationSettings() ?? LayoutAutomationSettings(
                    autoRestore: true,
                    saveBeforeDisplayChange: true,
                    periodicAutoSave: false,
                    ignoredBundleIdentifiers: [WindowMinderIdentity.bundleIdentifier]
                )
            }
        )
        coordinator.onStatus = { [weak self] message in
            self?.presentStatus(message)
        }
        coordinator.onLayoutsChanged = { [weak self] in
            self?.reloadLayouts()
        }
        self.coordinator = coordinator
        hotkeys.onStore = { [weak self] in
            self?.storeNow()
        }
        hotkeys.onRestore = { [weak self] in
            self?.restoreNow()
        }
        registerHotkeys()
        observeAccessibilityTrust()
        _ = accessibility.promptForTrust()
        refreshAccessibilityTrust(source: .launch)
        observeFrontmostApp()
        coordinator.start()
        reloadLayouts()
        loginState = loginItems.state()
    }

    private func observeFrontmostApp() {
        noteExternalFrontmost(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, recheckTrust: false)
        frontmostObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            guard let model = self else { return }
            MainActor.assumeIsolated {
                model.noteExternalFrontmost(bundleID, recheckTrust: true)
            }
        }
    }

    private func noteExternalFrontmost(_ bundleID: String?, recheckTrust: Bool) {
        guard let bundleID, !bundleID.isEmpty, !isOwnBundle(bundleID) else { return }
        externalFrontmostBundleID = bundleID
        coordinator?.noteUserActivity()
        if recheckTrust, !accessibilityTrusted {
            refreshAccessibilityTrust(source: .frontmost)
        }
    }

    func refreshForMenu() {
        refreshAccessibilityTrust(source: .menuOpen)
        // The clear may not have resumed yet. Opening the menu applies the
        // same timestamp decision, so a fired timer cannot leave a leftover.
        reconcileStatusLine(now: Date())
        let state = loginItems.state()
        if loginState != state {
            loginState = state
        }
        reloadLayouts()
    }

    /// Live Accessibility probe plus the cached process flag. Starts or stops the one-second poll.
    func refreshAccessibilityTrust(source: AccessibilityTrustCheckSource) {
        if source == .activation {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastActivationCheckUptime < 0.3 {
                return
            }
            lastActivationCheckUptime = now
        }
        let trusted = accessibility.currentTrust(source: source)
        let changed = accessibilityTrusted != trusted
        if changed {
            accessibilityTrusted = trusted
        }
        reconcileStatusLine(now: Date())
        updateTrustPolling()
        if changed {
            if trusted {
                coordinator?.accessibilityWasGranted()
            }
            onAccessibilityTrustChange?()
        }
    }

    var isWindowOperationRunning: Bool {
        windowOperation != nil
    }

    var menuBarSymbol: String {
        switch menuBarActivity {
        case .idle:
            return "macwindow"
        case .busy:
            return "hourglass"
        case .success:
            return "checkmark.circle"
        }
    }

    var menuBarAccessibilityLabel: String {
        switch menuBarActivity {
        case .idle:
            return "Window Minder"
        case .busy, .success:
            return statusMessage ?? "Window Minder"
        }
    }

    func storeNow() {
        guard beginWindowOperation(starting: MenuStatusLine.storing) else { return }
        windowOperation = Task { @MainActor in
            let message = await self.coordinator?.storeCurrent() ?? "Window Minder is still starting."
            self.finishWindowOperation(message)
        }
    }

    func restoreNow() {
        guard beginWindowOperation(starting: MenuStatusLine.restoring) else { return }
        windowOperation = Task { @MainActor in
            let message = await self.coordinator?.restoreCurrent() ?? "Window Minder is still starting."
            self.finishWindowOperation(message)
        }
    }

    func deleteLayout(key: String) {
        do {
            try coordinator?.delete(key: key)
            reloadLayouts()
            presentStatus("Deleted the saved layout.")
        } catch {
            presentStatus(error.localizedDescription)
        }
    }

    func toggleLoginItem() {
        do {
            loginState = try loginItems.toggle()
            loginMessage = LoginItemPresentation.message(for: loginState)
        } catch {
            loginState = loginItems.state()
            loginMessage = LoginItemPresentation.registrationFailureMessage(
                errorDescription: error.localizedDescription,
                bundlePath: Bundle.main.bundlePath,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
            )
        }
    }

    func ignoreFrontmost() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let bundleID: String?
        if let current = frontmost?.bundleIdentifier, !current.isEmpty, !isOwnBundle(current) {
            bundleID = current
        } else {
            bundleID = externalFrontmostBundleID
        }
        guard let bundleID else {
            presentStatus("There is no frontmost app to ignore.")
            return
        }
        if isOwnBundle(bundleID) {
            presentStatus("Window Minder cannot ignore itself.")
            return
        }
        if !ignoredBundleIDs.contains(bundleID) {
            ignoredBundleIDs.append(bundleID)
            ignoredBundleIDs.sort()
        }
        presentStatus("Ignoring \(appName(for: bundleID)).")
    }

    func removeIgnored(_ bundleID: String) {
        ignoredBundleIDs.removeAll { $0 == bundleID }
    }

    func openAccessibilitySettings() {
        accessibility.openSettings()
    }

    func openPreferences() {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
            guard let window = NSApp.windows.first(where: { $0.canBecomeKey && $0.isVisible }) else { return }
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func appName(for bundleID: String) -> String {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let name = running.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bundle = Bundle(url: url)
        else {
            return bundleID
        }
        if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.isEmpty {
            return displayName
        }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
            return name
        }
        return bundleID
    }

    func layoutMenuTitle(_ layout: SavedLayout) -> String {
        let base = baseTitle(for: layout)
        let duplicates = layouts.filter { baseTitle(for: $0) == base }.count > 1
        let distinguished = duplicates ? "\(base) [\(layout.key.prefix(6))]" : base
        if layout.key == currentConfigurationKey {
            return "\(distinguished) (Current)"
        }
        return distinguished
    }

    var loginTitle: String {
        LoginItemPresentation.title(for: loginState)
    }

    private func beginWindowOperation(starting: String) -> Bool {
        guard windowOperation == nil else { return false }
        guard trustOrExplain() else { return false }
        guard coordinator != nil else {
            inProgressStatus = nil
            presentStatus("Window Minder is still starting.")
            return false
        }
        menuBarGeneration += 1
        menuBarActivity = .busy
        inProgressStatus = starting
        presentStatus(starting)
        return true
    }

    private func finishWindowOperation(_ message: String) {
        windowOperation = nil
        inProgressStatus = nil
        if !message.isEmpty {
            presentStatus(message)
        } else {
            reconcileStatusLine(now: Date())
        }
        reloadLayouts()
        guard message.hasPrefix("Stored ") || message.hasPrefix("Restored ") else {
            menuBarActivity = .idle
            return
        }
        menuBarGeneration += 1
        let generation = menuBarGeneration
        menuBarActivity = .success
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard generation == self.menuBarGeneration else { return }
            self.menuBarActivity = .idle
        }
    }

    private func trustOrExplain() -> Bool {
        refreshAccessibilityTrust(source: .action)
        guard accessibilityTrusted else {
            inProgressStatus = nil
            presentStatus(MenuStatusLine.accessibilityNeeded)
            return false
        }
        return true
    }

    /// Records a status line and, when it is only the result of a click,
    /// clears it after `MenuStatusLine.displayInterval`. The sleep does not
    /// run on the menu's tracking loop. Opening the menu reconciles from the
    /// timestamp if this task has not resumed yet.
    private func presentStatus(_ message: String?) {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text: String? = trimmed.isEmpty ? nil : trimmed
        statusPostedAt = text == nil ? nil : Date()
        statusMessage = text
        scheduleStatusExpiry()
    }

    private func scheduleStatusExpiry() {
        statusExpiryGeneration += 1
        let generation = statusExpiryGeneration
        let decision = statusDecision(now: Date())
        applyStatusDecision(decision)
        guard decision.isTransient else { return }
        let nanoseconds = UInt64(MenuStatusLine.displayInterval * 1_000_000_000)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard generation == self.statusExpiryGeneration else { return }
            self.reconcileStatusLine(now: Date())
        }
    }

    /// Shows the current state once a transient line is older than the
    /// display interval. A line that is still the real state is left alone.
    private func reconcileStatusLine(now: Date) {
        let decision = statusDecision(now: now)
        applyStatusDecision(decision)
        if decision.isTransient {
            return
        }
        statusExpiryGeneration += 1
    }

    private func applyStatusDecision(_ decision: MenuStatusLine.Resolution) {
        if statusMessage != decision.message {
            statusMessage = decision.message
        }
        if !decision.isTransient {
            statusPostedAt = nil
        }
    }

    private func statusDecision(now: Date) -> MenuStatusLine.Resolution {
        MenuStatusLine.resolve(
            message: statusMessage,
            postedAt: statusPostedAt,
            now: now,
            accessibilityTrusted: accessibilityTrusted,
            inProgressMessage: inProgressStatus
        )
    }

    private func observeAccessibilityTrust() {
        Self.trustRefreshTarget = self
        accessibilityChanges.onChange = { [weak self] in
            self?.recheckTrustAfterAccessibilityNotification()
        }
        accessibilityChanges.start()

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AppModel.trustRefreshTarget?.refreshAccessibilityTrust(source: .activation)
            }
        }
    }

    /// The distributed notification can arrive on any thread and before the grant
    /// is visible to Accessibility. Recheck now, then again after the follow-up delays.
    private func recheckTrustAfterAccessibilityNotification() {
        refreshAccessibilityTrust(source: .notification)
        notificationRecheckGeneration += 1
        let generation = notificationRecheckGeneration
        for delay in AccessibilityTrustPolling.notificationFollowUpDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let model = self else { return }
                MainActor.assumeIsolated {
                    guard generation == model.notificationRecheckGeneration else { return }
                    model.refreshAccessibilityTrust(source: .notification)
                }
            }
        }
    }

    private func updateTrustPolling() {
        if AccessibilityTrustPolling.shouldStopPolling(isTrusted: accessibilityTrusted) {
            stopTrustPolling()
        } else if AccessibilityTrustPolling.shouldStartPolling(
            isTrusted: accessibilityTrusted,
            timerAlreadyRunning: trustPollTimer != nil
        ) {
            startTrustPollingIfNeeded()
        }
    }

    private func startTrustPollingIfNeeded() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                guard let model = self else { return }
                MainActor.assumeIsolated {
                    model.startTrustPollingIfNeeded()
                }
            }
            return
        }
        guard trustPollTimer == nil else { return }
        let timer = Timer(timeInterval: AccessibilityTrustPolling.interval, repeats: true) { _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    AppModel.handleTrustPoll()
                }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        AppModel.handleTrustPoll()
                    }
                }
            }
        }
        timer.tolerance = 0.2
        // `.common` includes event tracking, so the poll keeps firing while the
        // menu is open. `.eventTracking` is added on its own in case this run
        // loop's common set does not.
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        trustPollTimer = timer
        accessibilityLogger.info(
            "Trust poll scheduled on the main run loop modes=common+eventTracking interval=\(AccessibilityTrustPolling.interval, privacy: .public)"
        )
    }

    private static func handleTrustPoll() {
        trustRefreshTarget?.refreshAccessibilityTrust(source: .poll)
    }

    private func stopTrustPolling() {
        guard trustPollTimer != nil else { return }
        trustPollTimer?.invalidate()
        trustPollTimer = nil
        accessibilityLogger.info("Trust poll stopped")
    }

    private func registerLoginItemOnFirstLaunch() {
        let state = loginItems.state()
        guard LoginItemRegistration.shouldRegisterOnLaunch(state) else {
            loginState = state
            return
        }
        do {
            loginState = try loginItems.registerIfNeeded()
            loginMessage = LoginItemPresentation.message(for: loginState)
        } catch {
            loginState = loginItems.state()
            loginMessage = LoginItemPresentation.registrationFailureMessage(
                errorDescription: error.localizedDescription,
                bundlePath: Bundle.main.bundlePath,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
            )
        }
    }

    private func reloadLayouts() {
        let configuration = displays.current()
        let loaded = coordinator.flatMap { try? $0.savedLayouts() } ?? []
        let nextKey = LayoutCatalog.layout(for: configuration, in: loaded)?.key
            ?? (configuration.displays.isEmpty ? nil : configuration.key)
        if currentConfigurationKey != nextKey {
            currentConfigurationKey = nextKey
        }
        let summary = displays.summary()
        if displaySummary != summary {
            displaySummary = summary
        }
        var seen = Set<String>()
        let sorted = loaded.sorted { lhs, rhs in
            let leftIsCurrent = lhs.key == currentConfigurationKey
            let rightIsCurrent = rhs.key == currentConfigurationKey
            if leftIsCurrent != rightIsCurrent { return leftIsCurrent }
            return lhs.savedAt > rhs.savedAt
        }.filter { seen.insert($0.key).inserted }
        if layouts != sorted {
            layouts = sorted
        }
    }

    private func isOwnBundle(_ bundleID: String) -> Bool {
        bundleID == WindowMinderIdentity.bundleIdentifier || bundleID == Bundle.main.bundleIdentifier
    }

    private func automationSettings() -> LayoutAutomationSettings {
        LayoutAutomationSettings(
            autoRestore: autoRestore,
            saveBeforeDisplayChange: saveBeforeDisplayChange,
            periodicAutoSave: periodicAutoSave,
            ignoredBundleIdentifiers: ignoredBundleIdentifiers
        )
    }

    private var ignoredBundleIdentifiers: Set<String> {
        var identifiers = Set(ignoredBundleIDs)
        identifiers.insert(WindowMinderIdentity.bundleIdentifier)
        if let bundleID = Bundle.main.bundleIdentifier {
            identifiers.insert(bundleID)
        }
        return identifiers
    }

    private func registerHotkeys() {
        hotkeys.register(store: storeHotkey, restore: restoreHotkey)
        hotkeyMessage = hotkeys.registrationError
    }

    private func persist(_ hotkey: StoredHotkey, codeKey: String, modifierKey: String) {
        defaults.set(Int(hotkey.keyCode), forKey: codeKey)
        defaults.set(Int(hotkey.modifiers), forKey: modifierKey)
    }

    private static func hotkey(_ defaults: UserDefaults, codeKey: String, modifierKey: String) -> StoredHotkey {
        StoredHotkey(
            keyCode: UInt32(defaults.integer(forKey: codeKey)),
            modifiers: UInt32(defaults.integer(forKey: modifierKey))
        )
    }

    private static var registration: [String: Any] {
        [
            Keys.autoRestore: true,
            Keys.saveBeforeDisplayChange: true,
            Keys.periodicAutoSave: false,
            Keys.storeHotkeyKeyCode: Int(StoredHotkey.storeWindows.keyCode),
            Keys.storeHotkeyModifiers: Int(StoredHotkey.storeWindows.modifiers),
            Keys.restoreHotkeyKeyCode: Int(StoredHotkey.restoreWindows.keyCode),
            Keys.restoreHotkeyModifiers: Int(StoredHotkey.restoreWindows.modifiers),
            Keys.ignoredBundleIDs: [String](),
        ]
    }

    private func baseTitle(for layout: SavedLayout) -> String {
        let names = layout.displays.compactMap(\.name).filter { !$0.isEmpty }
        if !names.isEmpty {
            return names.joined(separator: " + ")
        }
        return layout.displays.count == 1 ? "1 Display" : "\(layout.displays.count) Displays"
    }
}

private enum Keys {
    static let autoRestore = "autoRestore"
    static let saveBeforeDisplayChange = "saveBeforeDisplayChange"
    static let periodicAutoSave = "periodicAutoSave"
    static let storeHotkeyKeyCode = "storeHotkeyKeyCode"
    static let storeHotkeyModifiers = "storeHotkeyModifiers"
    static let restoreHotkeyKeyCode = "restoreHotkeyKeyCode"
    static let restoreHotkeyModifiers = "restoreHotkeyModifiers"
    static let ignoredBundleIDs = "ignoredBundleIDs"
}

/// Receives `com.apple.accessibility.api` even while System Settings is frontmost.
@MainActor
final class AccessibilityChangeObserver: NSObject {
    private static weak var current: AccessibilityChangeObserver?
    var onChange: (@MainActor () -> Void)?

    func start() {
        Self.current = self
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleAccessibilityAPINotification(_:)),
            name: Notification.Name("com.apple.accessibility.api"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc nonisolated func handleAccessibilityAPINotification(_ notification: Notification) {
        let onMain = Thread.isMainThread
        accessibilityLogger.info(
            "Accessibility notification received onMain=\(onMain, privacy: .public); rechecking now, after 0.5s, and after 2s"
        )
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                AccessibilityChangeObserver.current?.onChange?()
            }
        }
    }
}
