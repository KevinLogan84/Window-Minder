import AppKit
import SwiftUI

struct MenuContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Group {
            if !model.accessibilityTrusted {
                Text("Accessibility Access Not Granted")
                Button("Open Accessibility Settings…") {
                    model.openAccessibilitySettings()
                }
                Divider()
            }

            Text(model.displaySummary)

            Button("Store Windows Now") {
                model.storeNow()
            }
            .disabled(!model.accessibilityTrusted)

            Button("Restore Windows Now") {
                model.restoreNow()
            }
            .disabled(!model.accessibilityTrusted)

            if let statusMessage = model.statusMessage {
                Text(statusMessage)
            }

            Divider()

            Menu("Saved Layouts") {
                if model.layouts.isEmpty {
                    Text("No Saved Layouts")
                } else {
                    ForEach(model.layouts) { layout in
                        Menu(model.layoutMenuTitle(layout)) {
                            Button("Delete", role: .destructive) {
                                model.deleteLayout(key: layout.key)
                            }
                        }
                    }
                }
            }

            Divider()

            Toggle("Auto-Restore", isOn: $model.autoRestore)
                .accessibilityHint("Restores the saved layout when displays change and after the Mac wakes.")

            loginControl

            Menu("Ignored Apps") {
                if model.ignoredBundleIDs.isEmpty {
                    Text("None")
                } else {
                    ForEach(model.ignoredBundleIDs, id: \.self) { bundleID in
                        Button("Remove \(model.appName(for: bundleID))") {
                            model.removeIgnored(bundleID)
                        }
                    }
                }
                Divider()
                Button("Ignore Frontmost App") {
                    model.ignoreFrontmost()
                }
            }

            Divider()

            Button("Preferences…") {
                model.openPreferences()
            }
            Button("Quit Window Minder") {
                NSApp.terminate(nil)
            }
        }
        .onAppear {
            model.refreshForMenu()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            model.refreshForMenu()
        }
    }

    @ViewBuilder
    private var loginControl: some View {
        switch model.loginState {
        case .enabled, .notRegistered:
            Toggle(model.loginTitle, isOn: Binding(
                get: { model.loginState == .enabled },
                set: { enabled in
                    if enabled != (model.loginState == .enabled) {
                        model.toggleLoginItem()
                    }
                }
            ))
        case .requiresApproval, .notFound, .unknown:
            Button(model.loginTitle) {
                model.toggleLoginItem()
            }
        }
        if let loginMessage = model.loginMessage {
            Text(loginMessage)
        }
    }
}
