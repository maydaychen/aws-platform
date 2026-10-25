import Foundation
import SotoCore
import SotoEC2
import XCTest
@testable import AWSPlatform

final class AWSSecurityGroupServiceTests: XCTestCase {
    func testGroupsPaginateEmptyPagesAndPreserveNamesOwnersAndTags() async throws {
        let stub = SecurityGroupStub(groups: [
            .init(nextToken: "empty", securityGroups: [rawGroup()]), .init(nextToken: "last"),
            .init(securityGroups: [rawGroup(secondGroupID, name: "shared", owner: "444455556666")])
        ])
        let groups = try await service(stub).loadGroups(scope: scope())
        XCTAssertEqual(groups.map(\.name), ["application", "shared"])
        XCTAssertEqual(groups[0].id, groupID)
        XCTAssertEqual(groups[0].ownerID, "111122223333")
        XCTAssertEqual(groups[1].ownerID, "444455556666", "Visible shared groups must be retained without treating them as owned")
        XCTAssertEqual(groups[0].vpcID, "vpc-01234567")
        XCTAssertEqual(groups[0].description, "Fixture group")
        XCTAssertEqual(groups[0].tags, [.init(name: "Empty", value: ""), .init(name: "Name", value: "Display label")])
        let requests = await stub.requests()
        XCTAssertEqual(requests.groups.map(\.nextToken), [nil, "empty", "last"])
        XCTAssertTrue(requests.groups.allSatisfy { $0.maxResults == 200 && $0.groupIds == nil && $0.filters == nil && $0.groupNames == nil && $0.dryRun == nil })
        XCTAssertTrue(requests.instances.isEmpty)
    }

    func testRulesDistinguishIPv4IPv6PrefixAndStructuredGroupReferences() async throws {
        let permission = EC2.IpPermission(
            fromPort: 443, ipProtocol: "tcp", ipRanges: [.init(cidrIp: "0.0.0.0/0", description: "IPv4 clients")],
            ipv6Ranges: [.init(cidrIpv6: "::/0", description: "IPv6 clients")], prefixListIds: [.init(description: "Managed prefix", prefixListId: "pl-01234567")],
            toPort: 443, userIdGroupPairs: [.init(description: "Application source", groupId: secondGroupID, groupName: "peer",
                peeringStatus: "active", userId: "444455556666", vpcId: "vpc-12345678", vpcPeeringConnectionId: "pcx-01234567")]
        )
        let raw = EC2.SecurityGroup(description: "HTTPS", groupId: groupID, groupName: "application", ipPermissions: [permission],
            ipPermissionsEgress: [.init(ipProtocol: "-1", ipRanges: [.init(cidrIp: "0.0.0.0/0")])], ownerId: "111122223333")
        let groups = try await service(SecurityGroupStub(groups: [.init(securityGroups: [raw])])).loadGroups(scope: scope())
        let rules = groups[0].inboundRules
        XCTAssertEqual(rules.map(\.target), ["0.0.0.0/0", "::/0", "pl-01234567", secondGroupID])
        XCTAssertEqual(rules.map(\.protocolName), ["TCP", "TCP", "TCP", "TCP"])
        XCTAssertEqual(rules.map(\.portRange), ["443", "443", "443", "443"])
        XCTAssertEqual(rules.map { dictionary($0.fields)["Target type"] }, ["IPv4", "IPv6", "Prefix list", "Security group"])
        XCTAssertEqual(rules[0].description, "IPv4 clients")
        XCTAssertNil(rules[0].referencedGroupID)
        XCTAssertEqual(rules[3].referencedGroupID, secondGroupID)
        XCTAssertEqual(rules[3].referencedAccountID, "444455556666")
        XCTAssertEqual(dictionary(rules[3].fields)["VPC peering connection"], "pcx-01234567")
        XCTAssertEqual(dictionary(rules[3].fields)["Peering status"], "active")
        XCTAssertEqual(groups[0].outboundRules.first?.protocolName, "All")
        XCTAssertEqual(groups[0].outboundRules.first?.portRange, "All")
    }

