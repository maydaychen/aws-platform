import SotoCore
import XCTest
@testable import AWSPlatform

@MainActor
final class ProfileSSOLoginTests: XCTestCase {
    func testSuccessfulSessionLoginLeavesProfileEmptyUntilManualSelection() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var authorized = false
        var validations = 0
        let identity = AWSIdentity(account: "example", arn: "example", userID: "example")
        let vm = ProfileViewModel(defaults: defaults, profileValidator: { _, _ in
            validations += 1
            guard authorized else { throw AWSSSOCredentialError.tokenCacheNotFound("company") }
            return identity
        }, ssoLogin: { session, _ in
            XCTAssertEqual(session, "company")
            authorized = true
        })
        vm.loadProfiles([profile("work")], sessions: [AWSSOSession(name: "company")])
        vm.selectSource(.session("company"))
        vm.selectProfile(id: "work")
        let firstValidation = await vm.configureProvider()
        XCTAssertFalse(firstValidation)
        XCTAssertTrue(vm.requiresSSOLogin)

        let loginSucceeded = await vm.signIn()
        XCTAssertTrue(loginSucceeded)
        XCTAssertEqual(vm.signedInSessionID, "company")
        XCTAssertNil(vm.selectedProfileID)
        XCTAssertNil(vm.selectedProfile)
        XCTAssertEqual(vm.profileStatus, .idle)
        XCTAssertFalse(vm.isProfileReady)
        XCTAssertFalse(vm.requiresSSOLogin)
        XCTAssertEqual(validations, 1, "Session login must not validate an account automatically")
        let noProfileResult = await vm.configureProvider()
        XCTAssertFalse(noProfileResult)
        XCTAssertEqual(validations, 1, "An empty profile selection must not call STS")

