import Foundation
import SotoCore
import SotoElasticLoadBalancingV2
import XCTest
@testable import AWSPlatform

final class AWSELBServiceTests: XCTestCase {
    private typealias SDK = ElasticLoadBalancingV2

    func testLoadBalancerListPaginatesEmptyPagesAndMapsAllThreeKinds() async throws {
        let created = Date(timeIntervalSince1970: 1_780_000_000)
        let app = SDK.LoadBalancer(
            availabilityZones: [.init(loadBalancerAddresses: [.init(allocationId: "eipalloc-example", ipAddress: "192.0.2.1", iPv6Address: "2001:db8::1", privateIPv4Address: "10.0.0.1")],
                                       outpostId: "op-example", sourceNatIpv6Prefixes: ["2001:db8::/80"], subnetId: "subnet-example", zoneName: "us-east-1a")],
            canonicalHostedZoneId: "ZEXAMPLE", createdTime: created, customerOwnedIpv4Pool: "pool-example", dnsName: "app.example.test",
            enablePrefixForIpv6SourceNat: .off, enforceSecurityGroupInboundRulesOnPrivateLinkTraffic: "on", ipAddressType: .dualstack,
            ipamPools: .init(ipv4IpamPoolId: "ipam-example"), loadBalancerArn: lbARN(), loadBalancerName: "app", scheme: .internetFacing,
            securityGroups: ["sg-example"], state: .init(code: .active, reason: "Ready"), type: .application, vpcId: "vpc-example"
        )
        let stub = ELBStub(loadBalancers: [.init(loadBalancers: [app], nextMarker: "empty"), .init(nextMarker: "last"),
            .init(loadBalancers: [rawLB("net", kind: .network), rawLB("gwy", kind: .gateway)])])
        let values = try await service(stub).loadLoadBalancers(scope: scope())
        XCTAssertEqual(values.map(\.kind), ["application", "gateway", "network"])
        let lb = try XCTUnwrap(values.first { $0.name == "app" })
        XCTAssertEqual(lb.dnsName, "app.example.test")
        XCTAssertEqual(lb.scheme, "internet-facing")
        XCTAssertEqual(lb.state, "active")
        let fields = dictionary(lb.fields)
        XCTAssertEqual(fields["VPC"], "vpc-example")
        XCTAssertEqual(fields["IPv4 IPAM pool"], "ipam-example")
        XCTAssertEqual(fields["Security groups"], "sg-example")
        XCTAssertEqual(fields["Zone 1 subnet"], "subnet-example")
        XCTAssertEqual(fields["Zone 1 address 1 IPv6"], "2001:db8::1")
        XCTAssertEqual(fields["Zone 1 address 1 allocation"], "eipalloc-example")
        XCTAssertEqual(fields["IPv6 source NAT prefix"], "off")
        XCTAssertEqual(fields["State reason"], "Ready")
        let requests = await stub.requests()
        XCTAssertEqual(requests.loadBalancers.map(\.marker), [nil, "empty", "last"])
        XCTAssertTrue(requests.loadBalancers.allSatisfy { $0.pageSize == 400 && $0.names == nil && $0.loadBalancerArns == nil })
        XCTAssertTrue(requests.health.isEmpty)
    }

    func testLoadBalancerIdentityRejectsCrossAccountRegionPartitionKindNameAndClassicARN() async {
        let invalids: [SDK.LoadBalancer] = [
            .init(loadBalancerArn: lbARN(account: "444455556666"), loadBalancerName: "app", type: .application),
            .init(loadBalancerArn: lbARN(region: "eu-west-1"), loadBalancerName: "app", type: .application),
            .init(loadBalancerArn: lbARN().replacingOccurrences(of: "arn:aws:", with: "arn:aws-cn:"), loadBalancerName: "app", type: .application),
            .init(loadBalancerArn: lbARN(), loadBalancerName: "app", type: .network),
            .init(loadBalancerArn: lbARN(), loadBalancerName: "other", type: .application),
            .init(loadBalancerArn: "arn:aws:elasticloadbalancing:us-east-1:111122223333:loadbalancer/classic", loadBalancerName: "classic", type: .application),
            .init(loadBalancerArn: lbARN(), type: .application)
        ]
        for raw in invalids {
            await assertError(ELBError.invalidResponse) {
                _ = try await self.service(ELBStub(loadBalancers: [.init(loadBalancers: [raw])])).loadLoadBalancers(scope: self.scope())
            }
        }
    }

