import XCTest
@testable import AWSPlatform

@MainActor
final class FavoriteNavigationScopeTests: XCTestCase {
    private let services: [AWSService] = [.ec2, .lambda, .s3, .alarms, .sns, .route53,
                                         .loadBalancers, .targetGroups, .securityGroups, .ebsVolumes, .ebsSnapshots]

    func testAllSavedListsRejectUnverifiedOrChangedIdentityConfigurationAndRegion() async {
        let current = scope()
        let changedProfile = AWSProfile(name: current.profile.name, region: current.profile.region,
            ssoStartURL: nil, ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil, sourceProfile: "changed-source")
        let changed = [
            scope(account: "222222222222"), scope(role: "OtherRole"), scope(config: "/offline/other-config"),
            scope(credentials: "/offline/other-credentials"), scope(profile: changedProfile)
        ]
        for loaded in changed {
            let fixture = await Fixture.make(scope: loaded)
            for service in services {
                let navigation = begin(service)
                fixture.resolve(navigation, currentScope: current)
                XCTAssertFalse(fixture.hasSelection(service), "\(service) accepted a mismatched scope")
                XCTAssertNotNil(navigation.error, "\(service) did not reject mismatched scope")
            }
            await fixture.assertNoDetailRequests()
            await fixture.provider.shutdown()
        }
        let fixture = await Fixture.make(scope: current)
        for service in services {
            let navigation = begin(service)
            fixture.resolve(navigation, currentScope: nil)
            XCTAssertFalse(fixture.hasSelection(service))
            XCTAssertNotNil(navigation.error)
        }
        await fixture.assertNoDetailRequests()
        await fixture.provider.shutdown()
    }

    func testRegionalSavedListsRejectRegionMismatchEvenWhenAllOtherFieldsMatch() async {
        let fixture = await Fixture.make(scope: scope(region: "eu-west-1"))
        for service in services where service != .route53 {
            let navigation = begin(service)
            fixture.resolve(navigation, currentScope: scope())
            XCTAssertFalse(fixture.hasSelection(service), "\(service) accepted another region")
            XCTAssertNotNil(navigation.error)
        }
        await fixture.assertNoDetailRequests()
        await fixture.provider.shutdown()
    }

    func testCurrentScopeMustStillMatchSavedProfileAccountAndRegion() async {
        for current in [scope(profile: AWSProfile(name: "another", region: "us-east-1", ssoStartURL: nil,
                            ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil)),
                        scope(account: "222222222222"), scope(region: "eu-west-1")] {
            let fixture = await Fixture.make(scope: current)
            for service in services where current.region == "us-east-1" || service != .route53 {
                let navigation = begin(service)
                fixture.resolve(navigation, currentScope: current)
                XCTAssertFalse(fixture.hasSelection(service))
                XCTAssertNotNil(navigation.error)
            }
            await fixture.assertNoDetailRequests()
            await fixture.provider.shutdown()
        }
    }

    func testRoute53IgnoresResourceRegionAndStableRoleSessionSuffixIsAccepted() async {
        let loaded = scope(session: "old-session")
        let fixture = await Fixture.make(scope: loaded)
        let current = scope(region: "eu-west-1", session: "new-session")
        let navigation = begin(.route53)
        fixture.resolve(navigation, currentScope: current)
        XCTAssertEqual(fixture.route53.selectedZone?.id, "ZEXAMPLE")
        XCTAssertNil(navigation.error)
        fixture.route53.reset()
        await fixture.provider.shutdown()
    }

    func testStableRoleSessionSuffixIsAcceptedByEveryRegionalList() async {
        let fixture = await Fixture.make(scope: scope(session: "old-session"))
        for service in services where service != .route53 {
            let navigation = begin(service)
            fixture.resolve(navigation, currentScope: scope(session: "new-session"))
            XCTAssertTrue(fixture.hasSelection(service), "\(service) rejected the same stable role")
            XCTAssertNil(navigation.error)
        }
        fixture.cancel()
        await fixture.provider.shutdown()
    }

