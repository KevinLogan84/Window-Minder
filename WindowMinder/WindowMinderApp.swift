import SwiftUI

#if !os(Linux)
@main
#endif
struct WindowMinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @SceneBuilder var body: some Scene {
        // Declared before Settings so this scene captures the real openSettings
        // action. The window is kept off-screen by SettingsActionHost.
        Window(LocalizedStringKey(SettingsActionHost.sceneTitle), id: SettingsActionHost.sceneID) {
            SettingsActionHost()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 1, height: 1)
        .commandsRemoved()

        Settings {
            PreferencesView()
                .environment(appDelegate.model)
        }
        .defaultSize(width: 560, height: 620)
    }
}

enum MenuBarActivity: Equatable {
    case idle
    case busy
    case success
}