    func testICMPTypeCodeAndNumericProtocolsAreNotMisrepresentedAsPorts() async throws {
        let permissions: [EC2.IpPermission] = [
            .init(fromPort: 8, ipProtocol: "icmp", ipRanges: [.init(cidrIp: "192.0.2.0/24")], toPort: 0),
            .init(fromPort: -1, ipProtocol: "58", ipv6Ranges: [.init(cidrIpv6: "2001:db8::/32")], toPort: -1),
            .init(fromPort: 8000, ipProtocol: "6", ipRanges: [.init(cidrIp: "10.0.0.0/8")], toPort: 9000),
            .init(fromPort: 53, ipProtocol: "17", ipRanges: [.init(cidrIp: "10.0.0.0/8")], toPort: 53),
            .init(ipProtocol: "47", ipRanges: [.init(cidrIp: "10.0.0.0/8")]),
            .init(ipProtocol: "tcp", ipRanges: [.init(cidrIp: "10.0.0.0/8")])
        ]
        let raw = EC2.SecurityGroup(groupId: groupID, groupName: "protocols", ipPermissions: permissions)
        let result = try await service(SecurityGroupStub(groups: [.init(securityGroups: [raw])])).loadGroups(scope: scope())
        XCTAssertEqual(result[0].inboundRules.map(\.protocolName), ["ICMP", "ICMPv6", "TCP", "UDP", "Protocol 47", "TCP"])
        XCTAssertEqual(result[0].inboundRules.map(\.portRange), ["Type: 8; Code: 0", "Type: All; Code: All", "8000-9000", "53", "All", "Unknown"])
    }

    func testMissingOwnerAndDeletedReferenceMetadataAreNotInvented() async throws {
        let raw = EC2.SecurityGroup(groupId: groupID, groupName: "application", ipPermissions: [
            .init(ipProtocol: "-1", userIdGroupPairs: [.init(groupId: secondGroupID), .init(groupName: "legacy-name", userId: "111122223333")])
        ])
        let result = try await service(SecurityGroupStub(groups: [.init(securityGroups: [raw])])).loadGroups(scope: scope())
        XCTAssertNil(result[0].ownerID)
        XCTAssertNil(result[0].vpcID)
        XCTAssertNil(result[0].inboundRules[0].referencedAccountID)
        XCTAssertEqual(result[0].inboundRules[0].referencedGroupID, secondGroupID)
        XCTAssertNil(result[0].inboundRules[1].referencedGroupID)
        XCTAssertEqual(result[0].inboundRules[1].target, "legacy-name")
    }

    func testOptionalGroupARNAcceptsSharedOwnerAndRejectsContradictions() async throws {
        let sharedARN = "arn:aws:ec2:us-east-1:444455556666:security-group/\(groupID)"
        let shared = EC2.SecurityGroup(groupId: groupID, groupName: "shared", ownerId: "444455556666", securityGroupArn: sharedARN)
        let valid = try await service(SecurityGroupStub(groups: [.init(securityGroups: [shared])])).loadGroups(scope: scope())
        XCTAssertEqual(valid[0].ownerID, "444455556666")
        let invalid = [sharedARN.replacingOccurrences(of: "us-east-1", with: "eu-west-1"),
                       sharedARN.replacingOccurrences(of: "arn:aws:", with: "arn:aws-cn:"),
                       sharedARN.replacingOccurrences(of: groupID, with: secondGroupID),
                       sharedARN.replacingOccurrences(of: "444455556666", with: "111122223333")]
        for arn in invalid {
            let raw = EC2.SecurityGroup(groupId: groupID, groupName: "shared", ownerId: "444455556666", securityGroupArn: arn)
            await assertError(.invalidResponse) { _ = try await self.service(SecurityGroupStub(groups: [.init(securityGroups: [raw])])).loadGroups(scope: self.scope()) }
        }
    }

