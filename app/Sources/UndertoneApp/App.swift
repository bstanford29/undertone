import SwiftUI

@main
struct UndertoneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        // The standard Settings scene: ⌘, opens it, and so do the menu bar
        // item, the pill's Flow menu, and the main window's Settings button.
        Settings {
            SettingsWindowView()
                .environmentObject(delegate.model)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Open Undertone") { delegate.model.showApp(.home) }
            }
        }
    }
}
