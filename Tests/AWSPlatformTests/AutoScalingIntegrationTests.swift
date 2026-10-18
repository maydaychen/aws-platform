import XCTest
@testable import AWSPlatform

@MainActor
final class AutoScalingIntegrationTests: XCTestCase {
    func testProviderRejectsAutoScalingWithoutAProfileBeforeVerificationAndAfterClearing() async throws {
        let provider = AWSServiceProvider.testProvider()
        let profile = profile()
        let paths = paths()
        let scope = scope(profile: profile, paths: paths)
        await assertProviderError(.notConfigured, provider: provider, scope: scope)
        await provider.configure(profile: profile, region: scope.region, paths: paths)
        await assertProviderError(.notConfigured, provider: provider, scope: scope)
        _ = try await provider.validateIdentity()
        _ = try await provider.autoScalingClient(scope: scope)
        await provider.configure(profile: nil, region: scope.region, paths: paths)
        await assertProviderError(.notConfigured, provider: provider, scope: scope)
        await provider.shutdown()
    }

    func testProviderRejectsMismatchedProfileAccountPrincipalRegionAndEitherConfigurationPath() async throws {
        let provider = AWSServiceProvider.testProvider()
        let profile = profile()
        let paths = paths()
        try await provider.configureVerified(profile: profile, region: "eu-west-1", paths: paths)
        let mismatches = [
            scope(profile: self.profile(name: "other-profile"), paths: paths),
            scope(profile: self.profile(region: "us-east-1"), paths: paths),
            scope(profile: profile, account: "999900001111", paths: paths),
            scope(profile: profile, principal: "arn:aws:iam::111122223333:user/other", paths: paths),
            scope(profile: profile, region: "us-east-1", paths: paths),
            scope(profile: profile, paths: self.paths(config: "/example/other-config")),
            scope(profile: profile, paths: self.paths(credentials: "/example/other-credentials"))
        ]
        for mismatch in mismatches {
            await assertProviderError(.identityChanged, provider: provider, scope: mismatch)
        }
        let selected = try await provider.autoScalingClient(scope: scope(profile: profile, paths: paths))
        XCTAssertEqual(selected.config.region.rawValue, "eu-west-1")
        await provider.shutdown()
    }

    func testAutoScalingUsesSelectedRegionAndSharesVerifiedClientWithEC2() async throws {
        let provider = AWSServiceProvider.testProvider()
        let profile = profile()
        let paths = paths()
        let firstScope = scope(profile: profile, paths: paths)
        try await provider.configureVerified(profile: profile, region: firstScope.region, paths: paths)
        let first = try await provider.autoScalingClient(scope: firstScope)
        let firstEC2 = try await provider.ec2Client(scope: firstScope)
        XCTAssertTrue(first.client === firstEC2.client)
        XCTAssertEqual(first.config.region.rawValue, "eu-west-1")
        XCTAssertEqual(first.config.endpoint, "https://autoscaling.eu-west-1.amazonaws.com")

        let nextScope = scope(profile: profile, region: "ap-southeast-1", paths: paths)
        try await provider.configureVerified(profile: profile, region: nextScope.region, paths: paths)
        let next = try await provider.autoScalingClient(scope: nextScope)
        let nextEC2 = try await provider.ec2Client(scope: nextScope)
        XCTAssertTrue(next.client === first.client)
        XCTAssertTrue(next.client === nextEC2.client)
        XCTAssertEqual(next.config.region.rawValue, "ap-southeast-1")
        XCTAssertEqual(next.config.endpoint, "https://autoscaling.ap-southeast-1.amazonaws.com")
        await assertProviderError(.identityChanged, provider: provider, scope: firstScope)
        await provider.shutdown()
    }

