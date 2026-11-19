import Foundation
import SotoCore
import XCTest
@testable import AWSPlatform

@MainActor
final class S3BucketDetailsLoaderTests: XCTestCase {
    func testListedRegionSupportsParallelDetailsRetryListingAndDownloadWithoutLocationPermission() async throws {
        let entered = expectation(description: "all four details start before any response")
        entered.expectedFulfillmentCount = 4
        let release = S3DetailBarrier()
        let probe = S3DetailsHTTPProbe(hint: "EU", denyLocation: true, firstDetails: entered, release: release)
        let (vm, provider, scope) = try await makeWorkspace(probe)
        vm.refresh()
        await vm.waitForCurrentLoad()
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(vm.isBucketDetailsLoading)
        XCTAssertFalse(vm.isLoading)
        XCTAssertEqual(vm.selectedBucket?.region, "eu-west-1")
        await release.open()
        await vm.waitForDetails()

        XCTAssertFalse(vm.isBucketDetailsLoading)
        XCTAssertEqual(vm.selectedBucket?.versioningEnabled, true)
        XCTAssertEqual(vm.selectedBucket?.tags, ["Team": "first"])
        XCTAssertNil(vm.selectedBucket?.encryptionEnabled)
        XCTAssertNil(vm.selectedBucket?.publicAccessBlock)
        let errors = vm.selectedBucket?.detailError?.split(separator: "\n").map(String.init) ?? []
        XCTAssertEqual(errors.count, 2)
        XCTAssertTrue(errors.first?.hasPrefix("Encryption: ") == true)
        XCTAssertTrue(errors.last?.hasPrefix("Public Access Block: ") == true)

        await vm.loadObjects(bucket: "fixture-bucket")
        XCTAssertEqual(vm.objects.map(\.key), ["file"])
        vm.retrySelectedBucketDetails()
        XCTAssertTrue(vm.isBucketDetailsLoading)
        await vm.waitForDetails()
        XCTAssertNil(vm.selectedBucket?.detailError)
        XCTAssertEqual(vm.selectedBucket?.encryptionEnabled, true)
        XCTAssertEqual(vm.selectedBucket?.publicAccessBlock?.blockPublicACLs, true)
        XCTAssertEqual(vm.objects.map(\.key), ["file"], "Retry preserves the object browser")

        let context = S3TransferContext(scope: scope, bucket: "fixture-bucket", prefix: "", knownRegion: vm.selectedBucket?.region)
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("download")
        let object = try XCTUnwrap(vm.objects.first)
        _ = try await AWSS3TransferService(provider: provider).download(
            context: context, object: object, destination: .init(url: destination), progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: destination), Data("fixture".utf8))

        let requests = await probe.requests
        XCTAssertFalse(requests.contains { $0.operation == "location" })
        XCTAssertTrue(requests.contains { $0.operation == "object" })
        assertBucketRequests(requests, owner: scope.accountID, region: "eu-west-1")
        await provider.shutdown()
    }

    func testMissingMalformedAndCrossPartitionHintsUseOwnerBoundLocationAndMissingFieldsHaveDefaults() async throws {
        for hint in [nil, "invalid endpoint", "cn-north-1"] {
            let probe = S3DetailsHTTPProbe(hint: hint, location: "eu-west-1", missingDetails: true)
            let (vm, provider, scope) = try await makeWorkspace(probe)
            await vm.loadBuckets()
            await vm.waitForDetails()
            XCTAssertEqual(vm.selectedBucket?.region, "eu-west-1")
            XCTAssertEqual(vm.selectedBucket?.versioningEnabled, true)
            XCTAssertEqual(vm.selectedBucket?.encryptionEnabled, false)
            XCTAssertEqual(vm.selectedBucket?.publicAccessBlock,
                .init(blockPublicACLs: false, ignorePublicACLs: false, blockPublicPolicy: false, restrictPublicBuckets: false))
            XCTAssertEqual(vm.selectedBucket?.tags, [:])
            XCTAssertNil(vm.selectedBucket?.detailError)
            let requests = await probe.requests
            XCTAssertEqual(requests.filter { $0.operation == "location" }.count, 1)
            assertBucketRequests(requests, owner: scope.accountID, region: "eu-west-1")
            await provider.shutdown()
        }
    }

    func testOwnerMismatchInFallbackAndCrossPartitionLocationPreventDetailAndObjectRequests() async throws {
        for rejectOwner in [true, false] {
            let probe = S3DetailsHTTPProbe(hint: nil, location: "cn-north-1", bucketOwner: rejectOwner ? "999988887777" : "111122223333")
            let (vm, provider, scope) = try await makeWorkspace(probe)
            await vm.loadBuckets()
            await vm.waitForDetails()
            XCTAssertNil(vm.selectedBucket?.region)
            XCTAssertNotNil(vm.selectedBucket?.detailError)
            await vm.loadObjects(bucket: "fixture-bucket")
            XCTAssertFalse(vm.hasLoadedObjectPage)
            XCTAssertNotNil(vm.objectLoadError)
            let requests = await probe.requests
            XCTAssertEqual(requests.map(\.operation), ["buckets", "location", "location"])
            XCTAssertEqual(requests.dropFirst().map(\.owner), [scope.accountID, scope.accountID])
            await provider.shutdown()
        }
    }

    func testKnownLocationStillRejectsNonOwnedBucket() async throws {
        let probe = S3DetailsHTTPProbe(hint: "eu-west-1", bucketOwner: "999988887777")
        let (vm, provider, scope) = try await makeWorkspace(probe)
        await vm.loadBuckets()
        await vm.waitForDetails()
        XCTAssertNil(vm.selectedBucket?.versioningEnabled)
        XCTAssertEqual(vm.selectedBucket?.detailError?.split(separator: "\n").count, 4)
        await vm.loadObjects(bucket: "fixture-bucket")
        XCTAssertFalse(vm.hasLoadedObjectPage)
        XCTAssertNotNil(vm.objectLoadError)
        let requests = await probe.requests
        XCTAssertFalse(requests.contains { $0.operation == "location" })
        assertBucketRequests(requests, owner: scope.accountID, region: "eu-west-1")
        await provider.shutdown()
    }

    private func makeWorkspace(_ probe: S3DetailsHTTPProbe) async throws -> (S3ViewModel, AWSServiceProvider, MonitoringScope) {
        let provider = AWSServiceProvider.testProvider(transport: OfflineAWSHTTPClient { await probe.respond($0) })
        let scope = providerTestScope(.init(name: "test", region: "us-east-1",
            ssoStartURL: nil, ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil))
        try await provider.configureVerified(profile: scope.profile, region: scope.region)
        let vm = S3ViewModel()
        vm.configure(provider: provider, scope: scope, refreshImmediately: false)
        return (vm, provider, scope)
    }

    private func assertBucketRequests(_ requests: [S3DetailsHTTPProbe.Request], owner: String, region: String) {
        let scoped = requests.filter { $0.operation != "buckets" }
        XCTAssertFalse(scoped.isEmpty)
        XCTAssertTrue(scoped.allSatisfy { $0.owner == owner })
        XCTAssertTrue(scoped.filter { $0.operation != "location" }.allSatisfy { $0.host.contains(region) })
    }
}

