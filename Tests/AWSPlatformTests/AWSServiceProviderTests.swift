import XCTest
@testable import AWSPlatform

final class AWSServiceProviderTests: XCTestCase {
    func testHealthPreservesGlobalClientWhenResourceRegionChanges() async throws {
        let provider = AWSServiceProvider()
        let profile = makeProfile(name: "health-profile")
        let paths = AWSConfigurationPaths(environment: [:])
        let scope = HealthScope(profile: profile, identity: AWSIdentity(
            account: "111122223333", arn: "arn:aws:sts::111122223333:assumed-role/ReadOnly/session", userID: "test"
        ), paths: paths)
        await provider.configure(profile: profile, region: "ap-southeast-1", paths: paths)
        let first = try await provider.healthClient(scope: scope)
        await provider.configure(profile: profile, region: "eu-west-1", paths: paths)
        let second = try await provider.healthClient(scope: scope)
        XCTAssertTrue(first.client === second.client)
        XCTAssertEqual(second.config.region.rawValue, "us-east-1")
        XCTAssertEqual(second.config.endpoint, "https://health.us-east-1.amazonaws.com")
        await provider.configure(profile: profile, region: "eu-west-1", forceRefresh: true, paths: paths)
        let refreshed = try await provider.healthClient(scope: scope)
        XCTAssertFalse(second.client === refreshed.client)
        await provider.shutdown()
    }

    func testHealthRejectsDifferentProfilePathsAndClearedClient() async throws {
        let provider = AWSServiceProvider()
        let profile = makeProfile(name: "health-profile")
        let paths = AWSConfigurationPaths(environment: [:])
        let identity = AWSIdentity(account: "111122223333", arn: "arn:aws:iam::111122223333:user/test", userID: "test")
        await provider.configure(profile: profile, region: "us-west-2", paths: paths)
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
        await provider.configure(profile: nil, region: "us-west-2", paths: paths)
        do {
            _ = try await provider.healthClient(scope: HealthScope(profile: profile, identity: identity, paths: paths))
            XCTFail("A cleared profile must not have a Health client")
        } catch { XCTAssertEqual(error as? HealthError, .invalidScope) }
    }

    func testHealthEndpointsUseIdentityPartitionAndMatchingSigningRegion() async throws {
        let provider = AWSServiceProvider()
        let profile = makeProfile(name: "health-profile")
        let paths = AWSConfigurationPaths(environment: [:])
        for (partition, resourceRegion, signingRegion, endpoint) in [
            ("aws", "eu-west-1", "us-east-1", "https://health.us-east-1.amazonaws.com"),
            ("aws-cn", "cn-north-1", "cn-northwest-1", "https://health.cn-northwest-1.amazonaws.com.cn"),
            ("aws-us-gov", "us-gov-east-1", "us-gov-west-1", "https://health.us-gov-west-1.amazonaws.com")
        ] {
            let scope = HealthScope(profile: profile, identity: AWSIdentity(
                account: "111122223333", arn: "arn:\(partition):iam::111122223333:user/test", userID: "test"
            ), paths: paths)
            await provider.configure(profile: profile, region: resourceRegion, paths: paths)
            let client = try await provider.healthClient(scope: scope)
            XCTAssertEqual(client.config.region.rawValue, signingRegion)
            XCTAssertEqual(client.config.endpoint, endpoint)
        }
        await provider.shutdown()
    }

    func testSNSFollowsResourceRegionAndPreservesSharedCostClient() async throws {
        let provider = AWSServiceProvider()
        let profile = makeProfile(name: "sns-profile")
        let paths = AWSConfigurationPaths(environment: [:])
        await provider.configure(profile: profile, region: "ap-southeast-1", paths: paths)
        let first = try await provider.snsClient(profile: profile, paths: paths, region: "ap-southeast-1")
        let cost = try await provider.costExplorerClient(profile: profile, paths: paths, partition: .aws)
        XCTAssertEqual(first.config.region.rawValue, "ap-southeast-1")
        await provider.configure(profile: profile, region: "eu-west-1", paths: paths)
        let next = try await provider.snsClient(profile: profile, paths: paths, region: "eu-west-1")
        XCTAssertEqual(next.config.region.rawValue, "eu-west-1")
        XCTAssertTrue(next.client === first.client)
        XCTAssertTrue(next.client === cost.client)
        await provider.shutdown()
    }

    func testSNSRejectsStaleProfilePathsRegionAndClearedScope() async throws {
        let provider = AWSServiceProvider()
        let profile = makeProfile(name: "sns-profile")
        let paths = AWSConfigurationPaths(environment: [:])
        let otherPaths = AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/example/other-config"])
        await provider.configure(profile: profile, region: "us-east-1", paths: paths)
        for (requestedProfile, requestedPaths, region) in [
            (makeProfile(name: "other"), paths, "us-east-1"),
            (profile, otherPaths, "us-east-1"),
            (profile, paths, "eu-west-1")
        ] {
            do {
                _ = try await provider.snsClient(profile: requestedProfile, paths: requestedPaths, region: region)
                XCTFail("A stale request must not borrow another scope's client")
            } catch { XCTAssertTrue(error is SNSError) }
        }
        await provider.shutdown()
        do {
            _ = try await provider.snsClient(profile: profile, paths: paths, region: "us-east-1")
            XCTFail("Cleared profile must have no client")
        } catch { XCTAssertTrue(error is SNSError) }
    }