    func testAutoScalingAcceptsRenewedSessionForSameRoleAndRejectsAnotherRole() async throws {
        let identity = AWSIdentity(account: "111122223333",
                                   arn: "arn:aws:sts::111122223333:assumed-role/ScalingReader/first-session",
                                   userID: "test-role:first-session")
        let provider = AWSServiceProvider.testProvider(identity: identity)
        let profile = profile()
        let paths = paths()
        try await provider.configureVerified(profile: profile, region: "eu-west-1", paths: paths)
        let renewed = scope(profile: profile,
                            principal: "arn:aws:sts::111122223333:assumed-role/ScalingReader/next-session",
                            paths: paths)
        _ = try await provider.autoScalingClient(scope: renewed)
        let changedRole = scope(profile: profile,
                                principal: "arn:aws:sts::111122223333:assumed-role/AnotherReader/next-session",
                                paths: paths)
        await assertProviderError(.identityChanged, provider: provider, scope: changedRole)
        await provider.shutdown()
    }

    func testAutoScalingAppearsOnceAsSecondServiceInEC2Group() {
        XCTAssertEqual(AWSService.ec2Services.prefix(2), [.ec2, .autoScaling])
        XCTAssertEqual(AWSService.ec2Services.filter { $0 == .autoScaling }.count, 1)
        XCTAssertTrue(AWSService.autoScaling.isEC2Service)
        XCTAssertFalse(AWSService.standaloneServices.contains(.autoScaling))
        XCTAssertEqual(AWSService.autoScaling.sidebarTitle, "Auto Scaling")
        XCTAssertEqual(Set(AWSService.allCases.map(\.id)).count, AWSService.allCases.count)
        let sidebar = AWSService.ec2Services + AWSService.standaloneServices
        XCTAssertEqual(Set(sidebar), Set(AWSService.allCases))
        XCTAssertEqual(sidebar.count, AWSService.allCases.count)
    }

    func testAutoScalingSavedServiceIdentifierRoundTripsWithoutCollidingWithOtherServices() throws {
        let resource = savedGroup(profile: profile())
        let encoded = try JSONEncoder().encode(resource)
        let decoded = try JSONDecoder().decode(ResourceFavorite.self, from: encoded)
        XCTAssertEqual(AWSService.autoScaling.rawValue, "Auto Scaling")
        XCTAssertEqual(decoded, resource)
        XCTAssertEqual(decoded.id, resource.id)
        XCTAssertTrue(decoded.isValid)
        let sameResourceInEC2 = ResourceFavorite(profileName: resource.profileName, accountID: resource.accountID,
                                                region: resource.region, service: .ec2, resourceID: resource.resourceID,
                                                displayName: resource.displayName)
        XCTAssertNotEqual(resource.id, sameResourceInEC2.id)
    }

