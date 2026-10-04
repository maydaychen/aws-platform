import XCTest
@testable import AWSPlatform

@MainActor
final class RelationshipNavigationTests: XCTestCase {
    func testBeginRequiresExplicitVerifiedProfileAndCompleteIdentity() {
        let current = scope()
        let reference = reference(.ec2, scope: current)
        let nav = FavoriteNavigation()
        let alternatives: [MonitoringScope?] = [
            nil, scope(profile: "other"), scope(account: "222222222222"),
            scope(principal: "arn:aws:iam::111122223333:user/other"),
            scope(config: "/example/other-config"), scope(credentials: "/example/other-credentials"),
            scope(region: "global"), scope(principal: "arn:aws-cn:iam::111122223333:user/test")
        ]
        for selected in alternatives {
            XCTAssertFalse(nav.beginRelationship(reference, currentScope: selected, profiles: [current.profile]))
            XCTAssertNil(nav.target)
            XCTAssertNil(nav.relationshipReference)
        }
        let changedProfile = AWSProfile(name: current.profile.name, region: "ap-northeast-1", ssoStartURL: nil,
                                        ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil)
        XCTAssertFalse(nav.beginRelationship(reference, currentScope: current, profiles: [changedProfile]))
        XCTAssertFalse(nav.beginRelationship(reference, currentScope: current, profiles: []))
        let invalid = ResourceRelationReference(scope: current, service: .ec2, resourceID: "not-an-instance", name: "bad")
        XCTAssertFalse(nav.beginRelationship(invalid, currentScope: current, profiles: [current.profile]))
        XCTAssertTrue(nav.beginRelationship(reference, currentScope: current, profiles: [current.profile]))
        XCTAssertEqual(nav.relationshipReference, reference)
    }

    func testRegionalDestinationRequiresExplicitTargetRegionAndRevalidatesEveryScopeField() {
        let current = scope()
        let destination = scope(region: "ap-northeast-1")
        let reference = reference(.ec2, scope: destination)
        let nav = FavoriteNavigation()
        XCTAssertTrue(nav.beginRelationship(reference, currentScope: current, profiles: [current.profile]))
        XCTAssertFalse(nav.matches(profileName: current.profile.name, region: current.region))
        XCTAssertTrue(nav.matches(profileName: current.profile.name, region: destination.region))
        XCTAssertTrue(nav.validateRelationshipScope(destination))
        for changed in [current, scope(region: destination.region, principal: "arn:aws:iam::111122223333:user/changed"),
                        scope(region: destination.region, config: "/example/new-config"),
                        scope(account: "222222222222", region: destination.region)] {
            XCTAssertTrue(nav.beginRelationship(reference, currentScope: current, profiles: [current.profile]))
            XCTAssertFalse(nav.validateRelationshipScope(changed))
            XCTAssertNil(nav.target)
            XCTAssertNil(nav.relationshipReference)
        }
    }

    func testGlobalRecordUsesCurrentResourceRegionInsteadOfTheSheetsQueryRegion() async {
        let current = scope()
        let record = record(identifier: "blue")
        let reference = reference(.route53, scope: scope(region: "ap-northeast-1"), recordID: record.id)
        let vm = zoneVM(records: [record])
        vm.configure(scope: current.route53Scope)
        await vm.loadZones()
        let nav = FavoriteNavigation()
        XCTAssertTrue(nav.beginRelationship(reference, currentScope: current, profiles: [current.profile]))
        XCTAssertEqual(nav.target?.region, "global")
        XCTAssertEqual(nav.relationshipReference?.scope.region, current.region)
        XCTAssertTrue(nav.matches(profileName: current.profile.name, region: current.region))
        XCTAssertFalse(nav.matches(profileName: current.profile.name, region: "ap-northeast-1"))
        XCTAssertTrue(nav.validateRelationshipScope(current))
        await resolve(nav, route53: vm, latestScope: { current })
        XCTAssertEqual(vm.focusedRecordID, record.id)
        XCTAssertNil(nav.error)
    }