    func testGroupsRejectMalformedIdentityOwnerTagsAndDuplicates() async {
        let invalid: [EC2.SecurityGroup] = [
            .init(groupName: "missing-id"), .init(groupId: groupID), .init(groupId: "sg-invalid", groupName: "bad"),
            .init(groupId: groupID + "\n", groupName: "bad"), .init(groupId: groupID, groupName: "bad", ownerId: "not-an-account"),
            .init(groupId: groupID, groupName: "bad", tags: [.init(key: "Name")]),
            .init(groupId: groupID, groupName: "bad", tags: [.init(key: "Name", value: "one"), .init(key: "Name", value: "two")])
        ]
        for raw in invalid {
            await assertError(.invalidResponse) { _ = try await self.service(SecurityGroupStub(groups: [.init(securityGroups: [raw])])).loadGroups(scope: self.scope()) }
        }
        let duplicate = SecurityGroupStub(groups: [.init(nextToken: "next", securityGroups: [rawGroup()]), .init(securityGroups: [rawGroup()])])
        await assertError(.invalidResponse) { _ = try await self.service(duplicate).loadGroups(scope: self.scope()) }
    }

    func testRulesRejectMalformedDestinationsProtocolsAndPortRanges() async {
        let invalid: [EC2.IpPermission] = [
            .init(ipRanges: [.init(cidrIp: "0.0.0.0/0")]), .init(ipProtocol: "tcp"),
            .init(ipProtocol: "tcp", ipRanges: [.init(cidrIp: "999.0.0.0/8")]),
            .init(ipProtocol: "tcp", ipRanges: [.init(cidrIp: "10.0.0.0\u{0}hidden/8")]),
            .init(ipProtocol: "tcp", ipRanges: [.init(cidrIp: "0.0.0.0/33")]),
            .init(ipProtocol: "tcp", ipv6Ranges: [.init(cidrIpv6: "::/129")]),
            .init(ipProtocol: "tcp", prefixListIds: [.init(prefixListId: "not-a-prefix")]),
            .init(ipProtocol: "tcp", userIdGroupPairs: [.init(groupId: "bad")]),
            .init(ipProtocol: "tcp", userIdGroupPairs: [.init(groupId: secondGroupID, userId: "bad")]),
            .init(fromPort: 9000, ipProtocol: "tcp", ipRanges: [.init(cidrIp: "0.0.0.0/0")], toPort: 8000),
            .init(fromPort: -2, ipProtocol: "icmp", ipRanges: [.init(cidrIp: "0.0.0.0/0")], toPort: 0),
            .init(ipProtocol: "999", ipRanges: [.init(cidrIp: "0.0.0.0/0")])
        ]
        for rule in invalid {
            let raw = EC2.SecurityGroup(groupId: groupID, groupName: "bad", ipPermissions: [rule])
            await assertError(.invalidResponse) { _ = try await self.service(SecurityGroupStub(groups: [.init(securityGroups: [raw])])).loadGroups(scope: self.scope()) }
        }
    }

    func testExactInstanceQueryUsesFilterPaginatesAndUnionsPrimaryAndSecondaryENIGroups() async throws {
        let raw = EC2.Instance(instanceId: instanceID, networkInterfaces: [
            .init(groups: [.init(groupId: groupID)], networkInterfaceId: "eni-01234567"),
            .init(attachment: .init(deviceIndex: 1), groups: [.init(groupId: secondGroupID)], networkInterfaceId: "eni-12345678")
        ], securityGroups: [.init(groupId: groupID)], tags: [.init(key: "Name", value: "worker")], vpcId: "vpc-01234567")
        let stub = SecurityGroupStub(instances: [
            .init(nextToken: "empty", reservations: [.init(instances: [raw], ownerId: "111122223333")]),
            .init(nextToken: "last"), .init()
        ])
        let loaded = try await service(stub).loadInstance(scope: scope(), instanceID: instanceID)
        let result = try XCTUnwrap(loaded)
        XCTAssertEqual(result.id, instanceID)
        XCTAssertEqual(result.name, "worker")
        XCTAssertEqual(result.vpcID, "vpc-01234567")
        XCTAssertEqual(result.securityGroupIDs, [groupID, secondGroupID].sorted())
        let requests = await stub.requests()
        XCTAssertEqual(requests.instances.map(\.nextToken), [nil, "empty", "last"])
        for request in requests.instances {
            XCTAssertEqual(request.filters?.first?.name, "instance-id")
            XCTAssertEqual(request.filters?.first?.values, [instanceID])
            XCTAssertEqual(request.filters?.count, 1)
            XCTAssertEqual(request.maxResults, 200)
            XCTAssertNil(request.instanceIds)
            XCTAssertNil(request.dryRun)
        }
        XCTAssertTrue(requests.groups.isEmpty)
    }

