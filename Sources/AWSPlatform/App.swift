import SwiftUI

@main
struct AWSPlatformApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
    }
}