    func testChangedScopeBeforeResolveDoesNotAlterTheNewSelection() async {
        let current = scope()
        let vm = LambdaViewModel()
        let selected = function(name: "new-selection")
        vm.functions = [selected, function()]
        vm.selectedFunction = selected
        let nav = FavoriteNavigation()
        XCTAssertTrue(nav.beginRelationship(reference(.lambda), currentScope: current, profiles: [current.profile]))
        await resolve(nav, lambda: vm, latestScope: { self.scope(account: "222222222222") })
        XCTAssertEqual(vm.selectedFunction, selected)
        XCTAssertNil(nav.target)
        XCTAssertNil(nav.relationshipReference)
        XCTAssertNotNil(nav.error)
    }

    func testQualifiedLambdaMatchesOnlyExactBaseARNAndDoesNotSaveNavigation() async throws {
        let suite = "RelationshipNavigationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let favorites = FavoritesViewModel(defaults: defaults)
        let recents = RecentResourcesViewModel(defaults: defaults)
        let current = scope()
        let qualified = ResourceRelationReference(scope: current, service: .lambda,
            resourceID: "arn:aws:lambda:eu-west-1:111122223333:function:handler:live", name: "handler:live")
        for row in [function(), function(arn: "arn:aws:lambda:eu-west-1:222222222222:function:handler"),
                    function(arn: qualified.resourceID)] {
            let vm = LambdaViewModel()
            vm.functions = [row]
            vm.searchText = "hidden"
            vm.stateFilter = "Failed"
            vm.packageFilter = "Image"
            let nav = FavoriteNavigation()
            XCTAssertTrue(nav.beginRelationship(qualified, currentScope: current, profiles: [current.profile]))
            XCTAssertEqual(nav.relationshipReference?.resourceID, qualified.resourceID)
            XCTAssertEqual(nav.target?.resourceID, "handler")
            await resolve(nav, lambda: vm, latestScope: { current })
            if row == function() {
                XCTAssertEqual(vm.selectedFunction, row)
                XCTAssertEqual(vm.filteredFunctions, [row])
                XCTAssertNil(nav.error)
            } else {
                XCTAssertNil(vm.selectedFunction)
                XCTAssertTrue(nav.error?.contains("not found") == true)
                XCTAssertFalse(nav.error?.contains("saved") == true)
            }
            XCTAssertNil(nav.relationshipReference)
        }
        XCTAssertTrue(favorites.favorites.isEmpty)
        XCTAssertTrue(recents.entries.isEmpty)
        XCTAssertNil(defaults.object(forKey: FavoritesViewModel.storageKey))
        XCTAssertNil(defaults.object(forKey: RecentResourcesViewModel.storageKey))
    }

    func testMissingFailedOrLoadingInstanceNeverFallsBackToCachedSelection() async {
        let current = scope()
        let requested = instance()
        let other = instance(id: "i-87654321")
        for state in ["missing", "failed", "loading"] {
            let vm = EC2ViewModel()
            vm.instances = state == "missing" ? [other] : [requested, other]
            vm.selectedInstance = other
            vm.error = state == "failed" ? "Cached list is stale" : nil
            vm.isLoading = state == "loading"
            let nav = FavoriteNavigation()
            XCTAssertTrue(nav.beginRelationship(reference(.ec2), currentScope: current, profiles: [current.profile]))
            await resolve(nav, ec2: vm, latestScope: { current })
            XCTAssertNil(vm.selectedInstance)
            XCTAssertNil(nav.target)
            XCTAssertTrue(nav.error?.contains("Open Relationships again") == true)
        }
    }

