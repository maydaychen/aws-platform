import Foundation
import SotoCore
import SotoRDS
import XCTest
@testable import AWSPlatform

final class AWSRDSServiceTests: XCTestCase {
    func testInstancesFollowAllPagesIncludingEmptyMiddlePageAndSort() async throws {
        let fixture = RDSServiceFixture(instancePages: [
            .init(dbInstances: [rdsInstance("z-db")], marker: "empty"),
            .init(dbInstances: [], marker: "last"), .init(dbInstances: [rdsInstance("a-db")])
        ])
        let databases = try await fixture.service.loadInstances(scope: rdsServiceScope())
        XCTAssertEqual(databases.map(\.identifier), ["a-db", "z-db"])
        let requests = await fixture.requests()
        XCTAssertEqual(requests.instances.map(\.marker), [nil, "empty", "last"])
        XCTAssertTrue(requests.instances.allSatisfy { $0.maxRecords == 100 && $0.filters == nil && $0.dbInstanceIdentifier == nil })
        XCTAssertEqual(requests.total, 3)
    }

    func testClustersFollowAllPagesWithoutIncludingSharedClusters() async throws {
        let fixture = RDSServiceFixture(clusterPages: [
            .init(dbClusters: [rdsCluster("z-db")], marker: "empty"),
            .init(dbClusters: [], marker: "last"), .init(dbClusters: [rdsCluster("a-db")])
        ])
        let databases = try await fixture.service.loadClusters(scope: rdsServiceScope())
        XCTAssertEqual(databases.map(\.identifier), ["a-db", "z-db"])
        let requests = await fixture.requests()
        XCTAssertEqual(requests.clusters.map(\.marker), [nil, "empty", "last"])
        XCTAssertTrue(requests.clusters.allSatisfy {
            $0.maxRecords == 100 && $0.includeShared == false && $0.filters == nil && $0.dbClusterIdentifier == nil
        })
        XCTAssertEqual(requests.total, 3)
    }

    func testBothListsAcceptMissingCollectionsAndExplicitEmptyFinalMarkers() async throws {
        let fixture = RDSServiceFixture(instancePages: [.init(marker: "")], clusterPages: [.init(marker: "")])
        let instances = try await fixture.service.loadInstances(scope: rdsServiceScope())
        let clusters = try await fixture.service.loadClusters(scope: rdsServiceScope())
        XCTAssertTrue(instances.isEmpty)
        XCTAssertTrue(clusters.isEmpty)
        let requests = await fixture.requests()
        XCTAssertEqual(requests.total, 2)
    }

    func testBothListsRejectRepeatedWhitespaceAndCyclicMarkers() async {
        for markers in [["repeat", "repeat"], ["first", "second", "first"], [" \n"]] {
            let fixture = RDSServiceFixture(instancePages: markers.map { .init(marker: $0) },
                                            clusterPages: markers.map { .init(marker: $0) })
            await assertError(RDSError.incompletePagination) { _ = try await fixture.service.loadInstances(scope: rdsServiceScope()) }
            await assertError(RDSError.incompletePagination) { _ = try await fixture.service.loadClusters(scope: rdsServiceScope()) }
            let requests = await fixture.requests()
            XCTAssertEqual(requests.instances.count, markers.count)
            XCTAssertEqual(requests.clusters.count, markers.count)
        }
    }

    func testBothListsStopAtPageBudget() async {
        let fixture = RDSServiceFixture(instancePages: (0..<1_000).map { .init(marker: "page-\($0)") },
                                        clusterPages: (0..<1_000).map { .init(marker: "page-\($0)") })
        await assertError(RDSError.incompletePagination) { _ = try await fixture.service.loadInstances(scope: rdsServiceScope()) }
        await assertError(RDSError.incompletePagination) { _ = try await fixture.service.loadClusters(scope: rdsServiceScope()) }
        let requests = await fixture.requests()
        XCTAssertEqual(requests.instances.count, 1_000)
        XCTAssertEqual(requests.clusters.count, 1_000)
    }

