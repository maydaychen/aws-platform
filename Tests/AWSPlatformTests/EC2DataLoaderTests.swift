import Foundation
import SotoCore
import SotoEC2
import XCTest
@testable import AWSPlatform

final class EC2DataLoaderTests: XCTestCase {
    func testInstanceSDKPagesMapFieldsAndEmptyReservations() async throws {
        let launched = Date(timeIntervalSince1970: 1_700_000_000)
        let instance = EC2.Instance(
            architecture: .arm64, imageId: "ami-first", instanceId: "i-first", instanceType: .t4gMicro,
            keyName: "key", launchTime: launched, placement: .init(availabilityZone: "eu-west-1a"),
            platformDetails: "Linux/UNIX", privateIpAddress: "10.0.0.1", publicIpAddress: "192.0.2.1",
            securityGroups: [.init(groupId: "sg-first", groupName: "ignored"), .init(groupName: "legacy"), .init()],
            state: .init(name: .running), subnetId: "subnet-first",
            tags: [.init(key: "Name", value: "Example"), .init(key: "Team", value: "Ops"),
                   .init(key: "Team", value: "duplicate")], vpcId: "vpc-first"
        )
        let stub = InstancePageStub([
            .init(nextToken: "second", reservations: [.init(), .init(instances: [instance])]),
            .init(reservations: [.init(instances: [.init(instanceId: "i-second")])])
        ])
        let rows = try await EC2DataLoader.fetchInstances { try await stub.load($0) }
        XCTAssertEqual(rows.map(\.instanceId), ["i-first", "i-second"])
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.name, "Example")
        XCTAssertEqual(row.instanceType, "t4g.micro")
        XCTAssertEqual(row.state, "running")
        XCTAssertEqual(row.privateIP, "10.0.0.1")
        XCTAssertEqual(row.publicIP, "192.0.2.1")
        XCTAssertEqual(row.architecture, "arm64")
        XCTAssertEqual(row.platformDetails, "Linux/UNIX")
        XCTAssertEqual(row.availabilityZone, "eu-west-1a")
        XCTAssertEqual(row.vpcId, "vpc-first")
        XCTAssertEqual(row.subnetId, "subnet-first")
        XCTAssertEqual(row.securityGroups, ["sg-first", "legacy"])
        XCTAssertEqual(row.imageId, "ami-first")
        XCTAssertNil(row.imageName)
        XCTAssertEqual(row.keyName, "key")
        XCTAssertEqual(row.launchTime, launched)
        XCTAssertEqual(row.tags, ["Name": "Example", "Team": "Ops"])
        XCTAssertEqual(rows[1].name, "i-second")
        XCTAssertEqual(rows[1].state, "-")
        XCTAssertEqual(rows[1].instanceType, "-")
        let requests = await stub.requests
        XCTAssertEqual(requests.map(\.nextToken), [nil, "second"])
        XCTAssertEqual(requests.map(\.maxResults), [1_000, 1_000])
    }

    func testNilAndEmptyTokensFinishWithoutAnotherRequest() async throws {
        for token in [nil, ""] as [String?] {
            let stub = InstancePageStub([.init(nextToken: token)])
            let rows = try await EC2DataLoader.fetchInstances { try await stub.load($0) }
            XCTAssertTrue(rows.isEmpty)
            let requests = await stub.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testRepeatedCyclicAndWhitespaceTokensRejectIncompleteLists() async {
        for tokens in [["same", "same"], ["first", "second", "first"], [" \n"]] {
            let stub = InstancePageStub(tokens.map {
                .init(nextToken: $0, reservations: [.init(instances: [.init(instanceId: "i-partial")])])
            })
            do {
                _ = try await EC2DataLoader.fetchInstances { try await stub.load($0) }
                XCTFail("An incomplete list must not return partial success")
            } catch { XCTAssertEqual(error as? EC2DataLoadError, .incompletePagination) }
            let requests = await stub.requests
            XCTAssertEqual(requests.count, tokens.count)
        }
    }

    func testPageLimitStopsUniqueTokensWithoutReturningPartialRows() async {
        let stub = InstancePageStub([.init(nextToken: "one"), .init(nextToken: "two")])
        do {
            _ = try await EC2DataLoader.fetchInstances(maximumPages: 2) { try await stub.load($0) }
            XCTFail("An unfinished list must fail at the page limit")
        } catch { XCTAssertEqual(error as? EC2DataLoadError, .incompletePagination) }
        let requests = await stub.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testNonPositivePageLimitMakesNoRequest() async {
        for limit in [0, -1] {
            let stub = InstancePageStub([])
            do {
                _ = try await EC2DataLoader.fetchInstances(maximumPages: limit) { try await stub.load($0) }
                XCTFail("Invalid limits must fail")
            } catch { XCTAssertEqual(error as? EC2DataLoadError, .incompletePagination) }
            let requests = await stub.requests
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func testCancellationAfterInstanceResponseStopsBeforeAnotherPage() async {
        let gate = TestGate()
        let task = Task {
            try await EC2DataLoader.fetchInstances { _ in
                await gate.wait()
                return .init(nextToken: "must-not-follow", reservations: [.init(instances: [.init(instanceId: "i-late")])])
            }
        }
        await gate.waitForEntry()
        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("A cancelled response must not be returned or paginated")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testImageRequestsAreBoundedBatchesAndDeduplicateInputIDs() async throws {
        let stub = ImageStub()
        let names = try await EC2DataLoader.fetchImageNames(ids: ["ami-c", "ami-a", "ami-b", "ami-a"], batchSize: 2) {
            try await stub.load($0)
        }
        XCTAssertEqual(names, ["ami-a": "name-ami-a", "ami-b": "name-ami-b", "ami-c": "name-ami-c"])
        let requests = await stub.requests
        XCTAssertEqual(requests.map(\.imageIds), [["ami-a", "ami-b"], ["ami-c"]])
    }

    func testMissingImageIsIsolatedAndOtherNamesSurvive() async throws {
        let stub = ImageStub(missing: ["ami-c"])
        let names = try await EC2DataLoader.fetchImageNames(ids: ["ami-a", "ami-b", "ami-c", "ami-d"]) {
            try await stub.load($0)
        }
        XCTAssertEqual(names, ["ami-a": "name-ami-a", "ami-b": "name-ami-b", "ami-d": "name-ami-d"])
        let requests = await stub.requests
        XCTAssertEqual(requests.map(\.imageIds), [
            ["ami-a", "ami-b", "ami-c", "ami-d"], ["ami-a", "ami-b"], ["ami-c", "ami-d"], ["ami-c"], ["ami-d"]
        ])
    }

    func testAllMissingImagesTerminateAtSingletons() async throws {
        let ids = ["ami-a", "ami-b", "ami-c", "ami-d"]
        let stub = ImageStub(missing: Set(ids))
        let names = try await EC2DataLoader.fetchImageNames(ids: ids) { try await stub.load($0) }
        XCTAssertTrue(names.isEmpty)
        let requests = await stub.requests
        XCTAssertEqual(requests.count, 2 * ids.count - 1, "Each failed batch splits into strictly smaller batches")
    }

    func testDuplicateSDKImageIDsMergeWithoutTrappingAndMissingIDsAreIgnored() async throws {
        let names = try await EC2DataLoader.fetchImageNames(ids: ["ami-a", "ami-b", "ami-c"]) { _ in
            .init(images: [
                .init(imageId: "ami-a", name: "first"), .init(imageId: "ami-a", name: "duplicate"),
                .init(description: "fallback", imageId: "ami-b"), .init(imageId: "ami-c"), .init(name: "no ID")
            ])
        }
        XCTAssertEqual(names, ["ami-a": "first", "ami-b": "fallback", "ami-c": "Unknown"])
    }

    func testOtherImageErrorsAreNotSplitOrRetried() async {
        for code in ["UnauthorizedOperation", "RequestLimitExceeded", "InternalError"] {
            let stub = ImageStub(errorCode: code)
            do {
                _ = try await EC2DataLoader.fetchImageNames(ids: ["ami-a", "ami-b"]) { try await stub.load($0) }
                XCTFail("Other errors must propagate")
            } catch { XCTAssertEqual((error as? AWSErrorType)?.errorCode, code) }
            let requests = await stub.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testEmptyImageIDsMakeNoRequest() async throws {
        let stub = ImageStub()
        let names = try await EC2DataLoader.fetchImageNames(ids: []) { try await stub.load($0) }
        XCTAssertTrue(names.isEmpty)
        let requests = await stub.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCancellationAfterImageResponseStopsBeforeAnotherBatch() async {
        let gate = TestGate()
        let task = Task {
            try await EC2DataLoader.fetchImageNames(ids: ["ami-a", "ami-b"], batchSize: 1) { _ in
                await gate.wait()
                return .init(images: [.init(imageId: "ami-a", name: "late")])
            }
        }
        await gate.waitForEntry()
        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("A cancelled response must not advance to another batch")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}

private actor InstancePageStub {
    private let pages: [EC2.DescribeInstancesResult]
    private(set) var requests: [EC2.DescribeInstancesRequest] = []

    init(_ pages: [EC2.DescribeInstancesResult]) { self.pages = pages }

    func load(_ request: EC2.DescribeInstancesRequest) throws -> EC2.DescribeInstancesResult {
        requests.append(request)
        guard requests.count <= pages.count else { throw FixtureError.unexpectedRequest }
        return pages[requests.count - 1]
    }
}

private actor ImageStub {
    let missing: Set<String>
    let errorCode: String?
    private(set) var requests: [EC2.DescribeImagesRequest] = []

    init(missing: Set<String> = [], errorCode: String? = nil) {
        self.missing = missing
        self.errorCode = errorCode
    }

    func load(_ request: EC2.DescribeImagesRequest) throws -> EC2.DescribeImagesResult {
        requests.append(request)
        if let errorCode { throw AWSResponseError(errorCode: errorCode) }
        if (request.imageIds ?? []).contains(where: missing.contains) {
            throw AWSResponseError(errorCode: "InvalidAMIID.NotFound")
        }
        return .init(images: (request.imageIds ?? []).map { .init(imageId: $0, name: "name-\($0)") })
    }
}

private enum FixtureError: Error { case unexpectedRequest }