    func testReverseGroupQueryIncludesInstancesBoundOnlyThroughSecondaryInterface() async throws {
        let first = EC2.Instance(instanceId: instanceID, networkInterfaces: [
            .init(description: "secondary interface", groups: [.init(groupId: secondGroupID)])
        ], securityGroups: [.init(groupId: groupID)])
        let second = EC2.Instance(instanceId: secondInstanceID, networkInterfaces: [.init(groups: [.init(groupId: secondGroupID)])])
        let stub = SecurityGroupStub(instances: [
            .init(nextToken: "last", reservations: [.init(instances: [first], ownerId: "111122223333")]),
            .init(reservations: [.init(instances: [second], ownerId: "111122223333")])
        ])
        let results = try await service(stub).loadInstancesUsingGroup(scope: scope(), groupID: secondGroupID)
        XCTAssertEqual(Set(results.map(\.id)), [instanceID, secondInstanceID])
        XCTAssertTrue(results.allSatisfy { $0.securityGroupIDs.contains(secondGroupID) })
        let requests = await stub.requests()
        XCTAssertEqual(requests.instances.map(\.nextToken), [nil, "last"])
        XCTAssertTrue(requests.instances.allSatisfy { $0.filters?.count == 1 && $0.filters?.first?.name == "network-interface.group-id" && $0.filters?.first?.values == [secondGroupID] })
    }

    func testMissingInstanceReturnsNilAndDoesNotSelectAnotherInstance() async throws {
        let empty = try await service(SecurityGroupStub(instances: [.init()])).loadInstance(scope: scope(), instanceID: instanceID)
        XCTAssertNil(empty)
        let wrong = SecurityGroupStub(instances: [.init(reservations: [.init(instances: [.init(instanceId: secondInstanceID)])])])
        await assertError(.invalidResponse) { _ = try await self.service(wrong).loadInstance(scope: self.scope(), instanceID: self.instanceID) }
    }

    func testInstanceMappingDoesNotGuessGroupIDsFromDescriptionsOrGroupNames() async throws {
        let raw = EC2.Instance(instanceId: instanceID, networkInterfaces: [.init(description: "ELB associated with \(groupID)")])
        let stub = SecurityGroupStub(instances: [.init(reservations: [.init(instances: [raw])])])
        let loaded = try await service(stub).loadInstance(scope: scope(), instanceID: instanceID)
        let result = try XCTUnwrap(loaded)
        XCTAssertEqual(result.name, instanceID)
        XCTAssertTrue(result.securityGroupIDs.isEmpty)
        let reverse = SecurityGroupStub(instances: [.init(reservations: [.init(instances: [raw])])])
        await assertError(.invalidResponse) { _ = try await self.service(reverse).loadInstancesUsingGroup(scope: self.scope(), groupID: self.groupID) }
    }

    func testInstanceQueriesRejectForeignReservationMalformedGroupsAndDuplicates() async {
        let cases: [[EC2.DescribeInstancesResult]] = [
            [.init(reservations: [.init(instances: [.init(instanceId: instanceID)], ownerId: "444455556666")])],
            [.init(reservations: [.init(instances: [.init(instanceId: instanceID)], ownerId: "")])],
            [.init(reservations: [.init(instances: [.init(instanceId: "i-invalid")])])],
            [.init(reservations: [.init(instances: [.init(instanceId: instanceID, securityGroups: [.init(groupName: groupID)])])])],
            [.init(reservations: [.init(instances: [.init(instanceId: instanceID, networkInterfaces: [.init(groups: [.init(groupId: "bad")])])])])],
            [.init(nextToken: "next", reservations: [.init(instances: [.init(instanceId: instanceID)])]),
             .init(reservations: [.init(instances: [.init(instanceId: instanceID)])])]
        ]
        for pages in cases {
            await assertError(.invalidResponse) { _ = try await self.service(SecurityGroupStub(instances: pages)).loadInstance(scope: self.scope(), instanceID: self.instanceID) }
        }
    }

