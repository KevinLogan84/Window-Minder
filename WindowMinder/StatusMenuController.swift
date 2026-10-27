import AppKit
import Observation

/// Menu-bar menu rebuilt on every open.
///
/// `MenuBarExtra` with the `.menu` style snapshots its content into an `NSMenu`
/// and was keeping a stale Accessibility warning after trust flipped.
/// `menuNeedsUpdate` reads the model and builds the items again.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let menu = NSMenu()
    private var statusItem: NSStatusItem?
    private var rebuilding = false
    private var menuOpen = false

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func install() {
        menu.delegate = self
        menu.autoenablesItems = false
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.menu = menu
        statusItem = item
        model.onAccessibilityTrustChange = { [weak self] in
            self?.rebuildIfOpen()
        }
        applyIcon()
        trackIcon()
    }

    @objc nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { [weak self] in
            guard let controller = self else { return }
            controller.prepare(menu)
        }
    }

    @objc nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated { [weak self] in
            guard let controller = self, menu === controller.menu else { return }
            controller.menuOpen = true
        }
    }

    @objc nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated { [weak self] in
            guard let controller = self, menu === controller.menu else { return }
            controller.menuOpen = false
        }
    }

    private func prepare(_ menu: NSMenu) {
        guard menu === self.menu, !rebuilding else { return }
        rebuilding = true
        menuOpen = true
        model.refreshForMenu()
        populate(menu)
        rebuilding = false
    }

    private func rebuildIfOpen() {
        guard menuOpen, !rebuilding else { return }
        rebuilding = true
        populate(menu)
        rebuilding = false
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        let actionsAllowed = AccessibilityTrustPolling.menuAllowsWindowActions(isTrusted: model.accessibilityTrusted)
            && !model.isWindowOperationRunning

        if AccessibilityTrustPolling.showsAccessDenied(isTrusted: model.accessibilityTrusted) {
            menu.addItem(actionItem(
                AccessibilityMenuCopy.accessNeeded,
                action: #selector(openAccessibilitySettings(_:))
            ))
            menu.addItem(.separator())
        }

        menu.addItem(label(model.displaySummary))
        menu.addItem(actionItem("Store Windows Now", action: #selector(storeWindows(_:)), enabled: actionsAllowed))
        menu.addItem(actionItem("Restore Windows Now", action: #selector(restoreWindows(_:)), enabled: actionsAllowed))
        if let statusMessage = model.statusMessage, !statusMessage.isEmpty {
            menu.addItem(label(statusMessage))
        }

        menu.addItem(.separator())
        menu.addItem(savedLayoutsItem())
        menu.addItem(.separator())

        menu.addItem(actionItem(
            "Auto-Restore",
            action: #selector(toggleAutoRestore(_:)),
            state: model.autoRestore ? .on : .off
        ))
        menu.items.last?.toolTip = "Restores the saved layout when a dock is connected or disconnected, and after the Mac wakes or logs in."

        if LoginItemPresentation.showsToggle(model.loginState) {
            menu.addItem(actionItem(
                model.loginTitle,
                action: #selector(toggleLogin(_:)),
                state: LoginItemPresentation.isEnabled(model.loginState) ? .on : .off
            ))
        } else {
            menu.addItem(actionItem(model.loginTitle, action: #selector(toggleLogin(_:))))
        }
        if let loginMessage = model.loginMessage, !loginMessage.isEmpty {
            menu.addItem(label(loginMessage))
        }

        menu.addItem(ignoredAppsItem())
        menu.addItem(.separator())
        menu.addItem(actionItem(SettingsWindowPlanner.menuTitle, action: #selector(openSettingsWindow(_:))))
        menu.addItem(actionItem("Quit Window Minder", action: #selector(quit(_:))))
    }

    private func savedLayoutsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Saved Layouts", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        if model.layouts.isEmpty {
            submenu.addItem(label("No Saved Layouts"))
        } else {
            for layout in model.layouts {
                let layoutItem = NSMenuItem(title: model.layoutMenuTitle(layout), action: nil, keyEquivalent: "")
                let layoutMenu = NSMenu()
                layoutMenu.autoenablesItems = false
                layoutMenu.addItem(actionItem(
                    "Delete",
                    action: #selector(deleteSavedLayout(_:)),
                    represented: layout.key
                ))
                layoutItem.submenu = layoutMenu
                submenu.addItem(layoutItem)
            }
        }
        item.submenu = submenu
        return item
    }

    private func ignoredAppsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Ignored Apps", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        if model.ignoredBundleIDs.isEmpty {
            submenu.addItem(label("None"))
        } else {
            for bundleID in model.ignoredBundleIDs {
                submenu.addItem(actionItem(
                    "Remove \(model.appName(for: bundleID))",
                    action: #selector(removeIgnored(_:)),
                    represented: bundleID
                ))
            }
        }
        submenu.addItem(.separator())
        submenu.addItem(actionItem("Ignore Frontmost App", action: #selector(ignoreFrontmost(_:))))
        item.submenu = submenu
        return item
    }

    private func label(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(
        _ title: String,
        action: Selector,
        enabled: Bool = true,
        state: NSControl.StateValue = .off,
        represented: String? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        item.state = state
        if let represented {
            item.representedObject = represented as NSString
        }
        return item
    }

    private func trackIcon() {
        withObservationTracking {
            _ = model.menuBarActivity
            _ = model.statusMessage
        } onChange: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let controller = self else { return }
                MainActor.assumeIsolated {
                    controller.applyIcon()
                    controller.trackIcon()
                }
            }
        }
    }

    private func applyIcon() {
        guard let button = statusItem?.button else { return }
        let description = model.menuBarAccessibilityLabel
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let image = NSImage(systemSymbolName: model.menuBarSymbol, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(description)
    }

    @objc nonisolated private func storeWindows(_ sender: NSMenuItem) {
        MainActor.assumeIsolated { [weak self] in
            guard let controller = self else { return }
            controller.model.storeNow()
        }
    }

    @objc nonisolated private func restoreWindows(_ sender: NSMenuItem) {
        MainActor.assumeIsolated { [weak self] in
            guard let controller = self else { return }
            controller.model.restoreNow()
        }
    }

    @objc nonisolated private func toggleAutoRestore(_ sender: NSMenuItem) {
        MainActor.assumeIsolated { [weak self] in
            guard let controller = self else { return }
            controller.model.autoRestore.toggle()
        }
    }

    @objc nonisolated private func toggleLogin(_ sender: NSMenuItem) {
        MainActor.assumeIsolated { [weak self] in
            guard let controller = self else { return }
            controller.model.toggleLoginItem()
        }
    }

    @objc nonisolated private func openAccessibilitySettings(_ sender: NSMenuItem) {
        MainActor.assumeIsolated { [weak self] in
            guard let controller = self else { return }
            controller.model.openAccessibilitySettings()
        }
    }

    /// The status item is still tracking the menu on this click. A window opened
    /// before the menu closes loses key status, so the open runs on a later turn.
    @objc nonisolated private func openSettingsWindow(_ sender: NSMenuItem) {
        DispatchQueue.main.async { [weak self] in
            guard let controller = self else { return }
            MainActor.assumeIsolated {
                controller.openSettingsWindowAfterMenuCloses()
            }
        }
    }

    private func openSettingsWindowAfterMenuCloses(attempt: Int = 0) {
        if menuOpen {
            menu.cancelTracking()
            guard attempt < 5 else {
                model.openSettingsWindow()
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let controller = self else { return }
                MainActor.assumeIsolated {
                    controller.openSettingsWindowAfterMenuCloses(attempt: attempt + 1)
                }
            }
            return
        }
        model.openSettingsWindow()
    }

    @objc nonisolated private func quit(_ sender: NSMenuItem) {
        MainActor.assumeIsolated { NSApp.terminate(nil) }
    }

    @objc nonisolated private func ignoreFrontmost(_ sender: NSMenuItem) {
        MainActor.assumeIsolated { [weak self] in
            guard let controller = self else { return }
            controller.model.ignoreFrontmost()
        }
    }

    @objc nonisolated private func removeIgnored(_ sender: NSMenuItem) {
        MainActor.assumeIsolated { [weak self] in
            guard let controller = self else { return }
            guard let bundleID = sender.representedObject as? String else { return }
            controller.model.removeIgnored(bundleID)
        }
    }

    @objc nonisolated private func deleteSavedLayout(_ sender: NSMenuItem) {
        MainActor.assumeIsolated { [weak self] in
            guard let controller = self else { return }
            guard let key = sender.representedObject as? String else { return }
            controller.model.deleteLayout(key: key)
        }
    }
}