        vm.selectProfile(id: "work")
        vm.beginConfiguration()
        let reconnected = await vm.configureProvider(forceRefresh: true)
        XCTAssertTrue(reconnected)
        XCTAssertEqual(validations, 2)
        XCTAssertEqual(vm.profileStatus, .valid(identity))
        XCTAssertTrue(vm.isProfileReady)
    }

    func testSessionWithoutAnyProfilesCanLoginWithoutIdentityValidation() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var loginCalls = 0
        let vm = ProfileViewModel(defaults: defaults, profileValidator: { _, _ in
            XCTFail("Session-only login must not choose an account")
            throw AWSServiceError.notConfigured
        }, ssoLogin: { session, _ in
            XCTAssertEqual(session, "standalone")
            loginCalls += 1
        })
        vm.loadProfiles([], sessions: [AWSSOSession(name: "standalone")])
        vm.selectSource(.session("standalone"))

        XCTAssertTrue(vm.canSignIn)
        let result = await vm.signIn()
        XCTAssertTrue(result)
        XCTAssertEqual(loginCalls, 1)
        XCTAssertEqual(vm.signedInSessionID, "standalone")
        XCTAssertNil(vm.selectedProfileID)
        XCTAssertFalse(vm.isProfileReady)
        XCTAssertEqual(vm.profileStatus, .idle)
    }

    func testCachedSessionAllowsExplicitProfileValidationWithoutNewLogin() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = AWSIdentity(account: "example", arn: "example", userID: "example")
        var calls = 0
        let vm = ProfileViewModel(defaults: defaults, profileValidator: { selectedProfile, _ in
            XCTAssertEqual(selectedProfile.name, "work")
            calls += 1
            return identity
        }, ssoLogin: { _, _ in XCTFail("Cached sessions do not require a new login") })
        vm.loadProfiles([profile("work")], sessions: [AWSSOSession(name: "company")])
        vm.selectSource(.session("company"))
        vm.selectProfile(id: "work")
        let result = await vm.configureProvider()

        XCTAssertTrue(result)
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(vm.isProfileReady)
        XCTAssertNil(vm.signedInSessionID, "Identity validation does not imply a new CLI login")
    }

    func testRepeatedLoginIsIgnoredAndProfileCannotBeSelectedWhileSigningIn() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var continuation: CheckedContinuation<Void, Never>?
        var calls = 0
        let vm = ProfileViewModel(defaults: defaults, ssoLogin: { _, _ in
            calls += 1
            await withCheckedContinuation { continuation = $0 }
        })
        vm.loadProfiles([profile("work")], sessions: [AWSSOSession(name: "company")])
        vm.selectSource(.session("company"))
        vm.selectProfile(id: "work")
        let first = Task { await vm.signIn() }
        while continuation == nil { await Task.yield() }
        XCTAssertTrue(vm.isSigningIn)
        XCTAssertNil(vm.selectedProfileID, "Starting login must clear the previous profile")
        vm.selectProfile(id: "work")
        XCTAssertNil(vm.selectedProfileID)
        let duplicate = await vm.signIn()
        XCTAssertFalse(duplicate)
        XCTAssertEqual(calls, 1)
        continuation?.resume()
        let result = await first.value
        XCTAssertTrue(result)
        XCTAssertFalse(vm.isSigningIn)
        XCTAssertNil(vm.selectedProfileID)
    }

    func testCancellationAllowsRetryWithoutReportingSuccess() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = ProfileViewModel(defaults: defaults, ssoLogin: { _, _ in
            try await Task.sleep(for: .seconds(30))
        })
        vm.loadProfiles([profile("work")], sessions: [AWSSOSession(name: "company")])
        vm.selectSource(.session("company"))
        let task = Task { await vm.signIn() }
        while !vm.isSigningIn { await Task.yield() }
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertFalse(vm.isSigningIn)
        XCTAssertTrue(vm.canSignIn)
        XCTAssertNil(vm.selectedProfileID)
        XCTAssertNil(vm.signedInSessionID)
        XCTAssertTrue(vm.loginMessage?.contains("cancelled") == true)
    }

    func testLateLoginSuccessOrFailureCannotAffectNewSession() async throws {
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
            vm.loadProfiles([
                profile("first", session: "first-session"), profile("second", session: "second-session")
            ], sessions: [AWSSOSession(name: "first-session"), AWSSOSession(name: "second-session")])
            vm.selectSource(.session("first-session"))
            let task = Task { await vm.signIn() }
            while continuation == nil { await Task.yield() }
            vm.selectSource(.session("second-session"))
            continuation?.resume()
            let result = await task.value

            XCTAssertFalse(result)
            XCTAssertEqual(vm.selectedSession?.name, "second-session")
            XCTAssertNil(vm.selectedProfileID)
            XCTAssertNil(vm.signedInSessionID)
            XCTAssertNil(vm.loginMessage)
            XCTAssertEqual(vm.profileStatus, .idle)
            XCTAssertTrue(vm.canSignIn)
            vm.selectProfile(id: "second")
            let reconnected = await vm.configureProvider()
            XCTAssertTrue(reconnected)
            XCTAssertEqual(vm.profileStatus, .valid(AWSIdentity(account: "second", arn: "example", userID: "example")))
        }
    }

    func testReloadRemovingSessionDiscardsPendingLoginResult() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var continuation: CheckedContinuation<Void, Never>?
        let vm = ProfileViewModel(defaults: defaults, ssoLogin: { _, _ in
            await withCheckedContinuation { continuation = $0 }
        })
        let profiles = [profile("work")]
        vm.loadProfiles(profiles, sessions: [AWSSOSession(name: "company")])
        vm.selectSource(.session("company"))
        let task = Task { await vm.signIn() }
        while continuation == nil { await Task.yield() }
        vm.loadProfiles(profiles, sessions: [])
        continuation?.resume()
        let result = await task.value

        XCTAssertFalse(result)
        XCTAssertNil(vm.profileSource)
        XCTAssertNil(vm.selectedProfileID)
        XCTAssertNil(vm.signedInSessionID)
        XCTAssertNil(vm.loginMessage)
        XCTAssertEqual(vm.profileStatus, .idle)
        XCTAssertFalse(vm.canSignIn)
    }

    func testOtherProfilesCannotLaunchSessionLogin() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = ProfileViewModel(defaults: defaults, ssoLogin: { _, _ in XCTFail("Must not launch") })
        vm.loadProfiles(ConfigReader.readProfiles(configContent: """
        [profile static]
        region = us-east-1
        [profile legacy]
        sso_start_url = https://example.invalid/start
        sso_region = us-east-1
        sso_account_id = 111122223333
        sso_role_name = ReadOnlyAccess
        """), sessions: [])
        vm.selectSource(.other)
        for name in ["static", "legacy"] {
            vm.selectProfile(id: name)
            XCTAssertFalse(vm.canSignIn)
            let result = await vm.signIn()
            XCTAssertFalse(result)
            XCTAssertEqual(vm.selectedProfileID, name)
        }
    }

    func testLoginFailureIsSanitizedAndRetrySucceedsWithoutSelectingProfile() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls = 0
        let vm = ProfileViewModel(defaults: defaults, ssoLogin: { _, _ in
            calls += 1
            if calls == 1 { throw NSError(domain: "private-token-output", code: 1) }
        })
        vm.loadProfiles([profile("work")], sessions: [AWSSOSession(name: "company")])
        vm.selectSource(.session("company"))
        let first = await vm.signIn()
        XCTAssertFalse(first)
        XCTAssertTrue(vm.canSignIn)
        XCTAssertFalse(vm.isProfileReady)
        XCTAssertNil(vm.selectedProfileID)
        XCTAssertNil(vm.signedInSessionID)
        XCTAssertFalse(vm.loginMessage?.contains("private-token-output") == true)
        XCTAssertNotNil(vm.loginMessage)

        let retry = await vm.signIn()
        XCTAssertTrue(retry)
        XCTAssertEqual(calls, 2)
        XCTAssertNil(vm.loginMessage)
        XCTAssertNil(vm.selectedProfileID)
        XCTAssertEqual(vm.signedInSessionID, "company")
    }

    func testDelayedEmptyProfileConfigurationPreservesImmediateLoginFailure() async throws {
        for error in [AWSSSOLoginService.LoginError.cliMissing, .failed] {
            let (defaults, suite) = try makeDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            var validations = 0
            let vm = ProfileViewModel(defaults: defaults, profileValidator: { _, _ in
                validations += 1
                return AWSIdentity(account: "example", arn: "example", userID: "example")
            }, ssoLogin: { _, _ in throw error })
            vm.loadProfiles([profile("work")], sessions: [AWSSOSession(name: "company")])
            vm.selectSource(.session("company"))
            vm.selectProfile(id: "work")
            let initiallyConnected = await vm.configureProvider()
            XCTAssertTrue(initiallyConnected)
            XCTAssertEqual(validations, 1)

            let loginSucceeded = await vm.signIn()
            XCTAssertFalse(loginSucceeded)
            XCTAssertFalse(vm.isSigningIn)
            let loginMessage = try XCTUnwrap(vm.loginMessage)
            XCTAssertEqual(loginMessage, error.localizedDescription)

            // A delayed SwiftUI profile-change callback can run after instant CLI failure.
            vm.beginConfiguration()
            XCTAssertEqual(vm.loginMessage, loginMessage)
            let reconfigured = await vm.configureProvider()
            XCTAssertFalse(reconfigured)
            XCTAssertEqual(vm.loginMessage, loginMessage)
            XCTAssertNil(vm.selectedProfileID)
            XCTAssertNil(vm.selectedProfile)
            XCTAssertFalse(vm.isProfileReady)
            XCTAssertEqual(vm.profileStatus, .idle)
            XCTAssertEqual(validations, 1, "Empty profile configuration must not validate an account")

            vm.selectProfile(id: "work")
            XCTAssertNil(vm.loginMessage, "An explicit profile selection clears the previous login feedback")
        }
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
            vm.loadProfiles([profile("work")], sessions: [AWSSOSession(name: "company")])
            vm.selectSource(.session("company"))
            vm.selectProfile(id: "work")
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

    private func profile(_ name: String, session: String = "company") -> AWSProfile {
        AWSProfile(name: name, region: "us-east-1", ssoStartURL: nil,
                   ssoRegion: nil, ssoAccountID: "111122223333", ssoRoleName: "ReadOnlyAccess",
                   ssoSessionName: session)
    }
}
