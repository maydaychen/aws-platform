import XCTest
@testable import AWSPlatform

@MainActor
final class ResourceRelationshipServiceTests: XCTestCase {
    func testInvalidScopeIDsAndForeignARNsMakeZeroCalls() async {
        let calls = Calls()
        let service = service(fixture(), calls: calls)
        let invalid = [
            reference(.ec2, id: "i-12345678", scope: scope(account: "invalid")),
            reference(.ec2, id: "i-12345678\n"), reference(.securityGroups, id: "sg-wrong"),
            reference(.loadBalancers, id: balancer(account: "222222222222").arn),
            reference(.loadBalancers, id: balancer(region: "eu-west-1").arn),
            reference(.loadBalancers, id: balancer(partition: "aws-cn").arn),
            reference(.route53, id: "/hostedzone/Z1"), reference(.s3, id: "bucket"),
            reference(.lambda, id: "arn:aws:lambda:us-east-1:111111111111:function:handler")
        ]
        for reference in invalid {
            do {
                _ = try await service.load(reference: reference, includeReverse: true)
                XCTFail("Invalid or non-explorable resource must fail")
            } catch {
                XCTAssertTrue(error is ResourceRelationError)
            }
        }
        let count = await calls.counts
        XCTAssertTrue(count.isEmpty)
    }

    func testLoadBalancerOneHopLoadsAssociationsAndGroupsWithoutReverseOrHealthCalls() async throws {
        var data = fixture()
        var unrelated = targetGroup(name: "other")
        unrelated.loadBalancerARNs = [balancer(name: "other").arn]
        data.targetGroups.append(unrelated)
        let calls = Calls()
        let result = try await service(data, calls: calls).load(reference: reference(.loadBalancers, id: balancer().arn), includeReverse: false)
        XCTAssertEqual(section("target-groups", result).nodes.map(\.reference?.resourceID), [targetGroup().arn])
        XCTAssertTrue(section("target-groups", result).nodes.first?.note?.contains("does not identify a listener rule") == true)
        XCTAssertEqual(section("security-groups", result).nodes.first?.reference?.resourceID, "sg-12345678")
        XCTAssertTrue(section("dns", result).requiresScan)
        let count = await calls.counts
        XCTAssertEqual(count, ["balancers": 1, "targetGroups": 1, "groups": 1])
    }

    func testIndependentSectionFailurePreservesOtherRelationsAndSanitizesErrors() async throws {
        var data = fixture()
        data.failures = ["targetGroups", "zones"]
        let result = try await service(data).load(reference: reference(.loadBalancers, id: balancer().arn), includeReverse: true)
        XCTAssertEqual(section("security-groups", result).nodes.count, 1)
        for id in ["target-groups", "dns"] {
            let failed = section(id, result)
            XCTAssertTrue(failed.isIncomplete)
            XCTAssertNotNil(failed.error)
            XCTAssertFalse(failed.error?.contains("secret-endpoint") == true)
        }
    }

    func testMissingSourceFailsBeforeNeighborRequests() async throws {
        var data = fixture()
        data.balancers = []
        let calls = Calls()
        do {
            _ = try await service(data, calls: calls).load(reference: reference(.loadBalancers, id: balancer().arn), includeReverse: true)
            XCTFail("Missing source must fail")
        } catch { XCTAssertEqual(error as? ResourceRelationError, .notFound) }
        let count = await calls.counts
        XCTAssertEqual(count, ["balancers": 1])
    }

    func testMalformedCrossScopeInventoryCannotProduceLinks() async {
        for wrong in [balancer(account: "222222222222"), balancer(region: "eu-west-1"), balancer(partition: "aws-cn")] {
            var data = fixture()
            data.balancers.append(wrong)
            do {
                _ = try await service(data).load(reference: reference(.loadBalancers, id: balancer().arn), includeReverse: false)
                XCTFail("Cross-scope inventory must fail")
            } catch { XCTAssertEqual(error as? ResourceRelationError, .invalidResource) }
        }
    }