    func testCloudWatchUsesSelectedRegionWithoutReplacingCostClient() async throws {
        let provider = AWSServiceProvider()
        let profile = makeProfile(name: "alarm-profile")
        let paths = AWSConfigurationPaths(environment: [:])
        await provider.configure(profile: profile, region: "ap-southeast-1", paths: paths)
        let first = try await provider.cloudWatchClient(profile: profile, paths: paths, region: "ap-southeast-1")
        let cost = try await provider.costExplorerClient(profile: profile, paths: paths, partition: .aws)
        XCTAssertEqual(first.config.region.rawValue, "ap-southeast-1")
        await provider.configure(profile: profile, region: "eu-west-1", paths: paths)
        let next = try await provider.cloudWatchClient(profile: profile, paths: paths, region: "eu-west-1")
        XCTAssertEqual(next.config.region.rawValue, "eu-west-1")
        XCTAssertTrue(next.client === first.client)
        XCTAssertTrue(next.client === cost.client)
        await provider.shutdown()
    }

    func testCloudWatchRejectsStaleProfilePathsRegionAndClearedScope() async throws {
        let provider = AWSServiceProvider()
        let profile = makeProfile(name: "alarm-profile")
        let paths = AWSConfigurationPaths(environment: [:])
        let otherPaths = AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/example/other-config"])
        await provider.configure(profile: profile, region: "us-east-1", paths: paths)
        for (requestedProfile, requestedPaths, region) in [
            (makeProfile(name: "other"), paths, "us-east-1"),
            (profile, otherPaths, "us-east-1"),
            (profile, paths, "eu-west-1")
        ] {
            do {
                _ = try await provider.cloudWatchClient(profile: requestedProfile, paths: requestedPaths, region: region)
                XCTFail("A stale request must not borrow another scope's client")
            } catch { XCTAssertTrue(error is AlarmError) }
        }
        await provider.shutdown()
        do {
            _ = try await provider.cloudWatchClient(profile: profile, paths: paths, region: "us-east-1")
            XCTFail("Cleared profile must have no client")
        } catch { XCTAssertTrue(error is AlarmError) }
    }

    func testResourceRegionChangePreservesCostClientButChangesResourceRegion() async throws {
        let provider = AWSServiceProvider()
        let profile = makeProfile(name: "cost-profile")
        let paths = AWSConfigurationPaths(environment: [:])
        await provider.configure(profile: profile, region: "ap-southeast-1", paths: paths)
        let first = try await provider.costExplorerClient(profile: profile, paths: paths, partition: .aws)
        await provider.configure(profile: profile, region: "eu-west-1", paths: paths)
        let second = try await provider.costExplorerClient(profile: profile, paths: paths, partition: .aws)
        XCTAssertTrue(first.client === second.client)
        XCTAssertEqual(second.config.region.rawValue, "us-east-1")
        let region = await provider.currentRegion
        XCTAssertEqual(region, "eu-west-1")
        await provider.shutdown()
    }

    func testCostClientRejectsDifferentProfileOrConfigurationSource() async throws {
        let provider = AWSServiceProvider()
        let profile = makeProfile(name: "cost-profile")
        let paths = AWSConfigurationPaths(environment: [:])
        await provider.configure(profile: profile, region: "us-east-1", paths: paths)
        do {
            _ = try await provider.costExplorerClient(profile: makeProfile(name: "other"), paths: paths, partition: .aws)
            XCTFail("A different profile must not reuse this client's credentials")
        } catch { XCTAssertTrue(error is CostError) }
        do {
            let otherPaths = AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/example/other-config"])
            _ = try await provider.costExplorerClient(profile: profile, paths: otherPaths, partition: .aws)
            XCTFail("A different configuration source must not reuse this client's credentials")
        } catch { XCTAssertTrue(error is CostError) }
        await provider.shutdown()
    }

    func testSameProfileNameWithChangedConfigurationReplacesClient() async throws {
        let provider = AWSServiceProvider()
        let firstProfile = makeProfile(name: "changed")
        await provider.configure(profile: firstProfile, region: "us-east-1")
        let first = try await provider.ec2Client().client
        let changed = AWSProfile(name: "changed", region: "eu-west-1", ssoStartURL: nil,
                                 ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil)
        await provider.configure(profile: changed, region: "us-east-1")
        let second = try await provider.ec2Client().client
        XCTAssertFalse(first === second)
        await provider.shutdown()
    }

    func testForcedRetryReplacesClientForSameProfileAndRegion() async throws {
        let provider = AWSServiceProvider()
        let profile = makeProfile(name: "test-retry")
        await provider.configure(profile: profile, region: "us-east-1")
        let first = try await provider.ec2Client().client
        await provider.configure(profile: profile, region: "us-east-1")
        let reused = try await provider.ec2Client().client
        XCTAssertTrue(first === reused)
        await provider.configure(profile: profile, region: "us-east-1", forceRefresh: true)
        let replaced = try await provider.ec2Client().client
        XCTAssertFalse(first === replaced)
        await provider.shutdown()
    }

    func testRapidReconfigurationShutsDownEveryReplacedClient() async {
        let provider = AWSServiceProvider()
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
