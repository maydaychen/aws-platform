import SotoS3
import XCTest
@testable import AWSPlatform

final class S3ViewModelTests: XCTestCase {
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
