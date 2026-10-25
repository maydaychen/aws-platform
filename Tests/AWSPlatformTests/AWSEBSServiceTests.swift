import Foundation
import SotoCore
import SotoEC2
import XCTest
@testable import AWSPlatform

final class AWSEBSServiceTests: XCTestCase {
    func testVolumesPaginateAndMapAttachedAndUnattachedVolumes() async throws {
        let probe = EBSRequestProbe()
        let rows = try await probe.service.load(kind: .volume, scope: ebsScope())
        XCTAssertEqual(rows.map(\.id), ["vol-12345678", "vol-87654321"])
        XCTAssertEqual(rows[0].name, "data")
        XCTAssertEqual(rows[0].volumeType, "gp3")
        XCTAssertEqual(rows[0].iops, 3000)
        XCTAssertEqual(rows[0].throughput, 125)
        XCTAssertEqual(rows[0].attachments.first?.instanceID, "i-12345678")
        XCTAssertEqual(rows[0].attachments.first?.deleteOnTermination, false)
        XCTAssertEqual(rows[0].ownerID, ebsScope().accountID)
        XCTAssertTrue(rows[1].attachments.isEmpty)
        XCTAssertNil(rows[1].encrypted, "Missing encryption must remain unknown")
        let requests = await probe.volumeRequests
        XCTAssertEqual(requests.map(\.nextToken), [nil, "next"])
        XCTAssertTrue(requests.allSatisfy { $0.maxResults == 200 && $0.volumeIds == nil && $0.dryRun == nil })
        let snapshotRequests = await probe.snapshotRequests
        XCTAssertTrue(snapshotRequests.isEmpty)
    }

