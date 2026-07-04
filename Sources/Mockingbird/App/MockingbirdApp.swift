import SwiftUI

@main
struct MockingbirdApp: App {
    @StateObject private var controller = SpeechController()

    var body: some Scene {
        MenuBarExtra {
            MockingbirdMenuView(controller: controller)
                .frame(width: 320)
        } label: {
            Image(systemName: controller.menuIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(controller: controller)
        }
    }
}
