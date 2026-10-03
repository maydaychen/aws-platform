import XCTest
@testable import AWSPlatform

@MainActor
final class ProfileViewModelTests: XCTestCase {
    func testStartupRestoresOnlySessionAndIgnoresSavedProfileAndRegion() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("production", forKey: "selectedProfileID")
        defaults.set("eu-west-1", forKey: "selectedRegion")
        defaults.set("company", forKey: "selectedSSOSessionID")
        let vm = ProfileViewModel(defaults: defaults)
        vm.loadProfiles([
            profile("default"), profile("production", region: "ap-northeast-1", session: "company")
        ], sessions: [AWSSOSession(name: "company")])

        XCTAssertEqual(vm.profileSource, .session("company"))
        XCTAssertEqual(vm.availableProfiles.map(\.name), ["production"])
        XCTAssertNil(vm.selectedProfileID)
        XCTAssertNil(vm.selectedProfile)
        XCTAssertEqual(vm.selectedRegion, "us-east-1")
        XCTAssertEqual(vm.profileStatus, .idle)
        XCTAssertFalse(vm.isProfileReady)
    }

    func testStartupDoesNotAutoSelectOnlySessionOrProfile() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = ProfileViewModel(defaults: defaults)
        vm.loadProfiles([profile("work", session: "company")], sessions: [AWSSOSession(name: "company")])

        XCTAssertNil(vm.profileSource)
        XCTAssertNil(vm.selectedSession)
        XCTAssertNil(vm.selectedProfileID)
        XCTAssertTrue(vm.availableProfiles.isEmpty)
    }

    func testProfilePickerFiltersBySessionAndOtherProfiles() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = AWSProfile(name: "legacy", region: "us-east-1",
                                ssoStartURL: "https://example.invalid/start", ssoRegion: "us-east-1",
                                ssoAccountID: "111122223333", ssoRoleName: "ReadOnlyAccess")
        let vm = ProfileViewModel(defaults: defaults)
        vm.loadProfiles([
            profile("work", session: "company"), profile("personal", session: "personal"),
            profile("static"), legacy
        ], sessions: [AWSSOSession(name: "company"), AWSSOSession(name: "personal")])

        vm.selectSource(.session("company"))
        XCTAssertEqual(vm.availableProfiles.map(\.name), ["work"])
        XCTAssertNil(vm.selectedProfileID)
        vm.selectProfile(id: "personal")
        XCTAssertNil(vm.selectedProfileID, "A profile from another session must not be accepted")
        vm.selectProfile(id: "work")
        XCTAssertEqual(vm.selectedProfileID, "work")

        vm.selectSource(.other)
        XCTAssertNil(vm.selectedProfileID)
        XCTAssertNil(vm.selectedSession)
        XCTAssertEqual(vm.availableProfiles.map(\.name), ["static", "legacy"])
        XCTAssertFalse(vm.canSignIn)
        vm.selectProfile(id: "legacy")
        XCTAssertEqual(vm.selectedProfileID, "legacy")

        vm.selectSource(.session("missing"))
        XCTAssertNil(vm.profileSource)
        XCTAssertNil(vm.selectedProfileID)
        XCTAssertTrue(vm.availableProfiles.isEmpty)
    }

    func testSelectingProfileUsesItsRegionButDoesNotRestoreItAfterRestart() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = [profile("work", region: "ap-southeast-2", session: "company")]
        let sessions = [AWSSOSession(name: "company")]
        let vm = ProfileViewModel(defaults: defaults)
        vm.loadProfiles(profiles, sessions: sessions)
        vm.selectSource(.session("company"))
        vm.selectProfile(id: "work")

        XCTAssertEqual(vm.selectedProfileID, "work")
        XCTAssertEqual(vm.selectedRegion, "ap-southeast-2")
        XCTAssertEqual(defaults.string(forKey: "selectedSSOSessionID"), "company")
        let restarted = ProfileViewModel(defaults: defaults)
        restarted.loadProfiles(profiles, sessions: sessions)
        XCTAssertEqual(restarted.selectedSession?.name, "company")
        XCTAssertNil(restarted.selectedProfileID)
        XCTAssertFalse(restarted.isProfileReady)
    }

    func testEmptyProfileSelectionNeverCallsValidatorAndClearsReadiness() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls = 0
        let vm = ProfileViewModel(defaults: defaults, profileValidator: { profile, _ in
            calls += 1
            return self.identity(profile.name)
        })
        vm.loadProfiles([profile("work")], sessions: [])
        vm.selectSource(.other)
        let emptyResult = await vm.configureProvider()
        XCTAssertFalse(emptyResult)
        XCTAssertEqual(calls, 0)
        vm.selectProfile(id: "work")
        let selectedResult = await vm.configureProvider()
        XCTAssertTrue(selectedResult)
        XCTAssertTrue(vm.isProfileReady)

        vm.selectProfile(id: nil)
        XCTAssertNil(vm.selectedProfileID)
        XCTAssertEqual(vm.profileStatus, .idle)
        XCTAssertFalse(vm.isProfileReady)
        vm.beginConfiguration()
        XCTAssertFalse(vm.isValidatingProfile)
        let clearedResult = await vm.configureProvider()
        XCTAssertFalse(clearedResult)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(vm.profileStatus, .idle)
    }

    func testRetryAfterFailedValidationValidatesSameExplicitProfileAgain() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls = 0
        let expected = identity("work")
        let vm = ProfileViewModel(defaults: defaults, profileValidator: { _, _ in
            calls += 1
            if calls == 1 { throw AWSServiceError.notConfigured }
            return expected
        })
        vm.loadProfiles([profile("work")], sessions: [])
        vm.selectSource(.other)
        vm.selectProfile(id: "work")
        let first = await vm.configureProvider()
        XCTAssertFalse(first)
        XCTAssertFalse(vm.isProfileReady)
        vm.beginConfiguration()
        XCTAssertTrue(vm.isValidatingProfile)
        let second = await vm.configureProvider(forceRefresh: true)
        XCTAssertTrue(second)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(vm.profileStatus, .valid(expected))
        XCTAssertFalse(vm.isValidatingProfile)
    }

    func testUnknownRegionRemainsAvailableAndCustomInputIsValidated() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = ProfileViewModel(defaults: defaults)
        vm.loadProfiles([profile("work", region: "ap-future-1")], sessions: [])
        vm.selectSource(.other)
        vm.selectProfile(id: "work")
        XCTAssertEqual(vm.selectedRegion, "ap-future-1")
        XCTAssertTrue(vm.availableRegions.contains("ap-future-1"))
        XCTAssertTrue(vm.availableRegions.contains("cn-north-1"))
        XCTAssertTrue(vm.availableRegions.contains("eu-central-2"))
        XCTAssertTrue(vm.selectCustomRegion("  EU-FUTURE-2  "))
        XCTAssertTrue(vm.availableRegions.contains("eu-future-2"))
        for invalid in ["", "   ", "https://example.com", "us-east", "a b-1"] {
            XCTAssertFalse(vm.selectCustomRegion(invalid))
        }
        XCTAssertEqual(vm.selectedRegion, "eu-future-2")
    }

    func testStaleValidationCannotOverwriteNewSessionProfile() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var continuation: CheckedContinuation<Void, Never>?
        let vm = ProfileViewModel(defaults: defaults, profileValidator: { profile, _ in
            if profile.name == "first" {
                await withCheckedContinuation { continuation = $0 }
            }
            return self.identity(profile.name)
        })
        vm.loadProfiles([
            profile("first", session: "first-session"), profile("second", session: "second-session")
        ], sessions: [AWSSOSession(name: "first-session"), AWSSOSession(name: "second-session")])
        vm.selectSource(.session("first-session"))
        vm.selectProfile(id: "first")
        let firstValidation = Task { await vm.configureProvider() }
        while continuation == nil { await Task.yield() }
        vm.selectSource(.session("second-session"))
        XCTAssertNil(vm.selectedProfileID)
        XCTAssertFalse(vm.isProfileReady)
        vm.selectProfile(id: "second")
        let secondResult = await vm.configureProvider()
        continuation?.resume()
        let firstResult = await firstValidation.value

        XCTAssertTrue(secondResult)
        XCTAssertFalse(firstResult)
        XCTAssertEqual(vm.profileStatus, .valid(identity("second")))
        XCTAssertFalse(vm.isValidatingProfile)
    }

    func testLateValidationSuccessOrFailureCannotRestoreClearedSelection() async throws {
        for shouldFail in [false, true] {
            let (defaults, suite) = try makeDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            var continuation: CheckedContinuation<Void, Never>?
            let vm = ProfileViewModel(defaults: defaults, profileValidator: { profile, _ in
                await withCheckedContinuation { continuation = $0 }
                if shouldFail { throw AWSServiceError.notConfigured }
                return self.identity(profile.name)
            })
            vm.loadProfiles([profile("work")], sessions: [])
            vm.selectSource(.other)
            vm.selectProfile(id: "work")
            let validation = Task { await vm.configureProvider() }
            while continuation == nil { await Task.yield() }
            vm.selectProfile(id: nil)
            continuation?.resume()
            let result = await validation.value

            XCTAssertFalse(result)
            XCTAssertNil(vm.selectedProfileID)
            XCTAssertEqual(vm.profileStatus, .idle)
            XCTAssertFalse(vm.isProfileReady)
            XCTAssertFalse(vm.isValidatingProfile)
        }
    }

    func testReloadDoesNotReselectProfileAfterExplicitClearing() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = [profile("work", session: "company")]
        let sessions = [AWSSOSession(name: "company")]
        let vm = ProfileViewModel(defaults: defaults)
        vm.loadProfiles(profiles, sessions: sessions)
        vm.selectSource(.session("company"))
        vm.selectProfile(id: "work")
        vm.selectProfile(id: nil)
        vm.loadProfiles(profiles, sessions: sessions)

        XCTAssertEqual(vm.selectedSession?.name, "company")
        XCTAssertNil(vm.selectedProfileID)
        XCTAssertFalse(vm.isProfileReady)
    }

    func testReloadMissingProfileClearsSelectionWithoutSelectingReplacement() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = ProfileViewModel(defaults: defaults, profileValidator: { profile, _ in self.identity(profile.name) })
        let sessions = [AWSSOSession(name: "company")]
        vm.loadProfiles([profile("work", session: "company")], sessions: sessions)
        vm.selectSource(.session("company"))
        vm.selectProfile(id: "work")
        _ = await vm.configureProvider()
        vm.loadProfiles([profile("replacement", session: "company")], sessions: sessions)

        XCTAssertEqual(vm.availableProfiles.map(\.name), ["replacement"])
        XCTAssertNil(vm.selectedProfileID)
        XCTAssertEqual(vm.profileStatus, .idle)
        XCTAssertFalse(vm.isProfileReady)
    }

    func testReloadMissingSessionClearsSessionAndProfile() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = ProfileViewModel(defaults: defaults, profileValidator: { profile, _ in self.identity(profile.name) })
        let profiles = [profile("work", session: "company")]
        vm.loadProfiles(profiles, sessions: [AWSSOSession(name: "company")])
        vm.selectSource(.session("company"))
        vm.selectProfile(id: "work")
        _ = await vm.configureProvider()
        vm.loadProfiles(profiles, sessions: [])

        XCTAssertNil(vm.profileSource)
        XCTAssertNil(vm.selectedSession)
        XCTAssertNil(vm.selectedProfileID)
        XCTAssertEqual(vm.profileStatus, .idle)
        XCTAssertFalse(vm.isProfileReady)
        XCTAssertNil(defaults.string(forKey: "selectedSSOSessionID"))
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "ProfileViewModelTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    private func profile(_ name: String, region: String = "us-east-1", session: String? = nil) -> AWSProfile {
        AWSProfile(name: name, region: region, ssoStartURL: nil, ssoRegion: nil,
                   ssoAccountID: nil, ssoRoleName: nil, ssoSessionName: session)
    }

    private func identity(_ name: String) -> AWSIdentity {
        AWSIdentity(account: name, arn: "arn:aws:iam::\(name):user/test", userID: name)
    }
}