    func testEC2UsesAllStructuredGroupIDsIncludingSecondaryInterfacesAndNeverGuessesOwners() async throws {
        var data = fixture()
        data.instances = [RelationInstance(id: "i-12345678", name: "web", securityGroupIDs: ["sg-12345678", "sg-87654321", "sg-11111111", "sg-12345678"])]
        data.groups += [SecurityGroupModel(id: "sg-87654321", name: "secondary", ownerID: "111111111111"),
                        SecurityGroupModel(id: "sg-11111111", name: "shared", ownerID: "222222222222")]
        let calls = Calls()
        let result = try await service(data, calls: calls).load(reference: reference(.ec2, id: "i-12345678"), includeReverse: false)
        let nodes = section("security-groups", result).nodes
        XCTAssertEqual(nodes.count, 3)
        XCTAssertEqual(Set(nodes.compactMap(\.reference?.resourceID)), ["sg-12345678", "sg-87654321"])
        XCTAssertNil(nodes.first { $0.name == "shared" }?.reference)
        XCTAssertTrue(section("target-groups", result).requiresScan)
        let count = await calls.counts
        XCTAssertEqual(count, ["instance": 1, "groups": 1])
    }

    func testEC2ReverseScanPreservesEveryPortAndPartialCounts() async throws {
        var data = fixture()
        let targets = [ELBTargetHealth(targetID: "i-12345678", port: 80, state: "unhealthy"),
                       ELBTargetHealth(targetID: "i-12345678", port: 443, state: "unused"),
                       ELBTargetHealth(targetID: "i-12345678", port: 8080, state: "unused", reason: "Target.NotRegistered"),
                       ELBTargetHealth(targetID: "i-87654321", port: 80, state: "healthy")]
        data.membership = ELBMembershipResult(matches: [.init(group: targetGroup(), targets: targets)], checkedGroupCount: 2,
                                              totalGroupCount: 3, failures: [.init(name: "failed-group", value: "secret-endpoint")])
        let result = try await service(data).load(reference: reference(.ec2, id: "i-12345678"), includeReverse: true)
        let memberships = section("target-groups", result)
        XCTAssertTrue(memberships.isIncomplete)
        XCTAssertEqual(memberships.checkedCount, 2)
        XCTAssertEqual(memberships.totalCount, 3)
        XCTAssertEqual(memberships.nodes.count, 2)
        XCTAssertEqual(Set(memberships.nodes.map(\.id)).count, 2)
        XCTAssertEqual(Set(memberships.nodes.flatMap(\.fields).filter { $0.name == "Port" }.map(\.value)), ["80", "443"])
        XCTAssertFalse(memberships.error?.contains("secret-endpoint") == true)
    }

    func testSGRuleReferencesOnlyLinkConfirmedSameAccountAndDoNotInferCIDRs() async throws {
        var data = fixture()
        data.groups[0].inboundRules = [
            rule("sg-87654321", owner: "111111111111"),
            rule("sg-11111111", owner: "222222222222"),
            rule("sg-22222222", owner: nil),
            rule("sg-33333333", owner: nil),
            SecurityGroupRule(protocolName: "tcp", portRange: "443", target: "10.0.0.0/8")
        ]
        data.groups += [SecurityGroupModel(id: "sg-87654321", name: "local", ownerID: "111111111111"),
                        SecurityGroupModel(id: "sg-11111111", name: "foreign", ownerID: "222222222222"),
                        SecurityGroupModel(id: "sg-22222222", name: "known-local", ownerID: "111111111111")]
        let calls = Calls()
        let result = try await service(data, calls: calls).load(reference: reference(.securityGroups, id: "sg-12345678"), includeReverse: false)
        let permissions = section("permissions", result)
        XCTAssertEqual(permissions.nodes.count, 4)
        XCTAssertEqual(Set(permissions.nodes.compactMap(\.reference?.resourceID)), ["sg-87654321", "sg-22222222"])
        XCTAssertTrue(permissions.nodes.allSatisfy { $0.relation.contains("permission reference") })
        XCTAssertTrue(section("instances", result).requiresScan)
        XCTAssertTrue(section("load-balancers", result).requiresScan)
        let count = await calls.counts
        XCTAssertEqual(count, ["groups": 1])
    }

    func testSGReverseSectionsFailIndependentlyAndUseStructuredBinding() async throws {
        var data = fixture()
        data.failures = ["instancesUsingGroup"]
        var unrelated = balancer(name: "unrelated")
        unrelated.securityGroupIDs = []
        unrelated.fields = [.init(name: "Security groups", value: "sg-12345678")]
        data.balancers.append(unrelated)
        let result = try await service(data).load(reference: reference(.securityGroups, id: "sg-12345678"), includeReverse: true)
        XCTAssertTrue(section("instances", result).isIncomplete)
        XCTAssertEqual(section("load-balancers", result).nodes.map(\.reference?.resourceID), [balancer().arn])
    }

