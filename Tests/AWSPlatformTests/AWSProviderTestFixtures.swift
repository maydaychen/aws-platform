import NIOCore
import SotoCore
@testable import AWSPlatform

extension AWSServiceProvider {
    static func testProvider(identity: AWSIdentity = .init(account: "111122223333",
        arn: "arn:aws:iam::111122223333:user/test", userID: "test"), transport: OfflineAWSHTTPClient? = nil) -> AWSServiceProvider {
        AWSServiceProvider(credentialFactory: { _, _ in
            .static(accessKeyId: "offline-test-access", secretAccessKey: "offline-test-secret")
        }, businessClientFactory: { credentials in
            if let transport { return AWSClient(credentialProvider: credentials, retryPolicy: .noRetry, httpClient: transport) }
            return AWSClient(credentialProvider: credentials)
        }, identityVerifier: { _, _ in identity })
    }

    func configureVerified(profile: AWSProfile?, region: String, forceRefresh: Bool = false,
                           paths: AWSConfigurationPaths = AWSConfigurationPaths()) async throws {
        await configure(profile: profile, region: region, forceRefresh: forceRefresh, paths: paths)
        if profile != nil { _ = try await validateIdentity() }
    }
}

actor OfflineAWSHTTPClient: AWSHTTPClient {
    private(set) var requestCount = 0
    private let respond: @Sendable (AWSHTTPRequest) async throws -> AWSHTTPResponse

    init(respond: @escaping @Sendable (AWSHTTPRequest) async throws -> AWSHTTPResponse = { _ in
        .init(status: .ok, headers: [:])
    }) {
        self.respond = respond
    }

    func execute(request: AWSHTTPRequest, timeout: TimeAmount, logger: Logger) async throws -> AWSHTTPResponse {
        requestCount += 1
        return try await respond(request)
    }
}

func providerTestScope(_ profile: AWSProfile, paths: AWSConfigurationPaths = AWSConfigurationPaths()) -> MonitoringScope {
    MonitoringScope(profile: profile, identity: .init(account: "111122223333",
        arn: "arn:aws:iam::111122223333:user/test", userID: "test"), region: "us-east-1", paths: paths)
}