    func testSecurityGroupRelationshipRejectsSharedOrUnknownOwnerButSavedNavigationRemainsReadable() async {
        let current = scope()
        for owner in [current.accountID, "222222222222", nil] as [String?] {
            let group = SecurityGroupModel(id: "sg-12345678", name: "web", ownerID: owner, vpcID: "vpc-12345678")
            let vm = SecurityGroupsViewModel(loader: { _ in [group] })
            vm.configure(scope: current)
            await vm.loadGroups()
            vm.searchText = "hidden"
            vm.vpcFilter = "missing"
            let nav = FavoriteNavigation()
            let reference = reference(.securityGroups)
            XCTAssertTrue(nav.beginRelationship(reference, currentScope: current, profiles: [current.profile]))
            await resolve(nav, securityGroups: vm, latestScope: { current })
            if owner == current.accountID {
                XCTAssertEqual(vm.selectedGroup, group)
                XCTAssertEqual(vm.filteredGroups, [group])
                XCTAssertNil(nav.error)
            } else {
                XCTAssertNil(vm.selectedGroup)
                XCTAssertNotNil(nav.error)
            }
            XCTAssertTrue(nav.begin(reference.favoriteDestination, profiles: [current.profile], selectedProfileName: current.profile.name))
            nav.resolve(ec2: EC2ViewModel(), lambda: LambdaViewModel(), s3: S3ViewModel(),
                        alarms: alarmVM(), sns: snsVM(), securityGroups: vm)
            XCTAssertEqual(vm.selectedGroup, group)
            XCTAssertNil(nav.error)
        }
    }

    func testStaleSecurityGroupsAndELBListsCannotOpenCachedRelationships() async {
        let current = scope()
        let probe = RelationshipFailureProbe()
        let group = SecurityGroupModel(id: "sg-12345678", name: "web", ownerID: current.accountID)
        let sg = SecurityGroupsViewModel(loader: { _ in try await probe.load("sg"); return [group] })
        sg.configure(scope: current)
        await sg.loadGroups()
        await sg.loadGroups()
        XCTAssertTrue(sg.isStale)
        let lb = ELBLoadBalancer(arn: reference(.loadBalancers).resourceID, name: "web", kind: "application")
        let tg = ELBTargetGroup(arn: reference(.targetGroups).resourceID, name: "web", targetType: "instance")
        let elb = ELBViewModel(loadBalancerLoader: { _ in try await probe.load("lb"); return [lb] },
                               targetGroupLoader: { _ in try await probe.load("tg"); return [tg] },
                               listenerLoader: { _, _ in [] }, ruleLoader: { _, _ in [] }, healthLoader: { _, _ in [] })
        elb.configure(scope: current)
        await elb.loadLoadBalancers()
        await elb.loadLoadBalancers()
        await elb.loadTargetGroups()
        await elb.loadTargetGroups()
        for service in [AWSService.securityGroups, .loadBalancers, .targetGroups] {
            let nav = FavoriteNavigation()
            XCTAssertTrue(nav.beginRelationship(reference(service), currentScope: current, profiles: [current.profile]))
            await resolve(nav, elb: elb, securityGroups: sg, latestScope: { current })
            XCTAssertNil(sg.selectedGroup)
            XCTAssertNil(elb.selectedLoadBalancer)
            XCTAssertNil(elb.selectedTargetGroup)
            XCTAssertNotNil(nav.error)
            XCTAssertNil(nav.relationshipReference)
        }
    }

    func testRecordFocusMatchesZoneNameTypeAndRoutingIdentifierAndClearsFilters() async {
        let current = scope()
        let blue = record(identifier: "blue")
        let green = record(identifier: "green")
        let txt = Route53Record(name: blue.name, type: "TXT", setIdentifier: blue.setIdentifier, values: ["example"])
        let otherZone = Route53HostedZone(id: "ZOTHER", name: "other.test.", isPrivate: true)
        let vm = zoneVM(records: [blue, green, txt], zones: [zone(), otherZone])
        vm.configure(scope: current.route53Scope)
        await vm.loadZones()
        vm.selectedZone = otherZone
        await vm.waitForDetails()
        vm.recordSearchText = "hidden"
        vm.recordTypeFilter = "TXT"
        let nav = FavoriteNavigation()
        XCTAssertTrue(nav.beginRelationship(reference(.route53, recordID: green.id), currentScope: current, profiles: [current.profile]))
        await resolve(nav, route53: vm, latestScope: { current })
        XCTAssertEqual(vm.selectedZone?.id, "ZEXAMPLE")
        XCTAssertEqual(vm.focusedRecordID, green.id)
        XCTAssertEqual(vm.recordSearchText, "")
        XCTAssertEqual(vm.recordTypeFilter, "All")
        XCTAssertEqual(vm.filteredRecords, [blue, green, txt])
        XCTAssertNil(nav.error)
        vm.selectedZone = otherZone
        XCTAssertNil(vm.focusedRecordID)
        await vm.waitForDetails()
        XCTAssertTrue(vm.focusRecord(blue.id))
        vm.configure(scope: scope(account: "222222222222").route53Scope)
        XCTAssertNil(vm.focusedRecordID)
        XCTAssertTrue(vm.records.isEmpty)
    }