    func testSGReverseUsageIncludesSecondaryBindingAndExcludesUnrelatedInstances() async throws {
        var data = fixture()
        data.instances = [RelationInstance(id: "i-12345678", name: "secondary binding", securityGroupIDs: ["sg-87654321", "sg-12345678"]),
                          RelationInstance(id: "i-87654321", name: "unrelated", securityGroupIDs: ["sg-87654321"])]
        let result = try await service(data).load(reference: reference(.securityGroups, id: "sg-12345678"), includeReverse: true)
        XCTAssertEqual(section("instances", result).nodes.map(\.reference?.resourceID), ["i-12345678"])
    }

    func testTargetGroupsPreserveIPTargetsWithoutLinksAndExactInstanceALBLambdaReferences() async throws {
        for (type, id, expected) in [
            ("instance", "i-12345678", AWSService.ec2),
            ("alb", balancer().arn, AWSService.loadBalancers),
            ("lambda", "arn:aws:lambda:us-east-1:111111111111:function:handler:live", AWSService.lambda)
        ] {
            var data = fixture()
            data.targetGroups = [targetGroup(targetType: type)]
            data.targets = [ELBTargetHealth(targetID: id, port: 443, state: "unhealthy", reason: "Target.FailedHealthChecks")]
            let result = try await service(data).load(reference: reference(.targetGroups, id: targetGroup().arn), includeReverse: false)
            let node = try XCTUnwrap(section("targets", result).nodes.first)
            XCTAssertEqual(node.reference?.service, expected)
            XCTAssertEqual(node.reference?.resourceID, id)
            XCTAssertTrue(node.fields.contains(.init(name: "Port", value: "443")))
            if type == "lambda" {
                XCTAssertTrue(node.fields.contains(.init(name: "Function ARN", value: id)))
                XCTAssertTrue(node.fields.contains(.init(name: "Qualifier", value: "live")))
                XCTAssertTrue(node.note?.contains("function-level") == true)
            }
        }
        var data = fixture()
        data.targetGroups = [targetGroup(targetType: "ip")]
        data.targets = [ELBTargetHealth(targetID: "10.0.0.12", port: 80, state: "healthy")]
        let calls = Calls()
        let result = try await service(data, calls: calls).load(reference: reference(.targetGroups, id: targetGroup().arn), includeReverse: false)
        XCTAssertNil(section("targets", result).nodes.first?.reference)
        XCTAssertTrue(section("targets", result).nodes.first?.note?.contains("without inferring") == true)
        let count = await calls.counts
        XCTAssertNil(count["instance"])
        XCTAssertNil(count["instancesUsingGroup"])
    }

    func testForeignTargetARNAndNotRegisteredTargetsHaveNoNavigation() async throws {
        var data = fixture()
        data.targetGroups = [targetGroup(targetType: "lambda")]
        data.targets = [ELBTargetHealth(targetID: "arn:aws:lambda:us-east-1:222222222222:function:handler", state: "healthy"),
                        ELBTargetHealth(targetID: "arn:aws:lambda:eu-west-1:111111111111:function:handler", state: "healthy"),
                        ELBTargetHealth(targetID: "arn:aws-cn:lambda:us-east-1:111111111111:function:handler", state: "healthy"),
                        ELBTargetHealth(targetID: "arn:aws:lambda:us-east-1:111111111111:function:handler", state: "unused", reason: "Target.NotRegistered")]
        let result = try await service(data).load(reference: reference(.targetGroups, id: targetGroup().arn), includeReverse: false)
        XCTAssertTrue(section("targets", result).nodes.allSatisfy { $0.reference == nil })
    }

    func testZoneListsWeightedRecordsAsDistinctOneHopNodesWithoutELBRead() async throws {
        var data = fixture()
        data.records["Z1"] = [aliasRecord(identifier: "blue"), aliasRecord(identifier: "green"),
                               Route53Record(name: "address.example.com.", type: "A", values: ["10.0.0.1"])]
        let calls = Calls()
        let result = try await service(data, calls: calls).load(reference: reference(.route53, id: "Z1"), includeReverse: false)
        let nodes = section("records", result).nodes
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(Set(nodes.map(\.id)).count, 2)
        XCTAssertEqual(Set(nodes.compactMap(\.reference?.recordID?.setIdentifier)), ["blue", "green"])
        let count = await calls.counts
        XCTAssertEqual(count, ["zones": 1, "records:Z1": 1])
    }

