import XCTest
@testable import AWSPlatform

final class AWSServiceProviderTests: XCTestCase {
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