    func testMissingOrFailedRecordNeverFocusesSimilarRecord() async {
        let current = scope()
        let requested = record(identifier: "missing")
        let zone = zone()
        for fails in [false, true] {
            let available = record(identifier: "blue")
            let vm = Route53ViewModel(listLoader: { _ in [zone] },
                                     detailLoader: { _, zone in Route53ZoneDetails(zone: zone, callerReference: "test") },
                                     recordLoader: { _, _ in
                                         if fails { throw Route53Error.invalidResponse }
                                         return [available]
                                     }, tagLoader: { _, _ in [:] })
            vm.configure(scope: current.route53Scope)
            await vm.loadZones()
            let nav = FavoriteNavigation()
            XCTAssertTrue(nav.beginRelationship(reference(.route53, recordID: requested.id), currentScope: current, profiles: [current.profile]))
            await resolve(nav, route53: vm, latestScope: { current })
            XCTAssertNil(vm.focusedRecordID)
            XCTAssertNotNil(nav.error)
            XCTAssertFalse(nav.error?.contains("saved") == true)
            XCTAssertNil(nav.relationshipReference)
            if fails { XCTAssertFalse(vm.focusRecord(available.id)) }
        }
    }

    func testNavigationCancellationLeavesSharedRecordRequestRunningWithoutLateFocus() async {
        for cancelCaller in [false, true] {
            let current = scope()
            let record = record(identifier: "blue")
            let gate = RelationshipRecordGate()
            let vm = gatedZoneVM(gate: gate, record: record)
            vm.configure(scope: current.route53Scope)
            await vm.loadZones()
            vm.selectedZone = zone()
            await gate.waitForEntry()
            XCTAssertFalse(vm.focusRecord(record.id), "A record cannot be focused while its list is still loading")
            let nav = FavoriteNavigation()
            XCTAssertTrue(nav.beginRelationship(reference(.route53, recordID: record.id), currentScope: current, profiles: [current.profile]))
            let task = Task { await self.resolve(nav, route53: vm, latestScope: { current }) }
            await Task.yield()
            if cancelCaller { task.cancel() } else { nav.cancel() }
            XCTAssertTrue(vm.isRecordsLoading, "Cancelling navigation must not cancel the shared record request")
            await gate.open()
            await task.value
            await vm.waitForDetails()
            XCTAssertEqual(vm.records, [record])
            XCTAssertNil(vm.recordsError)
            XCTAssertNil(vm.focusedRecordID)
            XCTAssertNil(nav.target)
            XCTAssertNil(nav.relationshipReference)
            XCTAssertNil(nav.error)
        }
    }

