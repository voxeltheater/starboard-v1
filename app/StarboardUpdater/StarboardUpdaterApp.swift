import SwiftUI

@main
struct StarboardUpdaterApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Starboard Updater", id: "main") {
            ContentView()
                .environmentObject(model)
                .onAppear { delegate.model = model }
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Stopping a DMX send sends sACN's stream-terminated packets.
        model?.stopAll()
        Thread.sleep(forTimeInterval: 0.3)
    }
}
