import SotoCore
import XCTest
@testable import AWSPlatform

final class AWSServiceProviderTests: XCTestCase {
    private let testIdentity = AWSIdentity(account: "111122223333", arn: "arn:aws:iam::111122223333:user/test", userID: "test")

    func testRevalidatingSameProfileForAnotherAccountOrRoleRejectsAllFourServiceRequests() async throws {
        let profile = makeProfile(name: "reused")
        let initial = Self.roleIdentity(role: "ReadOnly", session: "first")
        for replacement in [Self.roleIdentity(account: "222233334444", role: "ReadOnly", session: "second"),
                            Self.roleIdentity(role: "OtherRole", session: "second")] {
            let identity = ScopeIdentityProbe(initial)
            let transport = OfflineAWSHTTPClient()
            let provider = AWSServiceProvider(credentialFactory: { _, _ in
                .static(accessKeyId: "offline-access", secretAccessKey: "offline-secret")
            }, businessClientFactory: {
                AWSClient(credentialProvider: $0, retryPolicy: .noRetry, httpClient: transport)
            }, identityVerifier: { _, _ in await identity.current })
            let stale = MonitoringScope(profile: profile, identity: initial, region: profile.region)
            try await provider.configureVerified(profile: profile, region: stale.region)
            await identity.replace(with: replacement)
            try await provider.configureVerified(profile: profile, region: stale.region, forceRefresh: true)

            let cost = AWSCostService(provider: provider)
            let end = Date(timeIntervalSince1970: 1_800_000_000)
            let range = CostDateRange(start: end.addingTimeInterval(-86_400), end: end)
            do {
                _ = try await cost.load(scope: .init(profile: profile, identity: initial, paths: stale.paths),
                                        query: .init(range: range, region: nil, referenceDate: end))
                XCTFail("The stale Cost scope must be rejected")
            } catch { XCTAssertEqual((error as? CostError)?.localizedDescription, CostError.invalidIdentity.localizedDescription) }
            await assertRegionalRequestsRejected(provider, scope: stale, identity: initial)
            let sent = await transport.requestCount
            XCTAssertEqual(sent, 0)
            await provider.shutdown()
        }
    }

    func testValidSessionNameChangeWorksAndOldRegionRequestsDoNotReachTransport() async throws {
        let profile = makeProfile(name: "rotating")
        let initial = Self.roleIdentity(role: "ReadOnly", session: "first")
        let renewed = Self.roleIdentity(role: "ReadOnly", session: "second")
        let transport = OfflineAWSHTTPClient()
        let provider = AWSServiceProvider.testProvider(identity: renewed, transport: transport)
        let scope = MonitoringScope(profile: profile, identity: initial, region: profile.region)
        try await provider.configureVerified(profile: profile, region: scope.region)
        let costScope = CostScope(profile: profile, identity: initial, paths: scope.paths)
        let firstCost = try await provider.costExplorerClient(scope: costScope, partition: .aws)
        _ = try await provider.cloudWatchClient(scope: AlarmScope(profile: profile, identity: initial, region: scope.region))
        _ = try await provider.snsClient(scope: .init(profile: profile, identity: initial, region: scope.region))
        let page = try await AWSLogsService(provider: provider).load(query: logQuery(scope), cursor: nil)
        XCTAssertTrue(page.events.isEmpty)

        try await provider.configureVerified(profile: profile, region: "us-west-2")
        await assertRegionalRequestsRejected(provider, scope: scope, identity: initial)
        let nextCost = try await provider.costExplorerClient(scope: costScope, partition: .aws)
        XCTAssertTrue(nextCost.client === firstCost.client)
        let sent = await transport.requestCount
        XCTAssertEqual(sent, 1, "Only the valid Lambda Logs request should have reached HTTP transport")
        await provider.shutdown()
    }

