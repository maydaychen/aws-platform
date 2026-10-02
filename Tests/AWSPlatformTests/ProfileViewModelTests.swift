import XCTest
@testable import AWSPlatform

final class ProfileViewModelTests: XCTestCase {
    @MainActor
    func testRetryAfterFailedLoginValidatesSameProfileAgain() async throws {
        let suite = "ProfileViewModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls = 0
        let identity = AWSIdentity(account: "test", arn: "test", userID: "test")
        let vm = ProfileViewModel(defaults: defaults, profileValidator: { _, _ in
            calls += 1
            if calls == 1 { throw AWSServiceError.notConfigured }
            return identity
        })
        vm.loadProfiles([Self.makeProfile(name: "work", region: "us-east-1")])
        let first = await vm.configureProvider()
        XCTAssertFalse(first)
        XCTAssertFalse(vm.isProfileReady)
        vm.beginConfiguration()
        XCTAssertTrue(vm.isValidatingProfile)
        let second = await vm.configureProvider(forceRefresh: true)
        XCTAssertTrue(second)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(vm.profileStatus, .valid(identity))
        XCTAssertFalse(vm.isValidatingProfile)
    }

    @MainActor
    func testRegionOutsideBuiltInListIsRestoredAndCustomInputIsValidated() throws {
        let suite = "ProfileViewModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = ProfileViewModel(defaults: defaults)
        let profiles = [Self.makeProfile(name: "work", region: "ap-future-1")]
        vm.loadProfiles(profiles)
        XCTAssertTrue(vm.availableRegions.contains("ap-future-1"))
        XCTAssertTrue(vm.availableRegions.contains("cn-north-1"))
        XCTAssertTrue(vm.availableRegions.contains("eu-central-2"))
        XCTAssertTrue(vm.selectCustomRegion("  EU-FUTURE-2  "))
        XCTAssertTrue(vm.availableRegions.contains("eu-future-2"))
        for invalid in ["", "   ", "https://example.com", "us-east", "a b-1"] {
            XCTAssertFalse(vm.selectCustomRegion(invalid))
        }
        XCTAssertEqual(vm.selectedRegion, "eu-future-2")
        let restored = ProfileViewModel(defaults: defaults)
        restored.loadProfiles(profiles)
        XCTAssertEqual(restored.selectedRegion, "eu-future-2")
        XCTAssertTrue(restored.availableRegions.contains("eu-future-2"))
    }

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
