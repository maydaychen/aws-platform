import XCTest
import Sparkle
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
    func testCLIInstallationDefersQuitAndSparkleUntilLeaseEndsOnce() throws {
        let activity = TransferActivity()
        let maintenance = try XCTUnwrap(activity.beginCLIMaintenance())
        var installations = 0
        var replies = 0
        XCTAssertTrue(activity.postponeUpdate { installations += 1 })
        XCTAssertTrue(activity.postponeUpdate { XCTFail("Keep the first update continuation") })
        XCTAssertTrue(activity.postponeTermination { replies += 1 })
        XCTAssertTrue(activity.postponeTermination { XCTFail("Keep the first quit continuation") })
        XCTAssertEqual(installations, 0)
        XCTAssertEqual(replies, 0)
        XCTAssertNil(activity.beginCLIMaintenance())
        activity.finishCLIMaintenance(maintenance)
        activity.finishCLIMaintenance(maintenance)
        XCTAssertEqual(installations, 1)
        XCTAssertEqual(replies, 1)
        XCTAssertTrue(activity.isRestartPending)
    }

    @MainActor
    func testAbortedSparkleStillWaitsForCLIInstallationBeforeQuit() throws {
        let activity = TransferActivity()
        let maintenance = try XCTUnwrap(activity.beginCLIMaintenance())
        var replies = 0
        XCTAssertTrue(activity.postponeUpdate { XCTFail("An aborted Sparkle update must not resume") })
        XCTAssertTrue(activity.postponeTermination { replies += 1 })
        activity.cancelUpdate()
        XCTAssertTrue(activity.isRestartPending)
        XCTAssertTrue(activity.cliMaintenanceActive)
        XCTAssertEqual(replies, 0)
        activity.finishCLIMaintenance(maintenance)
        XCTAssertEqual(replies, 1)
    }

    @MainActor
    func testRestartRequestWithoutActivityPreventsMaintenance() {
        let activity = TransferActivity()
        XCTAssertFalse(activity.postponeUpdate { XCTFail("No activity to defer") })
        XCTAssertNil(activity.beginCLIMaintenance())
        activity.cancelUpdate()
        let maintenance = activity.beginCLIMaintenance()
        XCTAssertNotNil(maintenance)
        if let maintenance { activity.finishCLIMaintenance(maintenance) }
    }

    @MainActor
    func testSparkleCompletionUnlocksDismissedCycleButNotSuccessfulInstallation() throws {
        let activity = TransferActivity()
        let controller = AppUpdateController(transfers: activity)
        for selector in ["feedURLStringForUpdater:", "updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:",
                         "updater:willInstallUpdate:", "updater:didFinishUpdateCycleForUpdateCheck:error:", "updater:didAbortWithError:"] {
            XCTAssertTrue(controller.responds(to: NSSelectorFromString(selector)), "Sparkle must be able to dispatch \(selector)")
        }
        // Starting is disabled: no update fetch, preference writes or installer runs.
        let sparkle = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: controller, userDriverDelegate: nil)
        let delegate: SPUUpdaterDelegate = controller
        let lease = try XCTUnwrap(activity.begin())
        XCTAssertTrue(activity.postponeUpdate { XCTFail("Dismissed update must not resume installation") })
        delegate.updater?(sparkle.updater, didFinishUpdateCycleFor: .updates, error: nil)
        XCTAssertFalse(activity.isRestartPending)
        activity.finish(lease)
        activity.markUpdateInstallation()
        delegate.updater?(sparkle.updater, didFinishUpdateCycleFor: .updates, error: nil)
        XCTAssertTrue(activity.isRestartPending)
        XCTAssertNil(activity.begin())
        delegate.updater?(sparkle.updater, didFinishUpdateCycleFor: .updates, error: NSError(domain: "test", code: 1))
        XCTAssertFalse(activity.isRestartPending)
    }

    @MainActor
    func testRestartWaitsForAllWindowsAndCompletesOnce() throws {
        let activity = TransferActivity()
        let first = try XCTUnwrap(activity.begin())
        let second = try XCTUnwrap(activity.begin())
        var installations = 0
        XCTAssertTrue(activity.postponeUpdate { installations += 1 })
        XCTAssertNil(activity.begin())
        activity.finish(first)
        XCTAssertEqual(activity.activeCount, 1)
        XCTAssertEqual(installations, 0)
        activity.finish(second)
        activity.finish(second)
        XCTAssertEqual(installations, 1)
        XCTAssertTrue(activity.isRestartPending)
    }

    @MainActor
    func testAbortedUpdateUnlocksWithoutInstalling() throws {
        let activity = TransferActivity()
        let lease = try XCTUnwrap(activity.begin())
        XCTAssertTrue(activity.postponeUpdate { XCTFail("Aborted update must not install") })
        activity.cancelUpdate()
        XCTAssertFalse(activity.isRestartPending)
        activity.finish(lease)
        XCTAssertEqual(activity.activeCount, 0)
        XCTAssertNotNil(activity.begin())
    }

    @MainActor
    func testApplicationTerminationStillWaitsAfterUpdateAborts() throws {
        let activity = TransferActivity()
        let lease = try XCTUnwrap(activity.begin())
        var replies = 0
        XCTAssertTrue(activity.postponeUpdate { XCTFail("Aborted update") })
        XCTAssertTrue(activity.postponeTermination { replies += 1 })
        activity.cancelUpdate()
        XCTAssertNil(activity.begin())
        activity.finish(lease)
        activity.finish(lease)
        XCTAssertEqual(replies, 1)
    }

    @MainActor
    func testIdleRestartDoesNotPostponeButBlocksNewTransfers() {
        let activity = TransferActivity()
        XCTAssertFalse(activity.postponeUpdate { XCTFail("No deferred installation") })
        XCTAssertNil(activity.begin())
        activity.cancelUpdate()
        XCTAssertFalse(activity.postponeTermination { XCTFail("No deferred quit") })
        XCTAssertNotNil(activity.begin())
    }

    func testFeedsAreSeparateHTTPSURLsSelectedByAppSlice() {
        XCTAssertNotEqual(UpdateArchitecture.arm64.feedURL, UpdateArchitecture.x86_64.feedURL)
        for architecture in UpdateArchitecture.allCases {
            XCTAssertEqual(architecture.feedURL.scheme, "https")
            XCTAssertTrue(architecture.feedURL.lastPathComponent.contains(architecture.rawValue))
        }
        #if arch(arm64)
        XCTAssertEqual(UpdateArchitecture.current, .arm64)
        #else
        XCTAssertEqual(UpdateArchitecture.current, .x86_64)
        #endif
    }
}
