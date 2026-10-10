import XCTest
@testable import AWSPlatform

@MainActor
final class ProfileSelectionTests: XCTestCase {
    private let accountID = "111122223333"

    func testObsoleteAccountNameCacheIsRemovedWithoutChangingOtherPreferences() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = makeProfile("production", session: "company")
        let legacyCache = [["profileID": profile.id, "accountID": accountID, "name": "Cached Company",
                            "configPath": "/tmp/profile-test/config", "credentialsPath": "/tmp/profile-test/credentials"]]
        defaults.set(try JSONSerialization.data(withJSONObject: legacyCache), forKey: "profileAccountNames.v1")
        defaults.set("company", forKey: "selectedSSOSessionID")
        defaults.set("preserved", forKey: "otherPreference")

        let vm = ProfileViewModel(defaults: defaults)
        vm.loadProfiles([profile], sessions: [AWSSOSession(name: "company")])

        XCTAssertNil(defaults.data(forKey: "profileAccountNames.v1"))
        XCTAssertEqual(defaults.string(forKey: "otherPreference"), "preserved")
        XCTAssertEqual(vm.selectedSession?.name, "company")
        XCTAssertNil(vm.selectedProfileID)
        XCTAssertTrue(vm.filteredProfiles(matching: "Cached Company").isEmpty)
        XCTAssertEqual(vm.filteredProfiles(matching: "production").map(\.id), [profile.id])
        XCTAssertEqual(vm.profileStatus, .idle)
    }

    func testSearchCombinesCaseAndDiacriticInsensitiveTermsAcrossFieldsWithinSource() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = makeProfile("Pród-Work", session: "company", role: "AdministratorAccess")
        let second = makeProfile("dev", session: "company", role: "ReadOnlyAccess")
        let hidden = makeProfile("Pród-Hidden", session: "personal", role: "AdministratorAccess")
        let vm = ProfileViewModel(defaults: defaults)
        vm.loadProfiles([first, second, hidden], sessions: [AWSSOSession(name: "company"), AWSSOSession(name: "personal")])
        XCTAssertTrue(vm.filteredProfiles(matching: "").isEmpty)
        vm.selectSource(.session("company"))
        vm.selectProfile(id: second.id)

        XCTAssertEqual(vm.filteredProfiles(matching: " PROd ADMIN 1111 ").map(\.id), [first.id])
        XCTAssertEqual(vm.filteredProfiles(matching: "\n\t ").map(\.id), [first.id, second.id])
        XCTAssertTrue(vm.filteredProfiles(matching: "prod missing").isEmpty)
        XCTAssertEqual(vm.selectedProfileID, second.id, "Searching must not change selection")
        vm.selectSource(.session("personal"))
        XCTAssertEqual(vm.filteredProfiles(matching: "prod ADMIN").map(\.id), [hidden.id])
        XCTAssertNil(vm.selectedProfileID)
    }

    func testOtherProfileSearchDoesNotIncludeProfilesFromSSOSessions() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let ordinary = makeProfile("production")
        let sso = makeProfile("production-sso", session: "company")
        let vm = ProfileViewModel(defaults: defaults)
        vm.loadProfiles([ordinary, sso], sessions: [AWSSOSession(name: "company")])
        vm.selectSource(.other)

        XCTAssertEqual(vm.filteredProfiles(matching: "production").map(\.id), [ordinary.id])
        XCTAssertTrue(vm.filteredProfiles(matching: accountID).isEmpty)
        XCTAssertNil(vm.selectedProfileID)
    }

    func testSSOAccountIDIsSearchableBeforeSelectionAndVerifiedIdentityTakesPrecedence() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = makeProfile("production", session: "company")
        let actualAccount = "999988887777"
        let vm = ProfileViewModel(defaults: defaults, profileValidator: { _, _ in self.identity(actualAccount) })
        vm.loadProfiles([profile], sessions: [AWSSOSession(name: "company")])
        vm.selectSource(.session("company"))
        XCTAssertEqual(vm.filteredProfiles(matching: accountID).map(\.id), [profile.id])
        XCTAssertNil(vm.selectedProfileID)

        vm.selectProfile(id: profile.id)
        let ready = await vm.configureProvider()
        XCTAssertTrue(ready)
        XCTAssertEqual(vm.accountID(for: profile), actualAccount)
        XCTAssertEqual(vm.filteredProfiles(matching: actualAccount).map(\.id), [profile.id])
        XCTAssertTrue(vm.filteredProfiles(matching: accountID).isEmpty)
        XCTAssertEqual(vm.selectedProfile?.name, "production")
        vm.selectProfile(id: nil)
        XCTAssertEqual(vm.accountID(for: profile), accountID)
        XCTAssertFalse(vm.isProfileReady)
    }

    func testOrdinaryAccountIDUsesOnlyCurrentVerifiedIdentityAndRetriesDoNotWriteNameCache() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = makeProfile("production")
        let second = makeProfile("development")
        var validations = 0
        let vm = ProfileViewModel(defaults: defaults, profileValidator: { profile, _ in
            validations += 1
            return self.identity(profile.id == first.id ? self.accountID : "999988887777")
        })
        vm.loadProfiles([first, second], sessions: [])
        vm.selectSource(.other)
        vm.selectProfile(id: first.id)
        XCTAssertTrue(vm.filteredProfiles(matching: accountID).isEmpty)
        let ready = await vm.configureProvider()
        XCTAssertTrue(ready)
        XCTAssertEqual(vm.filteredProfiles(matching: accountID).map(\.id), [first.id])

        vm.beginConfiguration()
        let retryReady = await vm.configureProvider(forceRefresh: true)
        XCTAssertTrue(retryReady)
        XCTAssertEqual(validations, 2)
        XCTAssertNil(defaults.data(forKey: "profileAccountNames.v1"))
        vm.selectProfile(id: second.id)
        XCTAssertNil(vm.accountID(for: first))
        XCTAssertTrue(vm.filteredProfiles(matching: accountID).isEmpty)
        let secondReady = await vm.configureProvider()
        XCTAssertTrue(secondReady)
        XCTAssertEqual(vm.filteredProfiles(matching: "999988887777").map(\.id), [second.id])
        vm.selectProfile(id: nil)
        XCTAssertNil(vm.accountID(for: second))
        XCTAssertNil(defaults.data(forKey: "profileAccountNames.v1"))
    }

    func testProfileSubtitleContainsOnlyRoleAndKnownAccountID() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = ProfileViewModel(defaults: defaults)
        XCTAssertEqual(vm.profileSubtitle(makeProfile("production", session: "company", role: "ReadOnlyAccess")),
                       "ReadOnlyAccess · 111122223333")
        XCTAssertEqual(vm.profileSubtitle(makeProfile("ordinary")), "")
        XCTAssertEqual(vm.profileSubtitle(makeProfile("production", session: "company")), accountID)
    }

    func testSessionLoginKeepsProfileEmptyAndDoesNotValidateIdentityOrWriteNameCache() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var validations = 0
        var logins = 0
        let vm = ProfileViewModel(defaults: defaults, profileValidator: { _, _ in
            validations += 1
            return self.identity(self.accountID)
        }, ssoLogin: { _, _ in logins += 1 })
        vm.loadProfiles([makeProfile("production", session: "company")], sessions: [AWSSOSession(name: "company")])
        vm.selectSource(.session("company"))
        let signedIn = await vm.signIn()
        XCTAssertTrue(signedIn)
        XCTAssertEqual(logins, 1)
        XCTAssertEqual(validations, 0)
        XCTAssertNil(vm.selectedProfile)
        XCTAssertFalse(vm.isProfileReady)
        XCTAssertNil(defaults.data(forKey: "profileAccountNames.v1"))
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "ProfileSelectionTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    private func makeProfile(_ name: String, session: String? = nil, role: String? = nil) -> AWSProfile {
        AWSProfile(name: name, region: "us-east-1", ssoStartURL: nil, ssoRegion: nil,
                   ssoAccountID: session == nil ? nil : accountID, ssoRoleName: role, ssoSessionName: session)
    }

    private func identity(_ account: String) -> AWSIdentity {
        AWSIdentity(account: account, arn: "arn:aws:iam::\(account):user/test", userID: "test")
    }
}