    func testBothListsCanFinishOnLastAllowedPage() async throws {
        var instancePages: [RDS.DBInstanceMessage] = (0..<999).map { .init(marker: "page-\($0)") }
        var clusterPages: [RDS.DBClusterMessage] = (0..<999).map { .init(marker: "page-\($0)") }
        instancePages.append(.init(dbInstances: [rdsInstance()]))
        clusterPages.append(.init(dbClusters: [rdsCluster()]))
        let fixture = RDSServiceFixture(instancePages: instancePages, clusterPages: clusterPages)
        let instances = try await fixture.service.loadInstances(scope: rdsServiceScope())
        let clusters = try await fixture.service.loadClusters(scope: rdsServiceScope())
        XCTAssertEqual(instances.count, 1)
        XCTAssertEqual(clusters.count, 1)
        let requests = await fixture.requests()
        XCTAssertEqual(requests.total, 2_000)
    }

    func testBothListsFailRatherThanReturningPartialResultsWhenLaterPageFails() async {
        let instances = RDSServiceFixture(instancePages: [.init(dbInstances: [rdsInstance()], marker: "next")],
                                           failOperation: .instances, failAt: 1)
        await assertError(AWSRDSService.RequestError.instancesPermission) {
            _ = try await instances.service.loadInstances(scope: rdsServiceScope())
        }
        let clusters = RDSServiceFixture(clusterPages: [.init(dbClusters: [rdsCluster()], marker: "next")],
                                          failOperation: .clusters, failAt: 1)
        await assertError(AWSRDSService.RequestError.clustersPermission) {
            _ = try await clusters.service.loadClusters(scope: rdsServiceScope())
        }
    }

    func testDuplicateInstanceAndClusterIdentityAcrossPagesIsRejected() async {
        let fixture = RDSServiceFixture(instancePages: [
            .init(dbInstances: [rdsInstance()], marker: "next"), .init(dbInstances: [rdsInstance()])
        ], clusterPages: [
            .init(dbClusters: [rdsCluster()], marker: "next"), .init(dbClusters: [rdsCluster()])
        ])
        await assertError(RDSError.invalidResponse) { _ = try await fixture.service.loadInstances(scope: rdsServiceScope()) }
        await assertError(RDSError.invalidResponse) { _ = try await fixture.service.loadClusters(scope: rdsServiceScope()) }
    }

    func testSameIdentifierAcrossInstanceAndClusterKeepsDistinctARNs() async throws {
        let fixture = RDSServiceFixture(instancePages: [.init(dbInstances: [rdsInstance()])],
                                        clusterPages: [.init(dbClusters: [rdsCluster()])])
        let instances = try await fixture.service.loadInstances(scope: rdsServiceScope())
        let clusters = try await fixture.service.loadClusters(scope: rdsServiceScope())
        XCTAssertEqual(instances.first?.identifier, clusters.first?.identifier)
        XCTAssertNotEqual(instances.first?.id, clusters.first?.id)
        XCTAssertEqual(instances.first?.kind, .instance)
        XCTAssertEqual(clusters.first?.kind, .cluster)
    }

    func testBothListsRejectWrongAccountRegionPartitionTypeAndIdentifier() async {
        let prefixes = [
            "arn:aws:rds:eu-west-1:999988887777:", "arn:aws:rds:us-east-1:111122223333:",
            "arn:aws-cn:rds:eu-west-1:111122223333:", "arn:aws:ec2:eu-west-1:111122223333:"
        ]
        for prefix in prefixes {
            let fixture = RDSServiceFixture(instancePages: [.init(dbInstances: [rdsInstance(arn: prefix + "db:example")])],
                                            clusterPages: [.init(dbClusters: [rdsCluster(arn: prefix + "cluster:example")])])
            await assertError(RDSError.invalidResponse) { _ = try await fixture.service.loadInstances(scope: rdsServiceScope()) }
            await assertError(RDSError.invalidResponse) { _ = try await fixture.service.loadClusters(scope: rdsServiceScope()) }
        }
        for suffix in ["cluster:example", "db:other", "db:example:extra"] {
            let fixture = RDSServiceFixture(instancePages: [.init(dbInstances: [
                rdsInstance(arn: "arn:aws:rds:eu-west-1:111122223333:" + suffix)
            ])])
            await assertError(RDSError.invalidResponse) { _ = try await fixture.service.loadInstances(scope: rdsServiceScope()) }
        }
        for suffix in ["db:example", "cluster:other", "cluster:example:extra"] {
            let fixture = RDSServiceFixture(clusterPages: [.init(dbClusters: [
                rdsCluster(arn: "arn:aws:rds:eu-west-1:111122223333:" + suffix)
            ])])
            await assertError(RDSError.invalidResponse) { _ = try await fixture.service.loadClusters(scope: rdsServiceScope()) }
        }
    }

