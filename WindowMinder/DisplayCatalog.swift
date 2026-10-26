import AppKit
import CoreGraphics

/// Reads the connected screens. The configuration key prefers the EDID vendor,
/// product, and serial. `CGDisplayCreateUUIDFromDisplayID` is only a fallback, and
/// `CGDirectDisplayID` is never stored.
@MainActor
struct DisplayCatalog {
    func current() -> DisplayConfiguration {
        var displays: [DisplayDescriptor] = []
        for screen in NSScreen.screens {
            guard let displayID = displayID(for: screen) else { continue }
            let vendor = CGDisplayVendorNumber(displayID)
            let product = CGDisplayModelNumber(displayID)
            let serial = CGDisplaySerialNumber(displayID)
            let uuid = uuidString(for: displayID) ?? ""
            let hasEDID = vendor != 0 && product != 0
            if uuid.isEmpty && !hasEDID { continue }
            let frame = screen.frame
            let name = screen.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            displays.append(
                DisplayDescriptor(
                    uuid: uuid,
                    frame: WMRect(
                        x: Double(frame.origin.x),
                        y: Double(frame.origin.y),
                        width: Double(frame.size.width),
                        height: Double(frame.size.height)
                    ),
                    pixelWidth: Int(CGDisplayPixelsWide(displayID)),
                    pixelHeight: Int(CGDisplayPixelsHigh(displayID)),
                    name: name.isEmpty ? nil : name,
                    vendorID: hasEDID ? vendor : nil,
                    productID: hasEDID ? product : nil,
                    serialNumber: hasEDID ? serial : nil
                )
            )
        }
        return DisplayConfiguration(displays: displays)
    }

    /// Height of the display whose bottom-left is the Cocoa origin.
    func primaryHeight() -> Double {
        let frames = NSScreen.screens.map { screen in
            WMRect(
                x: Double(screen.frame.origin.x),
                y: Double(screen.frame.origin.y),
                width: Double(screen.frame.size.width),
                height: Double(screen.frame.size.height)
            )
        }
        return PrimaryDisplayHeight.points(frames: frames)
    }

    func currentKey() -> String? {
        let configuration = current()
        guard !configuration.displays.isEmpty else { return nil }
        return configuration.key
    }

    func summary() -> String {
        let configuration = current()
        let names = configuration.displays.compactMap(\.name).filter { !$0.isEmpty }
        if !names.isEmpty {
            return names.joined(separator: " + ")
        }
        switch configuration.displays.count {
        case 0:
            return "No Displays"
        case 1:
            return "1 Display"
        default:
            return "\(configuration.displays.count) Displays"
        }
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    private func uuidString(for displayID: CGDirectDisplayID) -> String? {
        guard let created = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        let uuid = retainedDisplayUUID(created)
        guard let raw = CFUUIDCreateString(nil, uuid) else { return nil }
        return uuidText(raw)
    }

    /// Create-rule imports return `Unmanaged`; annotated headers return the CF type directly.
    private func retainedDisplayUUID(_ uuid: CFUUID) -> CFUUID {
        uuid
    }

    private func retainedDisplayUUID(_ uuid: Unmanaged<CFUUID>) -> CFUUID {
        uuid.takeRetainedValue()
    }

    private func uuidText(_ value: CFString) -> String {
        value as String
    }

    private func uuidText(_ value: Unmanaged<CFString>) -> String {
        value.takeRetainedValue() as String
    }
}

/// Forwards `CGDisplayRegisterReconfigurationCallback` onto the main actor.
/// A dock connect or disconnect posts a burst of these; the coordinator debounces them.
@MainActor
final class DisplayReconfigurationMonitor {
    static let shared = DisplayReconfigurationMonitor()
    var onReconfigure: @MainActor () -> Void = {}
    private var installed = false

    func start() {
        guard !installed else { return }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let error = CGDisplayRegisterReconfigurationCallback({ display, flags, userInfo in
            handleDisplayReconfiguration(display, flags, userInfo)
        }, pointer)
        guard error == .success else { return }
        installed = true
    }

    fileprivate func fire() {
        onReconfigure()
    }
}

private func handleDisplayReconfiguration(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    _ = display
    _ = flags
    guard let userInfo else { return }
    DispatchQueue.main.async {
        let raw = userInfo
        MainActor.assumeIsolated {
            let monitor = Unmanaged<DisplayReconfigurationMonitor>.fromOpaque(raw).takeUnretainedValue()
            monitor.fire()
        }
    }
}
