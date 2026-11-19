import Foundation
import SotoCore
import XCTest
@testable import AWSPlatform

private actor RenewableTestCredentials: CredentialProvider {
    nonisolated var description: String { "OfflineRenewal" }
    var value: Credential = StaticCredential(accessKeyId: "offline-access", secretAccessKey: "offline-secret", sessionToken: "first")
    var calls = 0
    var nextError: Error?
    func replace(_ token: String) {
        value = StaticCredential(accessKeyId: "offline-access", secretAccessKey: "offline-secret", sessionToken: token)
    }
    func failNext(with error: Error = RetryProbeError.unavailable) { nextError = error }
    func getCredential(logger: Logger) async throws -> Credential {
        calls += 1
        if let error = nextError {
            nextError = nil
            throw error
        }
        return value
    }
}

private enum RetryProbeError: LocalizedError {
    case unavailable
    var errorDescription: String? { "offline-untrusted-response-marker" }
}

private final class CredentialRetryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var count = 0
    func now() -> TimeInterval { lock.withLock { time } }
    func advance(_ interval: TimeInterval) { lock.withLock { time += interval } }
    func invalidated() { lock.withLock { count += 1 } }
    var invalidations: Int { lock.withLock { count } }
}

private actor IdentityVerificationProbe {
    var calls = 0
    var invalidations = 0
    var failures = 0
    var cancellations = 0
    let identity: AWSIdentity
    let replacement: AWSIdentity
    init(identity: AWSIdentity, replacement: AWSIdentity) {
        self.identity = identity
        self.replacement = replacement
    }
    func failNext() { failures += 1 }
    func cancelNext() { cancellations += 1 }
    func verify(_ credential: Credential) throws -> AWSIdentity {
        calls += 1
        if cancellations > 0 {
            cancellations -= 1
            throw CancellationError()
        }
        if failures > 0 {
            failures -= 1
            throw RetryProbeError.unavailable
        }
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
            region: "us-east-1", expectedAccount: "111122223333", verifier: { value, _ in try await probe.verify(value) }, onInvalidation: {})
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
                region: "us-east-1", expectedAccount: nil, verifier: { value, _ in try await probe.verify(value) },
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
            catch { XCTAssertEqual(error as? AWSServiceError, shouldFail ? .identityUnavailable : .identityChanged) }
        }
    }

    func testConcurrentRequestsShareVerificationOfTheExactCandidate() async throws {
        let gate = TestGate()
        let probe = IdentityVerificationProbe(identity: Self.identity(), replacement: Self.identity())
        let bound = IdentityBoundCredentialProvider(source: AWSClient(credentialProvider: .static(
            accessKeyId: "offline-access", secretAccessKey: "offline-secret", sessionToken: "first")),
            region: "us-east-1", expectedAccount: nil, verifier: { value, _ in
                let identity = try await probe.verify(value)
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

    func testRenewedCredentialVerificationFailureRecoversWithoutInvalidating() async throws {
        let source = RenewableTestCredentials()
        let clock = CredentialRetryClock()
        let probe = IdentityVerificationProbe(identity: Self.identity(), replacement: Self.identity(session: "renewed"))
        let bound = IdentityBoundCredentialProvider(source: AWSClient(credentialProvider: .custom { _ in source }),
            region: "us-east-1", expectedAccount: "111122223333",
            verifier: { value, _ in try await probe.verify(value) }, onInvalidation: { clock.invalidated() }, now: { clock.now() })
        addTeardownBlock { try await bound.shutdown() }
        _ = try await bound.getCredential(logger: logger)
        await source.replace("renewed")
        await probe.failNext()
        await expectUnavailable(bound)
        await expectUnavailable(bound)
        let failedCalls = await probe.calls
        XCTAssertEqual(failedCalls, 2, "A failed renewed credential must not be issued or retried inside the cooldown")
        XCTAssertEqual(clock.invalidations, 0)
        let retainedIdentity = try await bound.identity()
        XCTAssertEqual(retainedIdentity, Self.identity())
        clock.advance(1)
        let recovered = try await bound.getCredential(logger: logger)
        XCTAssertEqual(recovered.sessionToken, "renewed")
        let recoveredIdentity = try await bound.identity()
        XCTAssertEqual(recoveredIdentity, Self.identity(session: "renewed"))
    }

    func testSourceCredentialFailureDoesNotInvalidateVerifiedIdentityAndIsSanitized() async throws {
        let source = RenewableTestCredentials()
        let clock = CredentialRetryClock()
        let bound = IdentityBoundCredentialProvider(source: AWSClient(credentialProvider: .custom { _ in source }),
            region: "us-east-1", expectedAccount: nil, verifier: { _, _ in Self.identity() },
            onInvalidation: { clock.invalidated() }, now: { clock.now() })
        addTeardownBlock { try await bound.shutdown() }
        _ = try await bound.getCredential(logger: logger)
        await source.failNext()
        await expectUnavailable(bound)
        await expectUnavailable(bound)
        let calls = await source.calls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(clock.invalidations, 0)
        clock.advance(1)
        _ = try await bound.getCredential(logger: logger)
    }

    func testCLIMaintenanceDoesNotInvalidateIdentityOrScheduleCredentialBackoff() async throws {
        let source = RenewableTestCredentials()
        let clock = CredentialRetryClock()
        let bound = IdentityBoundCredentialProvider(source: AWSClient(credentialProvider: .custom { _ in source }),
            region: "us-east-1", expectedAccount: nil, verifier: { _, _ in Self.identity() },
            onInvalidation: { clock.invalidated() }, now: { clock.now() })
        addTeardownBlock { try await bound.shutdown() }
        _ = try await bound.getCredential(logger: logger)
        await source.failNext(with: AWSCLIUpdateError.busy)
        do { _ = try await bound.getCredential(logger: logger); XCTFail("CLI maintenance must block credential export") }
        catch {
            XCTAssertEqual(error as? AWSCLIUpdateError, .busy)
            XCTAssertFalse(UserFacingError.requiresSSOLogin(error))
            XCTAssertEqual(UserFacingError.message(for: error), AWSCLIUpdateError.busy.localizedDescription)
            XCTAssertEqual(UserFacingError.loginMessage(for: error, profileName: "offline"), AWSCLIUpdateError.busy.localizedDescription)
        }
        _ = try await bound.getCredential(logger: logger)
        XCTAssertEqual(clock.invalidations, 0)
        let actual = try await bound.identity()
        XCTAssertEqual(actual, Self.identity())
    }

    func testRepeatedInitialVerificationFailuresHaveBoundedBackoffAndSuccessResetsIt() async throws {
        let source = RenewableTestCredentials()
        let clock = CredentialRetryClock()
        let probe = IdentityVerificationProbe(identity: Self.identity(), replacement: Self.identity())
        let bound = IdentityBoundCredentialProvider(source: AWSClient(credentialProvider: .custom { _ in source }),
            region: "us-east-1", expectedAccount: nil, verifier: { value, _ in try await probe.verify(value) },
            onInvalidation: { clock.invalidated() }, now: { clock.now() })
        addTeardownBlock { try await bound.shutdown() }
        for (index, delay) in [1.0, 2, 4, 8, 16, 30, 30].enumerated() {
            await probe.failNext()
            await expectUnavailable(bound)
            for _ in 0..<8 { await expectUnavailable(bound) }
            clock.advance(delay - 0.5)
            await expectUnavailable(bound)
            let calls = await probe.calls
            XCTAssertEqual(calls, index + 1)
            clock.advance(0.5)
        }
        _ = try await bound.getCredential(logger: logger)
        await source.replace("renewed")
        await probe.failNext()
        await expectUnavailable(bound)
        clock.advance(1)
        _ = try await bound.getCredential(logger: logger)
        XCTAssertEqual(clock.invalidations, 0)
    }

    func testSourceLoginRequiredClassificationIsPreservedWithoutOriginalText() async throws {
        let source = RenewableTestCredentials()
        let bound = IdentityBoundCredentialProvider(source: AWSClient(credentialProvider: .custom { _ in source }),
            region: "us-east-1", expectedAccount: nil, verifier: { _, _ in Self.identity() }, onInvalidation: {})
        addTeardownBlock { try await bound.shutdown() }
        await source.failNext(with: AWSSSOCredentialError.tokenExpired("offline-untrusted-response-marker"))
        do { _ = try await bound.getCredential(logger: logger); XCTFail("Missing SSO authorization must not issue credentials") }
        catch {
            XCTAssertTrue(UserFacingError.requiresSSOLogin(error))
            XCTAssertFalse(String(describing: error).contains("offline-untrusted-response-marker"))
        }
    }

    func testConcurrentVerificationFailureSchedulesOnlyOneRetryDelay() async throws {
        let gate = TestGate()
        let clock = CredentialRetryClock()
        let source = RenewableTestCredentials()
        let probe = IdentityVerificationProbe(identity: Self.identity(), replacement: Self.identity())
        await probe.failNext()
        let bound = IdentityBoundCredentialProvider(source: AWSClient(credentialProvider: .custom { _ in source }),
            region: "us-east-1", expectedAccount: nil, verifier: { value, _ in
                if await probe.calls == 0 { await gate.wait() }
                return try await probe.verify(value)
            }, onInvalidation: { clock.invalidated() }, now: { clock.now() })
        addTeardownBlock { try await bound.shutdown() }
        let logger = self.logger
        let requests = (0..<8).map { _ in Task { try await bound.getCredential(logger: logger) } }
        await gate.waitForEntry()
        for _ in 0..<1000 {
            if await source.calls >= 8 { break }
            await Task.yield()
        }
        await gate.open()
        for request in requests {
            do { _ = try await request.value; XCTFail("Shared failed verification must not issue credentials") }
            catch { XCTAssertEqual(error as? AWSServiceError, .identityUnavailable) }
        }
        clock.advance(1)
        _ = try await bound.getCredential(logger: logger)
        let calls = await probe.calls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(clock.invalidations, 0)
    }

    func testCancelledVerifierIsRemovedAndNextRequestCanVerifyAgain() async throws {
        let probe = IdentityVerificationProbe(identity: Self.identity(), replacement: Self.identity())
        await probe.cancelNext()
        let bound = IdentityBoundCredentialProvider(source: AWSClient(credentialProvider: .static(
            accessKeyId: "offline-access", secretAccessKey: "offline-secret", sessionToken: "first")),
            region: "us-east-1", expectedAccount: nil,
            verifier: { value, _ in try await probe.verify(value) }, onInvalidation: {})
        addTeardownBlock { try await bound.shutdown() }
        do { _ = try await bound.getCredential(logger: logger); XCTFail("Cancelled verification must not issue credentials") }
        catch { XCTAssertTrue(error is CancellationError) }
        _ = try await bound.getCredential(logger: logger)
        let calls = await probe.calls
        XCTAssertEqual(calls, 2)
    }

    func testCancellingOneWaiterDoesNotCancelSharedVerificationOrLoseIdentity() async throws {
        let gate = TestGate()
        let probe = IdentityVerificationProbe(identity: Self.identity(), replacement: Self.identity())
        let source = RenewableTestCredentials()
        let bound = IdentityBoundCredentialProvider(source: AWSClient(credentialProvider: .custom { _ in source }),
            region: "us-east-1", expectedAccount: nil, verifier: { value, _ in
                let identity = try await probe.verify(value)
                await gate.wait()
                return identity
            }, onInvalidation: {})
        addTeardownBlock { try await bound.shutdown() }
        let logger = self.logger
        let first = Task { try await bound.getCredential(logger: logger) }
        await gate.waitForEntry()
        let second = Task { try await bound.getCredential(logger: logger) }
        for _ in 0..<1000 {
            if await source.calls >= 2 { break }
            await Task.yield()
        }
        first.cancel()
        await gate.open()
        do { _ = try await first.value; XCTFail("A cancelled waiter must not receive credentials") }
        catch { XCTAssertTrue(error is CancellationError) }
        _ = try await second.value
        let identity = try await bound.identity()
        let calls = await probe.calls
        XCTAssertEqual(identity, Self.identity())
        XCTAssertEqual(calls, 1)
    }

    func testConcurrentDifferentAccountCandidateInvalidatesPendingVerifiedCandidate() async throws {
        let gate = TestGate()
        let source = RenewableTestCredentials()
        let clock = CredentialRetryClock()
        let bound = IdentityBoundCredentialProvider(source: AWSClient(credentialProvider: .custom { _ in source }),
            region: "us-east-1", expectedAccount: "111122223333", verifier: { value, _ in
                if value.sessionToken == "first" {
                    await gate.wait()
                    return Self.identity()
                }
                return Self.identity(account: "444455556666")
            }, onInvalidation: { clock.invalidated() })
        addTeardownBlock { try await bound.shutdown() }
        let logger = self.logger
        let first = Task { try await bound.getCredential(logger: logger) }
        await gate.waitForEntry()
        await source.replace("wrong-account")
        do { _ = try await bound.getCredential(logger: logger); XCTFail("Wrong account must be rejected") }
        catch { XCTAssertEqual(error as? AWSServiceError, .identityChanged) }
        await gate.open()
        do { _ = try await first.value; XCTFail("An invalidated generation must never issue pending credentials") }
        catch { XCTAssertEqual(error as? AWSServiceError, .identityChanged) }
        XCTAssertEqual(clock.invalidations, 1)
    }

    private func expectUnavailable(_ bound: IdentityBoundCredentialProvider,
                                   file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await bound.getCredential(logger: logger); XCTFail("Unverified credentials must not be issued", file: file, line: line) }
        catch {
            XCTAssertEqual(error as? AWSServiceError, .identityUnavailable, file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains("offline-untrusted-response-marker"), file: file, line: line)
        }
    }

    @MainActor
    func testInvalidationDeliveredBeforeValidationPublishesReadiness() async throws {
        let source = RenewableTestCredentials()
        let provider = AWSServiceProvider(credentialFactory: { _, _ in .custom { _ in source } },
            identityVerifier: { value, _ in Self.identity(account: value.sessionToken == "first" ? "111122223333" : "444455556666") })
        let suite = "security-profile-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = AWSProfile(name: "offline", region: "us-east-1", ssoStartURL: nil, ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil)
        let gate = TestGate()
        var validatingGeneration: UUID?
        let vm = ProfileViewModel(defaults: defaults, provider: provider, bindingValidator: { provider in
            let validation = try await provider.validateBinding()
            if await provider.currentRegion == "us-west-2" {
                validatingGeneration = validation.generation
                await gate.wait()
            }
            return validation
        })
        vm.loadProfiles([profile], sessions: [])
        vm.selectSource(.other)
        vm.selectProfile(id: profile.id)
        let initiallyReady = await vm.configureProvider()
        XCTAssertTrue(initiallyReady)
        let scope = MonitoringScope(profile: profile, identity: Self.identity(), region: "us-east-1")
        let client = try await provider.s3Client(scope: scope)
        let oldFailure = vm.identityFailureID

        vm.selectedRegion = "us-west-2"
        let validation = Task { await vm.configureProvider() }
        await gate.waitForEntry()
        XCTAssertEqual(vm.profileStatus, .checking)
        await source.replace("changed")
        do { _ = try await client.client.credentialProvider.getCredential(logger: logger); XCTFail("The old client must reject a different identity") }
        catch { XCTAssertEqual(error as? AWSServiceError, .identityChanged) }
        // Deliver the event through the same handler before validation can resume.
        if let validatingGeneration { await vm.handleIdentityFailure(validatingGeneration) }
        else { XCTFail("The paused validation must identify its binding") }
        await gate.open()

        let ready = await validation.value
        XCTAssertFalse(ready)
        XCTAssertFalse(vm.isProfileReady)
        XCTAssertEqual(vm.profileStatus, .failed(AWSServiceError.identityChanged.localizedDescription))
        XCTAssertNotEqual(vm.identityFailureID, oldFailure)
        vm.selectedRegion = "us-east-1"
        await source.replace("first")
        let reverified = await vm.configureProvider(forceRefresh: true)
        XCTAssertTrue(reverified)
        if let validatingGeneration { await vm.handleIdentityFailure(validatingGeneration) }
        XCTAssertTrue(vm.isProfileReady, "A previous binding's failure cannot invalidate the new binding")
        await vm.shutdown()
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
