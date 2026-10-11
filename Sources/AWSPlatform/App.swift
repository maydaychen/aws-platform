import AppKit
import SwiftUI

@main
struct AWSPlatformApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var favoritesVM = FavoritesViewModel()
    @StateObject private var recentsVM = RecentResourcesViewModel()
    @StateObject private var languageSettings = LanguageSettings()
    @StateObject private var updates = AppUpdateController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(favoritesVM)
                .environmentObject(recentsVM)
                .environment(\.locale, languageSettings.locale)
                .frame(minWidth: 960, minHeight: 600)
                .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                    languageSettings.refreshSystemLanguages()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    languageSettings.refreshSystemLanguages()
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L10n.text("Check for Updates…", locale: languageSettings.locale)) {
                    updates.checkForUpdates()
                }
                .disabled(!updates.canCheckForUpdates)
            }
        }

        Settings {
            SettingsView(settings: languageSettings, updates: updates, transfers: updates.transfers)
                .environment(\.locale, languageSettings.locale)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppUpdateController.shared.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        TransferActivity.shared.postponeTermination {
            sender.reply(toApplicationShouldTerminate: true)
        } ? .terminateLater : .terminateNow
    }
}
