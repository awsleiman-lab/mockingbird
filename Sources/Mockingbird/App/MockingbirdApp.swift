import Sparkle
import SwiftUI

@main
struct MockingbirdApp: App {
    @StateObject private var controller = SpeechController()
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        MenuBarExtra {
            MockingbirdMenuView(controller: controller, updaterController: updaterController)
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
