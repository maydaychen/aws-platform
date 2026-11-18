import Combine
import Foundation

/// Provides the packaged application version and public release destination without an in-app updater.
@MainActor
final class AppUpdateController: ObservableObject {
    static let shared = AppUpdateController()
    static let releasesURL = URL(string: "https://github.com/maydaychen/aws-platform/releases")!

    let transfers: TransferActivity
    private var observations = Set<AnyCancellable>()

    init(transfers: TransferActivity? = nil) {
        self.transfers = transfers ?? .shared
        self.transfers.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &observations)
    }

    var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "Development") (\(info["CFBundleVersion"] as? String ?? "0"))"
    }
}