    private func assertRegionalRequestsRejected(_ provider: AWSServiceProvider, scope: MonitoringScope, identity: AWSIdentity) async {
        do {
            _ = try await AWSAlarmService(provider: provider).loadAlarms(scope: .init(
                profile: scope.profile, identity: identity, region: scope.region, paths: scope.paths))
            XCTFail("The stale Alarm scope must be rejected")
        } catch { XCTAssertEqual((error as? AlarmError)?.localizedDescription, AlarmError.invalidScope.localizedDescription) }
        do {
            _ = try await AWSSNSService(provider: provider).loadTopics(scope: .init(
                profile: scope.profile, identity: identity, region: scope.region, paths: scope.paths))
            XCTFail("The stale SNS scope must be rejected")
        } catch { XCTAssertEqual((error as? SNSError)?.localizedDescription, SNSError.invalidScope.localizedDescription) }
        do {
            _ = try await AWSLogsService(provider: provider).load(query: logQuery(scope), cursor: nil)
            XCTFail("The stale Lambda Logs scope must be rejected")
        } catch { XCTAssertEqual(error as? LambdaLogsError, .invalidQuery) }
    }

    private func logQuery(_ scope: MonitoringScope) -> LambdaLogQuery {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        return LambdaLogQuery(scope: scope, context: .init(functionName: "handler", configuredLogGroup: nil),
                              startTime: end.addingTimeInterval(-3_600), endTime: end, filterPattern: "")
    }

    private static func roleIdentity(account: String = "111122223333", role: String, session: String) -> AWSIdentity {
        .init(account: account, arn: "arn:aws:sts::\(account):assumed-role/\(role)/\(session)", userID: "AROAoffline:\(session)")
    }

    func testHealthPreservesGlobalClientWhenResourceRegionChanges() async throws {
        let provider = AWSServiceProvider.testProvider(identity: .init(account: "111122223333",
            arn: "arn:aws:sts::111122223333:assumed-role/ReadOnly/session", userID: "test"))
        let profile = makeProfile(name: "health-profile")
        let paths = AWSConfigurationPaths(environment: [:])
        let scope = HealthScope(profile: profile, identity: AWSIdentity(
            account: "111122223333", arn: "arn:aws:sts::111122223333:assumed-role/ReadOnly/session", userID: "test"
        ), paths: paths)
        try await provider.configureVerified(profile: profile, region: "ap-southeast-1", paths: paths)
        let first = try await provider.healthClient(scope: scope)
        try await provider.configureVerified(profile: profile, region: "eu-west-1", paths: paths)
        let second = try await provider.healthClient(scope: scope)
        XCTAssertTrue(first.client === second.client)
        XCTAssertEqual(second.config.region.rawValue, "us-east-1")
        XCTAssertEqual(second.config.endpoint, "https://health.us-east-1.amazonaws.com")
        try await provider.configureVerified(profile: profile, region: "eu-west-1", forceRefresh: true, paths: paths)
        let refreshed = try await provider.healthClient(scope: scope)
        XCTAssertFalse(second.client === refreshed.client)
        await provider.shutdown()
    }

    func testHealthRejectsDifferentProfilePathsAndClearedClient() async throws {
        let provider = AWSServiceProvider.testProvider()
        let profile = makeProfile(name: "health-profile")
        let paths = AWSConfigurationPaths(environment: [:])
        let identity = AWSIdentity(account: "111122223333", arn: "arn:aws:iam::111122223333:user/test", userID: "test")
        try await provider.configureVerified(profile: profile, region: "us-west-2", paths: paths)
        let staleScopes = [
            HealthScope(profile: makeProfile(name: "other"), identity: identity, paths: paths),
            HealthScope(profile: profile, identity: identity, paths: AWSConfigurationPaths(environment: [
                "AWS_CONFIG_FILE": "/example/different-config"
            ]))
        ]
        for scope in staleScopes {
            do {
                _ = try await provider.healthClient(scope: scope)
                XCTFail("Stale Health scope must not borrow another profile's client")
            } catch { XCTAssertEqual(error as? HealthError, .invalidScope) }
        }
        try await provider.configureVerified(profile: nil, region: "us-west-2", paths: paths)
        do {
            _ = try await provider.healthClient(scope: HealthScope(profile: profile, identity: identity, paths: paths))
            XCTFail("A cleared profile must not have a Health client")
        } catch { XCTAssertEqual(error as? HealthError, .invalidScope) }
    }