    func testBothListsRequireARNAndIdentifierRatherThanDroppingRows() async {
        let instances: [RDS.DBInstance] = [.init(dbInstanceIdentifier: "example"), .init(dbInstanceArn: "arn"), .init()]
        for instance in instances {
            let fixture = RDSServiceFixture(instancePages: [.init(dbInstances: [instance])])
            await assertError(RDSError.invalidResponse) { _ = try await fixture.service.loadInstances(scope: rdsServiceScope()) }
        }
        let clusters: [RDS.DBCluster] = [.init(dbClusterIdentifier: "example"), .init(dbClusterArn: "arn"), .init()]
        for cluster in clusters {
            let fixture = RDSServiceFixture(clusterPages: [.init(dbClusters: [cluster])])
            await assertError(RDSError.invalidResponse) { _ = try await fixture.service.loadClusters(scope: rdsServiceScope()) }
        }
    }

    func testChinaAndGovCloudPartitionMatchesCurrentScope() async throws {
        for (region, partition) in [("cn-north-1", "aws-cn"), ("us-gov-west-1", "aws-us-gov")] {
            let fixture = RDSServiceFixture(instancePages: [.init(dbInstances: [
                rdsInstance(arn: "arn:\(partition):rds:\(region):111122223333:db:example")
            ])], clusterPages: [.init(dbClusters: [
                rdsCluster(arn: "arn:\(partition):rds:\(region):111122223333:cluster:example")
            ])])
            let scope = rdsServiceScope(region: region, partition: partition)
            let instances = try await fixture.service.loadInstances(scope: scope)
            let clusters = try await fixture.service.loadClusters(scope: scope)
            XCTAssertEqual(instances.count, 1)
            XCTAssertEqual(clusters.count, 1)
        }
    }

    func testNeptuneAndDocumentDBAreExcludedBeforeIdentityValidationButFutureEnginesRemain() async throws {
        let fixture = RDSServiceFixture(instancePages: [.init(dbInstances: [
            .init(engine: "neptune"), .init(engine: "docdb"), rdsInstance("future", engine: "future-engine"), rdsInstance("unknown", engine: nil)
        ])], clusterPages: [.init(dbClusters: [
            .init(engine: "neptune"), .init(engine: "docdb"), rdsCluster("future", engine: "future-engine"), rdsCluster("unknown", engine: nil)
        ])])
        let instances = try await fixture.service.loadInstances(scope: rdsServiceScope())
        let clusters = try await fixture.service.loadClusters(scope: rdsServiceScope())
        XCTAssertEqual(instances.map(\.identifier), ["future", "unknown"])
        XCTAssertEqual(clusters.map(\.identifier), ["future", "unknown"])
        XCTAssertEqual(instances.first?.engine, "future-engine")
    }

