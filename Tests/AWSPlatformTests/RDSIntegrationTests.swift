import XCTest
@testable import AWSPlatform

@MainActor
final class RDSIntegrationTests: XCTestCase {
    func testProviderRejectsRDSBeforeVerificationAndAfterClearingProfile() async throws {
        let provider = AWSServiceProvider.testProvider()
        let profile = profile()
        let paths = paths()
        let scope = scope(profile: profile, paths: paths)
        await provider.configure(profile: profile, region: scope.region, paths: paths)
        await assertProviderError(.notConfigured, provider: provider, scope: scope)
        _ = try await provider.validateIdentity()
        _ = try await provider.rdsClient(scope: scope)
        await provider.configure(profile: nil, region: scope.region, paths: paths)
        await assertProviderError(.notConfigured, provider: provider, scope: scope)
        await provider.shutdown()
    }

    func testProviderRejectsWrongProfileAccountPrincipalRegionAndConfigurationPaths() async throws {
        let provider = AWSServiceProvider.testProvider()
        let profile = profile()
        let paths = paths()
        try await provider.configureVerified(profile: profile, region: "eu-west-1", paths: paths)
        let mismatches = [
            scope(profile: self.profile(name: "different"), paths: paths),
            scope(profile: self.profile(region: "us-east-1"), paths: paths),
            scope(profile: profile, account: "999900001111", paths: paths),
            scope(profile: profile, principal: "arn:aws:iam::111122223333:user/different", paths: paths),
            scope(profile: profile, region: "us-east-1", paths: paths),
            scope(profile: profile, paths: self.paths(config: "/example/different-config")),
            scope(profile: profile, paths: self.paths(credentials: "/example/different-credentials"))
        ]
        for mismatched in mismatches {
            await assertProviderError(.identityChanged, provider: provider, scope: mismatched)
        }
        let selected = try await provider.rdsClient(scope: scope(profile: profile, paths: paths))
        XCTAssertEqual(selected.config.region.rawValue, "eu-west-1")
        await provider.shutdown()
    }

    func testRDSUsesSelectedRegionalClientAndSharesTheVerifiedAWSClient() async throws {
        let provider = AWSServiceProvider.testProvider()
        let profile = profile()
        let paths = paths()
        let firstScope = scope(profile: profile, paths: paths)
        try await provider.configureVerified(profile: profile, region: firstScope.region, paths: paths)
        let first = try await provider.rdsClient(scope: firstScope)
        let firstEC2 = try await provider.ec2Client(scope: firstScope)
        XCTAssertTrue(first.client === firstEC2.client)
        XCTAssertEqual(first.config.region.rawValue, "eu-west-1")
        XCTAssertEqual(first.config.endpoint, "https://rds.eu-west-1.amazonaws.com")

        let nextScope = scope(profile: profile, region: "ap-southeast-1", paths: paths)
        try await provider.configureVerified(profile: profile, region: nextScope.region, paths: paths)
        let next = try await provider.rdsClient(scope: nextScope)
        let nextEC2 = try await provider.ec2Client(scope: nextScope)
        XCTAssertTrue(next.client === first.client)
        XCTAssertTrue(next.client === nextEC2.client)
        XCTAssertEqual(next.config.region.rawValue, "ap-southeast-1")
        XCTAssertEqual(next.config.endpoint, "https://rds.ap-southeast-1.amazonaws.com")
        await assertProviderError(.identityChanged, provider: provider, scope: firstScope)
        await provider.shutdown()
    }

    func testRDSAcceptsSameRoleWithNewSessionNameButRejectsDifferentRole() async throws {
        let identity = AWSIdentity(account: "111122223333",
                                   arn: "arn:aws:sts::111122223333:assumed-role/DatabaseReader/original-session",
                                   userID: "test-role:original-session")
        let provider = AWSServiceProvider.testProvider(identity: identity)
        let profile = profile()
        let paths = paths()
        try await provider.configureVerified(profile: profile, region: "eu-west-1", paths: paths)
        let renewed = scope(profile: profile,
                            principal: "arn:aws:sts::111122223333:assumed-role/DatabaseReader/renewed-session",
                            paths: paths)
        _ = try await provider.rdsClient(scope: renewed)
        let different = scope(profile: profile,
                              principal: "arn:aws:sts::111122223333:assumed-role/DifferentReader/renewed-session",
                              paths: paths)
        await assertProviderError(.identityChanged, provider: provider, scope: different)
        await provider.shutdown()
    }

    func testRDSIsAStandaloneSidebarServiceOutsideEC2Group() {
        XCTAssertTrue(AWSService.allCases.contains(.rds))
        XCTAssertTrue(AWSService.standaloneServices.contains(.rds))
        XCTAssertFalse(AWSService.ec2Services.contains(.rds))
        XCTAssertFalse(AWSService.rds.isEC2Service)
        XCTAssertEqual(AWSService.rds.sidebarTitle, "RDS")
    }

    func testSavedRDSNavigationFinishesWithUnsupportedErrorForFavoritesAndRecents() {
        let selected = profile()
        let resource = ResourceFavorite(profileName: selected.name, accountID: "111122223333", region: "eu-west-1",
                                        service: .rds, resourceID: "arn:aws:rds:eu-west-1:111122223333:db:example",
                                        displayName: "example")
        let ec2 = EC2ViewModel()
        let lambda = LambdaViewModel()
        let s3 = S3ViewModel()
        let alarms = AlarmViewModel(listLoader: { _ in [] }, tagLoader: { _, _ in [:] }, historyLoader: { _, _ in [] })
        let sns = SNSViewModel(listLoader: { _ in [] }, attributeLoader: { _, _ in [:] },
                               tagLoader: { _, _ in [:] }, subscriptionLoader: { _, _ in [] })
        for source in [FavoriteNavigation.Source.favorite, .recent] {
            let navigation = FavoriteNavigation()
            XCTAssertTrue(navigation.begin(resource, profiles: [selected], selectedProfileName: selected.name, source: source))
            XCTAssertTrue(navigation.verifyAccount(resource.accountID))
            XCTAssertNotNil(navigation.target)
            navigation.resolve(ec2: ec2, lambda: lambda, s3: s3, alarms: alarms, sns: sns)
            XCTAssertNil(navigation.target)
            XCTAssertEqual(navigation.error, "Unable to open example: Saved RDS navigation is not available. Open RDS and select a database. The \(source.noun) is still saved.")
            XCTAssertNil(ec2.selectedInstance)
            XCTAssertNil(lambda.selectedFunction)
            XCTAssertNil(s3.selectedBucket)
            XCTAssertNil(alarms.selectedAlarm)
            XCTAssertNil(sns.selectedTopic)
        }
    }

    private func profile(name: String = "rds-work", region: String = "eu-west-1") -> AWSProfile {
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
            _ = try await provider.rdsClient(scope: scope)
            XCTFail("Invalid scope must not receive an RDS client", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AWSServiceError, expected, file: file, line: line)
        }
    }
}
