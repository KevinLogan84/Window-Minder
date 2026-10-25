import SwiftUI

@main
struct WindowMinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Window Minder", systemImage: "macwindow") {
            MenuContentView()
                .environment(appDelegate.model)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            PreferencesView()
                .environment(appDelegate.model)
        }
        .defaultSize(width: 560, height: 620)
    }
}