    func testTargetGroupConfigurationPreservesHealthChecksAndAllTargetTypes() async throws {
        let group = SDK.TargetGroup(
            healthCheckEnabled: false, healthCheckIntervalSeconds: 30, healthCheckPath: "/ready", healthCheckPort: "traffic-port",
            healthCheckProtocol: .http, healthCheckTimeoutSeconds: 5, healthyThresholdCount: 2, ipAddressType: .ipv6,
            loadBalancerArns: [lbARN()], matcher: .init(grpcCode: "0", httpCode: "200-299"), port: 8080, protocol: .http,
            protocolVersion: "HTTP2", targetControlPort: 8081, targetGroupArn: tgARN(), targetGroupName: "group", targetType: .instance,
            unhealthyThresholdCount: 3, vpcId: "vpc-example"
        )
        let stub = ELBStub(groups: [.init(nextMarker: "next", targetGroups: [group]), .init(targetGroups: [rawTG("ip", type: .ip), rawTG("lambda", type: .lambda), rawTG("alb", type: .alb)])])
        let groups = try await service(stub).loadTargetGroups(scope: scope())
        XCTAssertEqual(Set(groups.map(\.targetType)), ["instance", "ip", "lambda", "alb"])
        let mapped = try XCTUnwrap(groups.first { $0.name == "group" })
        XCTAssertEqual(mapped.port, 8080)
        XCTAssertEqual(mapped.protocolName, "HTTP")
        XCTAssertEqual(mapped.loadBalancerARNs, [lbARN()])
        let fields = dictionary(mapped.fields)
        XCTAssertEqual(fields["Health checks enabled"], "No")
        XCTAssertEqual(fields["Health check port"], "traffic-port")
        XCTAssertEqual(fields["Health check path"], "/ready")
        XCTAssertEqual(fields["HTTP success codes"], "200-299")
        XCTAssertEqual(fields["gRPC success codes"], "0")
        XCTAssertEqual(fields["Target control port"], "8081")
        XCTAssertEqual(fields["Unhealthy threshold"], "3")
        let requests = await stub.requests()
        XCTAssertEqual(requests.groups.map(\.marker), [nil, "next"])
        XCTAssertTrue(requests.groups.allSatisfy { $0.pageSize == 400 && $0.loadBalancerArn == nil && $0.targetGroupArns == nil && $0.names == nil })
    }

    func testFilteredTargetGroupQueryRequiresRequestedParentAssociation() async throws {
        let raw = rawTG(loadBalancers: [lbARN()])
        let stub = ELBStub(groups: [.init(targetGroups: [raw])])
        let result = try await service(stub).loadTargetGroups(scope: scope(), loadBalancerARN: lbARN())
        XCTAssertEqual(result.count, 1)
        let requests = await stub.requests()
        XCTAssertEqual(requests.groups.first?.loadBalancerArn, lbARN())
        await assertError(ELBError.invalidResponse) {
            _ = try await self.service(ELBStub(groups: [.init(targetGroups: [self.rawTG()])])).loadTargetGroups(scope: self.scope(), loadBalancerARN: self.lbARN())
        }
        let invalid = SDK.TargetGroup(targetGroupArn: tgARN(account: "444455556666"), targetGroupName: "group", targetType: .instance)
        await assertError(ELBError.invalidResponse) {
            _ = try await self.service(ELBStub(groups: [.init(targetGroups: [invalid])])).loadTargetGroups(scope: self.scope())
        }
    }

    func testListenersPreserveTLSAndWeightedForwardsDeduplicatedInExecutionOrder() async throws {
        let forward = SDK.Action(forwardConfig: .init(targetGroups: [.init(targetGroupArn: tgARN(), weight: 20), .init(targetGroupArn: tgARN("other"), weight: 80)],
                                                     targetGroupStickinessConfig: .init(durationSeconds: 120, enabled: true)), order: 2, targetGroupArn: tgARN(), type: .forward)
        let auth = SDK.Action(authenticateCognitoConfig: .init(userPoolArn: "pool-example", userPoolClientId: "client-example"), order: 1, type: .authenticateCognito)
        let raw = SDK.Listener(alpnPolicy: ["HTTP2Preferred"], certificates: [.init(certificateArn: "certificate-example", isDefault: true)],
            defaultActions: [forward, auth], listenerArn: listenerARN(), loadBalancerArn: lbARN(),
            mutualAuthentication: .init(advertiseTrustStoreCaNames: .on, ignoreClientCertificateExpiry: false, mode: "verify", trustStoreArn: "trust-store-example", trustStoreAssociationStatus: .active),
            port: 443, protocol: .https, sslPolicy: "TLS-example")
        let stub = ELBStub(listeners: [.init(listeners: [raw], nextMarker: "next"), .init()])
        let values = try await service(stub).loadListeners(scope: scope(), loadBalancer: lb())
        let listener = try XCTUnwrap(values.first)
        XCTAssertEqual(listener.actions.map(\.order), [1, 2])
        XCTAssertEqual(listener.actions.map(\.type), ["authenticate-cognito", "forward"])
        XCTAssertEqual(listener.actions[1].forwards, [.init(targetGroupARN: tgARN(), weight: 20), .init(targetGroupARN: tgARN("other"), weight: 80)])
        XCTAssertEqual(dictionary(listener.actions[1].fields)["Stickiness duration (seconds)"], "120")
        XCTAssertEqual(dictionary(listener.fields)["Mutual TLS mode"], "verify")
        XCTAssertEqual(dictionary(listener.fields)["Ignore client certificate expiry"], "No")
        XCTAssertEqual(dictionary(listener.fields)["Certificate 1 default"], "Yes")
        XCTAssertEqual(listener.port, 443)
        let requests = await stub.requests()
        XCTAssertEqual(requests.listeners.map(\.marker), [nil, "next"])
        XCTAssertTrue(requests.listeners.allSatisfy { $0.loadBalancerArn == lbARN() && $0.pageSize == 400 && $0.listenerArns == nil })
    }

