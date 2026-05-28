import Foundation

@MainActor
final class ProfileViewModel: ObservableObject {
    @Published var profiles: [AWSProfile] = []
    @Published var selectedProfileID: AWSProfile.ID?
    @Published var selectedRegion = "us-east-1"

    let provider = AWSServiceProvider()

    let availableRegions = [
        "us-east-1", "us-east-2", "us-west-1", "us-west-2",
        "ap-south-1", "ap-northeast-1", "ap-northeast-2",
        "ap-southeast-1", "ap-southeast-2",
        "eu-central-1", "eu-west-1", "eu-west-2", "eu-west-3",
        "ca-central-1", "sa-east-1"
    ]

    var selectedProfile: AWSProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    func loadProfiles() {
        profiles = ConfigReader.readProfiles()
        if let profile = selectedProfile ?? profiles.first {
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
    }

    func configureProvider() async {
        await provider.configure(profile: selectedProfile, region: selectedRegion)
    }
}
