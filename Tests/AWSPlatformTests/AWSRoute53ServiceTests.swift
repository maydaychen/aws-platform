import Foundation
import SotoCore
import SotoRoute53
import XCTest
@testable import AWSPlatform

final class AWSRoute53ServiceTests: XCTestCase {
    func testListsPublicAndPrivateZonesAcrossEmptyPagesWithCanonicalIDs() async throws {
        let stub = Route53Stub(zonePages: [
            .init(hostedZones: [rawZone("ZPUBLIC")], isTruncated: true, maxItems: 100, nextMarker: "empty"),
            .init(hostedZones: [], isTruncated: true, maxItems: 100, nextMarker: "last"),
            .init(hostedZones: [rawZone("ZPRIVATE", privateZone: true)], isTruncated: false, maxItems: 100)
        ])
        let zones = try await service(stub).loadZones(scope: scope())
        XCTAssertEqual(Set(zones.map(\.id)), ["ZPUBLIC", "ZPRIVATE"])
        XCTAssertEqual(zones.first { $0.id == "ZPUBLIC" }?.isPrivate, false)
        XCTAssertEqual(zones.first { $0.id == "ZPRIVATE" }?.isPrivate, true)
        XCTAssertEqual(zones.first?.recordCount, 4)
        XCTAssertEqual(zones.first?.comment, "Fixture zone")
        let requests = await stub.requests()
        XCTAssertEqual(requests.zones.map(\.marker), [nil, "empty", "last"])
        for request in requests.zones {
            XCTAssertEqual(request.maxItems, 100)
            XCTAssertNil(request.hostedZoneType)
            XCTAssertNil(request.delegationSetId)
        }
        XCTAssertTrue(requests.details.isEmpty)
        XCTAssertTrue(requests.records.isEmpty)
        XCTAssertTrue(requests.tags.isEmpty)
    }

    func testZoneListRejectsUnknownPrivacyInvalidIDsCountsAndDuplicateCanonicalIDs() async {
        let malformed: [Route53.HostedZone] = [
            .init(callerReference: "reference", id: "ZEXAMPLE", name: "example.test."),
            .init(callerReference: "reference", config: .init(), id: "ZEXAMPLE", name: "example.test."),
            rawZone("../other"), rawZone("ZEXAMPLE", name: ""), rawZone("ZEXAMPLE", count: -1)
        ]
        for raw in malformed {
            let stub = Route53Stub(zonePages: [.init(hostedZones: [raw], isTruncated: false, maxItems: 100)])
            await assertError(Route53Error.invalidResponse) { _ = try await self.service(stub).loadZones(scope: self.scope()) }
        }
        let duplicate = Route53.HostedZone(callerReference: "reference", config: .init(privateZone: false),
                                           id: "ZEXAMPLE", name: "example.test.")
        let stub = Route53Stub(zonePages: [
            .init(hostedZones: [rawZone()], isTruncated: true, maxItems: 100, nextMarker: "next"),
            .init(hostedZones: [duplicate], isTruncated: false, maxItems: 100)
        ])
        await assertError(Route53Error.invalidResponse) { _ = try await self.service(stub).loadZones(scope: self.scope()) }
    }

    func testZonePaginationRejectsMissingEmptyRepeatedMarkersAndPageLimit() async {
        let cases: [[Route53.ListHostedZonesResponse]] = [
            [.init(hostedZones: [rawZone()], isTruncated: true, maxItems: 100)],
            [.init(hostedZones: [], isTruncated: true, maxItems: 100, nextMarker: "")],
            [.init(hostedZones: [], isTruncated: true, maxItems: 100, nextMarker: "repeat"),
             .init(hostedZones: [], isTruncated: true, maxItems: 100, nextMarker: "repeat")],
            (0..<1_000).map { .init(hostedZones: [], isTruncated: true, maxItems: 100, nextMarker: "page-\($0)") }
        ]
        for pages in cases {
            let stub = Route53Stub(zonePages: pages)
            await assertError(Route53Error.incompletePagination) { _ = try await self.service(stub).loadZones(scope: self.scope()) }
            let requests = await stub.requests()
            XCTAssertEqual(requests.zones.count, pages.count)
        }
    }