    func testAuthenticationAllowlistOmitsSecretsExtraParametersCookiesEndpointsAndClaims() async throws {
        let secret = "ELB-sensitive-test-value"
        let actions: [SDK.Action] = [
            .init(authenticateOidcConfig: .init(authenticationRequestExtraParams: ["token": secret], authorizationEndpoint: "https://example.test/\(secret)",
                clientId: "public-client", clientSecret: secret, issuer: "https://issuer.example.test", onUnauthenticatedRequest: .deny, scope: "openid",
                sessionCookieName: secret, sessionTimeout: 60, tokenEndpoint: "https://example.test/\(secret)", useExistingClientSecret: true, userInfoEndpoint: "https://example.test/\(secret)"),
                  order: 1, type: .authenticateOidc),
            .init(authenticateCognitoConfig: .init(authenticationRequestExtraParams: ["token": secret], onUnauthenticatedRequest: .allow, scope: "openid",
                sessionCookieName: secret, sessionTimeout: 120, userPoolArn: "public-pool", userPoolClientId: "public-client", userPoolDomain: "example"), order: 2, type: .authenticateCognito),
            .init(jwtValidationConfig: .init(additionalClaims: [.init(format: .singleString, name: secret, values: [secret])], issuer: "public-issuer", jwksEndpoint: "https://example.test/\(secret)"), order: 3, type: .jwtValidation)
        ]
        let stub = ELBStub(listeners: [.init(listeners: [rawListener(actions: actions)])])
        let mapped = try await service(stub).loadListeners(scope: scope(), loadBalancer: lb())
        let output = String(reflecting: mapped)
        XCTAssertFalse(output.contains(secret))
        XCTAssertTrue(output.contains("public-client"))
        XCTAssertTrue(output.contains("openid"))
        XCTAssertTrue(output.contains("JWT additional claim count"))
        XCTAssertTrue(mapped[0].actions.allSatisfy { $0.forwards.isEmpty })
    }

    func testRedirectAndFixedResponseRemainNonForwardActions() async throws {
        let actions: [SDK.Action] = [
            .init(order: 1, redirectConfig: .init(host: "#{host}", path: "/#{path}", port: "443", protocol: "HTTPS", query: "#{query}", statusCode: .http301), type: .redirect),
            .init(fixedResponseConfig: .init(contentType: "text/plain", messageBody: "Maintenance", statusCode: "503"), order: 2, type: .fixedResponse)
        ]
        let result = try await service(ELBStub(listeners: [.init(listeners: [rawListener(actions: actions)])])).loadListeners(scope: scope(), loadBalancer: lb())
        XCTAssertEqual(result[0].actions.map(\.type), ["redirect", "fixed-response"])
        XCTAssertEqual(dictionary(result[0].actions[0].fields)["Redirect status"], "HTTP_301")
        XCTAssertEqual(dictionary(result[0].actions[0].fields)["Redirect query"], "#{query}")
        XCTAssertEqual(dictionary(result[0].actions[1].fields)["Response body"], "Maintenance")
        XCTAssertTrue(result[0].actions.allSatisfy { $0.forwards.isEmpty })
    }

    func testRulesPaginateAndPreserveAllConditionAndTransformForms() async throws {
        let conditions: [SDK.RuleCondition] = [
            .init(field: "host-header", hostHeaderConfig: .init(regexValues: ["^.*example$"], values: ["example.test"]), regexValues: ["top-regex"], values: ["legacy.example.test"]),
            .init(field: "path-pattern", pathPatternConfig: .init(regexValues: ["^/api"], values: ["/api/*"])),
            .init(field: "http-header", httpHeaderConfig: .init(httpHeaderName: "X-Environment", regexValues: ["^prod$"], values: ["prod"])),
            .init(field: "http-request-method", httpRequestMethodConfig: .init(values: ["GET", "POST"])),
            .init(field: "source-ip", sourceIpConfig: .init(values: ["192.0.2.0/24"])),
            .init(field: "query-string", queryStringConfig: .init(values: [.init(key: "version", value: "v2"), .init(value: "anonymous")]))
        ]
        let raw = SDK.Rule(actions: [.init(targetGroupArn: tgARN(), type: .forward)], conditions: conditions, isDefault: false, priority: "10", ruleArn: ruleARN(), transforms: [
            .init(hostHeaderRewriteConfig: .init(rewrites: [.init(regex: "^(.*).example.test$", replace: "$1.internal.test")]), type: .hostHeaderRewrite),
            .init(type: .urlRewrite, urlRewriteConfig: .init(rewrites: [.init(regex: "^/api/(.*)", replace: "/v2/$1")]))
        ])
        let stub = ELBStub(rules: [.init(nextMarker: "next", rules: [.init(isDefault: true, priority: "default", ruleArn: ruleARN("default"))]),
                                  .init(rules: [raw])])
        let rules = try await service(stub).loadRules(scope: scope(), listener: listener())
        XCTAssertEqual(rules.map(\.priority), ["10", "default"])
        XCTAssertEqual(rules[0].actions[0].forwards.map(\.targetGroupARN), [tgARN()])
        let fields = dictionary(rules[0].conditions)
        XCTAssertEqual(fields["1. host-header values"], "legacy.example.test")
        XCTAssertEqual(fields["1. host-header host regex"], "^.*example$")
        XCTAssertEqual(fields["3. http-header header"], "X-Environment")
        XCTAssertEqual(fields["4. http-request-method methods"], "GET | POST")
        XCTAssertEqual(fields["5. source-ip source IPs"], "192.0.2.0/24")
        XCTAssertEqual(fields["6. query-string query 2 value"], "anonymous")
        XCTAssertEqual(dictionary(rules[0].transforms)["1. host-header-rewrite host 1 replacement"], "$1.internal.test")
        XCTAssertEqual(dictionary(rules[0].transforms)["2. url-rewrite URL 1 regex"], "^/api/(.*)")
        let requests = await stub.requests()
        XCTAssertEqual(requests.rules.map(\.marker), [nil, "next"])
        XCTAssertTrue(requests.rules.allSatisfy { $0.listenerArn == listenerARN() && $0.pageSize == 400 && $0.ruleArns == nil })
    }

