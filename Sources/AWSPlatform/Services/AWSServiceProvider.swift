import Foundation
import SotoCore
import SotoEC2
import SotoLambda
import SotoS3
import SotoSTS
import SotoCostExplorer
import SotoCloudWatch
import SotoCloudWatchLogs
import SotoSNS
import SotoHealth
import SotoRoute53
import SotoElasticLoadBalancingV2

actor AWSServiceProvider {
    private var awsClient: AWSClient?
    private var ec2: EC2?
    private var lambda: Lambda?
    private var sts: STS?
    private(set) var currentProfileName: String?
    private(set) var currentRegion: String?
    private var currentPaths: AWSConfigurationPaths?
    private var currentProfile: AWSProfile?

    deinit {
        // App shutdown can outpace our async cleanup task. Use Soto's synchronous
        // fallback here so AWSClient does not trip its deinit assertion.
        try? awsClient?.syncShutdown()
    }

    func configure(
        profile: AWSProfile?,
        region: String,
        forceRefresh: Bool = false,
        paths: AWSConfigurationPaths = AWSConfigurationPaths()
    ) async {
        guard let profile else {
            await shutdown()
            return
        }

        if !forceRefresh, currentProfile == profile, currentPaths == paths, let awsClient {
            // Resource Region changes must not close in-flight global queries.
            if currentRegion != region {
                ec2 = EC2(client: awsClient, region: .init(rawValue: region))
                lambda = Lambda(client: awsClient, region: .init(rawValue: region))
                sts = STS(client: awsClient, region: .init(rawValue: region))
                currentRegion = region
            }
            return
        }

        let credentialProvider: CredentialProviderFactory
        if profile.isSSO && paths.usesCustomConfig {
            credentialProvider = .custom { context in
                RotatingCredentialProvider(
                    context: context,
                    provider: AWSCLICredentialProvider(profile: profile.name, paths: paths)
                )
            }
        } else if profile.isSSO {
            credentialProvider = .sso(profileName: profile.name)
        } else {
            credentialProvider = .configFile(
                credentialsFilePath: paths.credentials,
                configFilePath: paths.config,
                profile: profile.name
            )
        }

        let previousClient = awsClient
        let nextClient = AWSClient(credentialProvider: credentialProvider)

        // Replace the actor state before the first suspension point. A second
        // configure call can then only replace and close this new client; an
        // older call can no longer resume and overwrite a newer client.
        self.awsClient = nextClient
        self.ec2 = EC2(client: nextClient, region: .init(rawValue: region))
        self.lambda = Lambda(client: nextClient, region: .init(rawValue: region))
        self.sts = STS(client: nextClient, region: .init(rawValue: region))
        self.currentProfileName = profile.name
        self.currentRegion = region
        self.currentPaths = paths
        self.currentProfile = profile

        if let previousClient {
            await Self.shutdown(previousClient)
        }
    }

    func ec2Client() throws -> EC2 {
        guard let ec2 else { throw AWSServiceError.notConfigured }
        return ec2
    }

    /// Uses an explicitly selected relationship query region without reconfiguring the workspace.
    func relationshipEC2Client(scope: MonitoringScope) throws -> EC2 {
        guard scope.isValid, currentProfile == scope.profile, currentPaths == scope.paths,
              let awsClient else { throw SecurityGroupError.invalidScope }
        return EC2(client: awsClient, region: .init(rawValue: scope.region))
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

    func costExplorerClient(profile: AWSProfile, paths: AWSConfigurationPaths, partition: AWSPartition) throws -> CostExplorer {
        guard currentProfile == profile, currentPaths == paths, let awsClient else {
            throw CostError.invalidIdentity
        }
        return CostExplorer(client: awsClient, partition: partition)
    }

    func healthClient(scope: HealthScope) throws -> Health {
        let endpoint = try scope.endpoint()
        let paths = AWSConfigurationPaths(environment: [
            "AWS_CONFIG_FILE": scope.configPath, "AWS_SHARED_CREDENTIALS_FILE": scope.credentialsPath
        ])
        guard currentProfile == scope.profile, currentPaths == paths, let awsClient else {
            throw HealthError.invalidScope
        }
        let partition: AWSPartition
        switch endpoint.partition {
        case "aws-cn": partition = .awscn
        case "aws-us-gov": partition = .awsusgov
        default: partition = .aws
        }
        return Health(client: awsClient, partition: partition, endpoint: endpoint.url)
            .with(region: .init(rawValue: endpoint.region))
    }

    func elbClient(scope: MonitoringScope) throws -> ElasticLoadBalancingV2 {
        guard scope.isValid, currentProfile == scope.profile, currentPaths == scope.paths,
              currentRegion == scope.region, let awsClient else { throw ELBError.invalidScope }
        return ElasticLoadBalancingV2(client: awsClient, region: .init(rawValue: scope.region))
    }

    func relationshipELBClient(scope: MonitoringScope) throws -> ElasticLoadBalancingV2 {
        guard scope.isValid, currentProfile == scope.profile, currentPaths == scope.paths,
              let awsClient else { throw ELBError.invalidScope }
        return ElasticLoadBalancingV2(client: awsClient, region: .init(rawValue: scope.region))
    }

    func route53Client(scope: Route53Scope) throws -> Route53 {
        let partitionName = try scope.partition()
        let paths = AWSConfigurationPaths(environment: [
            "AWS_CONFIG_FILE": scope.configPath, "AWS_SHARED_CREDENTIALS_FILE": scope.credentialsPath
        ])
        guard currentProfile == scope.profile, currentPaths == paths, let awsClient else {
            throw Route53Error.invalidScope
        }
        let partition: AWSPartition
        switch partitionName {
        case "aws-cn": partition = .awscn
        case "aws-us-gov": partition = .awsusgov
        default: partition = .aws
        }
        return Route53(client: awsClient, partition: partition)
    }

    func cloudWatchClient(profile: AWSProfile, paths: AWSConfigurationPaths, region: String) throws -> CloudWatch {
        guard currentProfile == profile, currentPaths == paths, currentRegion == region, let awsClient else {
            throw AlarmError.invalidScope
        }
        return CloudWatch(client: awsClient, region: .init(rawValue: region))
    }

    func snsClient(profile: AWSProfile, paths: AWSConfigurationPaths, region: String) throws -> SNS {
        guard currentProfile == profile, currentPaths == paths, currentRegion == region, let awsClient else {
            throw SNSError.invalidScope
        }
        return SNS(client: awsClient, region: .init(rawValue: region))
    }

    func cloudWatchLogsClient(profile: AWSProfile, paths: AWSConfigurationPaths, region: String) throws -> CloudWatchLogs {
        guard currentProfile == profile, currentPaths == paths, currentRegion == region, let awsClient else {
            throw AWSServiceError.notConfigured
        }
        return CloudWatchLogs(client: awsClient, region: .init(rawValue: region))
    }

    func shutdown() async {
        let awsClient = self.awsClient
        self.awsClient = nil
        ec2 = nil
        lambda = nil
        sts = nil
        currentProfileName = nil
        currentRegion = nil
        currentPaths = nil
        currentProfile = nil

        guard let awsClient else { return }

        await Self.shutdown(awsClient)
    }

    private nonisolated static func shutdown(_ awsClient: AWSClient) async {
        // Detach cleanup from the caller's cancellation state. Reconfigure and
        // window teardown paths frequently cancel tasks, but the Soto client
        // still must be fully shut down before deinit.
        try? await Task.detached {
            try await awsClient.shutdown()
        }.value
    }
}

struct AWSIdentity: Hashable, Sendable {
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
