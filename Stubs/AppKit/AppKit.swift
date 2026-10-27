@_exported import Foundation

/// Linux stand-in for AppKit. Overrides and call labels match the macOS SDK.
/// `NSView.viewWillMove` is `viewWillMove(toWindow:)`, not `viewWillMove(to:)`.

public struct Selector: Hashable, Sendable {
    public let name: String
    public init(_ name: String) { self.name = name }
}

public struct NSUserInterfaceItemIdentifier: Hashable, RawRepresentable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public typealias NSRect = CGRect

open class NSResponder: NSObject {
    public override init() { super.init() }
}

@MainActor
open class NSView: NSResponder {
    public override init() { super.init() }
    public init(frame frameRect: NSRect) { super.init() }
    open var window: NSWindow? { nil }
    open var isOpaque: Bool { true }
    open func isAccessibilityElement() -> Bool { true }
    open func viewWillMove(toWindow newWindow: NSWindow?) {}
    open func viewDidMoveToWindow() {}
    open func setAccessibilityLabel(_ label: String?) {}
}

open class NSControl: NSView {
    public enum StateValue: Int {
        case mixed = -1
        case off = 0
        case on = 1
    }

    public enum ImagePosition: UInt {
        case imageOnly = 0
    }
}

open class NSFont: NSObject {
    public struct Weight: Hashable, Sendable {
        public static let regular = Weight()
    }
}

open class NSImage: NSObject {
    public struct SymbolConfiguration {
        public init(pointSize: CGFloat, weight: NSFont.Weight) {}
    }

    public init?(systemSymbolName: String, accessibilityDescription: String?) {}
    open func withSymbolConfiguration(_ configuration: SymbolConfiguration) -> NSImage? { self }
    open var isTemplate = false
}

open class NSButton: NSControl {
    open var image: NSImage?
    open var imagePosition: NSControl.ImagePosition = .imageOnly
}

open class NSStatusBarButton: NSButton {}

open class NSColor: NSObject {
    public static let systemRed = NSColor()
    public static let controlBackgroundColor = NSColor()
}

public protocol NSMenuDelegate: AnyObject {
    func menuNeedsUpdate(_ menu: NSMenu)
    func menuWillOpen(_ menu: NSMenu)
    func menuDidClose(_ menu: NSMenu)
}

open class NSMenuItem: NSObject {
    public init(title: String, action: Selector?, keyEquivalent: String) {}
    open var target: AnyObject?
    open var isEnabled = true
    open var state: NSControl.StateValue = .off
    open var representedObject: Any?
    open var submenu: NSMenu?
    open var toolTip: String?
    open class func separator() -> NSMenuItem {
        NSMenuItem(title: "", action: nil, keyEquivalent: "")
    }
}

open class NSMenu: NSObject {
    open weak var delegate: NSMenuDelegate?
    open var autoenablesItems = true
    open var items: [NSMenuItem] = []
    open func removeAllItems() { items.removeAll() }
    open func addItem(_ newItem: NSMenuItem) { items.append(newItem) }
    open func cancelTracking() {}
}

open class NSStatusItem: NSObject {
    public static let squareLength: CGFloat = -2
    open var menu: NSMenu?
    open var button: NSStatusBarButton? { NSStatusBarButton() }
}

open class NSStatusBar: NSObject {
    public static let system = NSStatusBar()
    open func statusItem(withLength length: CGFloat) -> NSStatusItem { NSStatusItem() }
}

open class NSWindow: NSResponder {
    public struct CollectionBehavior: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let moveToActiveSpace = CollectionBehavior(rawValue: 1 << 1)
        public static let transient = CollectionBehavior(rawValue: 1 << 3)
        public static let stationary = CollectionBehavior(rawValue: 1 << 4)
        public static let ignoresCycle = CollectionBehavior(rawValue: 1 << 6)
    }

    open var identifier: NSUserInterfaceItemIdentifier?
    open var title = ""
    open var isVisible = false
    open var isMiniaturized = false
    open var alphaValue: CGFloat = 1
    open var ignoresMouseEvents = false
    open var hasShadow = true
    open var isExcludedFromWindowsMenu = false
    open var isRestorable = true
    open var isKeyWindow = false
    open var collectionBehavior: CollectionBehavior = []

    open func deminiaturize(_ sender: Any?) {}
    open func makeKeyAndOrderFront(_ sender: Any?) {}
    open func orderFrontRegardless() {}
    open func makeKey() {}
    open func resignKey() {}
    open func setFrame(_ frameRect: NSRect, display flag: Bool) {}
}

