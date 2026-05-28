import Foundation
import SotoCore
import SotoEC2
import SotoLambda
import SotoS3

actor AWSServiceProvider {
    private var awsClient: AWSClient?
    private var ec2: EC2?
    private var lambda: Lambda?
    private var s3: S3?
    private(set) var currentProfileName: String?
    private(set) var currentRegion: String?

    func configure(profile: AWSProfile?, region: String) async {
        guard let profile else {
            await shutdown()
            return
        }

        if currentProfileName == profile.name, currentRegion == region, awsClient != nil {
            return
        }

        await shutdown()

        let awsClient = AWSClient(
            credentialProvider: .configFile(profile: profile.name, options: .init()),
            httpClientProvider: .createNew
        )

        self.awsClient = awsClient
        self.ec2 = EC2(client: awsClient, region: .init(rawValue: region))
        self.lambda = Lambda(client: awsClient, region: .init(rawValue: region))
        self.s3 = S3(client: awsClient, region: .init(rawValue: region))
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

    func s3Client() throws -> S3 {
        guard let s3 else { throw AWSServiceError.notConfigured }
        return s3
    }

    func shutdown() async {
        if let awsClient {
            try? await awsClient.shutdown()
        }
        awsClient = nil
        ec2 = nil
        lambda = nil
        s3 = nil
        currentProfileName = nil
        currentRegion = nil
    }
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