    func testPaginationCyclesWhitespaceAndLimitsNeverReturnPartialLists() async {
        for tokens in [["repeat", "repeat"], ["   "], (0..<1_000).map { "page-\($0)" }] {
            let groupStub = SecurityGroupStub(groups: tokens.map { .init(nextToken: $0) })
            await assertError(.incompletePagination) { _ = try await self.service(groupStub).loadGroups(scope: self.scope()) }
            let instanceStub = SecurityGroupStub(instances: tokens.map { .init(nextToken: $0) })
            await assertError(.incompletePagination) { _ = try await self.service(instanceStub).loadInstance(scope: self.scope(), instanceID: self.instanceID) }
            let groupRequests = await groupStub.requests()
            let instanceRequests = await instanceStub.requests()
            XCTAssertEqual(groupRequests.groups.count, tokens.count)
            XCTAssertEqual(instanceRequests.instances.count, tokens.count)
        }
    }

    func testLaterPageFailureCannotReturnEarlierInventoryAsComplete() async {
        let groups = SecurityGroupStub(groups: [.init(nextToken: "next", securityGroups: [rawGroup()])])
        await assertError(.invalidResponse) { _ = try await self.service(groups).loadGroups(scope: self.scope()) }
        let instances = SecurityGroupStub(instances: [.init(nextToken: "next", reservations: [.init(instances: [.init(instanceId: instanceID)])])])
        await assertError(.invalidResponse) { _ = try await self.service(instances).loadInstance(scope: self.scope(), instanceID: self.instanceID) }
    }

    func testInvalidScopeIDsAndRegionMismatchMakeNoRequests() async {
        let stub = SecurityGroupStub()
        let service = service(stub)
        for invalid in [scope(account: ""), scope(profile: ""), scope(region: "cn-north-1"), scope(principal: "arn:aws:sts::444455556666:assumed-role/Test/session")] {
            await assertError(.invalidScope) { _ = try await service.loadGroups(scope: invalid) }
            await assertError(.invalidScope) { _ = try await service.loadInstance(scope: invalid, instanceID: self.instanceID) }
            await assertError(.invalidScope) { _ = try await service.loadInstancesUsingGroup(scope: invalid, groupID: self.groupID) }
        }
        await assertError(.invalidResponse) { _ = try await service.loadInstance(scope: self.scope(), instanceID: self.instanceID + "\n") }
        await assertError(.invalidResponse) { _ = try await service.loadInstancesUsingGroup(scope: self.scope(), groupID: "sg-invalid") }
        let requests = await stub.requests()
        XCTAssertTrue(requests.groups.isEmpty)
        XCTAssertTrue(requests.instances.isEmpty)
    }

