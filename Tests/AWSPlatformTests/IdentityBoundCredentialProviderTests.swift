import SotoCore
import XCTest
@testable import AWSPlatform

private actor RenewableTestCredentials: CredentialProvider {
    nonisolated var description: String { "OfflineRenewal" }
    var value: Credential = StaticCredential(accessKeyId: "offline-access", secretAccessKey: "offline-secret", sessionToken: "first")
    func replace(_ token: String) {
        value = StaticCredential(accessKeyId: "offline-access", secretAccessKey: "offline-secret", sessionToken: token)
    }
    func getCredential(logger: Logger) async throws -> Credential { value }
}

private actor IdentityVerificationProbe {
    var calls = 0
    var invalidations = 0
    let identity: AWSIdentity
    let replacement: AWSIdentity
    init(identity: AWSIdentity, replacement: AWSIdentity) {
        self.identity = identity
        self.replacement = replacement
    }
    func verify(_ credential: Credential) -> AWSIdentity {
        calls += 1
        return credential.sessionToken == "first" ? identity : replacement
    }
    func invalidated() { invalidations += 1 }
}

final class IdentityBoundCredentialProviderTests: XCTestCase {
    private let logger = Logger(label: "offline-credential-tests")
    private static func identity(account: String = "111122223333", role: String = "ReadOnly", id: String = "AROAoffline",
                                 session: String = "first") -> AWSIdentity {
        .init(account: account, arn: "arn:aws:sts::\(account):assumed-role/\(role)/\(session)", userID: "\(id):\(session)")
    }

    func testIdenticalCredentialsAreVerifiedOnceAndSameRoleRenewalIsAllowed() async throws {
        let source = RenewableTestCredentials()
        let probe = IdentityVerificationProbe(identity: Self.identity(), replacement: Self.identity(session: "renewed"))
        let bound = IdentityBoundCredentialProvider(source: AWSClient(credentialProvider: .custom { _ in source }),
            region: "us-east-1", expectedAccount: "111122223333", verifier: { value, _ in await probe.verify(value) }, onInvalidation: {})
        addTeardownBlock { try await bound.shutdown() }
        _ = try await bound.getCredential(logger: logger)
        _ = try await bound.getCredential(logger: logger)
        let initialCalls = await probe.calls
        XCTAssertEqual(initialCalls, 1)
        await source.replace("renewed")
        let next = try await bound.getCredential(logger: logger)
        XCTAssertEqual(next.sessionToken, "renewed")
        let count = await probe.calls
        XCTAssertEqual(count, 2, "Every distinct credential must be verified, including token-only changes")
    }

    func testAccountRoleAndRoleIDChangesPermanentlyInvalidateTheOldClient() async throws {
        for replacement in [Self.identity(account: "444455556666"), Self.identity(role: "Admin"), Self.identity(id: "AROAother")] {
            let source = RenewableTestCredentials()
            let probe = IdentityVerificationProbe(identity: Self.identity(), replacement: replacement)
            let bound = IdentityBoundCredentialProvider(source: AWSClient(credentialProvider: .custom { _ in source }),
                region: "us-east-1", expectedAccount: nil, verifier: { value, _ in await probe.verify(value) },
                onInvalidation: { Task { await probe.invalidated() } })
            addTeardownBlock { try await bound.shutdown() }
            _ = try await bound.getCredential(logger: logger)
            await source.replace("changed")
            do { _ = try await bound.getCredential(logger: logger); XCTFail("Changed identity must never reach a business request") }
            catch { XCTAssertEqual(error as? AWSServiceError, .identityChanged) }
            await source.replace("first")
            do { _ = try await bound.getCredential(logger: logger); XCTFail("An old cached client must remain invalid") }
            catch { XCTAssertEqual(error as? AWSServiceError, .identityChanged) }
            let count = await probe.calls
            XCTAssertEqual(count, 2)
        }
    }

    func testFailedSTSAndConfiguredSSOAccountMismatchCannotIssueCredentials() async throws {
        for shouldFail in [true, false] {
            let bound = IdentityBoundCredentialProvider(source: AWSClient(credentialProvider: .static(
                accessKeyId: "offline-access", secretAccessKey: "offline-secret")), region: "us-east-1",
                expectedAccount: "444455556666", verifier: { _, _ in
                    if shouldFail { throw AWSServiceError.identityUnavailable }
                    return Self.identity()
                }, onInvalidation: {})
            addTeardownBlock { try await bound.shutdown() }
            do { _ = try await bound.getCredential(logger: logger); XCTFail("Unverified credentials must be rejected") }
            catch { XCTAssertEqual(error as? AWSServiceError, .identityChanged) }
        }
    }

    func testConcurrentRequestsShareVerificationOfTheExactCandidate() async throws {
        let gate = TestGate()
        let probe = IdentityVerificationProbe(identity: Self.identity(), replacement: Self.identity())
        let bound = IdentityBoundCredentialProvider(source: AWSClient(credentialProvider: .static(
            accessKeyId: "offline-access", secretAccessKey: "offline-secret", sessionToken: "first")),
            region: "us-east-1", expectedAccount: nil, verifier: { value, _ in
                let identity = await probe.verify(value)
                await gate.wait()
                return identity
            }, onInvalidation: {})
        addTeardownBlock { try await bound.shutdown() }
        let logger = self.logger
        let requests = (0..<8).map { _ in Task { try await bound.getCredential(logger: logger) } }
        await gate.waitForEntry()
        await gate.open()
        for request in requests { _ = try await request.value }
        let count = await probe.calls
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testInvalidationClearsProfileReadinessAndRequiresExplicitRetry() async throws {
        let source = RenewableTestCredentials()
        let provider = AWSServiceProvider(credentialFactory: { _, _ in .custom { _ in source } },
            identityVerifier: { value, _ in Self.identity(account: value.sessionToken == "first" ? "111122223333" : "444455556666") })
        let suite = "security-profile-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = ProfileViewModel(defaults: defaults, provider: provider)
        let profile = AWSProfile(name: "offline", region: "us-east-1", ssoStartURL: nil, ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil)
        vm.loadProfiles([profile], sessions: [])
        vm.selectSource(.other)
        vm.selectProfile(id: profile.id)
        let ready = await vm.configureProvider()
        XCTAssertTrue(ready)
        let scope = MonitoringScope(profile: profile, identity: Self.identity(), region: "us-east-1", paths: .init())
        let client = try await provider.s3Client(scope: scope)
        let oldFailure = vm.identityFailureID
        await source.replace("changed")
        do { _ = try await client.client.credentialProvider.getCredential(logger: logger); XCTFail("Cached service must reject refreshed identity") }
        catch { XCTAssertEqual(error as? AWSServiceError, .identityChanged) }
        for _ in 0..<1000 where vm.isProfileReady { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(vm.isProfileReady)
        XCTAssertNotEqual(vm.identityFailureID, oldFailure)
        XCTAssertEqual(vm.selectedProfileID, profile.id)
        await source.replace("first")
        let recovered = await vm.configureProvider(forceRefresh: true)
        XCTAssertTrue(recovered)
        await vm.shutdown()
    }
}
