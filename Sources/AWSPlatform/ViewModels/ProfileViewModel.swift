import Foundation

@MainActor
final class ProfileViewModel: ObservableObject {
    @Published var profiles: [AWSProfile] = []
    @Published var selectedProfileID: AWSProfile.ID?
    @Published var selectedRegion = "us-east-1"
    @Published var isValidatingProfile = false
    @Published var profileStatus: ProfileStatus = .idle

    private let savedProfileKey = "selectedProfileID"
    private let savedRegionKey = "selectedRegion"
    private let defaults: UserDefaults

    let provider = AWSServiceProvider()

    let availableRegions = [
        "us-east-1", "us-east-2", "us-west-1", "us-west-2",
        "ap-south-1", "ap-northeast-1", "ap-northeast-2",
        "ap-southeast-1", "ap-southeast-2",
        "eu-central-1", "eu-west-1", "eu-west-2", "eu-west-3",
        "ca-central-1", "sa-east-1"
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedProfile: AWSProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    func loadProfiles(_ profiles: [AWSProfile]? = nil) {
        self.profiles = profiles ?? ConfigReader.readProfiles()
        let savedProfileID = defaults.string(forKey: savedProfileKey)
        let savedRegion = defaults.string(forKey: savedRegionKey)

        if let savedProfileID, let profile = self.profiles.first(where: { $0.id == savedProfileID }) {
            selectedProfileID = profile.id
            selectedRegion = savedRegion ?? profile.region
        } else if let profile = selectedProfile ?? self.profiles.first {
            selectedProfileID = profile.id
            selectedRegion = profile.region
        } else {
            selectedProfileID = nil
            selectedRegion = "us-east-1"
        }
    }

    func selectProfile(id: AWSProfile.ID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        selectedProfileID = id
        selectedRegion = profile.region
        saveSelection()
    }

    func configureProvider() async -> Bool {
        saveSelection()
        isValidatingProfile = true
        profileStatus = .checking
        defer { isValidatingProfile = false }

        await provider.configure(profile: selectedProfile, region: selectedRegion)
        guard selectedProfile != nil else {
            profileStatus = .failed("No AWS profile found. Configure `~/.aws/config` first.")
            return false
        }

        do {
            try Task.checkCancellation()
            let identity = try await provider.validateIdentity()
            try Task.checkCancellation()
            profileStatus = .valid(identity)
            return true
        } catch is CancellationError {
            profileStatus = .idle
            return false
        } catch {
            let profileName = selectedProfile?.name ?? "default"
            profileStatus = .failed(UserFacingError.loginMessage(for: error, profileName: profileName))
            return false
        }
    }

    func shutdown() async {
        await provider.shutdown()
    }

    private func saveSelection() {
        defaults.set(selectedProfileID, forKey: savedProfileKey)
        defaults.set(selectedRegion, forKey: savedRegionKey)
    }
}

enum ProfileStatus: Hashable {
    case idle
    case checking
    case valid(AWSIdentity)
    case failed(String)
}