public protocol NSApplicationDelegate: AnyObject {
    func applicationDidFinishLaunching(_ notification: Notification)
    func applicationDidBecomeActive(_ notification: Notification)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool
}

open class NSApplication: NSResponder {
    public static let shared = NSApplication()
    open var windows: [NSWindow] = []
    open var keyWindow: NSWindow?

    public enum ActivationPolicy: UInt {
        case regular = 0
        case accessory = 1
        case prohibited = 2
    }

    open func activate(ignoringOtherApps flag: Bool) {}
    open func activate() {}
    @discardableResult
    open func setActivationPolicy(_ activationPolicy: ActivationPolicy) -> Bool { false }
    open func terminate(_ sender: Any?) {}

    public static let didBecomeActiveNotification = Notification.Name("NSApplicationDidBecomeActiveNotification")
    public static let didChangeScreenParametersNotification = Notification.Name("NSApplicationDidChangeScreenParametersNotification")
}

public let NSApp = NSApplication.shared

open class NSRunningApplication: NSObject {
    open var bundleIdentifier: String? { nil }
    open var localizedName: String? { nil }
    open var processIdentifier: pid_t { 0 }
    open var isTerminated = false
    open var isHidden = false
    open var activationPolicy: NSApplication.ActivationPolicy { .regular }
    open class var current: NSRunningApplication { NSRunningApplication() }
}

open class NSWorkspace: NSObject {
    public static let shared = NSWorkspace()
    open var frontmostApplication: NSRunningApplication? { nil }
    open var runningApplications: [NSRunningApplication] { [] }
    open func urlForApplication(withBundleIdentifier bundleIdentifier: String) -> URL? { nil }
    @discardableResult
    open func open(_ url: URL) -> Bool { false }
    open var notificationCenter: NotificationCenter { .default }
    public static let didActivateApplicationNotification = Notification.Name("NSWorkspaceDidActivateApplicationNotification")
    public static let didWakeNotification = Notification.Name("NSWorkspaceDidWakeNotification")
    public static let screensDidWakeNotification = Notification.Name("NSWorkspaceScreensDidWakeNotification")
    public static let applicationUserInfoKey = "NSWorkspaceApplicationKey"
}

public struct NSDeviceDescriptionKey: Hashable, RawRepresentable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

open class NSScreen: NSObject {
    open class var screens: [NSScreen] { [] }
    open var frame: NSRect { .zero }
    open var localizedName: String { "" }
    open var deviceDescription: [NSDeviceDescriptionKey: Any] { [:] }
}

open class NSEvent: NSObject {
    public struct ModifierFlags: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let command = ModifierFlags(rawValue: 1 << 20)
        public static let shift = ModifierFlags(rawValue: 1 << 17)
        public static let option = ModifierFlags(rawValue: 1 << 19)
        public static let control = ModifierFlags(rawValue: 1 << 18)
    }

    public struct EventTypeMask: OptionSet, Sendable {
        public let rawValue: UInt64
        public init(rawValue: UInt64) { self.rawValue = rawValue }
        public static let keyDown = EventTypeMask(rawValue: 1 << 10)
    }

    open var keyCode: UInt16 { 0 }
    open var modifierFlags: ModifierFlags { [] }

    public static func addLocalMonitorForEvents(
        matching mask: EventTypeMask,
        handler: @escaping (NSEvent) -> NSEvent?
    ) -> Any? {
        nil
    }

    public static func removeMonitor(_ eventMonitor: Any) {}
    public static var pressedMouseButtons: Int { 0 }
}

open class DistributedNotificationCenter: NotificationCenter, @unchecked Sendable {
    public enum SuspensionBehavior: UInt {
        case deliverImmediately = 4
    }

    private static let sharedCenter = DistributedNotificationCenter()
    open class func `default`() -> DistributedNotificationCenter { sharedCenter }

    open func addObserver(
        _ observer: Any,
        selector: Selector,
        name: Notification.Name?,
        object: Any?,
        suspensionBehavior: SuspensionBehavior
    ) {}
}

extension RunLoop.Mode {
    /// Present on Apple's Foundation. Linux's corelibs Foundation does not define it.
    public static let eventTracking = RunLoop.Mode("NSEventTrackingRunLoopMode")
}