    func testSavedAutoScalingNavigationFinishesForFavoritesAndRecentsWithoutChangingOtherViewModels() {
        let selected = profile()
        let resource = savedGroup(profile: selected)
        let ec2 = EC2ViewModel()
        let lambda = LambdaViewModel()
        let s3 = S3ViewModel()
        let alarms = AlarmViewModel(listLoader: { _ in [] }, tagLoader: { _, _ in [:] }, historyLoader: { _, _ in [] })
        let sns = SNSViewModel(listLoader: { _ in [] }, attributeLoader: { _, _ in [:] },
                               tagLoader: { _, _ in [:] }, subscriptionLoader: { _, _ in [] })
        let route53 = Route53ViewModel(listLoader: { _ in [] }, detailLoader: { _, _ in throw AWSServiceError.notConfigured },
                                       recordLoader: { _, _ in [] }, tagLoader: { _, _ in [:] })
        let elb = ELBViewModel(loadBalancerLoader: { _ in [] }, targetGroupLoader: { _ in [] },
                               listenerLoader: { _, _ in [] }, ruleLoader: { _, _ in [] }, healthLoader: { _, _ in [] })
        let securityGroups = SecurityGroupsViewModel(loader: { _ in [] })
        let volumes = EBSViewModel(kind: .volume, loader: { _, _ in [] })
        let snapshots = EBSViewModel(kind: .snapshot, loader: { _, _ in [] })
        ec2.searchText = "retain-ec2"
        lambda.searchText = "retain-lambda"
        s3.bucketSearchText = "retain-s3"
        alarms.searchText = "retain-alarms"
        sns.searchText = "retain-sns"
        route53.searchText = "retain-route53"
        elb.searchText = "retain-elb"
        securityGroups.searchText = "retain-security-groups"
        volumes.searchText = "retain-volumes"
        snapshots.searchText = "retain-snapshots"

        for source in [FavoriteNavigation.Source.favorite, .recent] {
            let navigation = FavoriteNavigation()
            XCTAssertTrue(navigation.begin(resource, profiles: [selected], selectedProfileName: selected.name, source: source))
            XCTAssertTrue(navigation.verifyAccount(resource.accountID))
            XCTAssertNotNil(navigation.target)
            navigation.resolve(ec2: ec2, lambda: lambda, s3: s3, alarms: alarms, sns: sns, route53: route53,
                               elb: elb, securityGroups: securityGroups, volumes: volumes, snapshots: snapshots)
            XCTAssertNil(navigation.target)
            XCTAssertEqual(navigation.error, "Unable to open example: Saved Auto Scaling navigation is not available. Open Auto Scaling and select a group. The \(source.noun) is still saved.")
            XCTAssertNil(ec2.selectedInstance)
            XCTAssertNil(lambda.selectedFunction)
            XCTAssertNil(s3.selectedBucket)
            XCTAssertNil(alarms.selectedAlarm)
            XCTAssertNil(sns.selectedTopic)
            XCTAssertNil(route53.selectedZone)
            XCTAssertNil(elb.selectedLoadBalancer)
            XCTAssertNil(elb.selectedTargetGroup)
            XCTAssertNil(securityGroups.selectedGroup)
            XCTAssertNil(volumes.selectedResource)
            XCTAssertNil(snapshots.selectedResource)
            XCTAssertEqual(ec2.searchText, "retain-ec2")
            XCTAssertEqual(lambda.searchText, "retain-lambda")
            XCTAssertEqual(s3.bucketSearchText, "retain-s3")
            XCTAssertEqual(alarms.searchText, "retain-alarms")
            XCTAssertEqual(sns.searchText, "retain-sns")
            XCTAssertEqual(route53.searchText, "retain-route53")
            XCTAssertEqual(elb.searchText, "retain-elb")
            XCTAssertEqual(securityGroups.searchText, "retain-security-groups")
            XCTAssertEqual(volumes.searchText, "retain-volumes")
            XCTAssertEqual(snapshots.searchText, "retain-snapshots")
        }
    }

    private func savedGroup(profile: AWSProfile) -> ResourceFavorite {
        ResourceFavorite(profileName: profile.name, accountID: "111122223333", region: "eu-west-1",
                         service: .autoScaling,
                         resourceID: "arn:aws:autoscaling:eu-west-1:111122223333:autoScalingGroup:example-id:autoScalingGroupName/example",
                         displayName: "example")
    }

    private func profile(name: String = "asg-work", region: String = "eu-west-1") -> AWSProfile {
        AWSProfile(name: name, region: region, ssoStartURL: nil, ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil)
    }

    private func paths(config: String = "/example/config", credentials: String = "/example/credentials") -> AWSConfigurationPaths {
        AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": config, "AWS_SHARED_CREDENTIALS_FILE": credentials])
    }

    private func scope(profile: AWSProfile, account: String = "111122223333", principal: String? = nil,
                       region: String = "eu-west-1", paths: AWSConfigurationPaths) -> MonitoringScope {
        MonitoringScope(profile: profile,
                        identity: AWSIdentity(account: account, arn: principal ?? "arn:aws:iam::\(account):user/test", userID: "test"),
                        region: region, paths: paths)
    }

    private func assertProviderError(_ expected: AWSServiceError, provider: AWSServiceProvider, scope: MonitoringScope,
                                     file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await provider.autoScalingClient(scope: scope)
            XCTFail("Invalid scope must not receive an Auto Scaling client", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AWSServiceError, expected, file: file, line: line)
        }
    }
}
