import XCTest
@testable import AWSPlatform

final class AWSServiceProviderTests: XCTestCase {
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
