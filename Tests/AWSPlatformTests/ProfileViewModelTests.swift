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
                Self.makeProfile(name: "default", region: "us-east-1"),
                Self.makeProfile(name: "production", region: "ap-northeast-1")
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
                Self.makeProfile(name: "default", region: "us-east-1"),
                Self.makeProfile(name: "staging", region: "ap-southeast-2")
            ])

            vm.selectProfile(id: "staging")

            XCTAssertEqual(vm.selectedProfileID, "staging")
            XCTAssertEqual(vm.selectedRegion, "ap-southeast-2")
            XCTAssertEqual(defaults.string(forKey: "selectedProfileID"), "staging")
            XCTAssertEqual(defaults.string(forKey: "selectedRegion"), "ap-southeast-2")
        }
    }

    func testStaleValidationCannotOverwriteLatestProfileStatus() async {
        let suiteName = "ProfileViewModelTests.\(UUID().uuidString)"
        let viewModel: ProfileViewModel? = await MainActor.run {
            guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
            return ProfileViewModel(
                defaults: defaults,
                profileValidator: { profile, _ in
                    if profile.name == "first" {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    return AWSIdentity(
                        account: profile.name,
                        arn: "arn:aws:iam::\(profile.name):user/test",
                        userID: profile.name
                    )
                }
            )
        }
        guard let vm = viewModel else {
            XCTFail("Unable to create isolated user defaults")
            return
        }
        await MainActor.run {
            vm.loadProfiles([
                Self.makeProfile(name: "first", region: "us-east-1"),
                Self.makeProfile(name: "second", region: "eu-west-1")
            ])
        }

        let firstValidation = Task { await vm.configureProvider() }
        try? await Task.sleep(nanoseconds: 10_000_000)
        await MainActor.run { vm.selectProfile(id: "second") }
        let secondValidation = Task { await vm.configureProvider() }

        let secondResult = await secondValidation.value
        let firstResult = await firstValidation.value

        await MainActor.run {
            XCTAssertTrue(secondResult)
            XCTAssertFalse(firstResult)
            XCTAssertEqual(
                vm.profileStatus,
                .valid(
                    AWSIdentity(
                        account: "second",
                        arn: "arn:aws:iam::second:user/test",
                        userID: "second"
                    )
                )
            )
            XCTAssertFalse(vm.isValidatingProfile)
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
    }

    private nonisolated static func makeProfile(name: String, region: String) -> AWSProfile {
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
