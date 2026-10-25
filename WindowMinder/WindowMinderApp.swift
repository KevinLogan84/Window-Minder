import SwiftUI

@main
struct WindowMinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(appDelegate.model)
        } label: {
            MenuBarStatusLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            PreferencesView()
                .environment(appDelegate.model)
        }
        .defaultSize(width: 560, height: 620)
    }
}

private struct MenuBarStatusLabel: View {
    var model: AppModel

    var body: some View {
        Image(systemName: model.menuBarSymbol)
            .symbolRenderingMode(.monochrome)
            .symbolEffect(.pulse, options: .repeating, isActive: model.menuBarActivity == .busy)
            .accessibilityLabel(model.menuBarAccessibilityLabel)
    }
}

enum MenuBarActivity: Equatable {
    case idle
    case busy
    case success
}