    func testHealthEndpointsUseIdentityPartitionAndMatchingSigningRegion() async throws {
        let profile = makeProfile(name: "health-profile")
        let paths = AWSConfigurationPaths(environment: [:])
        for (partition, resourceRegion, signingRegion, endpoint) in [
            ("aws", "eu-west-1", "us-east-1", "https://health.us-east-1.amazonaws.com"),
            ("aws-cn", "cn-north-1", "cn-northwest-1", "https://health.cn-northwest-1.amazonaws.com.cn"),
            ("aws-us-gov", "us-gov-east-1", "us-gov-west-1", "https://health.us-gov-west-1.amazonaws.com")
        ] {
            let provider = AWSServiceProvider.testProvider(identity: .init(account: "111122223333",
                arn: "arn:\(partition):iam::111122223333:user/test", userID: "test"))
            let scope = HealthScope(profile: profile, identity: AWSIdentity(
                account: "111122223333", arn: "arn:\(partition):iam::111122223333:user/test", userID: "test"
            ), paths: paths)
            try await provider.configureVerified(profile: profile, region: resourceRegion, paths: paths)
            let client = try await provider.healthClient(scope: scope)
            XCTAssertEqual(client.config.region.rawValue, signingRegion)
            XCTAssertEqual(client.config.endpoint, endpoint)
            await provider.shutdown()
        }
    }

    func testSNSFollowsResourceRegionAndPreservesSharedCostClient() async throws {
        let provider = AWSServiceProvider.testProvider()
        let profile = makeProfile(name: "sns-profile")
        let paths = AWSConfigurationPaths(environment: [:])
        try await provider.configureVerified(profile: profile, region: "ap-southeast-1", paths: paths)
        let first = try await provider.snsClient(scope: SNSScope(profile: profile, identity: testIdentity, region: "ap-southeast-1", paths: paths))
        let cost = try await provider.costExplorerClient(scope: .init(profile: profile, identity: testIdentity, paths: paths), partition: .aws)
        XCTAssertEqual(first.config.region.rawValue, "ap-southeast-1")
        try await provider.configureVerified(profile: profile, region: "eu-west-1", paths: paths)
        let next = try await provider.snsClient(scope: SNSScope(profile: profile, identity: testIdentity, region: "eu-west-1", paths: paths))
        XCTAssertEqual(next.config.region.rawValue, "eu-west-1")
        XCTAssertTrue(next.client === first.client)
        XCTAssertTrue(next.client === cost.client)
        await provider.shutdown()
    }

    func testSNSRejectsStaleProfilePathsRegionAndClearedScope() async throws {
        let provider = AWSServiceProvider.testProvider()
        let profile = makeProfile(name: "sns-profile")
        let paths = AWSConfigurationPaths(environment: [:])
        let otherPaths = AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/example/other-config"])
        try await provider.configureVerified(profile: profile, region: "us-east-1", paths: paths)
        for (requestedProfile, requestedPaths, region) in [
            (makeProfile(name: "other"), paths, "us-east-1"),
            (profile, otherPaths, "us-east-1"),
            (profile, paths, "eu-west-1")
        ] {
            do {
                _ = try await provider.snsClient(scope: SNSScope(profile: requestedProfile, identity: testIdentity, region: region, paths: requestedPaths))
                XCTFail("A stale request must not borrow another scope's client")
            } catch { XCTAssertTrue(error is SNSError) }
        }
        await provider.shutdown()
        do {
            _ = try await provider.snsClient(scope: SNSScope(profile: profile, identity: testIdentity, region: "us-east-1", paths: paths))
            XCTFail("Cleared profile must have no client")
        } catch { XCTAssertTrue(error is SNSError) }
    }