    func testCreatingResourcesKeepMissingEndpointsAndOptionalBooleansUnknown() async throws {
        let fixture = RDSServiceFixture(instancePages: [.init(dbInstances: [
            .init(dbInstanceArn: rdsInstance().dbInstanceArn, dbInstanceIdentifier: "example", dbInstanceStatus: "creating")
        ])], clusterPages: [.init(dbClusters: [
            .init(dbClusterArn: rdsCluster().dbClusterArn, dbClusterIdentifier: "example", status: "creating")
        ])])
        let instances = try await fixture.service.loadInstances(scope: rdsServiceScope())
        let clusters = try await fixture.service.loadClusters(scope: rdsServiceScope())
        for resource in instances + clusters {
            XCTAssertEqual(resource.status, "creating")
            XCTAssertNil(resource.endpoint)
            XCTAssertNil(resource.port)
            XCTAssertNil(resource.multiAZ)
            XCTAssertNil(resource.publiclyAccessible)
            XCTAssertNil(resource.encrypted)
            XCTAssertNil(resource.deletionProtection)
        }
    }

    func testInstanceMapsReturnedNetworkStorageProtectionAndTags() async throws {
        let raw = RDS.DBInstance(
            allocatedStorage: 128, availabilityZone: "eu-west-1a", backupRetentionPeriod: 7,
            dbClusterIdentifier: "parent", dbInstanceArn: rdsInstance().dbInstanceArn, dbInstanceClass: "db.t4g.medium",
            dbInstanceIdentifier: "example", dbInstanceStatus: "available",
            dbSubnetGroup: .init(dbSubnetGroupName: "private-db", subnets: [.init(subnetIdentifier: "subnet-a")], vpcId: "vpc-a"),
            deletionProtection: true, endpoint: .init(address: "example.test", port: 5432), engine: "postgres", engineVersion: "16",
            instanceCreateTime: Date(timeIntervalSince1970: 1_000), kmsKeyId: "key-a", multiAZ: false,
            publiclyAccessible: false, secondaryAvailabilityZone: "eu-west-1b", storageEncrypted: true,
            storageType: "gp3", tagList: [.init(key: "Environment", value: "dev")],
            vpcSecurityGroups: [.init(vpcSecurityGroupId: "sg-a")]
        )
        let fixture = RDSServiceFixture(instancePages: [.init(dbInstances: [raw])])
        let resources = try await fixture.service.loadInstances(scope: rdsServiceScope())
        let resource = try XCTUnwrap(resources.first)
        XCTAssertEqual(resource.engine, "postgres")
        XCTAssertEqual(resource.engineVersion, "16")
        XCTAssertEqual(resource.instanceClass, "db.t4g.medium")
        XCTAssertEqual(resource.clusterIdentifier, "parent")
        XCTAssertEqual(resource.endpoint, "example.test")
        XCTAssertEqual(resource.port, 5432)
        XCTAssertEqual(resource.availabilityZone, "eu-west-1a")
        XCTAssertEqual(resource.secondaryAvailabilityZone, "eu-west-1b")
        XCTAssertEqual(resource.vpcID, "vpc-a")
        XCTAssertEqual(resource.subnetGroup, "private-db")
        XCTAssertEqual(resource.subnetIDs, ["subnet-a"])
        XCTAssertEqual(resource.securityGroupIDs, ["sg-a"])
        XCTAssertEqual(resource.allocatedStorageGB, 128)
        XCTAssertEqual(resource.backupRetentionDays, 7)
        XCTAssertEqual(resource.storageType, "gp3")
        XCTAssertEqual(resource.kmsKeyID, "key-a")
        XCTAssertEqual(resource.multiAZ, false)
        XCTAssertEqual(resource.publiclyAccessible, false)
        XCTAssertEqual(resource.encrypted, true)
        XCTAssertEqual(resource.deletionProtection, true)
        XCTAssertEqual(resource.tags, ["Environment": "dev"])
        XCTAssertEqual(resource.createdAt, Date(timeIntervalSince1970: 1_000))
    }