    func testInvalidScopeClearsExistingSelectionsInsteadOfKeepingWrongAccountDetails() async {
        let fixture = await Fixture.make(scope: scope())
        for service in services {
            fixture.resolve(begin(service), currentScope: scope())
            XCTAssertTrue(fixture.hasSelection(service))
            let navigation = begin(service)
            fixture.resolve(navigation, currentScope: scope(account: "222222222222"))
            XCTAssertFalse(fixture.hasSelection(service))
            XCTAssertNotNil(navigation.error)
        }
        fixture.cancel()
        await fixture.provider.shutdown()
    }

    func testPublicLoadingAndErrorStatesCannotOpenEC2OrLambdaRows() async {
        let fixture = await Fixture.make(scope: scope())
        for service in [AWSService.ec2, .lambda] {
            fixture.ec2.isLoading = true
            fixture.lambda.isLoading = true
            var navigation = begin(service)
            fixture.resolve(navigation, currentScope: scope())
            XCTAssertFalse(fixture.hasSelection(service))
            XCTAssertNotNil(navigation.error)
            fixture.ec2.isLoading = false
            fixture.lambda.isLoading = false
            fixture.ec2.error = "Refresh failed"
            fixture.lambda.error = "Refresh failed"
            navigation = begin(service)
            fixture.resolve(navigation, currentScope: scope())
            XCTAssertFalse(fixture.hasSelection(service))
            XCTAssertTrue(navigation.error?.contains("Refresh failed") == true)
            fixture.ec2.error = nil
            fixture.lambda.error = nil
        }
        await fixture.provider.shutdown()
    }

    func testSNSAndAlarmCachedRowsCannotOpenDuringRefreshOrAfterFailure() async {
        for service in [AWSService.alarms, .sns] {
            let list = FailingListProbe()
            let details = DetailProbe()
            let current = scope()
            let identity = AWSIdentity(account: current.accountID, arn: current.principalARN, userID: "test")
            let alarms = AlarmViewModel(listLoader: { _ in
                try await list.check()
                return [CloudWatchAlarm(arn: Fixture.resourceID(.alarms), name: "saved", kind: .metric, state: "OK")]
            }, tagLoader: { _, _ in await details.record(); return [:] }, historyLoader: { _, _ in await details.record(); return [] })
            let sns = SNSViewModel(listLoader: { _ in
                try await list.check()
                return [SNSTopic(arn: Fixture.resourceID(.sns), name: "saved")]
            }, attributeLoader: { _, _ in await details.record(); return [:] },
                tagLoader: { _, _ in await details.record(); return [:] }, subscriptionLoader: { _, _ in await details.record(); return [] })
            alarms.configure(scope: AlarmScope(profile: current.profile, identity: identity, region: current.region, paths: current.paths))
            sns.configure(scope: SNSScope(profile: current.profile, identity: identity, region: current.region, paths: current.paths))
            await alarms.loadAlarms()
            await sns.loadTopics()
            let gate = TestGate()
            await list.failNext(after: gate)
            if service == .alarms { alarms.refresh() } else { sns.refresh() }
            await gate.waitForEntry()
            for phase in ["loading", "failed"] {
                if phase == "failed" {
                    await gate.open()
                    if service == .alarms { await alarms.waitForCurrentLoad() } else { await sns.waitForCurrentLoad() }
                }
                XCTAssertFalse(service == .alarms ? alarms.alarms.isEmpty : sns.topics.isEmpty)
                let navigation = begin(service)
                navigation.resolve(ec2: EC2ViewModel(), lambda: LambdaViewModel(), s3: S3ViewModel(),
                    alarms: alarms, sns: sns, currentScope: current)
                XCTAssertNil(alarms.selectedAlarm)
                XCTAssertNil(sns.selectedTopic)
                XCTAssertNotNil(navigation.error)
                await alarms.waitForDetails()
                await sns.waitForDetails()
                let count = await details.count
                XCTAssertEqual(count, 0)
            }
        }
    }