    func testRecordUsesExactCompositeIdentityAndKeepsUnmatchedTargetsVisible() async throws {
        var data = fixture()
        let matching = aliasRecord(identifier: "blue")
        let unmatched = aliasRecord(identifier: "green", dns: "other.example.com.")
        let sameTarget = aliasRecord(identifier: "canary")
        data.records["Z1"] = [matching, unmatched, sameTarget]
        let service = service(data)
        let found = try await service.load(reference: reference(.route53, id: "Z1", record: matching.id), includeReverse: false)
        XCTAssertEqual(section("load-balancers", found).nodes.first?.reference?.resourceID, balancer().arn)
        let canary = try await service.load(reference: reference(.route53, id: "Z1", record: sameTarget.id), includeReverse: false)
        XCTAssertNotEqual(section("load-balancers", found).nodes.first?.id, section("load-balancers", canary).nodes.first?.id)
        let missing = try await service.load(reference: reference(.route53, id: "Z1", record: unmatched.id), includeReverse: false)
        XCTAssertEqual(section("load-balancers", missing).nodes.first?.name, "other.example.com.")
        XCTAssertNil(section("load-balancers", missing).nodes.first?.reference)
        do {
            _ = try await service.load(reference: reference(.route53, id: "Z1", record: aliasRecord(identifier: "absent").id), includeReverse: false)
            XCTFail("Another weighted record must not substitute for the target")
        } catch { XCTAssertEqual(error as? ResourceRelationError, .notFound) }
    }

    func testRecordELBFailurePreservesUnlinkedTargetAndMarksIncomplete() async throws {
        var data = fixture()
        data.failures = ["balancers"]
        let result = try await service(data).load(reference: reference(.route53, id: "Z1", record: aliasRecord().id), includeReverse: false)
        let targets = section("load-balancers", result)
        XCTAssertEqual(targets.nodes.count, 1)
        XCTAssertNil(targets.nodes.first?.reference)
        XCTAssertTrue(targets.isIncomplete)
        XCTAssertNotNil(targets.error)
    }

    func testDNSQueryUsesExactlyTheExplicitRegion() async throws {
        var data = fixture()
        data.balancers = [balancer(region: "eu-west-1")]
        let calls = Calls()
        let ref = reference(.route53, id: "Z1", record: aliasRecord().id).replacingRegion("eu-west-1")
        let result = try await service(data, calls: calls).load(reference: ref, includeReverse: false)
        XCTAssertEqual(section("load-balancers", result).nodes.first?.reference?.scope.region, "eu-west-1")
        let regions = await calls.regions
        XCTAssertEqual(regions, ["eu-west-1"])
    }

    func testReverseDNSKeepsZoneAndWeightedIdentityAndPartialFailures() async throws {
        var data = fixture()
        data.zones = [zone("Z1"), zone("Z2"), zone("Z3")]
        data.records = ["Z1": [aliasRecord(identifier: "blue"), aliasRecord(identifier: "green")],
                        "Z2": [aliasRecord(identifier: "blue")], "Z3": []]
        data.failures = ["records:Z3"]
        let result = try await service(data).load(reference: reference(.loadBalancers, id: balancer().arn), includeReverse: true)
        let dns = section("dns", result)
        XCTAssertEqual(dns.nodes.count, 3)
        XCTAssertEqual(Set(dns.nodes.map(\.id)).count, 3)
        XCTAssertEqual(dns.checkedCount, 2)
        XCTAssertEqual(dns.totalCount, 3)
        XCTAssertTrue(dns.isIncomplete)
        XCTAssertTrue(dns.error?.contains("Z3") == true)
        XCTAssertFalse(dns.error?.contains("secret-endpoint") == true)
        XCTAssertEqual(dns.resourceFailures.map(\.resourceID), ["Z3"])
        XCTAssertEqual(dns.resourceFailures.first?.message, ResourceRelationError.failed.localizedDescription)
        XCTAssertEqual(Set(dns.nodes.compactMap(\.reference?.resourceID)), ["Z1", "Z2"])
    }