    func testClusterMapsMembersAndServerlessV2WithoutInferringVpcOrEngineMode() async throws {
        let raw = RDS.DBCluster(
            allocatedStorage: 1, availabilityZones: ["eu-west-1a", "eu-west-1b"], backupRetentionPeriod: 14,
            clusterCreateTime: Date(timeIntervalSince1970: 2_000), dbClusterArn: rdsCluster().dbClusterArn,
            dbClusterIdentifier: "example", dbClusterInstanceClass: "db.r6g.large",
            dbClusterMembers: [.init(dbInstanceIdentifier: "writer", isClusterWriter: true, promotionTier: 0),
                               .init(dbInstanceIdentifier: "reader", isClusterWriter: false, promotionTier: 2)],
            dbSubnetGroup: "private-db", deletionProtection: false, endpoint: "writer.test", engine: "aurora-postgresql",
            engineMode: "provisioned", engineVersion: "16", kmsKeyId: "key-b", multiAZ: true, port: 5432,
            publiclyAccessible: false, readerEndpoint: "reader.test",
            serverlessV2ScalingConfiguration: .init(maxCapacity: 16, minCapacity: 0), status: "available",
            storageEncrypted: true, storageType: "aurora-iopt1", tagList: [], vpcSecurityGroups: [.init(vpcSecurityGroupId: "sg-b")]
        )
        let fixture = RDSServiceFixture(clusterPages: [.init(dbClusters: [raw])])
        let resources = try await fixture.service.loadClusters(scope: rdsServiceScope())
        let resource = try XCTUnwrap(resources.first)
        XCTAssertEqual(resource.engineMode, "provisioned")
        XCTAssertEqual(resource.serverlessV2MinACU, 0)
        XCTAssertEqual(resource.serverlessV2MaxACU, 16)
        XCTAssertEqual(resource.members, [.init(identifier: "writer", isWriter: true, promotionTier: 0),
                                          .init(identifier: "reader", isWriter: false, promotionTier: 2)])
        XCTAssertEqual(resource.subnetGroup, "private-db")
        XCTAssertNil(resource.vpcID)
        XCTAssertTrue(resource.subnetIDs.isEmpty)
        XCTAssertEqual(resource.availabilityZones, ["eu-west-1a", "eu-west-1b"])
        XCTAssertEqual(resource.endpoint, "writer.test")
        XCTAssertEqual(resource.readerEndpoint, "reader.test")
        XCTAssertEqual(resource.instanceClass, "db.r6g.large")
        XCTAssertEqual(resource.tags, [:])
        XCTAssertEqual(resource.createdAt, Date(timeIntervalSince1970: 2_000))
    }

    func testTagListDistinguishesUnavailableEmptyAndEmptyValues() async throws {
        let fixture = RDSServiceFixture(instancePages: [.init(dbInstances: [
            rdsInstance("absent"), rdsInstance("empty", tags: []), rdsInstance("value", tags: [.init(key: "Flag")])
        ])])
        let resources = try await fixture.service.loadInstances(scope: rdsServiceScope())
        XCTAssertNil(resources[0].tags)
        XCTAssertEqual(resources[1].tags, [:])
        XCTAssertEqual(resources[2].tags, ["Flag": ""])
    }

    func testDuplicateAndMissingTagKeysAreRejectedForBothKinds() async {
        for tags: [RDS.Tag] in [[.init(key: "Env", value: "a"), .init(key: "Env", value: "b")], [.init(value: "missing-key")]] {
            let fixture = RDSServiceFixture(instancePages: [.init(dbInstances: [rdsInstance(tags: tags)])],
                                            clusterPages: [.init(dbClusters: [rdsCluster(tags: tags)])])
            await assertError(RDSError.invalidResponse) { _ = try await fixture.service.loadInstances(scope: rdsServiceScope()) }
            await assertError(RDSError.invalidResponse) { _ = try await fixture.service.loadClusters(scope: rdsServiceScope()) }
        }
    }

    func testMalformedAndDuplicateClusterMembersAreRejected() async {
        for members: [RDS.DBClusterMember] in [[.init()], [.init(dbInstanceIdentifier: "same"), .init(dbInstanceIdentifier: "same")]] {
            let raw = RDS.DBCluster(dbClusterArn: rdsCluster().dbClusterArn, dbClusterIdentifier: "example", dbClusterMembers: members)
            let fixture = RDSServiceFixture(clusterPages: [.init(dbClusters: [raw])])
            await assertError(RDSError.invalidResponse) { _ = try await fixture.service.loadClusters(scope: rdsServiceScope()) }
        }
    }

