import AppKit
import ApplicationServices
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

    /// Combines the cached process flag with a live attribute copy.
    func currentTrust(source: AccessibilityTrustCheckSource) -> Bool {
        let processTrusted = AXIsProcessTrusted()
        let probeError = liveProbeError()
        let line = AccessibilityTrustDecision.logLine(
            source: source,
            processTrusted: processTrusted,
            probeError: probeError
        )
        trustLogger.info("\(line, privacy: .public)")
        trusted = AccessibilityTrustDecision.isTrusted(processTrusted: processTrusted, probeError: probeError)
        return trusted
    }

    var isTrusted: Bool {
        trusted
    }

    /// System-wide focused application, then the frontmost app's windows if that
    /// copy is API-disabled. API-disabled fails immediately; the timeout only
    /// bounds a trusted-but-unresponsive call.
    private func liveProbeError() -> Int32 {
        var errors = [copyAttributeError(AXUIElementCreateSystemWide(), attribute(kAXFocusedApplicationAttribute))]
        if errors[0] == AccessibilityAPIErrorCode.apiDisabled,
           let application = frontmostApplicationElement() {
            errors.append(copyAttributeError(application, attribute(kAXWindowsAttribute)))
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

    private func attribute(_ value: CFString) -> CFString {
        value
    }

    private func attribute(_ value: Unmanaged<CFString>) -> CFString {
        value.takeUnretainedValue()
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
