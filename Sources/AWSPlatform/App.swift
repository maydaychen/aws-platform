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
        WindowGroup(id: MainWindowLifecycle.sceneID) {
            ContentView()
                .modifier(MainWindowLifecycle(appDelegate: appDelegate))
                .environmentObject(favoritesVM)
                .environmentObject(recentsVM)
                .environment(\.locale, languageSettings.locale)
                .frame(minWidth: WorkspaceLayout.minimumWindowWidth, minHeight: 600)
                .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                    languageSettings.refreshSystemLanguages()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    languageSettings.refreshSystemLanguages()
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            MainWindowCommands(locale: languageSettings.locale)
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
    var reopenMainWindow: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, let reopenMainWindow else { return true }
        reopenMainWindow()
        return false
    }

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

private struct MainWindowLifecycle: ViewModifier {
    static let sceneID = "main"
    @Environment(\.openWindow) private var openWindow
    let appDelegate: AppDelegate

    func body(content: Content) -> some View {
        content.onAppear {
            let action = openWindow
            // Keep the scene action available after the last window's view disappears.
            appDelegate.reopenMainWindow = { action(id: Self.sceneID) }
        }
    }
}

private struct MainWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let locale: Locale

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L10n.text("New Window", locale: locale)) {
                openWindow(id: MainWindowLifecycle.sceneID)
            }
            .keyboardShortcut("n")
        }
    }
}
