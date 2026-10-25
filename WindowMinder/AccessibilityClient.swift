import AppKit
import ApplicationServices

enum AccessibilityClientError: LocalizedError {
    case notTrusted

    var errorDescription: String? {
        "Accessibility access is not granted."
    }
}

/// Trust prompts and the list of apps worth scanning. Window reads run in `AXWindowWork`.
@MainActor
final class AccessibilityClient {
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