    func testLateRecordResolutionCannotOverwriteNewNavigationOrSelection() async {
        let current = scope()
        let record = record(identifier: "blue")
        let gate = RelationshipRecordGate()
        let vm = gatedZoneVM(gate: gate, record: record)
        vm.configure(scope: current.route53Scope)
        await vm.loadZones()
        let nav = FavoriteNavigation()
        XCTAssertTrue(nav.beginRelationship(reference(.route53, recordID: record.id), currentScope: current, profiles: [current.profile]))
        let old = Task { await self.resolve(nav, route53: vm, latestScope: { current }) }
        await gate.waitForEntry()
        let lambda = LambdaViewModel()
        lambda.functions = [function()]
        XCTAssertTrue(nav.beginRelationship(reference(.lambda), currentScope: current, profiles: [current.profile]))
        await resolve(nav, lambda: lambda, latestScope: { current })
        XCTAssertEqual(lambda.selectedFunction, function())
        await gate.open()
        await old.value
        XCTAssertNil(vm.focusedRecordID)
        XCTAssertEqual(lambda.selectedFunction, function())
        XCTAssertNil(nav.error)
        XCTAssertNil(nav.relationshipReference)
    }

    func testLateRecordResolutionRechecksIdentityRegionAndCurrentZoneWithoutChangingNewSelection() async {
        for change in ["identity", "region", "zone"] {
            let current = scope()
            let record = record(identifier: "blue")
            let gate = RelationshipRecordGate()
            let other = Route53HostedZone(id: "ZOTHER", name: "other.test.", isPrivate: true)
            let vm = gatedZoneVM(gate: gate, record: record, zones: [zone(), other])
            vm.configure(scope: current.route53Scope)
            await vm.loadZones()
            let live = RelationshipLiveScope(current)
            let nav = FavoriteNavigation()
            XCTAssertTrue(nav.beginRelationship(reference(.route53, recordID: record.id), currentScope: current, profiles: [current.profile]))
            let task = Task { await self.resolve(nav, route53: vm, latestScope: { live.value }) }
            await gate.waitForEntry()
            if change == "identity" {
                live.value = scope(account: "222222222222")
                vm.configure(scope: live.value!.route53Scope)
                await vm.loadZones()
                vm.selectedZone = other
            } else if change == "region" {
                live.value = scope(region: "ap-northeast-1")
            } else {
                vm.selectedZone = other
            }
            await gate.open()
            await task.value
            await vm.waitForDetails()
            XCTAssertNil(vm.focusedRecordID)
            XCTAssertEqual(vm.selectedZone?.id, change == "region" ? "ZEXAMPLE" : other.id)
            XCTAssertNotNil(nav.error)
            XCTAssertNil(nav.relationshipReference)
        }
    }

    private func scope(profile: String = "work", account: String = "111122223333", region: String = "eu-west-1",
                       principal: String? = nil, config: String = "/example/config", credentials: String = "/example/credentials") -> MonitoringScope {
        MonitoringScope(profile: AWSProfile(name: profile, region: "eu-west-1", ssoStartURL: nil,
                                           ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil),
                        identity: AWSIdentity(account: account, arn: principal ?? "arn:aws:iam::\(account):user/test", userID: "test"),
                        region: region, paths: AWSConfigurationPaths(environment: [
                            "AWS_CONFIG_FILE": config, "AWS_SHARED_CREDENTIALS_FILE": credentials
                        ]))
    }

    private func reference(_ service: AWSService, scope: MonitoringScope? = nil,
                           recordID: Route53Record.ID? = nil) -> ResourceRelationReference {
        let scope = scope ?? self.scope()
        let id: String
        switch service {
        case .ec2: id = "i-12345678"
        case .lambda: id = "arn:aws:lambda:\(scope.region):\(scope.accountID):function:handler"
        case .loadBalancers: id = "arn:aws:elasticloadbalancing:\(scope.region):\(scope.accountID):loadbalancer/app/web/0123456789abcdef"
        case .targetGroups: id = "arn:aws:elasticloadbalancing:\(scope.region):\(scope.accountID):targetgroup/web/0123456789abcdef"
        case .securityGroups: id = "sg-12345678"
        default: id = "ZEXAMPLE"
        }
        return ResourceRelationReference(scope: scope, service: service, resourceID: id, name: "Related resource", recordID: recordID)
    }

    private func zone() -> Route53HostedZone { Route53HostedZone(id: "ZEXAMPLE", name: "example.test.", isPrivate: false) }

