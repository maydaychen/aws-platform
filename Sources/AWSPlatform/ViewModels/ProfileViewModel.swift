import Foundation

@MainActor
final class ProfileViewModel: ObservableObject {
    typealias ProfileValidator = (AWSProfile, String) async throws -> AWSIdentity

    @Published var profiles: [AWSProfile] = []
    @Published var selectedProfileID: AWSProfile.ID?
    @Published var selectedRegion = "us-east-1"
    @Published var isValidatingProfile = false
    @Published var profileStatus: ProfileStatus = .idle

    private let savedProfileKey = "selectedProfileID"
    private let savedRegionKey = "selectedRegion"
    private let defaults: UserDefaults
    private let profileValidator: ProfileValidator?
    private var configurationGeneration = 0

    let provider = AWSServiceProvider()

    let availableRegions = [
        "us-east-1", "us-east-2", "us-west-1", "us-west-2",
        "ap-south-1", "ap-northeast-1", "ap-northeast-2",
        "ap-southeast-1", "ap-southeast-2",
        "eu-central-1", "eu-west-1", "eu-west-2", "eu-west-3",
        "ca-central-1", "sa-east-1"
    ]

    init(
        defaults: UserDefaults = .standard,
        profileValidator: ProfileValidator? = nil
    ) {
        self.defaults = defaults
        self.profileValidator = profileValidator
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
        configurationGeneration += 1
        let generation = configurationGeneration
        let profile = selectedProfile
        let region = selectedRegion

        saveSelection()
        isValidatingProfile = true
        profileStatus = .checking
        defer {
            if generation == configurationGeneration {
                isValidatingProfile = false
            }
        }

        guard let profile else {
            await provider.configure(profile: nil, region: region)
            guard generation == configurationGeneration else { return false }
            profileStatus = .failed("No AWS profile found. Configure `~/.aws/config` first.")
            return false
        }

        do {
            try Task.checkCancellation()
            let identity: AWSIdentity
            if let profileValidator {
                identity = try await profileValidator(profile, region)
            } else {
                await provider.configure(profile: profile, region: region)
                try Task.checkCancellation()
                identity = try await provider.validateIdentity()
            }
            try Task.checkCancellation()
            guard generation == configurationGeneration else { return false }
            profileStatus = .valid(identity)
            return true
        } catch is CancellationError {
            if generation == configurationGeneration {
                profileStatus = .idle
            }
            return false
        } catch {
            guard generation == configurationGeneration else { return false }
            profileStatus = .failed(UserFacingError.loginMessage(for: error, profileName: profile.name))
            return false
        }
    }

    func shutdown() async {
        configurationGeneration += 1
        isValidatingProfile = false
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
