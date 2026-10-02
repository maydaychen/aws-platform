import SotoS3
import XCTest
@testable import AWSPlatform

final class S3ViewModelTests: XCTestCase {
    @MainActor
    func testLateObjectsCannotReplaceNewPrefix() async {
        let gate = TestGate()
        let vm = S3ViewModel(objectLoader: { _, prefix in
            if prefix == "old/" { await gate.wait() }
            return [S3ObjectModel(key: prefix + "file", size: nil, lastModified: nil, storageClass: nil, isPrefix: false)]
        })
        let old = Task { await vm.loadObjects(bucket: "example", prefix: "old/") }
        await gate.waitForEntry()
        await vm.loadObjects(bucket: "example", prefix: "new/")
        await gate.open()
        await old.value
        XCTAssertEqual(vm.currentPrefix, "new/")
        XCTAssertEqual(vm.objects.map(\.key), ["new/file"])
        XCTAssertEqual(vm.selectedObject?.key, "new/file")
    }

    @MainActor
    func testResetRejectsLateObjectError() async {
        let gate = TestGate()
        let vm = S3ViewModel(objectLoader: { _, _ in
            await gate.wait()
            throw S3TestError.failed
        })
        let request = Task { await vm.loadObjects(bucket: "example") }
        await gate.waitForEntry()
        vm.reset()
        await gate.open()
        await request.value
        XCTAssertTrue(vm.objects.isEmpty)
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func testCancelledObjectRequestCannotEndNewLoadingState() async {
        let oldGate = TestGate()
        let newGate = TestGate()
        let vm = S3ViewModel(objectLoader: { _, prefix in
            await (prefix == "old/" ? oldGate : newGate).wait()
            return []
        })
        let old = Task { await vm.loadObjects(bucket: "example", prefix: "old/") }
        await oldGate.waitForEntry()
        vm.cancelLoading()
        let current = Task { await vm.loadObjects(bucket: "example", prefix: "new/") }
        await newGate.waitForEntry()
        await oldGate.open()
        await old.value
        XCTAssertTrue(vm.isLoading)
        await newGate.open()
        await current.value
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func testResetRejectsLateDetailsForSameBucketName() async {
        let gate = TestGate()
        let bucket = makeBucket(name: "example")
        let vm = S3ViewModel(detailLoader: { bucket in
            await gate.wait()
            var updated = bucket
            updated.region = "old-region"
            return updated
        })
        vm.buckets = [bucket]
        vm.selectedBucket = bucket
        let request = Task { await vm.loadBucketDetails(name: bucket.name) }
        await gate.waitForEntry()
        vm.reset()
        vm.buckets = [bucket]
        vm.selectedBucket = bucket
        await gate.open()
        await request.value
        XCTAssertNil(vm.buckets.first?.region)
        XCTAssertNil(vm.selectedBucket?.region)
    }

    @MainActor
    func testResetRejectsLateBucketSuccess() async {
        let gate = TestGate()
        let oldBucket = makeBucket(name: "old")
        let vm = S3ViewModel(bucketLoader: {
            await gate.wait()
            return [oldBucket]
        })
        let request = Task { await vm.loadBuckets() }
        await gate.waitForEntry()
        vm.reset()
        await gate.open()
        await request.value

        XCTAssertTrue(vm.buckets.isEmpty)
        XCTAssertNil(vm.selectedBucket)
        XCTAssertNil(vm.error)
    }

    @MainActor
    func testOldBucketFailureCannotClearNewResults() async {
        let gate = TestGate()
        let bucket = makeBucket(name: "current")
        var calls = 0
        let vm = S3ViewModel(bucketLoader: {
            calls += 1
            if calls == 1 {
                await gate.wait()
                throw S3TestError.failed
            }
            return [bucket]
        })
        let oldRequest = Task { await vm.loadBuckets() }
        await gate.waitForEntry()
        await vm.loadBuckets()
        await gate.open()
        await oldRequest.value

        XCTAssertEqual(vm.buckets, [bucket])
        XCTAssertNil(vm.error)
    }

    func testLoadBucketsSelectsFirstBucket() async {
        let bucket = makeBucket(name: "example")
        let vm = await MainActor.run {
            S3ViewModel(bucketLoader: { [bucket] in [bucket] })
        }

        await vm.loadBuckets()

        await MainActor.run {
            XCTAssertEqual(vm.buckets, [bucket])
            XCTAssertEqual(vm.selectedBucket, bucket)
            XCTAssertNil(vm.error)
            XCTAssertFalse(vm.isLoading)
        }
    }

    func testLoadBucketsFailureShowsError() async {
        let vm = await MainActor.run {
            S3ViewModel(bucketLoader: { throw S3TestError.failed })
        }

        await vm.loadBuckets()

        await MainActor.run {
            XCTAssertTrue(vm.buckets.isEmpty)
            XCTAssertNil(vm.selectedBucket)
            XCTAssertEqual(vm.error, "S3 test operation failed.")
            XCTAssertFalse(vm.isLoading)
        }
    }

    func testPublicAccessBlockMapsEachSettingIndependently() {
        let configuration = S3.PublicAccessBlockConfiguration(
            blockPublicAcls: true,
            blockPublicPolicy: false,
            ignorePublicAcls: true,
            restrictPublicBuckets: false
        )

        let result = S3ViewModel.publicAccessBlock(from: configuration)

        XCTAssertTrue(result.blockPublicACLs)
        XCTAssertTrue(result.ignorePublicACLs)
        XCTAssertFalse(result.blockPublicPolicy)
        XCTAssertFalse(result.restrictPublicBuckets)
    }

    func testPublicAccessBlockTreatsMissingValuesAsDisabled() {
        let result = S3ViewModel.publicAccessBlock(
            from: S3.PublicAccessBlockConfiguration()
        )

        XCTAssertFalse(result.blockPublicACLs)
        XCTAssertFalse(result.ignorePublicACLs)
        XCTAssertFalse(result.blockPublicPolicy)
        XCTAssertFalse(result.restrictPublicBuckets)
    }

    private func makeBucket(name: String) -> S3BucketModel {
        S3BucketModel(
            name: name,
            region: nil,
            creationDate: nil,
            versioningEnabled: nil,
            encryptionEnabled: nil,
            publicAccessBlock: nil,
            tags: [:],
            detailError: nil
        )
    }
}

private enum S3TestError: LocalizedError {
    case failed

    var errorDescription: String? {
        "S3 test operation failed."
    }
}
