import XCTest
@testable import AWSPlatform

final class TransferActivityTests: XCTestCase {
    @MainActor
    func testCLIMaintenanceIsExclusiveWithTransfersAcrossWindows() throws {
        let activity = TransferActivity()
        let first = try XCTUnwrap(activity.begin())
        let second = try XCTUnwrap(activity.begin())
        XCTAssertNil(activity.beginCLIMaintenance())
        activity.finish(first)
        XCTAssertNil(activity.beginCLIMaintenance())
        activity.finish(second)
        let maintenance = try XCTUnwrap(activity.beginCLIMaintenance())
        XCTAssertTrue(activity.cliMaintenanceActive)
        XCTAssertEqual(activity.activeCount, 0, "CLI maintenance must not inflate the S3 transfer count")
        XCTAssertNil(activity.beginCLIMaintenance())
        XCTAssertNil(activity.begin())
        activity.finishCLIMaintenance(UUID())
        XCTAssertTrue(activity.cliMaintenanceActive)
        activity.finishCLIMaintenance(maintenance)
        activity.finishCLIMaintenance(maintenance)
        XCTAssertFalse(activity.cliMaintenanceActive)
        let next = try XCTUnwrap(activity.begin())
        activity.finish(next)
    }

    @MainActor
    func testCLIInstallationDefersQuitUntilLeaseEndsOnce() throws {
        let activity = TransferActivity()
        let maintenance = try XCTUnwrap(activity.beginCLIMaintenance())
        var replies = 0
        XCTAssertTrue(activity.postponeTermination { replies += 1 })
        XCTAssertTrue(activity.postponeTermination { XCTFail("Keep the first quit continuation") })
        XCTAssertEqual(replies, 0)
        XCTAssertNil(activity.beginCLIMaintenance())
        activity.finishCLIMaintenance(maintenance)
        activity.finishCLIMaintenance(maintenance)
        XCTAssertEqual(replies, 1)
        XCTAssertFalse(activity.isRestartPending)
    }

    @MainActor
    func testQuitWaitsForAllActiveTransfersAndCompletesOnce() throws {
        let activity = TransferActivity()
        let first = try XCTUnwrap(activity.begin())
        let second = try XCTUnwrap(activity.begin())
        var replies = 0
        XCTAssertTrue(activity.postponeTermination { replies += 1 })
        XCTAssertNil(activity.begin())
        activity.finish(first)
        XCTAssertEqual(activity.activeCount, 1)
        XCTAssertEqual(replies, 0)
        activity.finish(second)
        activity.finish(second)
        XCTAssertEqual(replies, 1)
        XCTAssertFalse(activity.isRestartPending)
    }

    @MainActor
    func testIdleTerminationDoesNotPostpone() {
        let activity = TransferActivity()
        XCTAssertFalse(activity.postponeTermination { XCTFail("No deferred quit") })
        XCTAssertNotNil(activity.begin())
    }

    @MainActor
    func testControllerExposesVersionFormatAndPublicReleasesURL() {
        let activity = TransferActivity()
        let controller = AppUpdateController(transfers: activity)
        XCTAssertFalse(controller.version.isEmpty)
        XCTAssertEqual(AppUpdateController.releasesURL.absoluteString,
                       "https://github.com/maydaychen/aws-platform/releases")
    }
}