    func testListenerAndRuleARNsMustMatchExactParentsAndRulesRejectNonALB() async {
        for arn in [listenerARN("other", lbName: "other"), listenerARN() + "/extra", listenerARN().replacingOccurrences(of: "111122223333", with: "444455556666")] {
            let stub = ELBStub(listeners: [.init(listeners: [.init(listenerArn: arn, loadBalancerArn: lbARN())])])
            await assertError(ELBError.invalidResponse) { _ = try await self.service(stub).loadListeners(scope: self.scope(), loadBalancer: self.lb()) }
        }
        let wrongParent = ELBStub(listeners: [.init(listeners: [.init(listenerArn: listenerARN(), loadBalancerArn: lbARN("other"))])])
        await assertError(ELBError.invalidResponse) { _ = try await self.service(wrongParent).loadListeners(scope: self.scope(), loadBalancer: self.lb()) }
        for arn in [ruleARN(listenerID: "other"), ruleARN() + "/extra"] {
            let stub = ELBStub(rules: [.init(rules: [.init(isDefault: false, priority: "1", ruleArn: arn)])])
            await assertError(ELBError.invalidResponse) { _ = try await self.service(stub).loadRules(scope: self.scope(), listener: self.listener()) }
        }
        let noCalls = ELBStub()
        let network = ELBListener(arn: listenerARN(kind: "net"), loadBalancerARN: lbARN(kind: "net"), protocolName: "TCP")
        await assertError(ELBError.invalidResponse) { _ = try await self.service(noCalls).loadRules(scope: self.scope(), listener: network) }
        let requests = await noCalls.requests()
        XCTAssertTrue(requests.rules.isEmpty)
    }

    func testActionMappingRejectsCrossAccountForwardsConflictingWeightsAndOrders() async {
        let cases: [[SDK.Action]] = [
            [.init(targetGroupArn: tgARN(account: "444455556666"), type: .forward)],
            [.init(forwardConfig: .init(targetGroups: [.init(targetGroupArn: tgARN(), weight: 1), .init(targetGroupArn: tgARN(), weight: 2)]), type: .forward)],
            [.init(order: 1, type: .redirect), .init(order: 1, type: .fixedResponse)],
            [.init(order: 0, type: .forward)], [.init()]
        ]
        for actions in cases {
            await assertError(ELBError.invalidResponse) {
                _ = try await self.service(ELBStub(listeners: [.init(listeners: [self.rawListener(actions: actions)])])).loadListeners(scope: self.scope(), loadBalancer: self.lb())
            }
        }
    }

    func testTargetHealthPreservesRegistrationPortsAndAdministrativeState() async throws {
        let raw = SDK.TargetHealthDescription(
            administrativeOverride: .init(description: "Shifted", reason: .zonalShiftEngaged, state: .zonalShiftActive),
            anomalyDetection: .init(mitigationInEffect: .yes, result: .anomalous), healthCheckPort: "8080",
            target: .init(availabilityZone: "us-east-1a", id: instanceID, port: 8080, quicServerId: "quic-example"),
            targetHealth: .init(description: "Health check failed", reason: .failedHealthChecks, state: .unhealthy)
        )
        let stub = ELBStub(health: [.init(targetHealthDescriptions: [raw, target(instanceID, port: 8443, state: .unused)])])
        let targets = try await service(stub).loadTargetHealth(scope: scope(), group: group())
        XCTAssertEqual(targets.map(\.port), [8080, 8443])
        XCTAssertEqual(targets[0].state, "unhealthy")
        XCTAssertEqual(targets[0].reason, "Target.FailedHealthChecks")
        XCTAssertEqual(targets[0].description, "Health check failed")
        XCTAssertEqual(dictionary(targets[0].fields)["Anomaly result"], "anomalous")
        XCTAssertEqual(dictionary(targets[0].fields)["Administrative override"], "zonal_shift_active")
        XCTAssertEqual(dictionary(targets[0].fields)["QUIC server ID"], "quic-example")
        let requests = await stub.requests()
        XCTAssertEqual(requests.health.count, 1)
        XCTAssertEqual(requests.health[0].targetGroupArn, tgARN())
        XCTAssertEqual(requests.health[0].include, [.all])
        XCTAssertNil(requests.health[0].targets)
    }