    func testInvalidScopeMakesNoRequests() async {
        for scope in [rdsServiceScope(profile: ""), rdsServiceScope(account: "bad"),
                      rdsServiceScope(region: "bad"), rdsServiceScope(region: "cn-north-1")] {
            let fixture = RDSServiceFixture()
            await assertError(RDSError.invalidScope) { _ = try await fixture.service.loadInstances(scope: scope) }
            await assertError(RDSError.invalidScope) { _ = try await fixture.service.loadClusters(scope: scope) }
            let requests = await fixture.requests()
            XCTAssertEqual(requests.total, 0)
        }
    }

    func testSafeErrorsClassifyCredentialsNetworkThrottleEncryptionAndUnknownWithoutLeakingText() async {
        let errors: [(Error, AWSRDSService.RequestError)] = [
            (RDSFixtureError("ExpiredTokenException"), .credentials), (URLError(.notConnectedToInternet), .network),
            (RDSFixtureError("ThrottlingException"), .throttled), (RDSFixtureError("KMSKeyNotAccessibleFault"), .encryption),
            (RDSFixtureError("UnrecognizedFailure"), .failed)
        ]
        for (error, expected) in errors {
            let fixture = RDSServiceFixture(failOperation: .instances, failure: error)
            await assertError(expected) { _ = try await fixture.service.loadInstances(scope: rdsServiceScope()) }
            XCTAssertFalse(expected.localizedDescription.contains("private-rds-token"))
        }
    }

    func testLocalPermissionFailureDoesNotAffectOtherResourceKind() async throws {
        let fixture = RDSServiceFixture(clusterPages: [.init(dbClusters: [rdsCluster()])], failOperation: .instances)
        await assertError(AWSRDSService.RequestError.instancesPermission) {
            _ = try await fixture.service.loadInstances(scope: rdsServiceScope())
        }
        let clusters = try await fixture.service.loadClusters(scope: rdsServiceScope())
        XCTAssertEqual(clusters.count, 1)
    }

    func testCancellationDuringRequestRejectsLateSuccessForBothKinds() async {
        for kind in RDSResourceKind.allCases {
            let gate = RDSServiceRequestGate()
            let fixture = RDSServiceFixture(instancePages: [.init(dbInstances: [rdsInstance()])],
                                            clusterPages: [.init(dbClusters: [rdsCluster()])], gate: gate)
            let task = Task {
                if kind == .instance { return try await fixture.service.loadInstances(scope: rdsServiceScope()) }
                return try await fixture.service.loadClusters(scope: rdsServiceScope())
            }
            await gate.waitForEntry()
            task.cancel()
            await gate.open()
            do {
                _ = try await task.value
                XCTFail("A cancelled request must not publish a late response")
            } catch { XCTAssertTrue(error is CancellationError) }
            let requests = await fixture.requests()
            XCTAssertEqual(requests.total, 1)
        }
    }

    func testCancelledTaskMakesNoRequests() async {
        for kind in RDSResourceKind.allCases {
            let fixture = RDSServiceFixture()
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                if kind == .instance { return try await fixture.service.loadInstances(scope: rdsServiceScope()) }
                return try await fixture.service.loadClusters(scope: rdsServiceScope())
            }
            do {
                _ = try await task.value
                XCTFail("A pre-cancelled task must not query RDS")
            } catch { XCTAssertTrue(error is CancellationError) }
            let requests = await fixture.requests()
            XCTAssertEqual(requests.total, 0)
        }
    }

    private func assertError<E: Error & Equatable>(_ expected: E, operation: () async throws -> Void,
                                                  file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("Expected a safe error", file: file, line: line)
        } catch { XCTAssertEqual(error as? E, expected, file: file, line: line) }
    }
}