    func testCloudWatchUsesSelectedRegionWithoutReplacingCostClient() async throws {
        let provider = AWSServiceProvider.testProvider()
        let profile = makeProfile(name: "alarm-profile")
        let paths = AWSConfigurationPaths(environment: [:])
        try await provider.configureVerified(profile: profile, region: "ap-southeast-1", paths: paths)
        let first = try await provider.cloudWatchClient(scope: AlarmScope(profile: profile, identity: testIdentity, region: "ap-southeast-1", paths: paths))
        let cost = try await provider.costExplorerClient(scope: .init(profile: profile, identity: testIdentity, paths: paths), partition: .aws)
        XCTAssertEqual(first.config.region.rawValue, "ap-southeast-1")
        try await provider.configureVerified(profile: profile, region: "eu-west-1", paths: paths)
        let next = try await provider.cloudWatchClient(scope: AlarmScope(profile: profile, identity: testIdentity, region: "eu-west-1", paths: paths))
        XCTAssertEqual(next.config.region.rawValue, "eu-west-1")
        XCTAssertTrue(next.client === first.client)
        XCTAssertTrue(next.client === cost.client)
        await provider.shutdown()
    }

    func testCloudWatchRejectsStaleProfilePathsRegionAndClearedScope() async throws {
        let provider = AWSServiceProvider.testProvider()
        let profile = makeProfile(name: "alarm-profile")
        let paths = AWSConfigurationPaths(environment: [:])
        let otherPaths = AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/example/other-config"])
        try await provider.configureVerified(profile: profile, region: "us-east-1", paths: paths)
        for (requestedProfile, requestedPaths, region) in [
            (makeProfile(name: "other"), paths, "us-east-1"),
            (profile, otherPaths, "us-east-1"),
            (profile, paths, "eu-west-1")
        ] {
            do {
                _ = try await provider.cloudWatchClient(scope: AlarmScope(profile: requestedProfile, identity: testIdentity, region: region, paths: requestedPaths))
                XCTFail("A stale request must not borrow another scope's client")
            } catch { XCTAssertTrue(error is AlarmError) }
        }
        await provider.shutdown()
        do {
            _ = try await provider.cloudWatchClient(scope: AlarmScope(profile: profile, identity: testIdentity, region: "us-east-1", paths: paths))
            XCTFail("Cleared profile must have no client")
        } catch { XCTAssertTrue(error is AlarmError) }
    }

    func testResourceRegionChangePreservesCostClientButChangesResourceRegion() async throws {
        let provider = AWSServiceProvider.testProvider()
        let profile = makeProfile(name: "cost-profile")
        let paths = AWSConfigurationPaths(environment: [:])
        try await provider.configureVerified(profile: profile, region: "ap-southeast-1", paths: paths)
        let first = try await provider.costExplorerClient(scope: .init(profile: profile, identity: testIdentity, paths: paths), partition: .aws)
        try await provider.configureVerified(profile: profile, region: "eu-west-1", paths: paths)
        let second = try await provider.costExplorerClient(scope: .init(profile: profile, identity: testIdentity, paths: paths), partition: .aws)
        XCTAssertTrue(first.client === second.client)
        XCTAssertEqual(second.config.region.rawValue, "us-east-1")
        let region = await provider.currentRegion
        XCTAssertEqual(region, "eu-west-1")
        await provider.shutdown()
    }

    func testCostClientRejectsDifferentProfileOrConfigurationSource() async throws {
        let provider = AWSServiceProvider.testProvider()
        let profile = makeProfile(name: "cost-profile")
        let paths = AWSConfigurationPaths(environment: [:])
        try await provider.configureVerified(profile: profile, region: "us-east-1", paths: paths)
        do {
            _ = try await provider.costExplorerClient(scope: .init(profile: makeProfile(name: "other"), identity: testIdentity, paths: paths), partition: .aws)
            XCTFail("A different profile must not reuse this client's credentials")
        } catch { XCTAssertTrue(error is CostError) }
        do {
            let otherPaths = AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/example/other-config"])
            _ = try await provider.costExplorerClient(scope: .init(profile: profile, identity: testIdentity, paths: otherPaths), partition: .aws)
            XCTFail("A different configuration source must not reuse this client's credentials")
        } catch { XCTAssertTrue(error is CostError) }
        await provider.shutdown()
    }

    func testSameProfileNameWithChangedConfigurationReplacesClient() async throws {
        let provider = AWSServiceProvider.testProvider()
        let firstProfile = makeProfile(name: "changed")
        try await provider.configureVerified(profile: firstProfile, region: "us-east-1")
        let first = try await provider.ec2Client(scope: providerTestScope(firstProfile)).client
        let changed = AWSProfile(name: "changed", region: "eu-west-1", ssoStartURL: nil,
                                 ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil)
        try await provider.configureVerified(profile: changed, region: "us-east-1")
        let second = try await provider.ec2Client(scope: providerTestScope(changed)).client
        XCTAssertFalse(first === second)
        await provider.shutdown()
    }

