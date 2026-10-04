import AppKit
import SwiftUI

@main
struct AWSPlatformApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var favoritesVM = FavoritesViewModel()
    @StateObject private var recentsVM = RecentResourcesViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(favoritesVM)
                .environmentObject(recentsVM)
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
