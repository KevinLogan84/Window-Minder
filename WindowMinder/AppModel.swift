import AppKit
import Foundation
import Observation

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
    private var trustObservers: [NSObjectProtocol] = []
    private var trustPollTimer: Timer?
    private let accessibilityChanges = AccessibilityChangeObserver()
    private static let deniedStatusMessage = "Accessibility access is not granted."
    private static weak var trustRefreshTarget: AppModel?
    private var windowOperation: Task<Void, Never>?
    private var menuBarGeneration = 0

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
            self?.statusMessage = message
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
        observeFrontmostApp()
        observeAccessibilityTrust()
        accessibilityTrusted = accessibility.promptForTrust()
        updateTrustPolling()
        coordinator.start()
        reloadLayouts()
        loginState = loginItems.state()
    }

    private func observeFrontmostApp() {
        noteExternalFrontmost(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        frontmostObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                self?.noteExternalFrontmost(bundleID)
            }
        }
    }

    private func noteExternalFrontmost(_ bundleID: String?) {
        guard let bundleID, !bundleID.isEmpty, !isOwnBundle(bundleID) else { return }
        externalFrontmostBundleID = bundleID
        coordinator?.noteUserActivity()
    }

    func refreshForMenu() {
        refreshAccessibilityTrust()
        let state = loginItems.state()
        if loginState != state {
            loginState = state
        }
        reloadLayouts()
    }

    /// Re-reads `AXIsProcessTrusted` on the main actor and starts or stops the one-second poll.
    func refreshAccessibilityTrust() {
        let trusted = accessibility.isTrusted
        if accessibilityTrusted != trusted {
            accessibilityTrusted = trusted
        }
        if trusted, statusMessage == Self.deniedStatusMessage {
            statusMessage = nil
        }
        updateTrustPolling()
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
        guard beginWindowOperation(starting: "Storing windows…") else { return }
        windowOperation = Task { @MainActor in
            let message = await self.coordinator?.storeCurrent() ?? "Window Minder is still starting."
            self.finishWindowOperation(message)
        }
    }

    func restoreNow() {
        guard beginWindowOperation(starting: "Restoring windows…") else { return }
        windowOperation = Task { @MainActor in
            let message = await self.coordinator?.restoreCurrent() ?? "Window Minder is still starting."
            self.finishWindowOperation(message)
        }
    }

    func deleteLayout(key: String) {
        do {
            try coordinator?.delete(key: key)
            reloadLayouts()
            statusMessage = "Deleted the saved layout."
        } catch {
            statusMessage = error.localizedDescription
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
            statusMessage = "There is no frontmost app to ignore."
            return
        }
        if isOwnBundle(bundleID) {
            statusMessage = "Window Minder cannot ignore itself."
            return
        }
        if !ignoredBundleIDs.contains(bundleID) {
            ignoredBundleIDs.append(bundleID)
            ignoredBundleIDs.sort()
        }
        statusMessage = "Ignoring \(appName(for: bundleID))."
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
            statusMessage = "Window Minder is still starting."
            return false
        }
        menuBarGeneration += 1
        menuBarActivity = .busy
        statusMessage = starting
        return true
    }

    private func finishWindowOperation(_ message: String) {
        windowOperation = nil
        if !message.isEmpty {
            statusMessage = message
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
        refreshAccessibilityTrust()
        guard accessibilityTrusted else {
            statusMessage = Self.deniedStatusMessage
            return false
        }
        return true
    }

    private func observeAccessibilityTrust() {
        Self.trustRefreshTarget = self
        accessibilityChanges.onChange = { [weak self] in
            self?.refreshAccessibilityTrust()
        }
        accessibilityChanges.start()

        trustObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    AppModel.trustRefreshTarget?.refreshAccessibilityTrust()
                }
            }
        )
        trustObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    AppModel.trustRefreshTarget?.refreshAccessibilityTrust()
                }
            }
        )
    }

    private func updateTrustPolling() {
        if AccessibilityTrustPolling.shouldPoll(isTrusted: accessibilityTrusted) {
            startTrustPollingIfNeeded()
        } else {
            stopTrustPolling()
        }
    }

    private func startTrustPollingIfNeeded() {
        guard trustPollTimer == nil else { return }
        let timer = Timer(timeInterval: AccessibilityTrustPolling.interval, repeats: true) { _ in
            // The timer is on the main run loop, including menu tracking.
            MainActor.assumeIsolated {
                AppModel.trustRefreshTarget?.refreshAccessibilityTrust()
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        trustPollTimer = timer
    }

    private func stopTrustPolling() {
        trustPollTimer?.invalidate()
        trustPollTimer = nil
    }

    private func reloadLayouts() {
        let nextKey = displays.currentKey()
        if currentConfigurationKey != nextKey {
            currentConfigurationKey = nextKey
        }
        let summary = displays.summary()
        if displaySummary != summary {
            displaySummary = summary
        }
        let loaded = coordinator.flatMap { try? $0.savedLayouts() } ?? []
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
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                AccessibilityChangeObserver.current?.onChange?()
            }
        }
    }
}