    func testAllTargetTypesKeepIdentityWithoutInferringEC2FromIP() async throws {
        let cases: [(String, String)] = [("instance", instanceID), ("ip", "10.100.200.5"), ("ip", "2001:db8::1"),
            ("lambda", "arn:aws:lambda:us-east-1:111122223333:function:worker:live"), ("alb", lbARN())]
        for (type, id) in cases {
            let stub = ELBStub(health: [.init(targetHealthDescriptions: [target(id, port: type == "lambda" ? nil : 80)])])
            let values = try await service(stub).loadTargetHealth(scope: scope(), group: group(type: type))
            XCTAssertEqual(values.map(\.targetID), [id])
            if type == "ip" { XCTAssertNil(ELBResourceReference.target(values[0], group: group(type: type), scope: scope())) }
        }
        let stub = ELBStub(health: [.init(targetHealthDescriptions: [.init(target: .init(id: instanceID))])])
        let unknown = try await service(stub).loadTargetHealth(scope: scope(), group: group())
        XCTAssertEqual(unknown[0].state, "Unknown")
        XCTAssertNil(unknown[0].port)
        XCTAssertNil(unknown[0].reason)
    }

    func testTargetHealthRejectsInvalidIDsCrossAccountLambdaAndDuplicateRegistrations() async {
        let cases: [(String, [SDK.TargetHealthDescription])] = [
            ("instance", [target("10.0.0.1")]), ("instance", [target(instanceID + "\n")]), ("ip", [target(instanceID)]), ("ip", [target("999.1.2.3")]),
            ("lambda", [target("arn:aws:lambda:us-east-1:444455556666:function:worker")]),
            ("alb", [target(lbARN(kind: "net"))]), ("instance", [target(instanceID), target(instanceID)]),
            ("instance", [.init()]), ("instance", [target(instanceID, port: 0)])
        ]
        for (type, descriptions) in cases {
            await assertError(ELBError.invalidResponse) {
                _ = try await self.service(ELBStub(health: [.init(targetHealthDescriptions: descriptions)])).loadTargetHealth(scope: self.scope(), group: self.group(type: type))
            }
        }
    }

    func testFourListOperationsRejectRepeatedMarkersAndMaximumPageLimit() async {
        for operation in 0..<4 {
            for markers in [["repeat", "repeat"], (0..<1_000).map { "page-\($0)" }] {
                let stub = ELBStub(loadBalancers: markers.map { .init(nextMarker: $0) }, groups: markers.map { .init(nextMarker: $0) },
                                   listeners: markers.map { .init(nextMarker: $0) }, rules: markers.map { .init(nextMarker: $0) })
                await assertError(ELBError.incompletePagination) { try await self.perform(operation, service: self.service(stub), scope: self.scope()) }
                let requests = await stub.requests()
                XCTAssertEqual([requests.loadBalancers.count, requests.groups.count, requests.listeners.count, requests.rules.count][operation], markers.count)
            }
        }
    }

    func testFourListOperationsRejectDuplicatesAcrossPages() async {
        let stub = ELBStub(loadBalancers: [.init(loadBalancers: [rawLB()], nextMarker: "next"), .init(loadBalancers: [rawLB()])],
            groups: [.init(nextMarker: "next", targetGroups: [rawTG()]), .init(targetGroups: [rawTG()])],
            listeners: [.init(listeners: [rawListener()], nextMarker: "next"), .init(listeners: [rawListener()])],
            rules: [.init(nextMarker: "next", rules: [rawRule()]), .init(rules: [rawRule()])])
        for operation in 0..<4 {
            await assertError(ELBError.invalidResponse) { try await self.perform(operation, service: self.service(stub), scope: self.scope()) }
        }
    }