    func testForcedRetryReplacesClientForSameProfileAndRegion() async throws {
        let provider = AWSServiceProvider.testProvider()
        let profile = makeProfile(name: "test-retry")
        try await provider.configureVerified(profile: profile, region: "us-east-1")
        let first = try await provider.ec2Client(scope: providerTestScope(profile)).client
        try await provider.configureVerified(profile: profile, region: "us-east-1")
        let reused = try await provider.ec2Client(scope: providerTestScope(profile)).client
        XCTAssertTrue(first === reused)
        try await provider.configureVerified(profile: profile, region: "us-east-1", forceRefresh: true)
        let replaced = try await provider.ec2Client(scope: providerTestScope(profile)).client
        XCTAssertFalse(first === replaced)
        await provider.shutdown()
    }

    func testRapidReconfigurationShutsDownEveryReplacedClient() async throws {
        let provider = AWSServiceProvider.testProvider()
        let profiles = [
            makeProfile(name: "first"),
            makeProfile(name: "second"),
            makeProfile(name: "third")
        ]

        await provider.configure(profile: profiles[0], region: "us-east-1")

        for _ in 0..<10 {
            let first = Task {
                await provider.configure(profile: profiles[1], region: "us-west-2")
            }
            await Task.yield()
            let second = Task {
                await provider.configure(profile: profiles[2], region: "eu-west-1")
            }
            await first.value
            await second.value
        }

        await provider.shutdown()
    }

    func testConfiguredRoleMismatchPermanentlyRejectsBindingUntilExplicitRefresh() async throws {
        let probe = ConfiguredRoleIdentityProbe()
        let provider = AWSServiceProvider(credentialFactory: { _, _ in
            .static(accessKeyId: "offline-access", secretAccessKey: "offline-secret")
        }, identityVerifier: { _, _ in await probe.verify() })
        let profile = AWSProfile(name: "role-profile", region: "us-east-1", ssoStartURL: nil,
            ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil,
            roleARN: "arn:aws:iam::111122223333:role/ReadOnly", sourceProfile: "base")
        await provider.configure(profile: profile, region: "us-east-1")
        do { _ = try await provider.validateIdentity(); XCTFail("A different configured role must be rejected") }
        catch { XCTAssertEqual(error as? AWSServiceError, .identityChanged) }
        await probe.restoreExpectedRole()
        do { _ = try await provider.validateIdentity(); XCTFail("A mismatched generation must remain invalid") }
        catch { XCTAssertEqual(error as? AWSServiceError, .identityChanged) }
        let rejectedCalls = await probe.calls
        XCTAssertEqual(rejectedCalls, 1)
        await provider.configure(profile: profile, region: "us-east-1", forceRefresh: true)
        let identity = try await provider.validateIdentity()
        XCTAssertEqual(identity.arn, "arn:aws:sts::111122223333:assumed-role/ReadOnly/offline")
        await provider.shutdown()
    }

