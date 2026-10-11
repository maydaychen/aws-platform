import AppKit
import Combine
import Sparkle

enum UpdateArchitecture: String, CaseIterable {
    case arm64, x86_64

    static var current: Self {
        #if arch(arm64)
        return .arm64
        #else
        return .x86_64
        #endif
    }

    var feedURL: URL {
        URL(string: "https://raw.githubusercontent.com/maydaychen/aws-platform/main/updates/appcast-\(rawValue).xml")!
    }
}

@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdateController()

    @Published private var isReady = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var unavailable = false
    let transfers: TransferActivity
    private var controller: SPUStandardUpdaterController?
    private var observations = Set<AnyCancellable>()

    init(transfers: TransferActivity? = nil) {
        self.transfers = transfers ?? .shared
        super.init()
        self.transfers.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &observations)
    }

    var canCheckForUpdates: Bool { isReady && !transfers.isRestartPending }

    var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "Development") (\(info["CFBundleVersion"] as? String ?? "0"))"
    }

    func start() {
        guard controller == nil else { return }
        // SwiftPM's unbundled executable has no updater identity or trusted key.
        guard Bundle.main.bundleIdentifier == "AWSPlatform",
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            unavailable = true
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        do {
            try controller.updater.start()
            controller.updater.publisher(for: \.canCheckForUpdates)
                .sink { [weak self] in self?.isReady = $0 }
                .store(in: &observations)
            controller.updater.publisher(for: \.automaticallyChecksForUpdates)
                .sink { [weak self] in self?.automaticallyChecks = $0 }
                .store(in: &observations)
        } catch {
            unavailable = true
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        guard !unavailable else { return }
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        UpdateArchitecture.current.feedURL.absoluteString
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        transfers.postponeUpdate(installHandler)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        transfers.cancelUpdate()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        transfers.markUpdateInstallation()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        transfers.finishUpdateCycle(hasError: error != nil)
    }
}