    func testErrorsAreSanitizedForEveryQuery() async {
        let failures: [(Error, SecurityGroupError)] = [
            (AWSResponseError(errorCode: "UnauthorizedOperation"), .permission), (AWSResponseError(errorCode: "ExpiredToken"), .credentials),
            (AWSResponseError(errorCode: "RequestLimitExceeded"), .throttled), (AWSResponseError(errorCode: "InvalidNextToken"), .incompletePagination),
            (URLError(.notConnectedToInternet), .network),
            (NSError(domain: "private-sg-token", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-sg-token"]), .failed)
        ]
        for (error, expected) in failures {
            let service = service(SecurityGroupStub(failure: error))
            await assertError(expected) { _ = try await service.loadGroups(scope: self.scope()) }
            await assertError(expected) { _ = try await service.loadInstance(scope: self.scope(), instanceID: self.instanceID) }
            await assertError(expected) { _ = try await service.loadInstancesUsingGroup(scope: self.scope(), groupID: self.groupID) }
        }
    }

    func testCancellationBeforeQueryMakesNoCalls() async {
        for operation in 0..<3 {
            let gate = TestGate()
            let stub = SecurityGroupStub()
            let service = service(stub), scope = scope(), instanceID = instanceID, groupID = groupID
            let task = Task {
                await gate.wait()
                switch operation {
                case 0: _ = try await service.loadGroups(scope: scope)
                case 1: _ = try await service.loadInstance(scope: scope, instanceID: instanceID)
                default: _ = try await service.loadInstancesUsingGroup(scope: scope, groupID: groupID)
                }
            }
            await gate.waitForEntry()
            task.cancel()
            await gate.open()
            do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
            let requests = await stub.requests()
            XCTAssertTrue(requests.groups.isEmpty && requests.instances.isEmpty)
        }
    }

    func testCancellationAfterResponsePreventsReturningLateData() async {
        for operation in 0..<3 {
            let gate = TestGate()
            let service = AWSSecurityGroupService(groupLoader: { _ in await gate.wait(); return .init() },
                                                  instanceLoader: { _ in await gate.wait(); return .init() })
            let scope = scope(), instanceID = instanceID, groupID = groupID
            let task = Task {
                switch operation {
                case 0: _ = try await service.loadGroups(scope: scope)
                case 1: _ = try await service.loadInstance(scope: scope, instanceID: instanceID)
                default: _ = try await service.loadInstancesUsingGroup(scope: scope, groupID: groupID)
                }
            }
            await gate.waitForEntry()
            task.cancel()
            await gate.open()
            do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    private var groupID: String { "sg-0123456789abcdef0" }
    private var secondGroupID: String { "sg-12345678" }
    private var instanceID: String { "i-0123456789abcdef0" }
    private var secondInstanceID: String { "i-12345678" }

    private func rawGroup(_ id: String? = nil, name: String = "application", owner: String = "111122223333") -> EC2.SecurityGroup {
        .init(description: "Fixture group", groupId: id ?? groupID, groupName: name, ownerId: owner,
              tags: [.init(key: "Name", value: "Display label"), .init(key: "Empty", value: "")], vpcId: "vpc-01234567")
    }

    private func scope(account: String = "111122223333", profile: String = "work", region: String = "us-east-1", principal: String? = nil) -> MonitoringScope {
        MonitoringScope(profile: AWSProfile(name: profile, region: region, ssoStartURL: nil, ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil),
            identity: AWSIdentity(account: account, arn: principal ?? "arn:aws:sts::\(account):assumed-role/Test/session", userID: "example"), region: region,
            paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/example/config", "AWS_SHARED_CREDENTIALS_FILE": "/example/credentials"]))
    }

    private func service(_ stub: SecurityGroupStub) -> AWSSecurityGroupService {
        AWSSecurityGroupService(groupLoader: { try await stub.groups($0) }, instanceLoader: { try await stub.instances($0) })
    }

    private func dictionary(_ fields: [ELBField]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value) })
    }

    private func assertError(_ expected: SecurityGroupError, file: StaticString = #filePath, line: UInt = #line, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected error", file: file, line: line) }
        catch {
            XCTAssertEqual(error as? SecurityGroupError, expected, file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains("private-sg-token"), file: file, line: line)
        }
    }
}

private actor SecurityGroupStub {
    private var groupPages: [EC2.DescribeSecurityGroupsResult]
    private var instancePages: [EC2.DescribeInstancesResult]
    private let failure: Error?
    private var groupRequests: [EC2.DescribeSecurityGroupsRequest] = []
    private var instanceRequests: [EC2.DescribeInstancesRequest] = []

    init(groups: [EC2.DescribeSecurityGroupsResult] = [], instances: [EC2.DescribeInstancesResult] = [], failure: Error? = nil) {
        groupPages = groups
        instancePages = instances
        self.failure = failure
    }

    func groups(_ request: EC2.DescribeSecurityGroupsRequest) throws -> EC2.DescribeSecurityGroupsResult {
        groupRequests.append(request)
        if let failure { throw failure }
        guard !groupPages.isEmpty else { throw SecurityGroupError.invalidResponse }
        return groupPages.removeFirst()
    }

    func instances(_ request: EC2.DescribeInstancesRequest) throws -> EC2.DescribeInstancesResult {
        instanceRequests.append(request)
        if let failure { throw failure }
        guard !instancePages.isEmpty else { throw SecurityGroupError.invalidResponse }
        return instancePages.removeFirst()
    }

    func requests() -> (groups: [EC2.DescribeSecurityGroupsRequest], instances: [EC2.DescribeInstancesRequest]) {
        (groupRequests, instanceRequests)
    }
}
