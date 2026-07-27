import Foundation
import SotoCore
import SotoEC2
import SotoLambda
import SotoS3
import SotoSTS

actor AWSServiceProvider {
    private var awsClient: AWSClient?
    private var ec2: EC2?
    private var lambda: Lambda?
    private var sts: STS?
    private(set) var currentProfileName: String?
    private(set) var currentRegion: String?

    deinit {
        // App shutdown can outpace our async cleanup task. Use Soto's synchronous
        // fallback here so AWSClient does not trip its deinit assertion.
        try? awsClient?.syncShutdown()
    }

    func configure(profile: AWSProfile?, region: String) async {
        guard let profile else {
            await shutdown()
            return
        }

        if currentProfileName == profile.name, currentRegion == region, awsClient != nil {
            return
        }

        await shutdown()

        let credentialProvider: CredentialProviderFactory = profile.isSSO
            ? .sso(profileName: profile.name)
            : .configFile(profile: profile.name)

        let awsClient = AWSClient(credentialProvider: credentialProvider)

        self.awsClient = awsClient
        self.ec2 = EC2(client: awsClient, region: .init(rawValue: region))
        self.lambda = Lambda(client: awsClient, region: .init(rawValue: region))
        self.sts = STS(client: awsClient, region: .init(rawValue: region))
        self.currentProfileName = profile.name
        self.currentRegion = region
    }

    func ec2Client() throws -> EC2 {
        guard let ec2 else { throw AWSServiceError.notConfigured }
        return ec2
    }

    func lambdaClient() throws -> Lambda {
        guard let lambda else { throw AWSServiceError.notConfigured }
        return lambda
    }

    func s3Client(region: String? = nil) throws -> S3 {
        guard let awsClient else { throw AWSServiceError.notConfigured }
        let regionName = region ?? currentRegion
        guard let regionName else { throw AWSServiceError.notConfigured }
        return S3(client: awsClient, region: .init(rawValue: regionName))
    }

    func validateIdentity() async throws -> AWSIdentity {
        guard let sts else { throw AWSServiceError.notConfigured }
        let response = try await sts.getCallerIdentity(.init())
        return AWSIdentity(
            account: response.account ?? "-",
            arn: response.arn ?? "-",
            userID: response.userId ?? "-"
        )
    }

    func shutdown() async {
        let awsClient = self.awsClient
        self.awsClient = nil
        ec2 = nil
        lambda = nil
        sts = nil
        currentProfileName = nil
        currentRegion = nil

        guard let awsClient else { return }

        // Detach cleanup from the caller's cancellation state. Reconfigure and
        // window teardown paths frequently cancel tasks, but the Soto client
        // still must be fully shut down before deinit.
        try? await Task.detached {
            try await awsClient.shutdown()
        }.value
    }
}

struct AWSIdentity: Hashable {
    let account: String
    let arn: String
    let userID: String
}

enum AWSServiceError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Select an AWS profile and region first."
        }
    }
}