    private func record(identifier: String) -> Route53Record {
        Route53Record(name: "www.example.test.", type: "A", setIdentifier: identifier,
                      alias: Route53Alias(dnsName: "web.elb.amazonaws.com.", hostedZoneID: "ZELB", evaluateTargetHealth: true),
                      routingPolicy: "Weighted")
    }

    private func zoneVM(records: [Route53Record], zones: [Route53HostedZone]? = nil) -> Route53ViewModel {
        let zones = zones ?? [zone()]
        return Route53ViewModel(listLoader: { _ in zones },
                               detailLoader: { _, zone in Route53ZoneDetails(zone: zone, callerReference: "test") },
                               recordLoader: { _, _ in records }, tagLoader: { _, _ in [:] })
    }

    private func gatedZoneVM(gate: RelationshipRecordGate, record: Route53Record,
                            zones: [Route53HostedZone]? = nil) -> Route53ViewModel {
        let zones = zones ?? [zone()]
        return Route53ViewModel(listLoader: { _ in zones },
                               detailLoader: { _, zone in Route53ZoneDetails(zone: zone, callerReference: "test") },
                               recordLoader: { _, zone in
                                   if zone.id == "ZEXAMPLE" { await gate.wait() }
                                   return [record]
                               }, tagLoader: { _, _ in [:] })
    }

    private func function(name: String = "handler", arn: String? = nil) -> LambdaFunctionModel {
        LambdaFunctionModel(functionName: name, runtime: "provided.al2023", state: "Active", lastUpdateStatus: nil,
                            lastModified: nil, memorySize: nil, arn: arn ?? "arn:aws:lambda:eu-west-1:111122223333:function:\(name)",
                            handler: nil, role: nil, codeSize: nil, timeout: nil, environment: [:], vpcConfig: nil,
                            packageType: "Zip", imageUri: nil, tags: [:], codeLocation: nil, codeFiles: [])
    }

    private func instance(id: String = "i-12345678") -> EC2InstanceModel {
        EC2InstanceModel(instanceId: id, name: "web", instanceType: "t3.micro", state: "running", privateIP: nil,
                         publicIP: nil, platformDetails: nil, architecture: nil, vpcId: nil, subnetId: nil,
                         availabilityZone: nil, securityGroups: [], imageId: nil, imageName: nil, keyName: nil,
                         launchTime: nil, tags: [:])
    }

    private func alarmVM() -> AlarmViewModel {
        AlarmViewModel(listLoader: { _ in [] }, tagLoader: { _, _ in [:] }, historyLoader: { _, _ in [] })
    }

    private func snsVM() -> SNSViewModel {
        SNSViewModel(listLoader: { _ in [] }, attributeLoader: { _, _ in [:] }, tagLoader: { _, _ in [:] }, subscriptionLoader: { _, _ in [] })
    }

    private func resolve(_ nav: FavoriteNavigation, ec2: EC2ViewModel? = nil, lambda: LambdaViewModel? = nil,
                         route53: Route53ViewModel? = nil, elb: ELBViewModel? = nil,
                         securityGroups: SecurityGroupsViewModel? = nil,
                         latestScope: @MainActor () -> MonitoringScope?) async {
        await nav.resolveRelationship(ec2: ec2 ?? EC2ViewModel(), lambda: lambda ?? LambdaViewModel(), s3: S3ViewModel(),
                                      alarms: alarmVM(), sns: snsVM(), route53: route53, elb: elb,
                                      securityGroups: securityGroups, latestScope: latestScope)
    }
}

@MainActor
private final class RelationshipLiveScope {
    var value: MonitoringScope?
    init(_ value: MonitoringScope?) { self.value = value }
}

private actor RelationshipFailureProbe {
    private var counts: [String: Int] = [:]
    func load(_ key: String) throws {
        counts[key, default: 0] += 1
        if counts[key, default: 0] > 1 { throw ResourceRelationError.failed }
    }
}

private actor RelationshipRecordGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private var isOpen = false

    func wait() async {
        entered = true
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitForEntry() async {
        while !entered { await Task.yield() }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