private actor S3DetailBarrier {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if !isOpen { await withCheckedContinuation { waiters.append($0) } }
    }

    func open() {
        isOpen = true
        let ready = waiters
        waiters.removeAll()
        ready.forEach { $0.resume() }
    }
}

private actor S3DetailsHTTPProbe {
    struct Request: Sendable {
        let operation: String
        let host: String
        let owner: String?
    }

    let hint: String?
    let location: String
    let denyLocation: Bool
    let bucketOwner: String
    let missingDetails: Bool
    let firstDetails: XCTestExpectation?
    let release: S3DetailBarrier?
    private(set) var requests: [Request] = []

    init(hint: String?, location: String = "", denyLocation: Bool = false, bucketOwner: String = "111122223333",
         missingDetails: Bool = false, firstDetails: XCTestExpectation? = nil, release: S3DetailBarrier? = nil) {
        self.hint = hint
        self.location = location
        self.denyLocation = denyLocation
        self.bucketOwner = bucketOwner
        self.missingDetails = missingDetails
        self.firstDetails = firstDetails
        self.release = release
    }

    func respond(_ request: AWSHTTPRequest) async -> AWSHTTPResponse {
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let operation = query.first(where: { ["location", "versioning", "encryption", "publicAccessBlock", "tagging"].contains($0.name) })?.name
            ?? (query.contains { $0.name == "list-type" } ? "objects" :
                    request.url.path.hasSuffix("/file") ? "object" : "buckets")
        let owner = request.headers["x-amz-expected-bucket-owner"].first
        let first = !requests.contains { $0.operation == operation }
        requests.append(.init(operation: operation, host: request.url.host ?? "", owner: owner))
        if operation != "buckets", owner != bucketOwner { return error("AccessDenied") }

        if first, ["versioning", "encryption", "publicAccessBlock", "tagging"].contains(operation),
           let firstDetails, let release {
            firstDetails.fulfill()
            await release.wait()
            if ["encryption", "publicAccessBlock"].contains(operation) { return error("AccessDenied") }
        }

        switch operation {
        case "buckets":
            let region = hint.map { "<BucketRegion>\($0)</BucketRegion>" } ?? ""
            return xml("<ListAllMyBucketsResult><Buckets><Bucket><Name>fixture-bucket</Name>\(region)</Bucket></Buckets></ListAllMyBucketsResult>")
        case "location":
            if denyLocation { return error("AccessDenied") }
            return xml("<LocationConstraint>\(location)</LocationConstraint>")
        case "versioning": return xml("<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>")
        case "encryption":
            if missingDetails { return error("ServerSideEncryptionConfigurationNotFoundError", missing: true) }
            return xml("<ServerSideEncryptionConfiguration><Rule/></ServerSideEncryptionConfiguration>")
        case "publicAccessBlock":
            if missingDetails { return error("NoSuchPublicAccessBlockConfiguration", missing: true) }
            return xml("<PublicAccessBlockConfiguration><BlockPublicAcls>true</BlockPublicAcls></PublicAccessBlockConfiguration>")
        case "tagging":
            if missingDetails { return error("NoSuchTagSet", missing: true) }
            return xml("<Tagging><TagSet><Tag><Key>Team</Key><Value>first</Value></Tag><Tag><Key>Team</Key><Value>second</Value></Tag></TagSet></Tagging>")
        case "objects":
            return xml("<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>file</Key><Size>7</Size><ETag>etag</ETag></Contents></ListBucketResult>")
        default:
            return .init(status: .ok, headers: ["content-length": "7", "etag": "etag"], body: .init(string: "fixture"))
        }
    }

    private func xml(_ body: String) -> AWSHTTPResponse {
        .init(status: .ok, headers: ["content-type": "application/xml"], body: .init(string: body))
    }

    private func error(_ code: String, missing: Bool = false) -> AWSHTTPResponse {
        .init(status: missing ? .notFound : .forbidden, headers: ["content-type": "application/xml"],
              body: .init(string: "<Error><Code>\(code)</Code><Message>Offline fixture</Message></Error>"))
    }
}
