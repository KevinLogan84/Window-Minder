import AppKit
import SwiftUI

struct PreferencesView: View {
    @Environment(AppModel.self) private var model
    @ScaledMetric(relativeTo: .body) private var rowHeight = 36

    @ViewBuilder var body: some View {
        @Bindable var model = model

        Form {
            Section {
                ShortcutRecorder(title: "Store Windows", hotkey: $model.storeHotkey)
                    .frame(minHeight: rowHeight)
                ShortcutRecorder(title: "Restore Windows", hotkey: $model.restoreHotkey)
                    .frame(minHeight: rowHeight)
                if let hotkeyMessage = model.hotkeyMessage {
                    Text(hotkeyMessage)
                        .font(.callout)
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Shortcut registration failed. \(hotkeyMessage)")
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Shortcuts work while another app is focused. The defaults are Control-Option-Command-S to store and Control-Option-Command-R to restore.")
                    .font(.callout)
            }

            Section {
                Toggle("Auto-restore layouts", isOn: $model.autoRestore)
                    .accessibilityHint("Restores the matching layout when a dock is connected or disconnected, and after the Mac or its displays wake. A screen unlock restores only when the display setup changed. Waits until a window drag ends.")
                Toggle("Save layout before a display change", isOn: $model.saveBeforeDisplayChange)
                    .accessibilityHint("Keeps an in-memory snapshot and writes it for the previous display setup when displays change.")
                Toggle("Periodically save the current layout", isOn: $model.periodicAutoSave)
                    .accessibilityHint("Saves the current layout every 2 minutes. Off unless you turn it on.")
            } header: {
                Text("Automation")
            } footer: {
                Text("Display changes settle for a couple of seconds, so plugging in a dock is one restore. After the displays wake, a screen that is still connecting is waited on for about a minute and a half before a layout for fewer screens is applied. The previous setup is saved from the latest snapshot taken while that setup was still connected.")
                    .font(.callout)
            }

            Section {
                if model.ignoredBundleIDs.isEmpty {
                    Text("No apps are ignored.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.ignoredBundleIDs, id: \.self) { bundleID in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.appName(for: bundleID))
                                    .font(.body)
                                if model.appName(for: bundleID) != bundleID {
                                    Text(bundleID)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 12)
                            Button("Remove") {
                                model.removeIgnored(bundleID)
                            }
                            .accessibilityLabel("Remove \(model.appName(for: bundleID)) from ignored apps")
                        }
                    }
                }
                Button("Ignore Frontmost App") {
                    model.ignoreFrontmost()
                }
                .accessibilityHint("Adds the frontmost application to the ignored list.")
            } header: {
                Text("Ignored Apps")
            }

            Section {
                Text("Window Minder stays on this Mac. It does not use the network, accounts, ads, or analytics.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 480)
        .padding(8)
        .background(SettingsWindowTitleEnforcer())
    }
}

/// The Settings scene's title bar should say Settings, including after SwiftUI
/// applies its own title when the window is created.
private struct SettingsWindowTitleEnforcer: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsWindowTitleView {
        SettingsWindowTitleView(frame: .zero)
    }

    func updateNSView(_ nsView: SettingsWindowTitleView, context: Context) {
        nsView.applyTitle()
    }
}

@MainActor
private final class SettingsWindowTitleView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Self.applyTitle(to: window)
    }

    func applyTitle() {
        Self.applyTitle(to: window)
    }

    private static func applyTitle(to window: NSWindow?) {
        window?.title = SettingsWindowPlanner.windowTitle
    }
}