    func testRecreatedSameNameRoleWithDifferentUserIDRejectsStaleScopeAcrossServices() async throws {
        let profile = makeProfile(name: "recreated-role")
        let initial = AWSIdentity(account: "111122223333", arn: "arn:aws:sts::111122223333:assumed-role/ReadOnly/first",
                                  userID: "AROAfirst:first")
        let recreated = AWSIdentity(account: "111122223333", arn: "arn:aws:sts::111122223333:assumed-role/ReadOnly/second",
                                    userID: "AROAsecond:second")
        let probe = ScopeIdentityProbe(initial)
        let transport = OfflineAWSHTTPClient()
        let provider = AWSServiceProvider(credentialFactory: { _, _ in
            .static(accessKeyId: "offline-access", secretAccessKey: "offline-secret")
        }, businessClientFactory: {
            AWSClient(credentialProvider: $0, retryPolicy: .noRetry, httpClient: transport)
        }, identityVerifier: { _, _ in await probe.current })

        let staleMonitoring = MonitoringScope(profile: profile, identity: initial, region: profile.region)
        let staleCost = CostScope(profile: profile, identity: initial, paths: staleMonitoring.paths)
        let staleHealth = HealthScope(profile: profile, identity: initial, paths: staleMonitoring.paths)
        let staleRoute53 = Route53Scope(profile: profile, identity: initial, paths: staleMonitoring.paths)
        let staleAlarm = AlarmScope(profile: profile, identity: initial, region: profile.region, paths: staleMonitoring.paths)
        let staleSNS = SNSScope(profile: profile, identity: initial, region: profile.region, paths: staleMonitoring.paths)

        try await provider.configureVerified(profile: profile, region: staleMonitoring.region)
        await probe.replace(with: recreated)
        try await provider.configureVerified(profile: profile, region: staleMonitoring.region, forceRefresh: true)

        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let range = CostDateRange(start: end.addingTimeInterval(-86_400), end: end)
        do { _ = try await AWSCostService(provider: provider).load(scope: staleCost, query: .init(range: range, region: nil, referenceDate: end)); XCTFail("Stale Cost scope must be rejected") }
        catch { XCTAssertEqual((error as? CostError)?.localizedDescription, CostError.invalidIdentity.localizedDescription) }
        do { _ = try await provider.healthClient(scope: staleHealth); XCTFail("Stale Health scope must be rejected") }
        catch { XCTAssertEqual(error as? HealthError, .invalidScope) }
        do { _ = try await provider.route53Client(scope: staleRoute53); XCTFail("Stale Route53 scope must be rejected") }
        catch { XCTAssertEqual(error as? Route53Error, .invalidScope) }
        do { _ = try await AWSAlarmService(provider: provider).loadAlarms(scope: staleAlarm); XCTFail("Stale Alarm scope must be rejected") }
        catch { XCTAssertEqual((error as? AlarmError)?.localizedDescription, AlarmError.invalidScope.localizedDescription) }
        do { _ = try await AWSSNSService(provider: provider).loadTopics(scope: staleSNS); XCTFail("Stale SNS scope must be rejected") }
        catch { XCTAssertEqual((error as? SNSError)?.localizedDescription, SNSError.invalidScope.localizedDescription) }
        do { _ = try await provider.ec2Client(scope: staleMonitoring); XCTFail("Stale EC2 scope must be rejected") }
        catch { XCTAssertEqual(error as? AWSServiceError, .identityChanged) }
        do { _ = try await provider.s3Client(scope: staleMonitoring); XCTFail("Stale S3 scope must be rejected") }
        catch { XCTAssertEqual(error as? AWSServiceError, .identityChanged) }
        do { _ = try await provider.elbClient(scope: staleMonitoring); XCTFail("Stale ELB scope must be rejected") }
        catch { XCTAssertEqual(error as? ELBError, .invalidScope) }
        do { _ = try await AWSLogsService(provider: provider).load(query: logQuery(staleMonitoring), cursor: nil); XCTFail("Stale Logs scope must be rejected") }
        catch { XCTAssertEqual(error as? LambdaLogsError, .invalidQuery) }

        let sent = await transport.requestCount
        XCTAssertEqual(sent, 0)
        await provider.shutdown()
    }

    private func makeProfile(name: String) -> AWSProfile {
        AWSProfile(
            name: name,
            region: "us-east-1",
            ssoStartURL: nil,
            ssoRegion: nil,
            ssoAccountID: nil,
            ssoRoleName: nil
        )
    }
}

private actor ConfiguredRoleIdentityProbe {
    var calls = 0
    private var role = "Other"
    func restoreExpectedRole() { role = "ReadOnly" }
    func verify() -> AWSIdentity {
        calls += 1
        return .init(account: "111122223333", arn: "arn:aws:sts::111122223333:assumed-role/\(role)/offline",
                     userID: "AROAoffline:offline")
    }
}

private actor ScopeIdentityProbe {
    private(set) var current: AWSIdentity
    init(_ identity: AWSIdentity) { current = identity }
    func replace(with identity: AWSIdentity) { current = identity }
}
