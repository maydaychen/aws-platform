import Foundation
import SotoCore
import SotoEC2
import SotoLambda
import SotoS3
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
    private(set) var currentProfileName: String?
    private(set) var currentRegion: String?
    private var currentPaths: AWSConfigurationPaths?
    private var currentProfile: AWSProfile?
    private var binding: IdentityBoundCredentialProvider?
    private var validatedIdentity: AWSIdentity?
    private var generation = UUID()
    private let verifier: IdentityBoundCredentialProvider.Verifier
    private let credentialFactory: (@Sendable (AWSProfile, AWSConfigurationPaths) -> CredentialProviderFactory)?
    private let cliCredentialRunner: AWSCLICredentialProvider.Runner?
    nonisolated let identityInvalidations: AsyncStream<UUID>
    private let identityEvents: AsyncStream<UUID>.Continuation

    init(credentialFactory: (@Sendable (AWSProfile, AWSConfigurationPaths) -> CredentialProviderFactory)? = nil,
         cliCredentialRunner: AWSCLICredentialProvider.Runner? = nil,
         identityVerifier: @escaping IdentityBoundCredentialProvider.Verifier = { try await IdentityBoundCredentialProvider.verify($0, region: $1) }) {
        self.credentialFactory = credentialFactory
        self.cliCredentialRunner = cliCredentialRunner
        self.verifier = identityVerifier
        let stream = AsyncStream<UUID>.makeStream(bufferingPolicy: .bufferingNewest(8))
        identityInvalidations = stream.stream
        identityEvents = stream.continuation
    }

    deinit {
        // App shutdown can outpace our async cleanup task. Use Soto's synchronous
        // fallback here so AWSClient does not trip its deinit assertion.
        try? awsClient?.syncShutdown()
        identityEvents.finish()
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
                currentRegion = region
            }
            return
        }

        let credentialProvider: CredentialProviderFactory
        if let credentialFactory {
            credentialProvider = credentialFactory(profile, paths)
        } else if profile.roleARN != nil && profile.roleAccountID == nil {
            credentialProvider = .custom { _ in InvalidRoleCredentialProvider() }
        } else if profile.roleARN != nil || (profile.isSSO && paths.usesCustomConfig) {
            // Soto's config-file provider requires the destination section in
            // credentials before reading role_arn from config. The CLI resolves
            // source-only role layouts and custom-path SSO without that limit.
            let cliCredentialRunner = self.cliCredentialRunner
            credentialProvider = .custom { context in
                let provider: AWSCLICredentialProvider
                if let cliCredentialRunner {
                    provider = AWSCLICredentialProvider(profile: profile.name, paths: paths, runner: cliCredentialRunner)
                } else {
                    provider = AWSCLICredentialProvider(profile: profile.name, paths: paths)
                }
                return RotatingCredentialProvider(
                    context: context,
                    provider: provider
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
        let previousBinding = binding
        let nextGeneration = UUID()
        let events = identityEvents
        var profileVerifier = verifier
        if profile.roleARN != nil {
            let verifier = self.verifier
            let expectedPrincipal = profile.assumedRolePrincipalARN
            profileVerifier = { credential, region in
                let identity = try await verifier(credential, region)
                guard let expectedPrincipal,
                      AWSStablePrincipal.normalizedARN(identity.arn) == expectedPrincipal else {
                    throw AWSServiceError.identityUnavailable
                }
                return identity
            }
        }
        let nextBinding = IdentityBoundCredentialProvider(source: AWSClient(credentialProvider: credentialProvider),
            region: region, expectedAccount: profile.roleARN == nil ? profile.ssoAccountID : profile.roleAccountID,
            verifier: profileVerifier,
            onInvalidation: { events.yield(nextGeneration) })
        let nextClient = AWSClient(credentialProvider: .custom { _ in nextBinding })

        // Replace the actor state before the first suspension point. A second
        // configure call can then only replace and close this new client; an
        // older call can no longer resume and overwrite a newer client.
        self.awsClient = nextClient
        self.ec2 = EC2(client: nextClient, region: .init(rawValue: region))
        self.lambda = Lambda(client: nextClient, region: .init(rawValue: region))
        self.currentProfileName = profile.name
        self.currentRegion = region
        self.currentPaths = paths
        self.currentProfile = profile
        self.binding = nextBinding
        self.validatedIdentity = nil
        self.generation = nextGeneration

        await previousBinding?.invalidate()
        if let previousClient {
            await Self.shutdown(previousClient)
        }
    }

    func ec2Client(scope: MonitoringScope) async throws -> EC2 {
        try await requireIdentity(scope: scope, regional: true)
        guard let ec2 else { throw AWSServiceError.notConfigured }
        return ec2
    }

    /// Uses an explicitly selected relationship query region without reconfiguring the workspace.
    func relationshipEC2Client(scope: MonitoringScope) async throws -> EC2 {
        guard scope.isValid, currentProfile == scope.profile, currentPaths == scope.paths,
              matchesIdentity(account: scope.accountID, arn: scope.principalARN),
              let awsClient else { throw SecurityGroupError.invalidScope }
        try await requireIdentity(scope: scope)
        return EC2(client: awsClient, region: .init(rawValue: scope.region))
    }

    func lambdaClient(scope: MonitoringScope) async throws -> Lambda {
        try await requireIdentity(scope: scope, regional: true)
        guard let lambda else { throw AWSServiceError.notConfigured }
        return lambda
    }

    func s3Client(scope: MonitoringScope, region: String? = nil) async throws -> S3 {
        try await requireIdentity(scope: scope)
        guard let awsClient else { throw AWSServiceError.notConfigured }
        let regionName = region ?? currentRegion
        guard let regionName else { throw AWSServiceError.notConfigured }
        return S3(client: awsClient, region: .init(rawValue: regionName))
    }

    func validateIdentity() async throws -> AWSIdentity {
        guard let awsClient, let binding else { throw AWSServiceError.notConfigured }
        let token = generation
        _ = try await awsClient.credentialProvider.getCredential(logger: AWSClient.loggingDisabled)
        let identity = try await binding.identity()
        guard token == generation else { throw AWSServiceError.identityChanged }
        validatedIdentity = identity
        return identity
    }

    func transferS3Client(scope: MonitoringScope, region: String) async throws -> S3 {
        guard scope.isValid, currentProfile == scope.profile, currentPaths == scope.paths,
              matchesIdentity(account: scope.accountID, arn: scope.principalARN),
              currentRegion == scope.region, let awsClient else { throw S3TransferError.invalidScope }
        try await requireIdentity(scope: scope, regional: true)
        return S3(client: awsClient, region: .init(rawValue: region)).with(timeout: .minutes(30))
    }

    func costExplorerClient(profile: AWSProfile, paths: AWSConfigurationPaths, partition: AWSPartition) async throws -> CostExplorer {
        guard currentProfile == profile, currentPaths == paths, let awsClient else {
            throw CostError.invalidIdentity
        }
        try await requireIdentity()
        return CostExplorer(client: awsClient, partition: partition)
    }

    func healthClient(scope: HealthScope) async throws -> Health {
        let endpoint = try scope.endpoint()
        let paths = AWSConfigurationPaths(environment: [
            "AWS_CONFIG_FILE": scope.configPath, "AWS_SHARED_CREDENTIALS_FILE": scope.credentialsPath
        ])
        guard currentProfile == scope.profile, currentPaths == paths,
              matchesIdentity(account: scope.accountID, arn: scope.principalARN), let awsClient else {
            throw HealthError.invalidScope
        }
        try await requireIdentity()
        let partition: AWSPartition
        switch endpoint.partition {
        case "aws-cn": partition = .awscn
        case "aws-us-gov": partition = .awsusgov
        default: partition = .aws
        }
        return Health(client: awsClient, partition: partition, endpoint: endpoint.url)
            .with(region: .init(rawValue: endpoint.region))
    }

    func elbClient(scope: MonitoringScope) async throws -> ElasticLoadBalancingV2 {
        guard scope.isValid, currentProfile == scope.profile, currentPaths == scope.paths,
              matchesIdentity(account: scope.accountID, arn: scope.principalARN),
              currentRegion == scope.region, let awsClient else { throw ELBError.invalidScope }
        try await requireIdentity(scope: scope, regional: true)
        return ElasticLoadBalancingV2(client: awsClient, region: .init(rawValue: scope.region))
    }

    func relationshipELBClient(scope: MonitoringScope) async throws -> ElasticLoadBalancingV2 {
        guard scope.isValid, currentProfile == scope.profile, currentPaths == scope.paths,
              matchesIdentity(account: scope.accountID, arn: scope.principalARN),
              let awsClient else { throw ELBError.invalidScope }
        try await requireIdentity(scope: scope)
        return ElasticLoadBalancingV2(client: awsClient, region: .init(rawValue: scope.region))
    }

    func route53Client(scope: Route53Scope) async throws -> Route53 {
        let partitionName = try scope.partition()
        let paths = AWSConfigurationPaths(environment: [
            "AWS_CONFIG_FILE": scope.configPath, "AWS_SHARED_CREDENTIALS_FILE": scope.credentialsPath
        ])
        guard currentProfile == scope.profile, currentPaths == paths,
              matchesIdentity(account: scope.accountID, arn: scope.principalARN), let awsClient else {
            throw Route53Error.invalidScope
        }
        try await requireIdentity()
        let partition: AWSPartition
        switch partitionName {
        case "aws-cn": partition = .awscn
        case "aws-us-gov": partition = .awsusgov
        default: partition = .aws
        }
        return Route53(client: awsClient, partition: partition)
    }

    func cloudWatchClient(profile: AWSProfile, paths: AWSConfigurationPaths, region: String) async throws -> CloudWatch {
        guard currentProfile == profile, currentPaths == paths, currentRegion == region, let awsClient else {
            throw AlarmError.invalidScope
        }
        try await requireIdentity()
        return CloudWatch(client: awsClient, region: .init(rawValue: region))
    }

    func snsClient(profile: AWSProfile, paths: AWSConfigurationPaths, region: String) async throws -> SNS {
        guard currentProfile == profile, currentPaths == paths, currentRegion == region, let awsClient else {
            throw SNSError.invalidScope
        }
        try await requireIdentity()
        return SNS(client: awsClient, region: .init(rawValue: region))
    }

    func cloudWatchLogsClient(profile: AWSProfile, paths: AWSConfigurationPaths, region: String) async throws -> CloudWatchLogs {
        guard currentProfile == profile, currentPaths == paths, currentRegion == region, let awsClient else {
            throw AWSServiceError.notConfigured
        }
        try await requireIdentity()
        return CloudWatchLogs(client: awsClient, region: .init(rawValue: region))
    }

    func shutdown() async {
        let awsClient = self.awsClient
        let binding = self.binding
        self.awsClient = nil
        ec2 = nil
        lambda = nil
        currentProfileName = nil
        currentRegion = nil
        currentPaths = nil
        currentProfile = nil
        self.binding = nil
        validatedIdentity = nil
        generation = UUID()

        await binding?.invalidate()
        guard let awsClient else { return }

        await Self.shutdown(awsClient)
    }

    func isCurrentIdentityFailure(_ token: UUID) -> Bool { token == generation }

    private func matchesIdentity(account: String, arn: String) -> Bool {
        guard let identity = validatedIdentity else { return false }
        return account == identity.account
            && AWSStablePrincipal.normalizedARN(arn) == AWSStablePrincipal.normalizedARN(identity.arn)
    }

    private func requireIdentity(scope: MonitoringScope? = nil, regional: Bool = false) async throws {
        guard let binding, let identity = validatedIdentity else { throw AWSServiceError.notConfigured }
        let token = generation
        _ = try await binding.identity()
        guard token == generation else { throw AWSServiceError.identityChanged }
        if let scope {
            guard scope.isValid, currentProfile == scope.profile, currentPaths == scope.paths,
                  scope.accountID == identity.account,
                  AWSStablePrincipal.normalizedARN(scope.principalARN) == AWSStablePrincipal.normalizedARN(identity.arn),
                  !regional || scope.region == currentRegion else { throw AWSServiceError.identityChanged }
        }
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

private struct InvalidRoleCredentialProvider: CredentialProvider {
    func getCredential(logger: Logger) async throws -> Credential {
        throw AWSServiceError.identityUnavailable
    }
}

struct AWSIdentity: Hashable, Sendable {
    let account: String
    let arn: String
    let userID: String
}

enum AWSServiceError: LocalizedError, Equatable {
    case notConfigured
    case identityChanged, identityUnavailable

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Select an AWS profile and region first."
        case .identityChanged:
            return "The Profile credentials changed account or role, or could not be verified. Use Retry Connection to verify the Profile again."
        case .identityUnavailable:
            return "Could not verify the Profile credentials. Use Retry Connection to verify the Profile again."
        }
    }
}
