import SwiftUI

@main
struct WindowMinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
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
