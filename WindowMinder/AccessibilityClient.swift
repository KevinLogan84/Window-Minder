import AppKit
import ApplicationServices
import os

struct CapturedWindow {
    var record: WindowRecord
    var element: AXUIElement
}

struct RestoreReport {
    var restored: Int
    var failed: Int
}

enum AccessibilityClientError: LocalizedError {
    case notTrusted

    var errorDescription: String? {
        "Accessibility access is not granted."
    }
}

/// Reads and writes standard windows through the Accessibility API.
@MainActor
final class AccessibilityClient {
    private let logger = Logger(subsystem: WindowMinderIdentity.bundleIdentifier, category: "windows")
    private let fullScreenAttribute = "AXFullScreen"

    func promptForTrust() -> Bool {
        let options = [trustedPromptKey(kAXTrustedCheckOptionPrompt): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func captureWindows(ignoredBundleIdentifiers: Set<String>, primaryHeight: Double) throws -> [CapturedWindow] {
        guard isTrusted else { throw AccessibilityClientError.notTrusted }
        var captured: [CapturedWindow] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.processIdentifier > 0, let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { continue }
            if ignoredBundleIdentifiers.contains(bundleID) { continue }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var index = 0
            for element in copyWindows(of: axApp) {
                guard isStandardWindow(element) else { continue }
                defer { index += 1 }
                guard let frame = copyFrame(element) else { continue }
                let title = copyString(element, kAXTitleAttribute) ?? ""
                let cocoa = CoordinateConverter.cocoaFrame(fromAccessibility: frame, primaryHeight: primaryHeight)
                let record = WindowRecord(
                    bundleIdentifier: bundleID,
                    windowTitle: title,
                    windowIndex: index,
                    frame: cocoa
                )
                captured.append(CapturedWindow(record: record, element: element))
            }
        }
        return captured
    }

    func restore(
        records: [WindowRecord],
        ignoredBundleIdentifiers: Set<String>,
        primaryHeight: Double
    ) -> RestoreReport {
        let captured: [CapturedWindow]
        do {
            captured = try captureWindows(
                ignoredBundleIdentifiers: ignoredBundleIdentifiers,
                primaryHeight: primaryHeight
            )
        } catch {
            return RestoreReport(restored: 0, failed: max(records.count, 1))
        }

        let matches = WindowMatcher.match(
            saved: records,
            live: captured.map(\.record),
            ignoredBundleIdentifiers: ignoredBundleIdentifiers
        )
        var restored = 0
        var failed = 0
        for match in matches {
            guard let live = captured.first(where: { candidate in
                candidate.record.bundleIdentifier == match.live.bundleIdentifier
                    && candidate.record.windowIndex == match.live.windowIndex
                    && candidate.record.windowTitle == match.live.windowTitle
            }) else {
                failed += 1
                continue
            }
            if apply(frame: match.saved.frame, to: live.element, primaryHeight: primaryHeight) {
                restored += 1
            } else {
                failed += 1
                logger.error(
                    "Could not move \(match.live.bundleIdentifier, privacy: .public) window \(match.live.windowIndex, privacy: .public)"
                )
            }
        }
        return RestoreReport(restored: restored, failed: failed)
    }

    private func apply(frame: WMRect, to element: AXUIElement, primaryHeight: Double) -> Bool {
        exitFullscreenIfNeeded(element)
        let axFrame = CoordinateConverter.accessibilityFrame(fromCocoa: frame, primaryHeight: primaryHeight)
        let sizeOK = setSize(CGSize(width: axFrame.width, height: axFrame.height), on: element)
        let positionOK = setPoint(CGPoint(x: axFrame.x, y: axFrame.y), on: element)
        return sizeOK && positionOK
    }

    private func exitFullscreenIfNeeded(_ element: AXUIElement) {
        guard let value = copyAttribute(element, fullScreenAttribute) else { return }
        let isFullscreen: Bool
        if let boolValue = value as? Bool {
            isFullscreen = boolValue
        } else if CFGetTypeID(value) == CFBooleanGetTypeID() {
            isFullscreen = CFBooleanGetValue((value as! CFBoolean))
        } else {
            return
        }
        guard isFullscreen else { return }
        AXUIElementSetAttributeValue(element, fullScreenAttribute as CFString, kCFBooleanFalse)
    }

    /// A standard window has subrole AXStandardWindow. If the subrole is missing, role AXWindow still counts.
    /// Panels, sheets, and menus have a different subrole and are skipped.
    private func isStandardWindow(_ element: AXUIElement) -> Bool {
        var subroleValue: CFTypeRef?
        let subroleError = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
        if subroleError == .success, let subrole = bridgedString(subroleValue) {
            return subrole == kAXStandardWindowSubrole
        }
        let subroleMissing = subroleError == .noValue || subroleError == .attributeUnsupported || subroleValue == nil
        guard subroleMissing else { return false }
        guard let role = copyString(element, kAXRoleAttribute) else { return false }
        return role == kAXWindowRole
    }

    private func copyWindows(of app: AXUIElement) -> [AXUIElement] {
        guard let value = copyAttribute(app, kAXWindowsAttribute) else { return [] }
        if let elements = value as? [AXUIElement] {
            return elements
        }
        guard CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = value as! CFArray
        return (0..<CFArrayGetCount(array)).compactMap { index in
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { return nil }
            return Unmanaged<AXUIElement>.fromOpaque(pointer).takeUnretainedValue()
        }
    }

    private func copyFrame(_ element: AXUIElement) -> WMRect? {
        guard let position = copyPoint(element, kAXPositionAttribute),
              let size = copySize(element, kAXSizeAttribute)
        else { return nil }
        return WMRect(
            x: Double(position.x),
            y: Double(position.y),
            width: Double(size.width),
            height: Double(size.height)
        )
    }

    private func copyPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let raw = copyAttribute(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(raw as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func copySize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let raw = copyAttribute(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(raw as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        bridgedString(copyAttribute(element, attribute))
    }

    private func bridgedString(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as String
    }

    /// The prompt option is `Unmanaged<CFString>` in some SDKs and `CFString` in others.
    private func trustedPromptKey(_ value: CFString) -> String {
        value as String
    }

    private func trustedPromptKey(_ value: Unmanaged<CFString>) -> String {
        value.takeUnretainedValue() as String
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value
    }

    private func setPoint(_ point: CGPoint, on element: AXUIElement) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    private func setSize(_ size: CGSize, on element: AXUIElement) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
    }
}