    private func scope(profile: AWSProfile? = nil, account: String = "111111111111", role: String = "ReadOnly",
                       region: String = "us-east-1", session: String = "session", config: String = "/offline/config",
                       credentials: String = "/offline/credentials") -> MonitoringScope {
        MonitoringScope(profile: profile ?? AWSProfile(name: "work", region: "us-east-1", ssoStartURL: nil,
            ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil),
            identity: AWSIdentity(account: account, arn: "arn:aws:sts::\(account):assumed-role/\(role)/\(session)", userID: "test"),
            region: region, paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": config,
                "AWS_SHARED_CREDENTIALS_FILE": credentials]))
    }

    private func begin(_ service: AWSService) -> FavoriteNavigation {
        let resource = ResourceFavorite(profileName: "work", accountID: "111111111111",
            region: service == .route53 ? "global" : "us-east-1", service: service,
            resourceID: Fixture.resourceID(service), displayName: "Saved resource")
        let navigation = FavoriteNavigation()
        XCTAssertTrue(navigation.begin(resource, profiles: [scope().profile], selectedProfileName: "work"))
        return navigation
    }

    @MainActor
    private final class Fixture {
        let provider = AWSServiceProvider()
        let probe: DetailProbe
        let ec2 = EC2ViewModel()
        let lambda = LambdaViewModel()
        let s3 = S3ViewModel()
        let alarms: AlarmViewModel
        let sns: SNSViewModel
        let route53: Route53ViewModel
        let elb: ELBViewModel
        let securityGroups = SecurityGroupsViewModel(loader: { _ in [SecurityGroupModel(id: "sg-12345678", name: "saved")] })
        let volumes = EBSViewModel(kind: .volume) { _, scope in [ebsRow(account: scope.accountID)] }
        let snapshots = EBSViewModel(kind: .snapshot) { _, scope in [ebsRow(.snapshot, account: scope.accountID)] }

        init() {
            let probe = DetailProbe()
            self.probe = probe
            alarms = AlarmViewModel(listLoader: { _ in [CloudWatchAlarm(arn: Self.resourceID(.alarms), name: "saved", kind: .metric, state: "OK")] },
                tagLoader: { _, _ in await probe.record(); return [:] }, historyLoader: { _, _ in await probe.record(); return [] })
            sns = SNSViewModel(listLoader: { _ in [SNSTopic(arn: Self.resourceID(.sns), name: "saved")] },
                attributeLoader: { _, _ in await probe.record(); return [:] }, tagLoader: { _, _ in await probe.record(); return [:] },
                subscriptionLoader: { _, _ in await probe.record(); return [] })
            route53 = Route53ViewModel(listLoader: { _ in [.init(id: "ZEXAMPLE", name: "example.test.", isPrivate: false)] },
                detailLoader: { _, zone in await probe.record(); return .init(zone: zone, callerReference: "offline") },
                recordLoader: { _, _ in await probe.record(); return [] }, tagLoader: { _, _ in await probe.record(); return [:] })
            elb = ELBViewModel(loadBalancerLoader: { _ in [.init(arn: Self.resourceID(.loadBalancers), name: "saved", kind: "application")] },
                targetGroupLoader: { _ in [.init(arn: Self.resourceID(.targetGroups), name: "saved", targetType: "instance")] },
                listenerLoader: { _, _ in await probe.record(); return [] }, ruleLoader: { _, _ in await probe.record(); return [] },
                healthLoader: { _, _ in await probe.record(); return [] })
        }

        static func make(scope: MonitoringScope) async -> Fixture {
            let result = Fixture()
            // No provider configuration or credential resolution: any accidental detail client request is rejected locally.
            result.ec2.configure(provider: result.provider, scope: scope, refreshImmediately: false)
            result.lambda.configure(provider: result.provider, scope: scope, refreshImmediately: false)
            result.s3.configure(provider: result.provider, scope: scope, refreshImmediately: false)
            result.ec2.instances = [.init(instanceId: "i-example", name: "saved", instanceType: "t3.micro", state: "running",
                privateIP: nil, publicIP: nil, platformDetails: nil, architecture: nil, vpcId: nil, subnetId: nil,
                availabilityZone: nil, securityGroups: [], imageId: nil, imageName: nil, keyName: nil, launchTime: nil, tags: [:])]
            result.lambda.functions = [.init(functionName: "handler", runtime: nil, state: "Active", lastUpdateStatus: nil,
                lastModified: nil, memorySize: nil, arn: nil, handler: nil, role: nil, codeSize: nil, timeout: nil,
                environment: [:], vpcConfig: nil, packageType: "Zip", imageUri: nil, tags: [:], codeLocation: nil, codeFiles: [])]
            result.s3.buckets = [.init(name: "example-bucket", region: "us-east-1", creationDate: nil, versioningEnabled: nil,
                encryptionEnabled: nil, publicAccessBlock: nil, tags: [:], detailError: nil)]
            let identity = AWSIdentity(account: scope.accountID, arn: scope.principalARN, userID: "test")
            result.alarms.configure(scope: AlarmScope(profile: scope.profile, identity: identity, region: scope.region, paths: scope.paths))
            result.sns.configure(scope: SNSScope(profile: scope.profile, identity: identity, region: scope.region, paths: scope.paths))
            result.route53.configure(scope: scope.route53Scope)
            result.elb.configure(scope: scope)
            result.securityGroups.configure(scope: scope)
            result.volumes.configure(scope: scope)
            result.snapshots.configure(scope: scope)
            await result.alarms.loadAlarms()
            await result.sns.loadTopics()
            await result.route53.loadZones()
            await result.elb.loadLoadBalancers()
            await result.elb.loadTargetGroups()
            await result.securityGroups.loadGroups()
            await result.volumes.loadResources()
            await result.snapshots.loadResources()
            return result
        }

        nonisolated static func resourceID(_ service: AWSService) -> String {
            switch service {
            case .ec2: return "i-example"
            case .lambda: return "handler"
            case .s3: return "example-bucket"
            case .alarms: return "arn:aws:cloudwatch:us-east-1:111111111111:alarm:saved"
            case .sns: return "arn:aws:sns:us-east-1:111111111111:saved"
            case .route53: return "ZEXAMPLE"
            case .loadBalancers: return "arn:aws:elasticloadbalancing:us-east-1:111111111111:loadbalancer/app/saved/0123456789abcdef"
            case .targetGroups: return "arn:aws:elasticloadbalancing:us-east-1:111111111111:targetgroup/saved/0123456789abcdef"
            case .securityGroups: return "sg-12345678"
            case .ebsVolumes: return "vol-12345678"
            case .ebsSnapshots: return "snap-12345678"
            default: return "unused"
            }
        }

        func resolve(_ navigation: FavoriteNavigation, currentScope: MonitoringScope?) {
            navigation.resolve(ec2: ec2, lambda: lambda, s3: s3, alarms: alarms, sns: sns, route53: route53,
                elb: elb, securityGroups: securityGroups, volumes: volumes, snapshots: snapshots, currentScope: currentScope)
        }

        func hasSelection(_ service: AWSService) -> Bool {
            switch service {
            case .ec2: return ec2.selectedInstance != nil
            case .lambda: return lambda.selectedFunction != nil
            case .s3: return s3.selectedBucket != nil
            case .alarms: return alarms.selectedAlarm != nil
            case .sns: return sns.selectedTopic != nil
            case .route53: return route53.selectedZone != nil
            case .loadBalancers: return elb.selectedLoadBalancer != nil
            case .targetGroups: return elb.selectedTargetGroup != nil
            case .securityGroups: return securityGroups.selectedGroup != nil
            case .ebsVolumes: return volumes.selectedResource != nil
            case .ebsSnapshots: return snapshots.selectedResource != nil
            default: return false
            }
        }

        func assertNoDetailRequests(file: StaticString = #filePath, line: UInt = #line) async {
            await alarms.waitForDetails()
            await sns.waitForDetails()
            await route53.waitForDetails()
            await elb.waitForDetails()
            let count = await probe.count
            XCTAssertEqual(count, 0, "Rejected destinations must not query details", file: file, line: line)
        }

        func cancel() {
            ec2.reset(); lambda.reset(); s3.reset(); alarms.reset(); sns.reset(); route53.reset(); elb.reset()
            securityGroups.reset(); volumes.reset(); snapshots.reset()
        }
    }
}

private actor DetailProbe {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor FailingListProbe {
    private var gate: TestGate?
    func failNext(after gate: TestGate) { self.gate = gate }
    func check() async throws {
        guard let gate else { return }
        await gate.wait()
        throw URLError(.timedOut)
    }
}