    func testDetailsPreserveDelegationVPCAndLinkedServiceWithoutFollowingLinks() async throws {
        let raw = Route53.HostedZone(
            callerReference: "created-by-app", config: .init(comment: "Updated comment", privateZone: false), id: "/hostedzone/ZEXAMPLE",
            linkedService: .init(description: "Created by service", servicePrincipal: "example.amazonaws.com"),
            name: "example.test.", resourceRecordSetCount: 12
        )
        let stub = Route53Stub(detailResponse: .init(
            delegationSet: .init(id: "/delegationset/NEXAMPLE", nameServers: ["ns-1.example.test.", "ns-2.example.test."]),
            hostedZone: raw, vpCs: [.init(vpcId: "vpc-example", vpcRegion: .euWest1)]
        ))
        let details = try await service(stub).loadDetails(scope: scope(), zone: zone())
        XCTAssertEqual(details.zone.id, "ZEXAMPLE")
        XCTAssertEqual(details.zone.recordCount, 12)
        XCTAssertEqual(details.zone.comment, "Updated comment")
        XCTAssertEqual(details.callerReference, "created-by-app")
        XCTAssertEqual(details.nameServers, ["ns-1.example.test.", "ns-2.example.test."])
        XCTAssertEqual(details.delegationSetID, "/delegationset/NEXAMPLE")
        XCTAssertEqual(details.vpcs, [.init(id: "vpc-example", region: "eu-west-1")])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: details.linkedService.map { ($0.name, $0.value) }),
                       ["Service principal": "example.amazonaws.com", "Description": "Created by service"])
        let requests = await stub.requests()
        XCTAssertEqual(requests.details.map(\.id), ["ZEXAMPLE"])
        XCTAssertTrue(requests.zones.isEmpty)
        XCTAssertTrue(requests.records.isEmpty)
        XCTAssertTrue(requests.tags.isEmpty)
    }

    func testPrivateZoneWithoutDelegationNameServersAndMissingOptionalFieldsIsValid() async throws {
        let raw = Route53.HostedZone(callerReference: "reference", config: .init(privateZone: true),
                                     id: "ZEXAMPLE", name: "example.test.")
        let stub = Route53Stub(detailResponse: .init(hostedZone: raw))
        let details = try await service(stub).loadDetails(scope: scope(), zone: zone(privateZone: true))
        XCTAssertTrue(details.nameServers.isEmpty)
        XCTAssertNil(details.delegationSetID)
        XCTAssertTrue(details.vpcs.isEmpty)
        XCTAssertTrue(details.linkedService.isEmpty)
        XCTAssertNil(details.zone.recordCount)
        XCTAssertNil(details.zone.comment)
    }

    func testDetailsRejectWrongZoneIDNameTypeAndMalformedVPC() async {
        let cases: [Route53.GetHostedZoneResponse] = [
            .init(hostedZone: rawZone("ZOTHER")), .init(hostedZone: rawZone(name: "other.test.")),
            .init(hostedZone: rawZone(privateZone: true)), .init(hostedZone: rawZone(), vpCs: [.init(vpcId: "vpc-example")]),
            .init(hostedZone: rawZone(), vpCs: [.init(vpcRegion: .usEast1)])
        ]
        for response in cases {
            await assertError(Route53Error.invalidResponse) {
                _ = try await self.service(Route53Stub(detailResponse: response)).loadDetails(scope: self.scope(), zone: self.zone())
            }
        }
    }

    func testRecordPaginationUsesCompoundCursorAndKeepsSameNameTypeWithDistinctSetIdentifiers() async throws {
        let name = "weighted.example.test."
        let first = Route53.ResourceRecordSet(name: name, resourceRecords: [.init(value: "192.0.2.10")],
                                              setIdentifier: "east", ttl: 60, type: .a, weight: 10)
        let second = Route53.ResourceRecordSet(name: name, resourceRecords: [.init(value: "192.0.2.20")],
                                               setIdentifier: "west", ttl: 60, type: .a, weight: 20)
        let stub = Route53Stub(recordPages: [
            .init(isTruncated: true, maxItems: 100, nextRecordIdentifier: "west", nextRecordName: name,
                  nextRecordType: .a, resourceRecordSets: [first]),
            .init(isTruncated: true, maxItems: 100, nextRecordName: "z.example.test.", nextRecordType: .txt, resourceRecordSets: [second]),
            .init(isTruncated: true, maxItems: 100, nextRecordName: "zz.example.test.", nextRecordType: .mx, resourceRecordSets: []),
            .init(isTruncated: false, maxItems: 100, resourceRecordSets: [.init(name: "zz.example.test.", resourceRecords: [.init(value: "10 mail.example.test.")], ttl: 300, type: .mx)])
        ])
        let records = try await service(stub).loadRecords(scope: scope(), zone: zone())
        XCTAssertEqual(records.count, 3)
        XCTAssertNotEqual(records[0].id, records[1].id)
        XCTAssertEqual(records[0].setIdentifier, "east")
        XCTAssertEqual(records[1].setIdentifier, "west")
        XCTAssertEqual(records[0].routingPolicy, "Weighted")
        XCTAssertEqual(records[0].values, ["192.0.2.10"])
        let requests = await stub.requests()
        XCTAssertEqual(requests.records.map(\.hostedZoneId), Array(repeating: "ZEXAMPLE", count: 4))
        XCTAssertEqual(requests.records.map(\.maxItems), [300, 300, 300, 300])
        XCTAssertEqual(requests.records.map(\.startRecordName), [nil, name, "z.example.test.", "zz.example.test."])
        XCTAssertEqual(requests.records.map(\.startRecordType), [nil, .a, .txt, .mx])
        XCTAssertEqual(requests.records.map(\.startRecordIdentifier), [nil, "west", nil, nil])
    }

    func testAliasKeepsMissingTTLAndNormalRecordsPreserveValuesAndZeroTTL() async throws {
        let stub = recordsStub([
            .init(aliasTarget: .init(dnsName: "target.example.test.", evaluateTargetHealth: false, hostedZoneId: "/hostedzone/ZTARGET"),
                  name: "alias.example.test.", type: .a),
            .init(multiValueAnswer: false, name: "text.example.test.", resourceRecords: [.init(value: "\"part one\" \"part two\""), .init(value: "\"\"")], ttl: 0, type: .txt)
        ])
        let records = try await service(stub).loadRecords(scope: scope(), zone: zone())
        XCTAssertNil(records[0].ttl)
        XCTAssertTrue(records[0].values.isEmpty)
        XCTAssertEqual(records[0].alias, .init(dnsName: "target.example.test.", hostedZoneID: "ZTARGET", evaluateTargetHealth: false))
        XCTAssertEqual(records[0].routingPolicy, "Simple")
        XCTAssertEqual(records[1].ttl, 0)
        XCTAssertEqual(records[1].values, ["\"part one\" \"part two\"", "\"\""])
        XCTAssertEqual(records[1].routingFields, [.init(name: "Multivalue answer", value: "Disabled")])
    }

    func testAdvancedRoutingMetadataIncludesEveryAvailableReadField() async throws {
        let stub = recordsStub([
            .init(healthCheckId: "health-example", name: "weighted.example.test.", region: .euWest1, setIdentifier: "weighted",
                  trafficPolicyInstanceId: "policy-example", type: .a, weight: 0),
            .init(failover: .secondary, geoLocation: .init(continentCode: "EU", countryCode: "DE", subdivisionCode: "BE"),
                  name: "geo.example.test.", setIdentifier: "geo", type: .aaaa),
            .init(geoProximityLocation: .init(awsRegion: "us-east-1", bias: -10,
                                             coordinates: .init(latitude: "40.7", longitude: "-74.0"), localZoneGroup: "us-east-1-example-1"),
                  name: "proximity.example.test.", setIdentifier: "proximity", type: .a),
            .init(cidrRoutingConfig: .init(collectionId: "collection-example", locationName: "*"), multiValueAnswer: true,
                  name: "cidr.example.test.", setIdentifier: "cidr", type: .a)
        ])
        let records = try await service(stub).loadRecords(scope: scope(), zone: zone())
        XCTAssertEqual(records[0].routingPolicy, "Weighted, Latency")
        XCTAssertEqual(fields(records[0]), ["Weight": "0", "Latency region": "eu-west-1", "Health check ID": "health-example", "Traffic policy instance ID": "policy-example"])
        XCTAssertEqual(records[1].routingPolicy, "Failover, Geolocation")
        XCTAssertEqual(fields(records[1]), ["Failover": "SECONDARY", "Continent": "EU", "Country": "DE", "Subdivision": "BE"])
        XCTAssertEqual(records[2].routingPolicy, "Geoproximity")
        XCTAssertEqual(fields(records[2]), ["Geoproximity AWS region": "us-east-1", "Geoproximity bias": "-10", "Geoproximity latitude": "40.7",
                                            "Geoproximity longitude": "-74.0", "Geoproximity local zone group": "us-east-1-example-1"])
        XCTAssertEqual(records[3].routingPolicy, "IP-based, Multivalue answer")
        XCTAssertEqual(fields(records[3]), ["CIDR collection": "collection-example", "CIDR location": "*", "Multivalue answer": "Enabled"])
        let requests = await stub.requests()
        XCTAssertTrue(requests.zones.isEmpty)
        XCTAssertTrue(requests.details.isEmpty)
        XCTAssertTrue(requests.tags.isEmpty)
    }

    func testSimpleRecordsSupportNewTypesAndEscapedNamesWithoutGuessingTTL() async throws {
        let stub = recordsStub([
            .init(name: "\\052.example.test.", resourceRecords: [.init(value: "1 . alpn=\"h2\"")], type: .https),
            .init(name: "_service.example.test.", resourceRecords: [.init(value: "1 target.example.test.")], ttl: 60, type: .svcb)
        ])
        let records = try await service(stub).loadRecords(scope: scope(), zone: zone())
        XCTAssertEqual(records.map(\.type), ["HTTPS", "SVCB"])
        XCTAssertEqual(records[0].name, "\\052.example.test.")
        XCTAssertNil(records[0].ttl)
        XCTAssertEqual(records[0].routingPolicy, "Simple")
        XCTAssertTrue(records[0].routingFields.isEmpty)
    }

    func testRecordsRejectDuplicateIdentityInvalidNamesNegativeTTLAndMalformedAlias() async {
        let records: [[Route53.ResourceRecordSet]] = [
            [.init(name: "same.example.test.", type: .a), .init(name: "same.example.test.", type: .a)],
            [.init(name: "", type: .a)], [.init(name: "example.test.", setIdentifier: "", type: .a)],
            [.init(name: "example.test.", ttl: -1, type: .a)],
            [.init(aliasTarget: .init(dnsName: "target.test.", evaluateTargetHealth: true, hostedZoneId: "../bad"), name: "example.test.", type: .a)]
        ]
        for values in records {
            await assertError(Route53Error.invalidResponse) {
                _ = try await self.service(self.recordsStub(values)).loadRecords(scope: self.scope(), zone: self.zone())
            }
        }
    }

    func testRecordPaginationRejectsMissingNameTypeIdentifierAndRepeatingCompoundCursor() async {
        let cases: [[Route53.ListResourceRecordSetsResponse]] = [
            [.init(isTruncated: true, maxItems: 100, nextRecordType: .a, resourceRecordSets: [])],
            [.init(isTruncated: true, maxItems: 100, nextRecordName: "example.test.", resourceRecordSets: [])],
            [.init(isTruncated: true, maxItems: 100, nextRecordIdentifier: "", nextRecordName: "example.test.", nextRecordType: .a, resourceRecordSets: [])],
            [.init(isTruncated: true, maxItems: 100, nextRecordName: "example.test.", nextRecordType: .a,
                   resourceRecordSets: [.init(name: "example.test.", setIdentifier: "east", type: .a, weight: 1)])],
            [.init(isTruncated: true, maxItems: 100, nextRecordIdentifier: "east", nextRecordName: "example.test.", nextRecordType: .a, resourceRecordSets: []),
             .init(isTruncated: true, maxItems: 100, nextRecordIdentifier: "east", nextRecordName: "example.test.", nextRecordType: .a, resourceRecordSets: [])]
        ]
        for pages in cases {
            let stub = Route53Stub(recordPages: pages)
            await assertError(Route53Error.incompletePagination) {
                _ = try await self.service(stub).loadRecords(scope: self.scope(), zone: self.zone())
            }
            let requests = await stub.requests()
            XCTAssertEqual(requests.records.count, pages.count)
        }
    }

    func testRecordPageLimitRejectsIncompleteResults() async {
        let pages: [Route53.ListResourceRecordSetsResponse] = (0..<1_000).map {
            .init(isTruncated: true, maxItems: 100, nextRecordName: "record-\($0).example.test.", nextRecordType: .a, resourceRecordSets: [])
        }
        let stub = Route53Stub(recordPages: pages)
        await assertError(Route53Error.incompletePagination) {
            _ = try await self.service(stub).loadRecords(scope: self.scope(), zone: self.zone())
        }
        let requests = await stub.requests()
        XCTAssertEqual(requests.records.count, 1_000)
    }

    func testTagsRequestCanonicalZoneAndPreserveEmptyValues() async throws {
        let stub = Route53Stub(tagResponse: .init(resourceTagSet: .init(
            resourceId: "/hostedzone/ZEXAMPLE", resourceType: .hostedzone,
            tags: [.init(key: "Owner", value: "team"), .init(key: "Empty", value: "")]
        )))
        let tags = try await service(stub).loadTags(scope: scope(), zone: zone(id: "/hostedzone/ZEXAMPLE"))
        XCTAssertEqual(tags, ["Owner": "team", "Empty": ""])
        let requests = await stub.requests()
        XCTAssertEqual(requests.tags.map(\.resourceId), ["ZEXAMPLE"])
        XCTAssertEqual(requests.tags.map(\.resourceType), [.hostedzone])
    }

    func testTagsRejectWrongResourceMissingIdentityAndMalformedDuplicates() async {
        let sets: [Route53.ResourceTagSet] = [
            .init(resourceId: "ZOTHER", resourceType: .hostedzone), .init(resourceId: "ZEXAMPLE", resourceType: .healthcheck),
            .init(resourceType: .hostedzone), .init(resourceId: "ZEXAMPLE"),
            .init(resourceId: "ZEXAMPLE", resourceType: .hostedzone, tags: [.init(value: "value")]),
            .init(resourceId: "ZEXAMPLE", resourceType: .hostedzone, tags: [.init(key: "key")]),
            .init(resourceId: "ZEXAMPLE", resourceType: .hostedzone, tags: [.init(key: "key", value: "one"), .init(key: "key", value: "two")])
        ]
        for set in sets {
            await assertError(Route53Error.invalidResponse) {
                _ = try await self.service(Route53Stub(tagResponse: .init(resourceTagSet: set))).loadTags(scope: self.scope(), zone: self.zone())
            }
        }
    }

    func testInvalidScopeAndZoneIDMakeNoRequests() async {
        let stub = Route53Stub()
        let service = service(stub)
        for invalid in [scope(account: ""), scope(profile: " "), scope(principal: "arn:aws:sts::444455556666:assumed-role/Test/session")] {
            for operation in 0..<4 {
                await assertError(Route53Error.invalidScope) { try await self.perform(operation, service: service, scope: invalid, zone: self.zone()) }
            }
        }
        for operation in 1..<4 {
            await assertError(Route53Error.invalidResponse) { try await self.perform(operation, service: service, scope: self.scope(), zone: self.zone(id: "../bad")) }
        }
        await assertError(Route53Error.unsupportedPartition) { _ = try await service.loadZones(scope: self.scope(partition: "aws-iso")) }
        let requests = await stub.requests()
        XCTAssertTrue(requests.zones.isEmpty)
        XCTAssertTrue(requests.details.isEmpty)
        XCTAssertTrue(requests.records.isEmpty)
        XCTAssertTrue(requests.tags.isEmpty)
    }

    func testKnownPartitionsDoNotApplyResourceRegionToHostedZoneQuery() async throws {
        for partition in ["aws", "aws-cn", "aws-us-gov"] {
            let selected = scope(partition: partition)
            XCTAssertEqual(try selected.partition(), partition)
            let stub = Route53Stub(zonePages: [.init(hostedZones: [rawZone()], isTruncated: false, maxItems: 100)])
            let zones = try await service(stub).loadZones(scope: selected)
            XCTAssertEqual(zones.map(\.id), ["ZEXAMPLE"])
        }
    }

    func testErrorsAreOperationSpecificAndNeverExposeRawMessages() async {
        let denied = service(Route53Stub(failure: AWSResponseError(errorCode: "AccessDenied")))
        let permissions: [AWSRoute53Service.RequestError] = [.listPermission, .detailPermission, .recordsPermission, .tagsPermission]
        let actions = ["route53:ListHostedZones", "route53:GetHostedZone", "route53:ListResourceRecordSets", "route53:ListTagsForResource"]
        for operation in 0..<4 {
            await assertError(permissions[operation]) { try await self.perform(operation, service: denied, scope: self.scope(), zone: self.zone()) }
            XCTAssertTrue(permissions[operation].localizedDescription.contains(actions[operation]))
        }
        let failures: [(Error, AWSRoute53Service.RequestError)] = [
            (AWSResponseError(errorCode: "ExpiredToken"), .credentials), (AWSResponseError(errorCode: "Throttling"), .throttled),
            (AWSResponseError(errorCode: "PriorRequestNotComplete"), .throttled), (AWSResponseError(errorCode: "NoSuchHostedZone"), .notFound),
            (URLError(.notConnectedToInternet), .network),
            (NSError(domain: "private-route53-token", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-route53-token"]), .failed)
        ]
        for (failure, expected) in failures {
            let service = service(Route53Stub(failure: failure))
            for operation in 0..<4 {
                await assertError(expected) { try await self.perform(operation, service: service, scope: self.scope(), zone: self.zone()) }
            }
        }
    }

    func testCancellationBeforeRequestMakesNoCallsForAllOperations() async {
        for operation in 0..<4 {
            let gate = TestGate()
            let stub = Route53Stub()
            let service = service(stub)
            let selected = scope()
            let zone = zone()
            let task = Task {
                await gate.wait()
                switch operation {
                case 0: _ = try await service.loadZones(scope: selected)
                case 1: _ = try await service.loadDetails(scope: selected, zone: zone)
                case 2: _ = try await service.loadRecords(scope: selected, zone: zone)
                default: _ = try await service.loadTags(scope: selected, zone: zone)
                }
            }
            await gate.waitForEntry()
            task.cancel()
            await gate.open()
            do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
            let requests = await stub.requests()
            XCTAssertTrue(requests.zones.isEmpty)
            XCTAssertTrue(requests.details.isEmpty)
            XCTAssertTrue(requests.records.isEmpty)
            XCTAssertTrue(requests.tags.isEmpty)
        }
    }

    func testCancellationAfterResponsePreventsReturningDataForAllOperations() async {
        for operation in 0..<4 {
            let gate = TestGate()
            let raw = rawZone()
            let service = AWSRoute53Service(
                zoneLoader: { _ in await gate.wait(); return .init(hostedZones: [raw], isTruncated: false, maxItems: 100) },
                detailLoader: { _ in await gate.wait(); return .init(hostedZone: raw) },
                recordLoader: { _ in await gate.wait(); return .init(isTruncated: false, maxItems: 100, resourceRecordSets: []) },
                tagLoader: { _ in await gate.wait(); return .init(resourceTagSet: .init(resourceId: "ZEXAMPLE", resourceType: .hostedzone)) }
            )
            let selected = scope()
            let zone = zone()
            let task = Task {
                switch operation {
                case 0: _ = try await service.loadZones(scope: selected)
                case 1: _ = try await service.loadDetails(scope: selected, zone: zone)
                case 2: _ = try await service.loadRecords(scope: selected, zone: zone)
                default: _ = try await service.loadTags(scope: selected, zone: zone)
                }
            }
            await gate.waitForEntry()
            task.cancel()
            await gate.open()
            do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    private func rawZone(_ id: String = "ZEXAMPLE", name: String = "example.test.", privateZone: Bool = false, count: Int64 = 4) -> Route53.HostedZone {
        .init(callerReference: "reference", config: .init(comment: "Fixture zone", privateZone: privateZone),
              id: "/hostedzone/\(id)", name: name, resourceRecordSetCount: count)
    }

    private func zone(id: String = "ZEXAMPLE", privateZone: Bool = false) -> Route53HostedZone {
        .init(id: id, name: "example.test.", isPrivate: privateZone)
    }

    private func scope(account: String = "111122223333", principal: String? = nil, profile: String = "work", partition: String = "aws") -> Route53Scope {
        Route53Scope(
            profile: AWSProfile(name: profile, region: "ap-southeast-1", ssoStartURL: nil, ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil),
            identity: AWSIdentity(account: account, arn: principal ?? "arn:\(partition):sts::\(account):assumed-role/Test/session", userID: "example"),
            paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/example/config", "AWS_SHARED_CREDENTIALS_FILE": "/example/credentials"])
        )
    }

    private func fields(_ record: Route53Record) -> [String: String] {
        Dictionary(uniqueKeysWithValues: record.routingFields.map { ($0.name, $0.value) })
    }

    private func recordsStub(_ records: [Route53.ResourceRecordSet]) -> Route53Stub {
        Route53Stub(recordPages: [.init(isTruncated: false, maxItems: 100, resourceRecordSets: records)])
    }

    private func service(_ stub: Route53Stub) -> AWSRoute53Service {
        AWSRoute53Service(zoneLoader: { try await stub.zones($0) }, detailLoader: { try await stub.details($0) },
                          recordLoader: { try await stub.records($0) }, tagLoader: { try await stub.tags($0) })
    }

    private func perform(_ operation: Int, service: AWSRoute53Service, scope: Route53Scope, zone: Route53HostedZone) async throws {
        switch operation {
        case 0: _ = try await service.loadZones(scope: scope)
        case 1: _ = try await service.loadDetails(scope: scope, zone: zone)
        case 2: _ = try await service.loadRecords(scope: scope, zone: zone)
        default: _ = try await service.loadTags(scope: scope, zone: zone)
        }
    }

    private func assertError<E: Error & Equatable>(_ expected: E, file: StaticString = #filePath, line: UInt = #line,
                                                 operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected error", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? E, expected, file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains("private-route53-token"), file: file, line: line)
        }
    }
}

private actor Route53Stub {
    private var zonePages: [Route53.ListHostedZonesResponse]
    private let detailResponse: Route53.GetHostedZoneResponse?
    private var recordPages: [Route53.ListResourceRecordSetsResponse]
    private let tagResponse: Route53.ListTagsForResourceResponse?
    private let failure: Error?
    private var zoneRequests: [Route53.ListHostedZonesRequest] = []
    private var detailRequests: [Route53.GetHostedZoneRequest] = []
    private var recordRequests: [Route53.ListResourceRecordSetsRequest] = []
    private var tagRequests: [Route53.ListTagsForResourceRequest] = []

    init(zonePages: [Route53.ListHostedZonesResponse] = [], detailResponse: Route53.GetHostedZoneResponse? = nil,
         recordPages: [Route53.ListResourceRecordSetsResponse] = [], tagResponse: Route53.ListTagsForResourceResponse? = nil, failure: Error? = nil) {
        self.zonePages = zonePages
        self.detailResponse = detailResponse
        self.recordPages = recordPages
        self.tagResponse = tagResponse
        self.failure = failure
    }

    func zones(_ request: Route53.ListHostedZonesRequest) throws -> Route53.ListHostedZonesResponse {
        zoneRequests.append(request)
        if let failure { throw failure }
        guard !zonePages.isEmpty else { throw Route53Error.invalidResponse }
        return zonePages.removeFirst()
    }

    func details(_ request: Route53.GetHostedZoneRequest) throws -> Route53.GetHostedZoneResponse {
        detailRequests.append(request)
        if let failure { throw failure }
        guard let detailResponse else { throw Route53Error.invalidResponse }
        return detailResponse
    }

    func records(_ request: Route53.ListResourceRecordSetsRequest) throws -> Route53.ListResourceRecordSetsResponse {
        recordRequests.append(request)
        if let failure { throw failure }
        guard !recordPages.isEmpty else { throw Route53Error.invalidResponse }
        return recordPages.removeFirst()
    }

    func tags(_ request: Route53.ListTagsForResourceRequest) throws -> Route53.ListTagsForResourceResponse {
        tagRequests.append(request)
        if let failure { throw failure }
        guard let tagResponse else { throw Route53Error.invalidResponse }
        return tagResponse
    }

    func requests() -> (zones: [Route53.ListHostedZonesRequest], details: [Route53.GetHostedZoneRequest],
                       records: [Route53.ListResourceRecordSetsRequest], tags: [Route53.ListTagsForResourceRequest]) {
        (zoneRequests, detailRequests, recordRequests, tagRequests)
    }
}
