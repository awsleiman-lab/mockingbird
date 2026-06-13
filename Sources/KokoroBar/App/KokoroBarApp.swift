import SwiftUI

@main
struct KokoroBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = KokoroController()

    var body: some Scene {
        MenuBarExtra {
            KokoroMenuView(controller: controller)
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
