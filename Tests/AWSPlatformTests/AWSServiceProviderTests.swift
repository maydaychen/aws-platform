import XCTest
@testable import AWSPlatform

final class AWSServiceProviderTests: XCTestCase {
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
