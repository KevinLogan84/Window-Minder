import AppKit
import ApplicationServices
import CoreGraphics
import os

private let trustLogger = Logger(subsystem: WindowMinderIdentity.bundleIdentifier, category: "accessibility")

enum AccessibilityClientError: LocalizedError {
    case notTrusted

    var errorDescription: String? {
        "Accessibility access is not granted."
    }
}

/// Trust prompts and the list of apps worth scanning. Window reads run in `AXWindowWork`.
@MainActor
final class AccessibilityClient {
    /// Last combined decision. Layout reads use this so they do not call
    /// `AXIsProcessTrusted` again and pick up a stale cache.
    private var trusted = false

    /// Shows the system prompt once. The returned bool is not the source of truth:
    /// `AXIsProcessTrusted` can stay cached for the life of the process.
    @discardableResult
    func promptForTrust() -> Bool {
        let options = [trustedPromptKey(kAXTrustedCheckOptionPrompt): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Cached `AXIsProcessTrusted` plus a live window read.
    /// Apps that already have on-screen windows must return those windows.
    /// An empty or failed read is not trusted, even when the cache says true.
    func currentTrust(source: AccessibilityTrustCheckSource) -> Bool {
        let processTrusted = AXIsProcessTrusted()
        let probe = liveWindowProbe()
        let line = AccessibilityTrustDecision.logLine(
            source: source,
            processTrusted: processTrusted,
            probeError: probe.probeError
        )
        trustLogger.info("\(line, privacy: .public)")
        let effective = AccessibilityTrustDecision.isEffective(
            processTrusted: processTrusted,
            probeError: probe.probeError,
            onscreenAppsWithWindows: probe.onscreenAppsWithWindows,
            axWindowCount: probe.axWindowCount,
            axReadFailed: probe.axReadFailed
        )
        let readFailed = probe.axReadFailed ? "true" : "false"
        let effectiveText = effective ? "true" : "false"
        trustLogger.info(
            "Window probe source=\(source.rawValue, privacy: .public) onscreenApps=\(probe.onscreenAppsWithWindows, privacy: .public) axWindows=\(probe.axWindowCount, privacy: .public) axReadFailed=\(readFailed, privacy: .public) effective=\(effectiveText, privacy: .public)"
        )
        trusted = effective
        return trusted
    }

    var isTrusted: Bool {
        trusted
    }

    private struct WindowProbe {
        var probeError: Int32
        var onscreenAppsWithWindows: Int
        var axWindowCount: Int
        var axReadFailed: Bool
    }

    /// On-screen regular apps are read with `kAXWindowsAttribute`.
    /// No such apps falls back to the system-wide attribute probe.
    private func liveWindowProbe() -> WindowProbe {
        let pids = onscreenRegularAppPIDs()
        guard !pids.isEmpty else {
            return WindowProbe(
                probeError: liveProbeError(),
                onscreenAppsWithWindows: 0,
                axWindowCount: 0,
                axReadFailed: false
            )
        }
        var windows = 0
        var sawEmpty = false
        var hardError: Int32?
        for pid in pids.prefix(6) {
            let application = AXUIElementCreateApplication(pid)
            let (error, count) = copyWindowCount(application)
            if error == AccessibilityAPIErrorCode.apiDisabled {
                trustLogger.error(
                    "AX windows probe apiDisabled pid=\(pid, privacy: .public)"
                )
                return WindowProbe(
                    probeError: error,
                    onscreenAppsWithWindows: pids.count,
                    axWindowCount: 0,
                    axReadFailed: true
                )
            }
            if error == AccessibilityAPIErrorCode.success || error == AccessibilityAPIErrorCode.noValue {
                if count > 0 {
                    windows += count
                    break
                }
                sawEmpty = true
                continue
            }
            if error == AccessibilityAPIErrorCode.cannotComplete {
                trustLogger.error(
                    "AX windows probe timed out pid=\(pid, privacy: .public) error=\(error, privacy: .public)"
                )
                continue
            }
            trustLogger.error(
                "AX windows probe failed pid=\(pid, privacy: .public) error=\(error, privacy: .public)"
            )
            hardError = error
        }
        let probeError: Int32
        if windows > 0 {
            probeError = AccessibilityAPIErrorCode.success
        } else if let hardError {
            probeError = hardError
        } else if sawEmpty {
            probeError = AccessibilityAPIErrorCode.success
        } else {
            probeError = AccessibilityAPIErrorCode.cannotComplete
        }
        return WindowProbe(
            probeError: probeError,
            onscreenAppsWithWindows: pids.count,
            axWindowCount: windows,
            axReadFailed: hardError != nil && windows == 0
        )
    }

    /// Regular apps, other than Window Minder, that own an on-screen layer-0 window.
    /// The frontmost app is first so a working grant returns on the first read.
    private func onscreenRegularAppPIDs() -> [pid_t] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        var owners = Set<pid_t>()
        for window in info {
            let layer = integer(window[kCGWindowLayer as String]) ?? 0
            guard layer == 0 else { continue }
            guard let pid = integer(window[kCGWindowOwnerPID as String]), pid > 0 else { continue }
            if let bounds = window[kCGWindowBounds as String] as? [String: Any] {
                let width = cgFloat(bounds["Width"]) ?? 0
                let height = cgFloat(bounds["Height"]) ?? 0
                if width < 2 || height < 2 { continue }
            }
            owners.insert(pid_t(pid))
        }
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular
                && !app.isTerminated
                && owners.contains(app.processIdentifier)
                && !isOwnApp(app)
        }
        var ordered: [pid_t] = []
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           apps.contains(where: { $0.processIdentifier == front }) {
            ordered.append(front)
        }
        for app in apps where app.processIdentifier != ordered.first {
            ordered.append(app.processIdentifier)
        }
        return ordered
    }

