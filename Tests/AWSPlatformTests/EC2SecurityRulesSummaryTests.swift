import XCTest
@testable import AWSPlatform

final class EC2SecurityRulesSummaryTests: XCTestCase {
    func testMultipleGroupsKeepDirectionOrderOwnershipAndDuplicateRules() {
        let repeated = EC2SecurityRulesFixture.rule()
        let ipv6 = EC2SecurityRulesFixture.rule(source: "2001:db8:abcd:1234::/64", description: "IPv6 clients")
        let egress = EC2SecurityRulesFixture.rule(protocolName: "All", ports: "All", source: "0.0.0.0/0")
        let groups = [
            EC2SecurityRulesFixture.group("sg-web", name: "Web", inbound: [repeated, repeated], outbound: [egress]),
            EC2SecurityRulesFixture.group("sg-app", name: "Application", inbound: [repeated, ipv6], outbound: [ipv6, egress])
        ]

        let summary = EC2SecurityRuleSummary(groups: groups)

        XCTAssertEqual(summary.inbound.count, 4)
        XCTAssertEqual(summary.outbound.count, 3)
        XCTAssertEqual(summary.inbound.map(\.groupId), ["sg-web", "sg-web", "sg-app", "sg-app"])
        XCTAssertEqual(summary.inbound.map(\.groupName), ["Web", "Web", "Application", "Application"])
        XCTAssertEqual(summary.outbound.map(\.groupId), ["sg-web", "sg-app", "sg-app"])
        XCTAssertEqual(summary.inbound.map(\.rule), [repeated, repeated, repeated, ipv6])
        XCTAssertEqual(summary.outbound.map(\.rule), [egress, ipv6, egress])
    }

    func testRowIDsAreDeterministicAndDistinctAcrossDuplicatesGroupsAndDirections() {
        let rule = EC2SecurityRulesFixture.rule()
        // Even malformed duplicate group IDs must not create duplicate SwiftUI row IDs.
        let groups = [
            EC2SecurityRulesFixture.group("sg-same", name: "First", inbound: [rule, rule], outbound: [rule]),
            EC2SecurityRulesFixture.group("sg-same", name: "Second", inbound: [rule], outbound: [rule, rule])
        ]
        let first = EC2SecurityRuleSummary(groups: groups)
        let repeated = EC2SecurityRuleSummary(groups: groups)
        let ids = first.inbound.map(\.id) + first.outbound.map(\.id)

        XCTAssertEqual(Set(ids).count, 6)
        XCTAssertEqual(first.inbound.map(\.id), repeated.inbound.map(\.id))
        XCTAssertEqual(first.outbound.map(\.id), repeated.outbound.map(\.id))
        XCTAssertNotEqual(first.inbound[0].id, first.inbound[1].id)
        XCTAssertNotEqual(first.inbound[0].id, first.outbound[0].id)
        XCTAssertNotEqual(first.inbound[0].id, first.inbound[2].id)
    }

    func testUnnamedGroupAndUnknownRuleFieldsArePreservedWithoutInventingValues() {
        let rule = EC2SecurityRulesFixture.rule(protocolName: "-1", ports: "", source: "", description: nil)
        let summary = EC2SecurityRuleSummary(groups: [
            EC2SecurityRulesFixture.group("sg-unnamed", name: nil, inbound: [rule], outbound: [])
        ])

        XCTAssertEqual(summary.inbound.count, 1)
        XCTAssertEqual(summary.inbound.first?.groupId, "sg-unnamed")
        XCTAssertNil(summary.inbound.first?.groupName)
        XCTAssertEqual(summary.inbound.first?.rule, rule)
        XCTAssertTrue(summary.outbound.isEmpty)
    }

    func testEmptyGroupsAndEmptyRulesHaveNoSyntheticRows() {
        let noGroups = EC2SecurityRuleSummary(groups: [])
        let noRules = EC2SecurityRuleSummary(groups: [
            EC2SecurityRulesFixture.group("sg-empty", name: "Empty", inbound: [], outbound: [])
        ])

        XCTAssertTrue(noGroups.inbound.isEmpty)
        XCTAssertTrue(noGroups.outbound.isEmpty)
        XCTAssertTrue(noRules.inbound.isEmpty)
        XCTAssertTrue(noRules.outbound.isEmpty)
    }
}

enum EC2SecurityRulesFixture {
    static func rule(protocolName: String = "TCP", ports: String = "443", source: String = "10.0.0.0/8",
                     description: String? = "HTTPS clients") -> EC2SecurityRuleModel {
        EC2SecurityRuleModel(protocolName: protocolName, portRange: ports, source: source, description: description)
    }

    static func group(_ id: String, name: String?, inbound: [EC2SecurityRuleModel], outbound: [EC2SecurityRuleModel]) -> EC2SecurityGroupModel {
        EC2SecurityGroupModel(groupId: id, name: name, description: "Offline security group", vpcId: "vpc-offline",
                              inboundRules: inbound, outboundRules: outbound)
    }

    static var longGroups: [EC2SecurityGroupModel] {
        let longName = "Production-中文-" + String(repeating: "shared-service-", count: 8)
        let longDescription = "Allow HTTPS from IPv6 clients，保留安全组归属。 " + String(repeating: "Long rule description. ", count: 6)
        let https = rule(source: "2001:db8:abcd:1234:5678:90ab:cdef:0000/64", description: longDescription)
        return [
            group("sg-0123456789abcdef0", name: longName, inbound: [https, https], outbound: [
                rule(protocolName: "All", ports: "All", source: "::/0", description: "Outbound IPv6")
            ]),
            group("sg-0fedcba9876543210", name: nil, inbound: [
                rule(protocolName: "ICMPv6", ports: "128 / 0", source: "2001:db8::/32", description: nil)
            ], outbound: [])
        ]
    }

    static func instance() -> EC2InstanceModel {
        EC2InstanceModel(instanceId: "i-security-preview", name: "Security rules preview", instanceType: "t3.micro",
                         state: "running", privateIP: nil, publicIP: nil, platformDetails: nil, architecture: nil,
                         vpcId: "vpc-offline", subnetId: nil, availabilityZone: nil,
                         securityGroups: ["sg-0123456789abcdef0", "sg-0fedcba9876543210"],
                         imageId: nil, imageName: nil, keyName: nil, launchTime: nil, tags: [:])
    }

    static func detail(_ id: String) -> EC2InstanceDetailModel {
        EC2InstanceDetailModel(instanceId: id, privateDNSName: nil, publicDNSName: nil, ipv6Address: nil,
                               monitoringState: nil, stateTransitionReason: nil, iamProfileARN: nil,
                               rootDeviceName: nil, rootDeviceType: nil, virtualizationType: nil, hypervisor: nil,
                               lifecycle: nil, spotRequestId: nil, capacityReservationId: nil, cpuCoreCount: nil,
                               threadsPerCore: nil, ebsOptimized: nil, enaSupport: nil, sourceDestCheck: nil,
                               metadataHttpEndpoint: nil, metadataHttpTokens: nil, metadataHopLimit: nil,
                               metadataTags: nil, networkInterfaces: [], volumes: [], securityGroups: [],
                               warnings: [], securityGroupIDs: instance().securityGroups)
    }
}