    func testMembershipScansOnlyInstanceGroupsMatchesExactIDPreservesAllPortsAndMarksPartialFailures() async throws {
        let groups = [rawTG("match"), rawTG("fail"), rawTG("other"), rawTG("ip", type: .ip), rawTG("lambda", type: .lambda), rawTG("alb", type: .alb)]
        let responses: [String: SDK.DescribeTargetHealthOutput] = [
            tgARN("match"): .init(targetHealthDescriptions: [target(instanceID, port: 80, state: .unhealthy), target(instanceID, port: 443, state: .draining),
                target(instanceID, port: 8080, state: .unused, reason: .notRegistered), target("i-22222222", port: 80)]),
            tgARN("other"): .init(targetHealthDescriptions: [target("i-22222222")])
        ]
        let probe = MembershipProbe(responses: responses, failureARNs: [tgARN("fail")])
        let service = membershipService(groups: groups, probe: probe)
        let result = try await service.loadInstanceMembership(scope: scope(), instanceID: instanceID)
        XCTAssertEqual(result.totalGroupCount, 3)
        XCTAssertEqual(result.checkedGroupCount, 2)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.matches.map(\.group.name), ["match"])
        XCTAssertEqual(result.matches[0].targets.map(\.port), [80, 443])
        XCTAssertEqual(result.failures.map(\.name), ["fail"])
        XCTAssertFalse(String(reflecting: result.failures).contains("ELB-sensitive-test-value"))
        let observed = await probe.snapshot()
        XCTAssertEqual(Set(observed.arns), [tgARN("match"), tgARN("fail"), tgARN("other")])
    }

    func testMembershipBoundsHealthFanoutToFourAndDistinguishesCompleteEmpty() async throws {
        let groups = (0..<11).map { rawTG("group\($0)") }
        let probe = MembershipProbe(responses: [:])
        let result = try await membershipService(groups: groups, probe: probe).loadInstanceMembership(scope: scope(), instanceID: instanceID)
        XCTAssertTrue(result.isComplete)
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertEqual(result.checkedGroupCount, 11)
        XCTAssertEqual(result.totalGroupCount, 11)
        let observed = await probe.snapshot()
        XCTAssertEqual(observed.arns.count, 11)
        XCTAssertLessThanOrEqual(observed.maximumActive, 4)
        XCTAssertGreaterThan(observed.maximumActive, 1)
    }

    func testMembershipWithNoInstanceGroupsMakesNoHealthRequests() async throws {
        let probe = MembershipProbe(responses: [:])
        let result = try await membershipService(groups: [rawTG(type: .ip)], probe: probe).loadInstanceMembership(scope: scope(), instanceID: instanceID)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.totalGroupCount, 0)
        let observed = await probe.snapshot()
        XCTAssertTrue(observed.arns.isEmpty)
    }

    func testMembershipListFailureDoesNotBecomeCompleteEmptyResult() async {
        let service = service(ELBStub(failure: AWSResponseError(errorCode: "AccessDenied")))
        await assertError(AWSELBService.RequestError.targetGroupsPermission) {
            _ = try await service.loadInstanceMembership(scope: self.scope(), instanceID: self.instanceID)
        }
    }

    func testInvalidScopeAndInvalidInputsMakeNoCalls() async {
        let stub = ELBStub()
        let service = service(stub)
        for invalid in [scope(account: ""), scope(profile: ""), scope(principal: "arn:aws:sts::444455556666:assumed-role/Test/session")] {
            for operation in 0..<5 { await assertError(ELBError.invalidScope) { try await self.perform(operation, service: service, scope: invalid) } }
        }
        await assertError(ELBError.invalidResponse) { _ = try await service.loadInstanceMembership(scope: self.scope(), instanceID: "10.0.0.1") }
        await assertError(ELBError.invalidResponse) { _ = try await service.loadInstanceMembership(scope: self.scope(), instanceID: self.instanceID + "\n") }
        await assertError(ELBError.invalidResponse) { _ = try await service.loadTargetGroups(scope: self.scope(), loadBalancerARN: "bad") }
        let requests = await stub.requests()
        XCTAssertTrue(requests.loadBalancers.isEmpty && requests.groups.isEmpty && requests.listeners.isEmpty && requests.rules.isEmpty && requests.health.isEmpty)
    }

    func testErrorsAreSanitizedForEveryOperationAndNameRelevantPermissions() async {
        let denied = service(ELBStub(failure: AWSResponseError(errorCode: "AccessDenied")))
        let permissions: [AWSELBService.RequestError] = [.loadBalancersPermission, .targetGroupsPermission, .listenersPermission, .rulesPermission, .targetHealthPermission]
        let actions = ["DescribeLoadBalancers", "DescribeTargetGroups", "DescribeListeners", "DescribeRules", "DescribeTargetHealth"]
        for operation in 0..<5 {
            await assertError(permissions[operation]) { try await self.perform(operation, service: denied, scope: self.scope()) }
            XCTAssertTrue(permissions[operation].localizedDescription.contains("elasticloadbalancing:" + actions[operation]))
        }
        let failures: [(Error, AWSELBService.RequestError)] = [
            (AWSResponseError(errorCode: "ExpiredToken"), .credentials), (AWSResponseError(errorCode: "Throttling"), .throttled),
            (AWSResponseError(errorCode: "TargetGroupNotFound"), .notFound), (URLError(.notConnectedToInternet), .network),
            (NSError(domain: "ELB-sensitive-test-value", code: 1, userInfo: [NSLocalizedDescriptionKey: "ELB-sensitive-test-value"]), .failed)
        ]
        for (failure, expected) in failures {
            let service = service(ELBStub(failure: failure))
            for operation in 0..<5 { await assertError(expected) { try await self.perform(operation, service: service, scope: self.scope()) } }
        }
    }

    func testCancellationBeforeRequestMakesNoCallsForEveryOperationAndMembership() async {
        for operation in 0..<6 {
            let gate = TestGate()
            let stub = ELBStub()
            let service = service(stub)
            let scope = scope(), lb = lb(), listener = listener(), group = group(), instance = instanceID
            let task = Task {
                await gate.wait()
                switch operation {
                case 0: _ = try await service.loadLoadBalancers(scope: scope)
                case 1: _ = try await service.loadTargetGroups(scope: scope)
                case 2: _ = try await service.loadListeners(scope: scope, loadBalancer: lb)
                case 3: _ = try await service.loadRules(scope: scope, listener: listener)
                case 4: _ = try await service.loadTargetHealth(scope: scope, group: group)
                default: _ = try await service.loadInstanceMembership(scope: scope, instanceID: instance)
                }
            }
            await gate.waitForEntry()
            task.cancel()
            await gate.open()
            do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
            let requests = await stub.requests()
            XCTAssertTrue(requests.loadBalancers.isEmpty && requests.groups.isEmpty && requests.listeners.isEmpty && requests.rules.isEmpty && requests.health.isEmpty)
        }
    }

    func testCancellationAfterResponsePreventsPublishingForEveryOperation() async {
        for operation in 0..<5 {
            let gate = TestGate()
            let service = AWSELBService(loadBalancerLoader: { _ in await gate.wait(); return .init() }, targetGroupLoader: { _ in await gate.wait(); return .init() },
                listenerLoader: { _ in await gate.wait(); return .init() }, ruleLoader: { _ in await gate.wait(); return .init() }, healthLoader: { _ in await gate.wait(); return .init() })
            let scope = scope(), lb = lb(), listener = listener(), group = group()
            let task = Task {
                switch operation {
                case 0: _ = try await service.loadLoadBalancers(scope: scope)
                case 1: _ = try await service.loadTargetGroups(scope: scope)
                case 2: _ = try await service.loadListeners(scope: scope, loadBalancer: lb)
                case 3: _ = try await service.loadRules(scope: scope, listener: listener)
                default: _ = try await service.loadTargetHealth(scope: scope, group: group)
                }
            }
            await gate.waitForEntry()
            task.cancel()
            await gate.open()
            do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    func testMembershipCancellationDuringHealthNeverReturnsPartialResult() async {
        let gate = TestGate()
        let raw = rawTG()
        let service = AWSELBService(loadBalancerLoader: { _ in .init() }, targetGroupLoader: { _ in .init(targetGroups: [raw]) },
            listenerLoader: { _ in .init() }, ruleLoader: { _ in .init() }, healthLoader: { _ in await gate.wait(); return .init() })
        let selected = scope(), instance = instanceID
        let task = Task { try await service.loadInstanceMembership(scope: selected, instanceID: instance) }
        await gate.waitForEntry()
        task.cancel()
        await gate.open()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }

    private var instanceID: String { "i-0123456789abcdef0" }
    private func lbARN(_ name: String = "app", kind: String = "app", account: String = "111122223333", region: String = "us-east-1") -> String {
        "arn:aws:elasticloadbalancing:\(region):\(account):loadbalancer/\(kind)/\(name)/lb-id"
    }
    private func tgARN(_ name: String = "group", account: String = "111122223333") -> String {
        "arn:aws:elasticloadbalancing:us-east-1:\(account):targetgroup/\(name)/tg-id"
    }
    private func listenerARN(_ id: String = "listener-id", lbName: String = "app", kind: String = "app") -> String {
        "arn:aws:elasticloadbalancing:us-east-1:111122223333:listener/\(kind)/\(lbName)/lb-id/\(id)"
    }
    private func ruleARN(_ id: String = "rule-id", listenerID: String = "listener-id") -> String {
        "arn:aws:elasticloadbalancing:us-east-1:111122223333:listener-rule/app/app/lb-id/\(listenerID)/\(id)"
    }
    private func lb() -> ELBLoadBalancer { .init(arn: lbARN(), name: "app", kind: "application") }
    private func group(type: String = "instance") -> ELBTargetGroup { .init(arn: tgARN(), name: "group", targetType: type) }
    private func listener() -> ELBListener { .init(arn: listenerARN(), loadBalancerARN: lbARN(), protocolName: "HTTPS", port: 443) }
    private func rawLB(_ name: String = "app", kind: SDK.LoadBalancerTypeEnum = .application) -> SDK.LoadBalancer {
        let path = kind == .application ? "app" : kind == .network ? "net" : "gwy"
        return .init(loadBalancerArn: lbARN(name, kind: path), loadBalancerName: name, type: kind)
    }
    private func rawTG(_ name: String = "group", type: SDK.TargetTypeEnum = .instance, loadBalancers: [String]? = nil) -> SDK.TargetGroup {
        .init(loadBalancerArns: loadBalancers, targetGroupArn: tgARN(name), targetGroupName: name, targetType: type)
    }
    private func rawListener(actions: [SDK.Action] = []) -> SDK.Listener { .init(defaultActions: actions, listenerArn: listenerARN(), loadBalancerArn: lbARN(), port: 443, protocol: .https) }
    private func rawRule() -> SDK.Rule { .init(isDefault: false, priority: "1", ruleArn: ruleARN()) }
    private func target(_ id: String, port: Int? = 80, state: SDK.TargetHealthStateEnum = .healthy, reason: SDK.TargetHealthReasonEnum? = nil) -> SDK.TargetHealthDescription {
        .init(target: .init(id: id, port: port), targetHealth: .init(reason: reason, state: state))
    }
    private func dictionary(_ fields: [ELBField]) -> [String: String] { Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value) }) }
    private func scope(account: String = "111122223333", profile: String = "work", principal: String? = nil) -> MonitoringScope {
        MonitoringScope(profile: AWSProfile(name: profile, region: "us-east-1", ssoStartURL: nil, ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil),
            identity: AWSIdentity(account: account, arn: principal ?? "arn:aws:sts::\(account):assumed-role/Test/session", userID: "example"), region: "us-east-1",
            paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/example/config", "AWS_SHARED_CREDENTIALS_FILE": "/example/credentials"]))
    }
    private func service(_ stub: ELBStub) -> AWSELBService {
        AWSELBService(loadBalancerLoader: { try await stub.loadBalancers($0) }, targetGroupLoader: { try await stub.groups($0) },
                       listenerLoader: { try await stub.listeners($0) }, ruleLoader: { try await stub.rules($0) }, healthLoader: { try await stub.health($0) })
    }
    private func membershipService(groups: [SDK.TargetGroup], probe: MembershipProbe) -> AWSELBService {
        AWSELBService(loadBalancerLoader: { _ in .init() }, targetGroupLoader: { _ in .init(targetGroups: groups) },
                       listenerLoader: { _ in .init() }, ruleLoader: { _ in .init() }, healthLoader: { try await probe.load($0) })
    }
    private func perform(_ operation: Int, service: AWSELBService, scope: MonitoringScope) async throws {
        switch operation {
        case 0: _ = try await service.loadLoadBalancers(scope: scope)
        case 1: _ = try await service.loadTargetGroups(scope: scope)
        case 2: _ = try await service.loadListeners(scope: scope, loadBalancer: lb())
        case 3: _ = try await service.loadRules(scope: scope, listener: listener())
        default: _ = try await service.loadTargetHealth(scope: scope, group: group())
        }
    }
    private func assertError<E: Error & Equatable>(_ expected: E, file: StaticString = #filePath, line: UInt = #line, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected error", file: file, line: line) }
        catch {
            XCTAssertEqual(error as? E, expected, file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains("ELB-sensitive-test-value"), file: file, line: line)
        }
    }
}