    private func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let number = value as? Int { return number }
        return nil
    }

    private func cgFloat(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let number = value as? Double { return number }
        return nil
    }

    private func isOwnApp(_ app: NSRunningApplication) -> Bool {
        if app.processIdentifier == NSRunningApplication.current.processIdentifier {
            return true
        }
        let bundle = app.bundleIdentifier ?? ""
        return bundle == WindowMinderIdentity.bundleIdentifier || bundle == Bundle.main.bundleIdentifier
    }

    private func copyWindowCount(_ element: AXUIElement) -> (error: Int32, count: Int) {
        AXUIElementSetMessagingTimeout(element, Float(AccessibilityTrustPolling.probeTimeout))
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
        guard error == .success, let value else {
            return (error.rawValue, 0)
        }
        if let elements = value as? [AXUIElement] {
            return (error.rawValue, elements.count)
        }
        guard CFGetTypeID(value) == CFArrayGetTypeID() else {
            return (error.rawValue, 0)
        }
        return (error.rawValue, CFArrayGetCount(value as! CFArray))
    }

    /// System-wide focused application, then the frontmost app's windows if that
    /// copy is API-disabled. API-disabled fails immediately; the timeout only
    /// bounds a trusted-but-unresponsive call.
    private func liveProbeError() -> Int32 {
        // These kAX constants are String in Swift. Cast both to CFString the same way.
        var errors = [copyAttributeError(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString)]
        if errors[0] == AccessibilityAPIErrorCode.apiDisabled,
           let application = frontmostApplicationElement() {
            errors.append(copyAttributeError(application, kAXWindowsAttribute as CFString))
        }
        return AccessibilityTrustDecision.preferredProbeError(errors)
    }

    private func frontmostApplicationElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier > 0 else {
            return nil
        }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private func copyAttributeError(_ element: AXUIElement, _ name: CFString) -> Int32 {
        AXUIElementSetMessagingTimeout(element, Float(AccessibilityTrustPolling.probeTimeout))
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name, &value)
        _ = value
        return error.rawValue
    }

    func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func scanTargets(ignoredBundleIdentifiers: Set<String>) -> [ScanCandidate] {
        let candidates = NSWorkspace.shared.runningApplications.map { app in
            ScanCandidate(
                processIdentifier: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier ?? "",
                isHidden: app.isHidden,
                isTerminated: app.isTerminated,
                activationPolicy: Self.kind(app.activationPolicy)
            )
        }
        return WindowScanFilter.appsToScan(candidates, ignoredBundleIdentifiers: ignoredBundleIdentifiers)
    }

    private static func kind(_ policy: NSApplication.ActivationPolicy) -> AppActivationKind {
        switch policy {
        case .regular:
            return .regular
        case .accessory:
            return .accessory
        case .prohibited:
            return .prohibited
        @unknown default:
            return .unknown
        }
    }

    /// The prompt option is `Unmanaged<CFString>` in some SDKs and `CFString` in others.
    private func trustedPromptKey(_ value: CFString) -> String {
        value as String
    }

    private func trustedPromptKey(_ value: Unmanaged<CFString>) -> String {
        value.takeUnretainedValue() as String
    }
}
