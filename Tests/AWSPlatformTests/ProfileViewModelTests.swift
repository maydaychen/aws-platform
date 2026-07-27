import XCTest
@testable import AWSPlatform

final class ProfileViewModelTests: XCTestCase {
    func testLoadProfilesRestoresSavedSelection() async {
        await MainActor.run {
            let suiteName = "ProfileViewModelTests.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                XCTFail("Unable to create isolated user defaults")
                return
            }
            defer { defaults.removePersistentDomain(forName: suiteName) }

            defaults.set("production", forKey: "selectedProfileID")
            defaults.set("eu-west-1", forKey: "selectedRegion")

            let vm = ProfileViewModel(defaults: defaults)
            vm.loadProfiles([
                makeProfile(name: "default", region: "us-east-1"),
                makeProfile(name: "production", region: "ap-northeast-1")
            ])

            XCTAssertEqual(vm.selectedProfileID, "production")
            XCTAssertEqual(vm.selectedRegion, "eu-west-1")
        }
    }

    func testSelectProfileUsesProfileRegionAndPersistsSelection() async {
        await MainActor.run {
            let suiteName = "ProfileViewModelTests.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                XCTFail("Unable to create isolated user defaults")
                return
            }
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let vm = ProfileViewModel(defaults: defaults)
            vm.loadProfiles([
                makeProfile(name: "default", region: "us-east-1"),
                makeProfile(name: "staging", region: "ap-southeast-2")
            ])

            vm.selectProfile(id: "staging")

            XCTAssertEqual(vm.selectedProfileID, "staging")
            XCTAssertEqual(vm.selectedRegion, "ap-southeast-2")
            XCTAssertEqual(defaults.string(forKey: "selectedProfileID"), "staging")
            XCTAssertEqual(defaults.string(forKey: "selectedRegion"), "ap-southeast-2")
        }
    }

    private func makeProfile(name: String, region: String) -> AWSProfile {
        AWSProfile(
            name: name,
            region: region,
            ssoStartURL: nil,
            ssoRegion: nil,
            ssoAccountID: nil,
            ssoRoleName: nil
        )
    }
}
