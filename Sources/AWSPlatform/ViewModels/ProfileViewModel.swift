import Foundation
import SotoCore

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

    private static let knownRegions: [Region] = [
        .afsouth1, .apeast1, .apeast2, .apnortheast1, .apnortheast2, .apnortheast3,
        .apsouth1, .apsouth2, .apsoutheast1, .apsoutheast2, .apsoutheast3,
        .apsoutheast4, .apsoutheast5, .apsoutheast6, .apsoutheast7,
        .cacentral1, .cawest1, .cnnorth1, .cnnorthwest1, .eucentral1, .eucentral2,
        .eunorth1, .eusouth1, .eusouth2, .euwest1, .euwest2, .euwest3,
        .euscdeeast1, .ilcentral1, .mecentral1, .mesouth1, .mxcentral1, .saeast1,
        .useast1, .useast2, .uswest1, .uswest2, .usgoveast1, .usgovwest1
    ]

    var availableRegions: [String] {
        Set(Self.knownRegions.map(\.rawValue) + profiles.map(\.region) + [selectedRegion])
            .filter { !$0.isEmpty }.sorted()
    }

    var isProfileReady: Bool {
        if case .valid = profileStatus { return true }
        return false
    }

    @discardableResult
    func selectCustomRegion(_ input: String) -> Bool {
        let region = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard region.range(of: "^[a-z]{2}(?:-[a-z0-9]+)+-[0-9]+$", options: .regularExpression) != nil else {
            return false
        }
        selectedRegion = region
        saveSelection()
        return true
    }

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

    func beginConfiguration() {
        configurationGeneration += 1
        isValidatingProfile = true
        profileStatus = .checking
    }

    func configureProvider(forceRefresh: Bool = false) async -> Bool {
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
            profileStatus = .failed("No AWS profile found. Configure an AWS config or credentials file, then retry.")
            return false
        }

        do {
            try Task.checkCancellation()
            let identity: AWSIdentity
            if let profileValidator {
                identity = try await profileValidator(profile, region)
            } else {
                await provider.configure(profile: profile, region: region, forceRefresh: forceRefresh)
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
