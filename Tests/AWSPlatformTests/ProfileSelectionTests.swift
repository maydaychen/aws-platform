import XCTest
@testable import AWSPlatform

@MainActor
final class ProfileSelectionTests: XCTestCase {
    private let accountID = "111122223333"
    private let storageKey = "profileAccountNames.v1"

    func testNoSelectionAndSessionLoginNeverLoadAccountMetadata() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var validations = 0
        var metadataCalls = 0
        var logins = 0
        let vm = ProfileViewModel(defaults: defaults, profileValidator: { _, _ in
            validations += 1
            return self.identity()
        }, accountInformationLoader: { _, _, _ in
            metadataCalls += 1
            return AWSAccountInformation(accountID: self.accountID, name: "Company")
        }, ssoLogin: { _, _ in logins += 1 })
        let profile = makeProfile("production", session: "company")
        vm.loadProfiles([profile], sessions: [AWSSOSession(name: "company")])
        await assertConfiguration(vm, expected: false)
        vm.selectSource(.session("company"))
        let signedIn = await vm.signIn()
        XCTAssertTrue(signedIn)
        await settle()
        XCTAssertEqual(logins, 1)
        XCTAssertEqual(validations, 0)
        XCTAssertEqual(metadataCalls, 0)
        XCTAssertNil(vm.selectedProfile)
        XCTAssertFalse(vm.isProfileReady)
        XCTAssertTrue(vm.accountNames.isEmpty)
    }

    func testFailedIdentityValidationNeverLoadsMetadata() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls = 0
        let vm = ProfileViewModel(defaults: defaults, profileValidator: { _, _ in
            throw AWSServiceError.notConfigured
        }, accountInformationLoader: { _, _, _ in
            calls += 1
            return AWSAccountInformation(accountID: self.accountID, name: "Company")
        })
        select(makeProfile("production"), in: vm)
        await assertConfiguration(vm, expected: false)
        await settle()
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(vm.isProfileReady)
    }

    func testIdentityBecomesReadyBeforeBackgroundMetadataCompletes() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = MetadataGate()
        let vm = makeViewModel(defaults: defaults, gate: gate)
        let profile = makeProfile("production")
        select(profile, in: vm)
        await assertConfiguration(vm)
        XCTAssertTrue(vm.isProfileReady)
        XCTAssertEqual(vm.profileStatus, .valid(identity()))
        XCTAssertNil(vm.accountName(for: profile))
        await waitUntil { gate.calls == 1 }
        gate.complete(0, with: AWSAccountInformation(accountID: accountID, name: "Company"))
        await waitUntil { vm.accountName(for: profile) == "Company" }
        XCTAssertNotNil(defaults.data(forKey: storageKey))
        XCTAssertTrue(vm.isProfileReady)
    }

    func testMetadataFailureKeepsValidatedIdentityReady() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = MetadataGate()
        let vm = makeViewModel(defaults: defaults, gate: gate)
        let profile = makeProfile("production")
        select(profile, in: vm)
        await assertConfiguration(vm)
        await waitUntil { gate.calls == 1 }
        gate.fail(0)
        await waitUntil { gate.finished == 1 }
        await settle()
        XCTAssertTrue(vm.isProfileReady)
        XCTAssertEqual(vm.profileStatus, .valid(identity()))
        XCTAssertNil(vm.accountName(for: profile))
        XCTAssertNil(defaults.data(forKey: storageKey))
    }

    func testInvalidMetadataNamesAndMismatchedAccountAreRejected() async throws {
        let cases = [
            AWSAccountInformation(accountID: "999988887777", name: "Wrong account"),
            AWSAccountInformation(accountID: accountID, name: ""),
            AWSAccountInformation(accountID: accountID, name: " \t\n "),
            AWSAccountInformation(accountID: accountID, name: String(repeating: "a", count: 129)),
            AWSAccountInformation(accountID: accountID, name: "Company\u{0}Name"),
            AWSAccountInformation(accountID: accountID, name: "Company\nName"),
            AWSAccountInformation(accountID: accountID, name: "Company\u{7f}Name")
        ]
        for information in cases {
            let (defaults, suite) = try makeDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            let gate = MetadataGate()
            let vm = makeViewModel(defaults: defaults, gate: gate)
            let profile = makeProfile("production")
            select(profile, in: vm)
            await assertConfiguration(vm)
            await waitUntil { gate.calls == 1 }
            gate.complete(0, with: information)
            await waitUntil { gate.finished == 1 }
            await settle()
            XCTAssertTrue(vm.accountNames.isEmpty, "Rejected metadata must not enter storage")
            XCTAssertNil(vm.accountName(for: profile))
            XCTAssertTrue(vm.isProfileReady)
        }
    }

    func testAccountNameTrimsPaddingAndAccepts128CharacterBoundary() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = MetadataGate()
        let vm = makeViewModel(defaults: defaults, gate: gate)
        let profile = makeProfile("production")
        let expected = String(repeating: "名", count: 128)
        select(profile, in: vm)
        await assertConfiguration(vm)
        await waitUntil { gate.calls == 1 }
        gate.complete(0, with: AWSAccountInformation(accountID: accountID, name: "  " + expected + "  "))
        await waitUntil { vm.accountName(for: profile) == expected }
        XCTAssertEqual(vm.profileTitle(profile), expected)
    }

    func testLateMetadataCannotOverwriteNewProfileAfterSwitch() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = MetadataGate()
        let vm = makeViewModel(defaults: defaults, gate: gate)
        let first = makeProfile("first")
        let second = makeProfile("second")
        vm.loadProfiles([first, second], sessions: [])
        vm.selectSource(.other)
        vm.selectProfile(id: first.id)
        await assertConfiguration(vm)
        await waitUntil { gate.calls == 1 }
        vm.selectProfile(id: second.id)
        await assertConfiguration(vm)
        await waitUntil { gate.calls == 2 }
        gate.complete(1, with: AWSAccountInformation(accountID: accountID, name: "Current"))
        await waitUntil { vm.accountName(for: second) == "Current" }
        gate.complete(0, with: AWSAccountInformation(accountID: accountID, name: "Obsolete"))
        await waitUntil { gate.finished == 2 }
        await settle()
        XCTAssertEqual(gate.cancelledCalls, [0])
        XCTAssertEqual(vm.selectedProfileID, second.id)
        XCTAssertEqual(vm.accountNames.map(\.name), ["Current"])
        XCTAssertNil(vm.accountName(for: first))
    }

    func testClearingSelectionCancelsAndDiscardsLateMetadata() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = MetadataGate()
        let vm = makeViewModel(defaults: defaults, gate: gate)
        select(makeProfile("production"), in: vm)
        await assertConfiguration(vm)
        await waitUntil { gate.calls == 1 }
        vm.selectProfile(id: nil)
        gate.complete(0, with: AWSAccountInformation(accountID: accountID, name: "Obsolete"))
        await waitUntil { gate.finished == 1 }
        await settle()
        XCTAssertEqual(gate.cancelledCalls, [0])
        XCTAssertNil(vm.selectedProfile)
        XCTAssertEqual(vm.profileStatus, .idle)
        XCTAssertTrue(vm.accountNames.isEmpty)
        XCTAssertNil(defaults.data(forKey: storageKey))
    }

    func testChangingSourceCancelsMetadataWithoutSelectingAnotherProfile() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = MetadataGate()
        let vm = makeViewModel(defaults: defaults, gate: gate)
        let profile = makeProfile("production", session: "company")
        vm.loadProfiles([profile, makeProfile("other")], sessions: [AWSSOSession(name: "company")])
        vm.selectSource(.session("company"))
        vm.selectProfile(id: profile.id)
        await assertConfiguration(vm)
        await waitUntil { gate.calls == 1 }
        vm.selectSource(.other)
        gate.complete(0, with: AWSAccountInformation(accountID: accountID, name: "Obsolete"))
        await waitUntil { gate.finished == 1 }
        await settle()
        XCTAssertEqual(gate.cancelledCalls, [0])
        XCTAssertNil(vm.selectedProfile)
        XCTAssertFalse(vm.isProfileReady)
        XCTAssertTrue(vm.accountNames.isEmpty)
        XCTAssertEqual(gate.calls, 1)
    }

    func testSameProfileRetryGenerationDiscardsOlderMetadata() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = MetadataGate()
        let vm = makeViewModel(defaults: defaults, gate: gate)
        let profile = makeProfile("production")
        select(profile, in: vm)
        await assertConfiguration(vm)
        await waitUntil { gate.calls == 1 }
        vm.beginConfiguration()
        await assertConfiguration(vm, forceRefresh: true)
        await waitUntil { gate.calls == 2 }
        gate.complete(1, with: AWSAccountInformation(accountID: accountID, name: "Latest"))
        await waitUntil { vm.accountName(for: profile) == "Latest" }
        gate.complete(0, with: AWSAccountInformation(accountID: accountID, name: "Old"))
        await waitUntil { gate.finished == 2 }
        await settle()
        XCTAssertEqual(gate.cancelledCalls, [0])
        XCTAssertEqual(vm.accountNames.map(\.name), ["Latest"])
        XCTAssertTrue(vm.isProfileReady)
    }

    func testRegionChangeUsesCacheAndForceRefreshReloadsMetadata() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = MetadataGate()
        let vm = makeViewModel(defaults: defaults, gate: gate)
        let profile = makeProfile("production")
        select(profile, in: vm)
        await assertConfiguration(vm)
        await waitUntil { gate.calls == 1 }
        gate.complete(0, with: AWSAccountInformation(accountID: accountID, name: "First"))
        await waitUntil { vm.accountName(for: profile) == "First" }
        vm.selectedRegion = "ap-southeast-1"
        await assertConfiguration(vm)
        await settle()
        XCTAssertEqual(gate.calls, 1)
        XCTAssertTrue(vm.isProfileReady)
        await assertConfiguration(vm, forceRefresh: true)
        await waitUntil { gate.calls == 2 }
        gate.complete(1, with: AWSAccountInformation(accountID: accountID, name: "Refreshed"))
        await waitUntil { vm.accountName(for: profile) == "Refreshed" }
        XCTAssertEqual(vm.accountNames.count, 1)
    }

    func testSSOCacheRestoresOfflineWithoutSelectingProfile() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = makeProfile("production", session: "company")
        try seed([entry(profile: profile, name: "Company")], in: defaults)
        defaults.set("company", forKey: "selectedSSOSessionID")
        let vm = ProfileViewModel(defaults: defaults, profileValidator: { _, _ in
            XCTFail("Displaying a cached SSO account name must not validate an account")
            return self.identity()
        })
        vm.loadProfiles([profile], sessions: [AWSSOSession(name: "company")])
        XCTAssertEqual(vm.accountName(for: profile), "Company")
        XCTAssertEqual(vm.filteredProfiles(matching: "company").map(\.id), [profile.id])
        XCTAssertNil(vm.selectedProfileID)
        XCTAssertEqual(vm.profileStatus, .idle)
        XCTAssertFalse(vm.isProfileReady)
    }

    func testOrdinaryProfileCacheRequiresIdentityVerificationBeforeDisplay() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = makeProfile("production")
        try seed([entry(profile: profile, name: "Company")], in: defaults)
        let vm = ProfileViewModel(defaults: defaults, profileValidator: { _, _ in self.identity() })
        select(profile, in: vm)
        XCTAssertNil(vm.accountName(for: profile))
        XCTAssertEqual(vm.profileTitle(profile), profile.name)
        XCTAssertTrue(vm.filteredProfiles(matching: "Company").isEmpty)
        await assertConfiguration(vm)
        XCTAssertEqual(vm.accountName(for: profile), "Company")
        vm.selectProfile(id: nil)
        XCTAssertEqual(vm.accountName(for: profile), "Company", "An identity verified in this process remains known")
        let restarted = ProfileViewModel(defaults: defaults)
        select(profile, in: restarted)
        XCTAssertNil(restarted.accountName(for: profile), "A fresh process must not guess an ordinary profile's account")
    }

    func testCacheMatchesProfileAccountAndBothConfigurationPaths() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = makeProfile("production", session: "company")
        let paths = AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/tmp/profile-test/config-a",
                                                        "AWS_SHARED_CREDENTIALS_FILE": "/tmp/profile-test/credentials-a"])
        let cached = entry(profile: profile, name: "Company", paths: paths)
        try seed([cached], in: defaults)
        let vm = ProfileViewModel(defaults: defaults)
        vm.loadProfiles([profile], sessions: [AWSSOSession(name: "company")])
        vm.selectSource(.session("company"))
        XCTAssertEqual(vm.accountName(for: profile, paths: paths), "Company")
        let otherConfig = AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/tmp/profile-test/config-b",
                                                              "AWS_SHARED_CREDENTIALS_FILE": paths.credentials])
        let otherCredentials = AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": paths.config,
                                                                   "AWS_SHARED_CREDENTIALS_FILE": "/tmp/profile-test/credentials-b"])
        XCTAssertNil(vm.accountName(for: profile, paths: otherConfig))
        XCTAssertNil(vm.accountName(for: profile, paths: otherCredentials))
        XCTAssertNil(vm.accountName(for: makeProfile("different", session: "company"), paths: paths))
        XCTAssertNil(vm.accountName(for: makeProfile("production", session: "company", account: "999988887777"), paths: paths))
        XCTAssertFalse(cached.matches(profile: profile, accountID: "999988887777", paths: paths))
    }

    func testValidatedAccountIDOverridesDeclaredSSOAccountForCachedName() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = makeProfile("production", session: "company")
        try seed([entry(profile: profile, name: "Declared account")], in: defaults)
        let vm = ProfileViewModel(defaults: defaults, profileValidator: { _, _ in self.identity("999988887777") })
        vm.loadProfiles([profile], sessions: [AWSSOSession(name: "company")])
        vm.selectSource(.session("company"))
        XCTAssertEqual(vm.accountName(for: profile), "Declared account")
        vm.selectProfile(id: profile.id)
        await assertConfiguration(vm)
        XCTAssertNil(vm.accountName(for: profile), "Cached metadata must match STS, not a different configured account")
    }

    func testSearchCombinesCaseAndDiacriticInsensitiveTermsAcrossFieldsWithinSource() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = makeProfile("Pród-Work", session: "company", role: "AdministratorAccess")
        let second = makeProfile("dev", session: "company", role: "ReadOnlyAccess")
        let hidden = makeProfile("Pród-Hidden", session: "personal", role: "AdministratorAccess")
        try seed([entry(profile: first, name: "Société Singapore")], in: defaults)
        let vm = ProfileViewModel(defaults: defaults)
        vm.loadProfiles([first, second, hidden], sessions: [AWSSOSession(name: "company"), AWSSOSession(name: "personal")])
        XCTAssertTrue(vm.filteredProfiles(matching: "").isEmpty)
        vm.selectSource(.session("company"))
        vm.selectProfile(id: second.id)
        XCTAssertEqual(vm.filteredProfiles(matching: " PROd ADMIN 1111 societe ").map(\.id), [first.id])
        XCTAssertEqual(vm.filteredProfiles(matching: "\n\t ").map(\.id), [first.id, second.id])
        XCTAssertTrue(vm.filteredProfiles(matching: "production missing").isEmpty)
        XCTAssertEqual(vm.selectedProfileID, second.id, "Search must not change or clear selection")
        vm.selectSource(.session("personal"))
        XCTAssertEqual(vm.filteredProfiles(matching: "prod ADMIN").map(\.id), [hidden.id])
        XCTAssertNil(vm.selectedProfileID)
    }

    func testSearchFindsOrdinaryProfileAccountIDOnlyAfterIdentityVerification() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = makeProfile("production")
        try seed([entry(profile: profile, name: "Company")], in: defaults)
        let vm = ProfileViewModel(defaults: defaults, profileValidator: { _, _ in self.identity() })
        select(profile, in: vm)
        XCTAssertTrue(vm.filteredProfiles(matching: accountID).isEmpty)
        await assertConfiguration(vm)
        XCTAssertEqual(vm.filteredProfiles(matching: accountID).map(\.id), [profile.id])
        XCTAssertEqual(vm.selectedProfileID, profile.id)
    }

    func testPersistedMetadataRejectsInvalidDisplayNamesAndAccountIDs() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = makeProfile("production", session: "company")
        let invalidNames = ["", "   ", "Bad\u{0}Name", String(repeating: "a", count: 129)]
        var names = invalidNames.map { entry(profile: profile, name: $0) }
        names.append(ProfileAccountName(profileID: profile.id, accountID: "not-an-account", name: "Company",
                                        configPath: AWSConfigurationPaths().config,
                                        credentialsPath: AWSConfigurationPaths().credentials))
        names.append(entry(profile: profile, name: "Valid"))
        try seed(names, in: defaults)
        let vm = ProfileViewModel(defaults: defaults)
        vm.loadProfiles([profile], sessions: [AWSSOSession(name: "company")])
        vm.selectSource(.session("company"))
        XCTAssertEqual(vm.accountNames.map(\.name), ["Valid"])
        XCTAssertEqual(vm.accountName(for: profile), "Valid")
        XCTAssertNil(vm.selectedProfileID)
    }

    private func assertConfiguration(_ vm: ProfileViewModel, forceRefresh: Bool = false, expected: Bool = true,
                                     file: StaticString = #filePath, line: UInt = #line) async {
        let result = await vm.configureProvider(forceRefresh: forceRefresh)
        XCTAssertEqual(result, expected, file: file, line: line)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "ProfileSelectionTests." + UUID().uuidString
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    private func makeProfile(_ name: String, session: String? = nil, account: String? = nil, role: String? = nil) -> AWSProfile {
        AWSProfile(name: name, region: "us-east-1", ssoStartURL: nil, ssoRegion: nil,
                   ssoAccountID: account ?? (session == nil ? nil : accountID), ssoRoleName: role, ssoSessionName: session)
    }

    private func identity(_ account: String? = nil) -> AWSIdentity {
        let account = account ?? accountID
        return AWSIdentity(account: account, arn: "arn:aws:iam::\(account):role/test", userID: "test")
    }

    private func entry(profile: AWSProfile, name: String, paths: AWSConfigurationPaths = AWSConfigurationPaths()) -> ProfileAccountName {
        ProfileAccountName(profileID: profile.id, accountID: accountID, name: name,
                           configPath: paths.config, credentialsPath: paths.credentials)
    }

    private func seed(_ names: [ProfileAccountName], in defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(names), forKey: storageKey)
    }

    private func select(_ profile: AWSProfile, in vm: ProfileViewModel) {
        vm.loadProfiles([profile], sessions: [])
        vm.selectSource(.other)
        vm.selectProfile(id: profile.id)
    }

    private func makeViewModel(defaults: UserDefaults, gate: MetadataGate) -> ProfileViewModel {
        ProfileViewModel(defaults: defaults, profileValidator: { _, _ in self.identity() },
                         accountInformationLoader: { _, _, _ in try await gate.load() })
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(condition(), "Background operation did not reach the expected state", file: file, line: line)
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(5))
    }

    private final class MetadataGate {
        private(set) var calls = 0
        private(set) var finished = 0
        private(set) var cancelledCalls: [Int] = []
        private var continuations: [Int: CheckedContinuation<AWSAccountInformation, Error>] = [:]

        func load() async throws -> AWSAccountInformation {
            let index = calls
            calls += 1
            defer {
                finished += 1
                if Task.isCancelled { cancelledCalls.append(index) }
            }
            return try await withCheckedThrowingContinuation { continuations[index] = $0 }
        }

        func complete(_ index: Int, with value: AWSAccountInformation) {
            continuations.removeValue(forKey: index)?.resume(returning: value)
        }

        func fail(_ index: Int) {
            continuations.removeValue(forKey: index)?.resume(throwing: AWSServiceError.notConfigured)
        }
    }
}
