import XCTest
@testable import AWSPlatform

final class S3TransferProviderTests: XCTestCase {
    func testTransfersUseBucketRegionWithSelectedProfileClient() async throws {
        let provider = AWSServiceProvider.testProvider()
        let context = S3TransferFixtures.context()
        let scope = context.scope
        try await provider.configureVerified(profile: scope.profile, region: scope.region, paths: scope.paths)
        let workspace = try await provider.s3Client(scope: scope)
        let transfer = try await provider.transferS3Client(scope: scope, region: "ap-southeast-1")
        XCTAssertTrue(workspace.client === transfer.client)
        XCTAssertEqual(transfer.config.region.rawValue, "ap-southeast-1")
        let unchangedRegion = await provider.currentRegion
        XCTAssertEqual(unchangedRegion, "us-east-1")
        await provider.shutdown()
    }

    func testTransfersRejectChangedProfileRegionPathsAndClearedClient() async throws {
        let provider = AWSServiceProvider.testProvider()
        let context = S3TransferFixtures.context()
        let original = context.scope
        try await provider.configureVerified(profile: original.profile, region: original.region, paths: original.paths)
        let identity = AWSIdentity(account: original.accountID, arn: original.principalARN, userID: "test")
        let invalid = [
            S3TransferFixtures.context(profileName: "other").scope,
            MonitoringScope(profile: original.profile, identity: identity, region: "eu-west-1", paths: original.paths),
            MonitoringScope(profile: original.profile, identity: identity, region: original.region,
                paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/example/changed"]))
        ]
        for scope in invalid {
            do {
                _ = try await provider.transferS3Client(scope: scope, region: "ap-southeast-1")
                XCTFail("Stale transfer must not borrow a client")
            } catch { XCTAssertEqual(error as? S3TransferError, .invalidScope) }
        }
        await provider.shutdown()
        do {
            _ = try await provider.transferS3Client(scope: original, region: "ap-southeast-1")
            XCTFail("No transfer after Profile was cleared")
        } catch { XCTAssertEqual(error as? S3TransferError, .invalidScope) }
    }
}
