import XCTest
@testable import AWSPlatform

final class SubmoduleProviderScopeTests: XCTestCase {
    func testScopedMonitoringFactoriesRequireExplicitIdentityValidation() async {
        let provider = AWSServiceProvider.testProvider()
        let scope = makeScope()
        await provider.configure(profile: scope.profile, region: scope.region, paths: scope.paths)
        await assertRejected(provider, scope: scope, expected: .notConfigured)
        await provider.shutdown()
    }

    func testScopedMonitoringFactoriesRejectUnconfiguredAndClearedProfiles() async throws {
        let provider = AWSServiceProvider.testProvider()
        let scope = makeScope()
        await assertRejected(provider, scope: scope, expected: .notConfigured)
        try await provider.configureVerified(profile: scope.profile, region: scope.region, paths: scope.paths)
        _ = try await provider.cloudWatchClient(scope: scope)
        _ = try await provider.cloudWatchLogsClient(scope: scope)
        await provider.configure(profile: nil, region: scope.region, paths: scope.paths)
        await assertRejected(provider, scope: scope, expected: .notConfigured)
        await provider.shutdown()
    }

    func testScopedMonitoringFactoriesRejectProfileAccountRoleRegionAndBothPaths() async throws {
        let provider = AWSServiceProvider.testProvider()
        let scope = makeScope()
        try await provider.configureVerified(profile: scope.profile, region: scope.region, paths: scope.paths)
        for changed in [
            makeScope(profileName: "other"),
            makeScope(account: "444455556666", arn: "arn:aws:iam::444455556666:user/test"),
            makeScope(arn: "arn:aws:iam::111122223333:role/OtherRole"),
            makeScope(region: "eu-west-1"),
            makeScope(paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/example/other-config"])),
            makeScope(paths: AWSConfigurationPaths(environment: ["AWS_SHARED_CREDENTIALS_FILE": "/example/other-credentials"]))
        ] {
            await assertRejected(provider, scope: changed, expected: .identityChanged)
        }
        // Rejected lookups do not contaminate the verified client or its scope.
        let metrics = try await provider.cloudWatchClient(scope: scope)
        let logs = try await provider.cloudWatchLogsClient(scope: scope)
        XCTAssertTrue(metrics.client === logs.client)
        await provider.shutdown()
    }

    func testScopedMonitoringFactoriesRejectInvalidIdentityAndPartitionBeforeClientCreation() async throws {
        let provider = AWSServiceProvider.testProvider()
        let scope = makeScope()
        try await provider.configureVerified(profile: scope.profile, region: scope.region, paths: scope.paths)
        for invalid in [makeScope(account: "invalid"), makeScope(region: "invalid"), makeScope(region: "cn-north-1"),
                        makeScope(arn: "arn:aws:iam::444455556666:user/test")] {
            XCTAssertFalse(invalid.isValid)
            await assertRejected(provider, scope: invalid, expected: .identityChanged)
        }
        await provider.shutdown()
    }

    func testScopedMonitoringFactoriesShareBoundClientAndSelectedRegion() async throws {
        let provider = AWSServiceProvider.testProvider()
        let scope = makeScope(region: "ap-southeast-1")
        try await provider.configureVerified(profile: scope.profile, region: scope.region, paths: scope.paths)
        let metrics = try await provider.cloudWatchClient(scope: scope)
        let logs = try await provider.cloudWatchLogsClient(scope: scope)
        let rds = try await provider.rdsClient(scope: scope)
        XCTAssertTrue(metrics.client === logs.client)
        XCTAssertTrue(metrics.client === rds.client)
        XCTAssertEqual(metrics.config.region.rawValue, scope.region)
        XCTAssertEqual(logs.config.region.rawValue, scope.region)
        await provider.shutdown()
    }

    func testScopedMonitoringFactoriesFollowRegionAndRejectPreviousRegion() async throws {
        let provider = AWSServiceProvider.testProvider()
        let firstScope = makeScope()
        let nextScope = makeScope(region: "eu-west-1")
        try await provider.configureVerified(profile: firstScope.profile, region: firstScope.region, paths: firstScope.paths)
        let first = try await provider.cloudWatchClient(scope: firstScope)
        try await provider.configureVerified(profile: nextScope.profile, region: nextScope.region, paths: nextScope.paths)
        let metrics = try await provider.cloudWatchClient(scope: nextScope)
        let logs = try await provider.cloudWatchLogsClient(scope: nextScope)
        XCTAssertTrue(first.client === metrics.client)
        XCTAssertTrue(metrics.client === logs.client)
        XCTAssertEqual(metrics.config.region.rawValue, "eu-west-1")
        XCTAssertEqual(logs.config.region.rawValue, "eu-west-1")
        await assertRejected(provider, scope: firstScope, expected: .identityChanged)
        await provider.shutdown()
    }

    func testScopedMonitoringFactoriesAcceptSameStableRoleWithDifferentSTSSession() async throws {
        let provider = AWSServiceProvider.testProvider(identity: .init(account: "111122223333",
            arn: "arn:aws:sts::111122223333:assumed-role/ReadOnly/current-session", userID: "fixture"))
        let scope = makeScope(arn: "arn:aws:sts::111122223333:assumed-role/ReadOnly/earlier-session")
        try await provider.configureVerified(profile: scope.profile, region: scope.region, paths: scope.paths)
        let metrics = try await provider.cloudWatchClient(scope: scope)
        let logs = try await provider.cloudWatchLogsClient(scope: scope)
        XCTAssertTrue(metrics.client === logs.client)
        await assertRejected(provider, scope: makeScope(arn: "arn:aws:sts::111122223333:assumed-role/WriteRole/current-session"),
                             expected: .identityChanged)
        await provider.shutdown()
    }

    func testScopedMonitoringFactoriesRejectOldConfigAfterConfigurationSourceChanges() async throws {
        let provider = AWSServiceProvider.testProvider()
        let oldScope = makeScope()
        let next = makeScope(paths: AWSConfigurationPaths(environment: [
            "AWS_CONFIG_FILE": "/example/replacement-config", "AWS_SHARED_CREDENTIALS_FILE": "/example/replacement-credentials"
        ]))
        try await provider.configureVerified(profile: oldScope.profile, region: oldScope.region, paths: oldScope.paths)
        let first = try await provider.cloudWatchClient(scope: oldScope)
        try await provider.configureVerified(profile: next.profile, region: next.region, paths: next.paths)
        await assertRejected(provider, scope: oldScope, expected: .identityChanged)
        let metrics = try await provider.cloudWatchClient(scope: next)
        let logs = try await provider.cloudWatchLogsClient(scope: next)
        XCTAssertFalse(first.client === metrics.client)
        XCTAssertTrue(metrics.client === logs.client)
        await provider.shutdown()
    }

    private func assertRejected(_ provider: AWSServiceProvider, scope: MonitoringScope, expected: AWSServiceError,
                                file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await provider.cloudWatchClient(scope: scope)
            XCTFail("CloudWatch must reject a stale or unverified scope", file: file, line: line)
        } catch { XCTAssertEqual(error as? AWSServiceError, expected, file: file, line: line) }
        do {
            _ = try await provider.cloudWatchLogsClient(scope: scope)
            XCTFail("CloudWatch Logs must reject a stale or unverified scope", file: file, line: line)
        } catch { XCTAssertEqual(error as? AWSServiceError, expected, file: file, line: line) }
    }

    private func makeScope(profileName: String = "monitoring-test", account: String = "111122223333", region: String = "us-east-1",
                           arn: String = "arn:aws:iam::111122223333:user/test",
                           paths: AWSConfigurationPaths = AWSConfigurationPaths(environment: [:])) -> MonitoringScope {
        // Keep the profile's configured region stable: only the selected resource region changes.
        let profile = AWSProfile(name: profileName, region: "us-east-1", ssoStartURL: nil, ssoRegion: nil,
                                 ssoAccountID: nil, ssoRoleName: nil)
        return MonitoringScope(profile: profile, identity: .init(account: account, arn: arn, userID: "fixture"),
                               region: region, paths: paths)
    }
}