    func testSnapshotsAlwaysConstrainOwnerAndPaginate() async throws {
        let probe = EBSRequestProbe()
        let rows = try await probe.service.load(kind: .snapshot, scope: ebsScope())
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].volumeID, "vol-12345678")
        XCTAssertEqual(rows[0].storageTier, "archive")
        XCTAssertEqual(rows[0].progress, "100%")
        let requests = await probe.snapshotRequests
        XCTAssertEqual(requests.map(\.nextToken), [nil, "next"])
        XCTAssertTrue(requests.allSatisfy { $0.ownerIds == ["self"] && $0.maxResults == 200 && $0.snapshotIds == nil && $0.restorableByUserIds == nil })
    }

    func testEmptyPageWithContinuationIsNotMistakenForEmptyList() async throws {
        let service = AWSEBSService(volumes: { request in
            request.nextToken == nil ? .init(nextToken: "next", volumes: []) : .init(volumes: [.init(volumeId: "vol-12345678")])
        }, snapshots: { _ in XCTFail("Unexpected snapshot call"); return .init() })
        let rows = try await service.load(kind: .volume, scope: ebsScope())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].state, "Unknown")
    }

    func testContinuationFailureNeverReturnsPartialList() async {
        let service = AWSEBSService(volumes: { request in
            if request.nextToken != nil { throw AWSResponseError(errorCode: "UnauthorizedOperation") }
            return .init(nextToken: "next", volumes: [.init(volumeId: "vol-12345678")])
        }, snapshots: { _ in .init() })
        await expect(.volumesPermission, service: service)
    }

    func testLoopAndWhitespaceTokensAreRejected() async {
        for token in ["loop", " "] {
            let service = AWSEBSService(volumes: { _ in .init(nextToken: token, volumes: []) }, snapshots: { _ in .init() })
            await expect(.pagination, service: service)
        }
    }

    func testDuplicateAndMalformedResourceResponsesAreRejected() async {
        let responses: [[EC2.Volume]] = [
            [.init(volumeId: "vol-12345678"), .init(volumeId: "vol-12345678")],
            [.init(volumeId: "invalid")], [.init(size: -1, volumeId: "vol-12345678")],
            [.init(availabilityZone: "eu-west-1a", volumeId: "vol-12345678")],
            [.init(tags: [.init(key: "Name", value: "a"), .init(key: "Name", value: "b")], volumeId: "vol-12345678")],
            [.init(attachments: [.init(volumeId: "vol-87654321")], volumeId: "vol-12345678")]
        ]
        for response in responses {
            await expect(.invalidResponse, service: AWSEBSService(volumes: { _ in .init(volumes: response) }, snapshots: { _ in .init() }))
        }
    }

    func testForeignOrMissingSnapshotOwnerIsRejected() async {
        for owner in [nil, "444455556666"] {
            let service = AWSEBSService(volumes: { _ in .init() }, snapshots: { _ in
                .init(snapshots: [.init(ownerId: owner, snapshotId: "snap-12345678")])
            })
            await expect(.invalidResponse, service: service, kind: .snapshot)
        }
    }

    func testInvalidScopeNeverCallsEitherOperation() async {
        let service = AWSEBSService(volumes: { _ in XCTFail("Invalid scope queried"); return .init() },
                                    snapshots: { _ in XCTFail("Invalid scope queried"); return .init() })
        for scope in [ebsScope(account: "bad"), ebsScope(profile: ""), ebsScope(region: "global")] {
            do { _ = try await service.load(kind: .volume, scope: scope); XCTFail("Invalid scope accepted") }
            catch { XCTAssertEqual(error as? EBSError, .invalidScope) }
        }
    }

    func testErrorCategoriesAreSanitizedAndKindSpecific() async {
        let cases: [(Error, EBSError)] = [
            (AWSResponseError(errorCode: "AccessDenied"), .snapshotsPermission),
            (AWSResponseError(errorCode: "ExpiredToken"), .credentials),
            (AWSResponseError(errorCode: "RequestLimitExceeded"), .throttled),
            (URLError(.notConnectedToInternet), .network),
            (AWSResponseError(errorCode: "InvalidNextToken"), .pagination),
            (NSError(domain: "SENSITIVE_DIAGNOSTIC", code: 1), .failed)
        ]
        for (error, expected) in cases {
            let service = AWSEBSService(volumes: { _ in .init() }, snapshots: { _ in throw error })
            await expect(expected, service: service, kind: .snapshot)
        }
    }

    func testCancellationAfterLateResponseDoesNotReturnResources() async {
        let gate = TestGate()
        let service = AWSEBSService(volumes: { _ in
            await gate.wait()
            return .init(volumes: [.init(volumeId: "vol-12345678")])
        }, snapshots: { _ in .init() })
        let task = Task { try await service.load(kind: .volume, scope: ebsScope()) }
        await gate.waitForEntry(); task.cancel(); await gate.open()
        do { _ = try await task.value; XCTFail("Late cancelled response accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    private func expect(_ expected: EBSError, service: AWSEBSService, kind: EBSResource.Kind = .volume) async {
        do { _ = try await service.load(kind: kind, scope: ebsScope()); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? EBSError, expected) }
    }
}

private actor EBSRequestProbe {
    var volumeRequests: [EC2.DescribeVolumesRequest] = []
    var snapshotRequests: [EC2.DescribeSnapshotsRequest] = []
    nonisolated var service: AWSEBSService { AWSEBSService(volumes: { await self.volume($0) }, snapshots: { await self.snapshot($0) }) }
    private func volume(_ request: EC2.DescribeVolumesRequest) -> EC2.DescribeVolumesResult {
        volumeRequests.append(request)
        if request.nextToken != nil { return .init(volumes: [.init(volumeId: "vol-87654321")]) }
        return .init(nextToken: "next", volumes: [.init(attachments: [.init(deleteOnTermination: false, device: "/dev/sdf", instanceId: "i-12345678", state: .attached)],
            availabilityZone: "us-east-1a", encrypted: true, iops: 3000, size: 20, state: .inUse,
            tags: [.init(key: "Name", value: "data")], throughput: 125, volumeId: "vol-12345678", volumeType: .gp3)])
    }
    private func snapshot(_ request: EC2.DescribeSnapshotsRequest) -> EC2.DescribeSnapshotsResult {
        snapshotRequests.append(request)
        return .init(nextToken: request.nextToken == nil ? "next" : nil, snapshots: [.init(ownerId: "111122223333", progress: "100%",
            snapshotId: request.nextToken == nil ? "snap-12345678" : "snap-87654321", state: .completed, storageTier: .archive,
            volumeId: "vol-12345678", volumeSize: 20)])
    }
}
