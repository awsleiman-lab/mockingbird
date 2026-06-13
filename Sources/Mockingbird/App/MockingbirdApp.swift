import SwiftUI

@main
struct MockingbirdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = SpeechController()

    var body: some Scene {
        MenuBarExtra {
            MockingbirdMenuView(controller: controller)
                .frame(width: 320)
        } label: {
            Image(systemName: controller.menuIcon)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
}
