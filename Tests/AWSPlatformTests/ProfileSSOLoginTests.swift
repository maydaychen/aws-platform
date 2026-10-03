import SotoCore
import XCTest
@testable import AWSPlatform

@MainActor
final class ProfileSSOLoginTests: XCTestCase {
    func testSuccessfulLoginIsFollowedByIdentityValidation() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var authorized = false
        var validations = 0
        let identity = AWSIdentity(account: "example", arn: "example", userID: "example")
        let vm = ProfileViewModel(defaults: defaults, profileValidator: { _, _ in
            validations += 1
            guard authorized else { throw AWSSSOCredentialError.tokenCacheNotFound("work") }
            return identity
        }, ssoLogin: { profile, _ in
            XCTAssertEqual(profile, "work")
            authorized = true
        })
        vm.loadProfiles([profile("work")])
        let firstValidation = await vm.configureProvider()
        XCTAssertFalse(firstValidation)
        XCTAssertTrue(vm.requiresSSOLogin)
        let loginSucceeded = await vm.signIn()
        XCTAssertTrue(loginSucceeded)
        XCTAssertFalse(vm.isProfileReady, "CLI success alone must not mark AWS identity valid")
        vm.beginConfiguration()
        let reconnected = await vm.configureProvider(forceRefresh: true)
        XCTAssertTrue(reconnected)
        XCTAssertEqual(validations, 2)
        XCTAssertEqual(vm.profileStatus, .valid(identity))
        XCTAssertFalse(vm.requiresSSOLogin)
        XCTAssertFalse(vm.canSignIn)
    }

    func testRepeatedClickDoesNotStartAnotherLogin() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var continuation: CheckedContinuation<Void, Never>?
        var calls = 0
        let vm = ProfileViewModel(defaults: defaults, ssoLogin: { _, _ in
            calls += 1
            await withCheckedContinuation { continuation = $0 }
        })
        vm.loadProfiles([profile("work")])
        let first = Task { await vm.signIn() }
        while continuation == nil { await Task.yield() }
        XCTAssertTrue(vm.isSigningIn)
        let duplicate = await vm.signIn()
        XCTAssertFalse(duplicate)
        XCTAssertEqual(calls, 1)
        continuation?.resume()
        let result = await first.value
        XCTAssertTrue(result)
        XCTAssertFalse(vm.isSigningIn)
    }

    func testCancellationAllowsRetryWithoutReportingSuccess() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = ProfileViewModel(defaults: defaults, ssoLogin: { _, _ in
            try await Task.sleep(for: .seconds(30))
        })
        vm.loadProfiles([profile("work")])
        let task = Task { await vm.signIn() }
        while !vm.isSigningIn { await Task.yield() }
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertFalse(vm.isSigningIn)
        XCTAssertTrue(vm.canSignIn)
        XCTAssertTrue(vm.loginMessage?.contains("cancelled") == true)
    }

    func testLateLoginResultsCannotAffectNewProfile() async throws {
        for shouldFail in [false, true] {
            let (defaults, suite) = try makeDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            var continuation: CheckedContinuation<Void, Never>?
            let vm = ProfileViewModel(defaults: defaults, profileValidator: { profile, _ in
                AWSIdentity(account: profile.name, arn: "example", userID: "example")
            }, ssoLogin: { _, _ in
                await withCheckedContinuation { continuation = $0 }
                if shouldFail { throw AWSSSOLoginService.LoginError.failed }
            })
            vm.loadProfiles([profile("first"), profile("second")])
            let task = Task { await vm.signIn() }
            while continuation == nil { await Task.yield() }
            vm.selectProfile(id: "second")
            vm.beginConfiguration()
            let reconnected = await vm.configureProvider()
            XCTAssertTrue(reconnected)
            continuation?.resume()
            let result = await task.value
            XCTAssertFalse(result)
            XCTAssertNil(vm.loginMessage)
            XCTAssertEqual(vm.profileStatus, .valid(AWSIdentity(account: "second", arn: "example", userID: "example")))
        }
    }

    func testLateLoginCannotReconnectAfterRegionChange() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var continuation: CheckedContinuation<Void, Never>?
        let vm = ProfileViewModel(defaults: defaults, ssoLogin: { _, _ in
            await withCheckedContinuation { continuation = $0 }
        })
        vm.loadProfiles([profile("work")])
        let task = Task { await vm.signIn() }
        while continuation == nil { await Task.yield() }
        vm.selectedRegion = "eu-west-1"
        vm.beginConfiguration()
        continuation?.resume()
        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertEqual(vm.profileStatus, .checking)
    }

    func testNonSSOProfileCannotLaunchLogin() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = ProfileViewModel(defaults: defaults, ssoLogin: { _, _ in XCTFail("Must not launch") })
        vm.loadProfiles(ConfigReader.readProfiles(configContent: "[profile static]\nregion=us-east-1"))
        XCTAssertFalse(vm.canSignIn)
        let result = await vm.signIn()
        XCTAssertFalse(result)
    }

    func testLoginFailureIsSanitizedAndRetryable() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = ProfileViewModel(defaults: defaults, ssoLogin: { _, _ in
            throw NSError(domain: "private-token-output", code: 1)
        })
        vm.loadProfiles([profile("work")])
        let result = await vm.signIn()
        XCTAssertFalse(result)
        XCTAssertTrue(vm.canSignIn)
        XCTAssertFalse(vm.isProfileReady)
        XCTAssertFalse(vm.loginMessage?.contains("private-token-output") == true)
        XCTAssertNotNil(vm.loginMessage)
    }

    func testNetworkPermissionAndConfigurationFailuresAreNotLabeledLoginRequired() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let errors: [Error] = [
            URLError(.notConnectedToInternet),
            AWSSSOCredentialError.getRoleCredentialsFailed("HTTP 403: Failed to get SSO credentials"),
            AWSSSOCredentialError.ssoSessionNotFound("company"),
            AWSSSOCredentialError.tokenRefreshFailed("network unavailable")
        ]
        for error in errors {
            let vm = ProfileViewModel(defaults: defaults, profileValidator: { _, _ in throw error })
            vm.loadProfiles([profile("work")])
            let result = await vm.configureProvider()
            XCTAssertFalse(result)
            XCTAssertFalse(vm.requiresSSOLogin)
            guard case .failed(let message) = vm.profileStatus else { return XCTFail("Expected failed state") }
            XCTAssertFalse(message.contains("not logged in"))
            XCTAssertFalse(message.contains("login required"))
        }
        for error in [AWSSSOCredentialError.tokenCacheNotFound("work"), .tokenExpired("work"),
                      .clientRegistrationExpired("work"), .getRoleCredentialsFailed("HTTP 401: unauthorized")] {
            XCTAssertTrue(UserFacingError.requiresSSOLogin(error))
        }
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "ProfileSSOLoginTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    private func profile(_ name: String) -> AWSProfile {
        AWSProfile(name: name, region: "us-east-1", ssoStartURL: nil,
                   ssoRegion: nil, ssoAccountID: "111122223333", ssoRoleName: "ReadOnlyAccess")
    }
}