private actor ELBStub {
    typealias SDK = ElasticLoadBalancingV2
    private var lbPages: [SDK.DescribeLoadBalancersOutput]
    private var groupPages: [SDK.DescribeTargetGroupsOutput]
    private var listenerPages: [SDK.DescribeListenersOutput]
    private var rulePages: [SDK.DescribeRulesOutput]
    private var healthPages: [SDK.DescribeTargetHealthOutput]
    private let failure: Error?
    private var lbRequests: [SDK.DescribeLoadBalancersInput] = []
    private var groupRequests: [SDK.DescribeTargetGroupsInput] = []
    private var listenerRequests: [SDK.DescribeListenersInput] = []
    private var ruleRequests: [SDK.DescribeRulesInput] = []
    private var healthRequests: [SDK.DescribeTargetHealthInput] = []
    init(loadBalancers: [SDK.DescribeLoadBalancersOutput] = [], groups: [SDK.DescribeTargetGroupsOutput] = [],
         listeners: [SDK.DescribeListenersOutput] = [], rules: [SDK.DescribeRulesOutput] = [], health: [SDK.DescribeTargetHealthOutput] = [], failure: Error? = nil) {
        lbPages = loadBalancers; groupPages = groups; listenerPages = listeners; rulePages = rules; healthPages = health; self.failure = failure
    }
    func loadBalancers(_ request: SDK.DescribeLoadBalancersInput) throws -> SDK.DescribeLoadBalancersOutput {
        lbRequests.append(request)
        if let failure { throw failure }
        guard !lbPages.isEmpty else { throw ELBError.invalidResponse }
        return lbPages.removeFirst()
    }
    func groups(_ request: SDK.DescribeTargetGroupsInput) throws -> SDK.DescribeTargetGroupsOutput {
        groupRequests.append(request)
        if let failure { throw failure }
        guard !groupPages.isEmpty else { throw ELBError.invalidResponse }
        return groupPages.removeFirst()
    }
    func listeners(_ request: SDK.DescribeListenersInput) throws -> SDK.DescribeListenersOutput {
        listenerRequests.append(request)
        if let failure { throw failure }
        guard !listenerPages.isEmpty else { throw ELBError.invalidResponse }
        return listenerPages.removeFirst()
    }
    func rules(_ request: SDK.DescribeRulesInput) throws -> SDK.DescribeRulesOutput {
        ruleRequests.append(request)
        if let failure { throw failure }
        guard !rulePages.isEmpty else { throw ELBError.invalidResponse }
        return rulePages.removeFirst()
    }
    func health(_ request: SDK.DescribeTargetHealthInput) throws -> SDK.DescribeTargetHealthOutput {
        healthRequests.append(request)
        if let failure { throw failure }
        guard !healthPages.isEmpty else { throw ELBError.invalidResponse }
        return healthPages.removeFirst()
    }
    func requests() -> (loadBalancers: [SDK.DescribeLoadBalancersInput], groups: [SDK.DescribeTargetGroupsInput],
                       listeners: [SDK.DescribeListenersInput], rules: [SDK.DescribeRulesInput], health: [SDK.DescribeTargetHealthInput]) {
        (lbRequests, groupRequests, listenerRequests, ruleRequests, healthRequests)
    }
}

private actor MembershipProbe {
    typealias SDK = ElasticLoadBalancingV2
    private let responses: [String: SDK.DescribeTargetHealthOutput]
    private let failureARNs: Set<String>
    private var arns: [String] = []
    private var active = 0
    private var maximumActive = 0
    init(responses: [String: SDK.DescribeTargetHealthOutput], failureARNs: Set<String> = []) {
        self.responses = responses; self.failureARNs = failureARNs
    }
    func load(_ request: SDK.DescribeTargetHealthInput) async throws -> SDK.DescribeTargetHealthOutput {
        guard let arn = request.targetGroupArn else { throw ELBError.invalidResponse }
        arns.append(arn); active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(10))
        if failureARNs.contains(arn) { throw NSError(domain: "ELB-sensitive-test-value", code: 1) }
        return responses[arn] ?? .init()
    }
    func snapshot() -> (arns: [String], maximumActive: Int) { (arns, maximumActive) }
}
