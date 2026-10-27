import AppKit
import SwiftUI

/// Captures SwiftUI's `openSettings` action so the status-item menu can open
/// the Settings scene without `showSettingsWindow:` or `showPreferencesWindow:`.
///
/// Those selectors are a no-op for an `LSUIElement` app on macOS 14 and later.
/// The action is only real inside a SwiftUI scene, so a 1×1 window hosts this
/// view. The window stays ordered in (ordering it out drops the action) but it
/// is transparent, off-screen, and excluded from the window list.
struct SettingsActionHost: View {
    static let sceneID = "settings-action-host"
    static let sceneTitle = "Window Minder Host"
    static let windowIdentifier = "com.kevinlogan.WindowMinder.settings-action-host"

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        SettingsActionBinder(openSettings: openSettings)
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
    }
}

/// Opens Settings from the status item and brings that one window forward.
///
/// The app stays an accessory (`LSUIElement`). This never changes the
/// activation policy, so the Dock icon stays hidden.
@MainActor
enum SettingsWindowPresenter {
    private static var pendingAttempts = 0
    /// True after openSettings is called and before the next turn raises the window.
    /// A second click in that gap must not open another Settings window.
    private static var opening = false

    static func openFromStatusItem() {
        Self.pendingAttempts = 0
        Self.perform()
    }

    private static func perform() {
        let plan = SettingsWindowPlanner.presentation(for: Self.snapshots())
        NSApp.activate(ignoringOtherApps: true)
        if plan == .orderFront {
            Self.opening = false
        } else if !Self.opening {
            guard SettingsActionBridge.shared.open() else {
                guard Self.pendingAttempts < 8 else { return }
                Self.pendingAttempts += 1
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        SettingsWindowPresenter.perform()
                    }
                }
                return
            }
            Self.opening = true
        }
        Self.orderFront()
        // openSettings can create the window on the next turn. Activate and raise it then too.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                SettingsWindowPresenter.orderFront()
                SettingsWindowPresenter.opening = false
            }
        }
    }

    private static func snapshots() -> [SettingsWindowCandidate] {
        NSApp.windows.map { window in
            SettingsWindowCandidate(
                identifier: window.identifier?.rawValue,
                title: window.title,
                isVisible: window.isVisible,
                isMiniaturized: window.isMiniaturized,
                isActionHost: Self.isActionHost(window)
            )
        }
    }

    private static func isActionHost(_ window: NSWindow) -> Bool {
        let identifier = window.identifier?.rawValue
        if identifier == SettingsActionHost.windowIdentifier || identifier == SettingsActionHost.sceneID {
            return true
        }
        return window.title == SettingsActionHost.sceneTitle
    }

    private static func orderFront() {
        let settings = NSApp.windows.filter { window in
            SettingsWindowPlanner.isSettingsWindow(Self.candidate(for: window))
        }
        guard let window = settings.first(where: { $0.isVisible })
            ?? settings.first(where: { $0.isMiniaturized })
            ?? settings.first
        else { return }
        window.title = SettingsWindowPlanner.windowTitle
        var behavior = window.collectionBehavior
        behavior.insert(.moveToActiveSpace)
        window.collectionBehavior = behavior
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        // Accessory apps are not ordered front by makeKeyAndOrderFront alone.
        window.orderFrontRegardless()
    }

    private static func candidate(for window: NSWindow) -> SettingsWindowCandidate {
        SettingsWindowCandidate(
            identifier: window.identifier?.rawValue,
            title: window.title,
            isVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized,
            isActionHost: Self.isActionHost(window)
        )
    }
}

@MainActor
private final class SettingsActionBridge {
    static let shared = SettingsActionBridge()

    private var openSettings: OpenSettingsAction?

    func bind(_ action: OpenSettingsAction) {
        openSettings = action
    }

    /// Opens the Settings scene. False when the host has not captured the action yet.
    func open() -> Bool {
        guard let openSettings else { return false }
        openSettings()
        return true
    }
}

private struct SettingsActionBinder: NSViewRepresentable {
    var openSettings: OpenSettingsAction

    func makeNSView(context: Context) -> SettingsHostView {
        let view = SettingsHostView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.bind(openSettings)
        return view
    }

    func updateNSView(_ nsView: SettingsHostView, context: Context) {
        nsView.bind(openSettings)
    }
}

@MainActor
private final class SettingsHostView: NSView {
    private var isHiding = false

    override var isOpaque: Bool { false }

    override func isAccessibilityElement() -> Bool { false }

    func bind(_ action: OpenSettingsAction) {
        SettingsActionBridge.shared.bind(action)
        Self.scheduleHide(of: self)
    }

    override func viewWillMove(to newWindow: NSWindow?) {
        super.viewWillMove(to: newWindow)
        Self.hide(newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Self.scheduleHide(of: self)
    }

    private static func scheduleHide(of view: SettingsHostView) {
        guard !view.isHiding else { return }
        view.isHiding = true
        Self.hide(view.window)
        view.isHiding = false
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            MainActor.assumeIsolated {
                guard !view.isHiding else { return }
                view.isHiding = true
                Self.hide(view.window)
                view.isHiding = false
            }
        }
    }

    /// Keeps the host out of sight and out of the keyboard focus without closing it.
    private static func hide(_ window: NSWindow?) {
        guard let window else { return }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isExcludedFromWindowsMenu = true
        window.isRestorable = false
        window.identifier = NSUserInterfaceItemIdentifier(rawValue: SettingsActionHost.windowIdentifier)
        window.title = SettingsActionHost.sceneTitle
        var behavior = window.collectionBehavior
        behavior.insert(.transient)
        behavior.insert(.ignoresCycle)
        behavior.insert(.stationary)
        window.collectionBehavior = behavior
        window.setFrame(NSRect(x: -10000, y: -10000, width: 1, height: 1), display: false)
        if window.isKeyWindow {
            window.resignKey()
        }
    }
}