    func testReverseDNSScanRunsAtMostFourZoneReadsAtOnce() async throws {
        var data = fixture()
        data.zones = (1...9).map { zone("Z\($0)") }
        data.records = Dictionary(uniqueKeysWithValues: data.zones.map { ($0.id, [aliasRecord()]) })
        let gate = ScanGate()
        let service = service(data, scanGate: gate)
        let ref = reference(.loadBalancers, id: balancer().arn)
        let task = Task { try await service.load(reference: ref, includeReverse: true) }
        await gate.waitForFour()
        let before = await gate.snapshot()
        XCTAssertEqual(before.started, 4)
        XCTAssertEqual(before.maximum, 4)
        await gate.release()
        let result = try await task.value
        XCTAssertEqual(section("dns", result).checkedCount, 9)
        XCTAssertEqual(section("dns", result).totalCount, 9)
        let after = await gate.snapshot()
        XCTAssertLessThanOrEqual(after.maximum, 4)
    }

    func testCancellationBeforeStartMakesZeroCallsAndDuringScanThrows() async throws {
        let calls = Calls()
        let service = service(fixture(), calls: calls)
        let ref = reference(.loadBalancers, id: balancer().arn)
        let immediate = Task { try await service.load(reference: ref, includeReverse: true) }
        immediate.cancel()
        do { _ = try await immediate.value; XCTFail("Cancellation must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await calls.counts
        XCTAssertTrue(count.isEmpty)

        var data = fixture()
        data.zones = (1...8).map { zone("Z\($0)") }
        let gate = ScanGate()
        let scanning = self.service(data, scanGate: gate)
        let task = Task { try await scanning.load(reference: ref, includeReverse: true) }
        await gate.waitForFour()
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("Cancelled scan must not return partial success") }
        catch { XCTAssertTrue(error is CancellationError) }
        let scanned = await gate.snapshot()
        XCTAssertEqual(scanned.started, 4)
    }

    func testAliasRequiresDNSAndCanonicalZoneWithStrictDualstackHandling() {
        let lb = balancer()
        XCTAssertTrue(Route53LoadBalancerMatcher.matches(record: aliasRecord(dns: "WEB.EXAMPLE.ELB.AMAZONAWS.COM."), loadBalancer: lb))
        XCTAssertTrue(Route53LoadBalancerMatcher.matches(record: aliasRecord(dns: "dualstack.web.example.elb.amazonaws.com."), loadBalancer: lb))
        XCTAssertTrue(Route53LoadBalancerMatcher.matches(record: aliasRecord(zoneID: "/hostedzone/ZCANONICAL"), loadBalancer: lb))
        for dns in ["dualstack.dualstack.web.example.elb.amazonaws.com.", "evil.web.example.elb.amazonaws.com.",
                    "web.example.elb.amazonaws.com.evil.", "web.example.elb.amazonaws.com..", " web.example.elb.amazonaws.com.",
                    "web.example.elb.amazonaws.com.\n", "ｗｅｂ.example.elb.amazonaws.com."] {
            XCTAssertFalse(Route53LoadBalancerMatcher.matches(record: aliasRecord(dns: dns), loadBalancer: lb), dns)
        }
        XCTAssertFalse(Route53LoadBalancerMatcher.matches(record: aliasRecord(zoneID: "ZOTHER"), loadBalancer: lb))
        XCTAssertFalse(Route53LoadBalancerMatcher.matches(record: aliasRecord(zoneID: "ZCANONICAL\n"), loadBalancer: lb))
        let forgedAlias = Route53Record(name: "txt.example.com.", type: "TXT", alias: aliasRecord().alias)
        XCTAssertFalse(Route53LoadBalancerMatcher.matches(record: forgedAlias, loadBalancer: lb))
        let ipv6Alias = Route53Record(name: "ipv6.example.com.", type: "AAAA", alias: aliasRecord().alias)
        XCTAssertTrue(Route53LoadBalancerMatcher.matches(record: ipv6Alias, loadBalancer: lb))
        var missingZone = lb
        missingZone.canonicalHostedZoneID = nil
        XCTAssertFalse(Route53LoadBalancerMatcher.matches(record: aliasRecord(), loadBalancer: missingZone))
        let network = balancer(kind: "network")
        XCTAssertTrue(Route53LoadBalancerMatcher.matches(record: aliasRecord(), loadBalancer: network))
        XCTAssertFalse(Route53LoadBalancerMatcher.matches(record: aliasRecord(dns: "dualstack.web.example.elb.amazonaws.com."), loadBalancer: network))
        let gateway = balancer(kind: "gateway")
        XCTAssertFalse(Route53LoadBalancerMatcher.matches(record: aliasRecord(), loadBalancer: gateway))
        var internalBalancer = lb
        internalBalancer.dnsName = "internal-web.example.elb.amazonaws.com"
        XCTAssertFalse(Route53LoadBalancerMatcher.matches(record: aliasRecord(), loadBalancer: internalBalancer))
        XCTAssertTrue(Route53LoadBalancerMatcher.matches(record: aliasRecord(dns: "dualstack.internal-web.example.elb.amazonaws.com."),
                                                          loadBalancer: internalBalancer))
    }

    func testCNAMEMatchesDirectExactDNSOnlyAndRawTargetsStayVisible() {
        let lb = balancer()
        let direct = Route53Record(name: "www.example.com.", type: "CNAME", values: ["WEB.EXAMPLE.ELB.AMAZONAWS.COM."])
        XCTAssertTrue(Route53LoadBalancerMatcher.matches(record: direct, loadBalancer: lb))
        let dualstack = Route53Record(name: "www.example.com.", type: "CNAME", values: ["dualstack.web.example.elb.amazonaws.com."])
        XCTAssertTrue(Route53LoadBalancerMatcher.matches(record: dualstack, loadBalancer: lb))
        XCTAssertFalse(Route53LoadBalancerMatcher.matches(record: dualstack, loadBalancer: balancer(kind: "network")))
        var internalBalancer = lb
        internalBalancer.dnsName = "internal-web.example.elb.amazonaws.com"
        XCTAssertFalse(Route53LoadBalancerMatcher.matches(record: direct, loadBalancer: internalBalancer))
        for target in ["dualstack.dualstack.web.example.elb.amazonaws.com.", "middle.example.com.", "example.elb.amazonaws.com."] {
            let record = Route53Record(name: "www.example.com.", type: "CNAME", values: [target])
            XCTAssertFalse(Route53LoadBalancerMatcher.matches(record: record, loadBalancer: lb))
            XCTAssertEqual(Route53LoadBalancerMatcher.targets(in: record), [target])
        }
        XCTAssertEqual(Route53LoadBalancerMatcher.targets(in: aliasRecord(dns: " raw invalid target ")), [" raw invalid target "])
        XCTAssertTrue(Route53LoadBalancerMatcher.targets(in: Route53Record(name: "a.example.", type: "A", values: ["1.2.3.4"])).isEmpty)
    }

    private struct Fixture: Sendable {
        var balancers: [ELBLoadBalancer]
        var targetGroups: [ELBTargetGroup]
        var targets: [ELBTargetHealth] = []
        var groups: [SecurityGroupModel]
        var instances: [RelationInstance]
        var zones: [Route53HostedZone]
        var records: [String: [Route53Record]]
        var membership = ELBMembershipResult(checkedGroupCount: 0, totalGroupCount: 0)
        var failures: Set<String> = []
    }

    private actor Calls {
        var counts: [String: Int] = [:]
        var regions: [String] = []
        func record(_ operation: String, region: String? = nil) {
            counts[operation, default: 0] += 1
            if let region { regions.append(region) }
        }
    }

    private actor ScanGate {
        private var active = 0
        private var maximum = 0
        private var started = 0
        private var released = false
        private var blocked: [CheckedContinuation<Void, Never>] = []
        private var waitingForFour: [CheckedContinuation<Void, Never>] = []
        func enter() async {
            active += 1
            started += 1
            maximum = max(maximum, active)
            if started >= 4 { waitingForFour.forEach { $0.resume() }; waitingForFour = [] }
            if !released { await withCheckedContinuation { blocked.append($0) } }
            active -= 1
        }
        func waitForFour() async {
            if started >= 4 { return }
            await withCheckedContinuation { waitingForFour.append($0) }
        }
        func release() {
            released = true
            blocked.forEach { $0.resume() }
            blocked = []
        }
        func snapshot() -> (started: Int, maximum: Int) { (started, maximum) }
    }

    private func service(_ data: Fixture, calls: Calls = Calls(), scanGate: ScanGate? = nil) -> AWSResourceRelationshipService {
        let before: @Sendable (String, String?) async throws -> Void = { operation, region in
            await calls.record(operation, region: region)
            if data.failures.contains(operation) { throw NSError(domain: "secret-endpoint", code: 403) }
        }
        return AWSResourceRelationshipService(
            loadBalancers: { scope in try await before("balancers", scope.region); return data.balancers },
            loadTargetGroups: { _ in try await before("targetGroups", nil); return data.targetGroups },
            loadTargetHealth: { _, _ in try await before("health", nil); return data.targets },
            loadMembership: { _, _ in try await before("membership", nil); return data.membership },
            loadGroups: { _ in try await before("groups", nil); return data.groups },
            loadInstance: { _, id in try await before("instance", nil); return data.instances.first { $0.id == id } },
            loadInstancesUsingGroup: { _, _ in try await before("instancesUsingGroup", nil); return data.instances },
            loadZones: { _ in try await before("zones", nil); return data.zones },
            loadRecords: { _, zone in
                try await before("records:\(zone.id)", nil)
                await scanGate?.enter()
                return data.records[zone.id] ?? []
            }
        )
    }

    private func fixture() -> Fixture {
        Fixture(balancers: [balancer()], targetGroups: [targetGroup()],
                groups: [SecurityGroupModel(id: "sg-12345678", name: "web", ownerID: "111111111111")],
                instances: [RelationInstance(id: "i-12345678", name: "web", securityGroupIDs: ["sg-12345678"])],
                zones: [zone("Z1")], records: ["Z1": [aliasRecord()]])
    }

    private func section(_ id: String, _ result: ResourceRelationResult) -> ResourceRelationSection {
        guard let section = result.sections.first(where: { $0.id == id }) else {
            XCTFail("Missing section \(id)")
            return ResourceRelationSection(id: id, title: "Missing")
        }
        return section
    }

    private func reference(_ service: AWSService, id: String, scope: MonitoringScope? = nil,
                           record: Route53Record.ID? = nil) -> ResourceRelationReference {
        ResourceRelationReference(scope: scope ?? self.scope(), service: service, resourceID: id, name: "source", recordID: record)
    }

    private func scope(account: String = "111111111111") -> MonitoringScope {
        MonitoringScope(profile: AWSProfile(name: "work", region: "us-east-1", ssoStartURL: nil, ssoRegion: nil,
                                            ssoAccountID: nil, ssoRoleName: nil),
                        identity: AWSIdentity(account: account, arn: "arn:aws:iam::\(account):user/test", userID: "test"), region: "us-east-1")
    }

    private func balancer(name: String = "web", account: String = "111111111111", region: String = "us-east-1",
                          partition: String = "aws", kind: String = "application") -> ELBLoadBalancer {
        let arnKind = kind == "application" ? "app" : kind == "network" ? "net" : "gwy"
        return ELBLoadBalancer(arn: "arn:\(partition):elasticloadbalancing:\(region):\(account):loadbalancer/\(arnKind)/\(name)/1234567890abcdef",
                        name: name, kind: kind, dnsName: "web.example.elb.amazonaws.com", canonicalHostedZoneID: "ZCANONICAL",
                        securityGroupIDs: ["sg-12345678"])
    }

    private func targetGroup(name: String = "web", targetType: String = "instance") -> ELBTargetGroup {
        ELBTargetGroup(arn: "arn:aws:elasticloadbalancing:us-east-1:111111111111:targetgroup/\(name)/1234567890abcdef",
                       name: name, targetType: targetType, loadBalancerARNs: [balancer().arn])
    }

    private func zone(_ id: String) -> Route53HostedZone { Route53HostedZone(id: id, name: "example.com.", isPrivate: false) }

    private func aliasRecord(identifier: String? = nil, dns: String = "web.example.elb.amazonaws.com.",
                              zoneID: String = "ZCANONICAL") -> Route53Record {
        Route53Record(name: "www.example.com.", type: "A", setIdentifier: identifier,
                      alias: Route53Alias(dnsName: dns, hostedZoneID: zoneID, evaluateTargetHealth: true),
                      routingPolicy: identifier == nil ? "Simple" : "Weighted")
    }

    private func rule(_ id: String, owner: String?) -> SecurityGroupRule {
        SecurityGroupRule(protocolName: "tcp", portRange: "443", target: id,
                          referencedGroupID: id, referencedAccountID: owner)
    }
}
