import SotoCore
@testable import AWSPlatform

extension AWSServiceProvider {
    static func testProvider(identity: AWSIdentity = .init(account: "111122223333",
        arn: "arn:aws:iam::111122223333:user/test", userID: "test")) -> AWSServiceProvider {
        AWSServiceProvider(credentialFactory: { _, _ in
            .static(accessKeyId: "offline-test-access", secretAccessKey: "offline-test-secret")
        }, identityVerifier: { _, _ in identity })
    }

    func configureVerified(profile: AWSProfile?, region: String, forceRefresh: Bool = false,
                           paths: AWSConfigurationPaths = AWSConfigurationPaths()) async throws {
        await configure(profile: profile, region: region, forceRefresh: forceRefresh, paths: paths)
        if profile != nil { _ = try await validateIdentity() }
    }
}

func providerTestScope(_ profile: AWSProfile, paths: AWSConfigurationPaths = AWSConfigurationPaths()) -> MonitoringScope {
    MonitoringScope(profile: profile, identity: .init(account: "111122223333",
        arn: "arn:aws:iam::111122223333:user/test", userID: "test"), region: "us-east-1", paths: paths)
}
