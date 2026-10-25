import XCTest
@testable import AWSPlatform

@MainActor
final class S3RefreshLifecycleTests: XCTestCase {
    func testRefreshPreservesSelectedBucketDetailsAndObjectBrowserWithoutReloadingDetails() async {
        var detailCalls = 0
        let first = bucket("first")
        var selected = bucket("selected")
        selected.region = "eu-west-1"
        selected.versioningEnabled = true
        selected.encryptionEnabled = true
        selected.tags = ["owner": "team"]
        let vm = S3ViewModel(bucketLoader: { [first, self.bucket("selected")] }, detailLoader: {
            detailCalls += 1
            return $0
        }, objectLoader: { _, _, _ in
            .init(objects: [self.object("reports/file")], nextContinuationToken: "next")
        })
        vm.buckets = [first, selected]
        vm.selectedBucket = selected
        await vm.loadObjects(bucket: selected.name, prefix: "reports/")

        vm.refresh()
        await vm.waitForCurrentLoad()
        await vm.waitForDetails()

        XCTAssertEqual(vm.selectedBucket, selected)
        XCTAssertEqual(vm.buckets.last, selected)
        XCTAssertEqual(vm.currentPrefix, "reports/")
        XCTAssertEqual(vm.objects.map(\.key), ["reports/file"])
        XCTAssertEqual(vm.selectedObject?.key, "reports/file")
        XCTAssertEqual(vm.nextObjectToken, "next")
        XCTAssertEqual(detailCalls, 0)
        XCTAssertFalse(vm.isLoading)
    }

    func testRefreshKeepsLatestSelectionMadeWhileListRequestIsPending() async {
        let gate = TestGate()
        let first = bucket("first")
        let second = bucket("second")
        var detailNames: [String] = []
        let vm = S3ViewModel(bucketLoader: {
            await gate.wait()
            return [first, second]
        }, detailLoader: {
            detailNames.append($0.name)
            var updated = $0
            updated.region = "eu-west-1"
            return updated
        })
        vm.buckets = [first, second]
        vm.selectedBucket = first
        vm.refresh()
        await gate.waitForEntry()
        vm.selectBucket(second)
        await vm.waitForDetails()
        await gate.open()
        await vm.waitForCurrentLoad()

        XCTAssertEqual(vm.selectedBucket?.name, second.name)
        XCTAssertEqual(vm.selectedBucket?.region, "eu-west-1")
        XCTAssertEqual(detailNames, [second.name])
    }

    func testBucketRefreshAndObjectLoadCompleteIndependentlyInEitherOrder() async {
        for finishObjectsFirst in [false, true] {
            let listGate = TestGate()
            let objectGate = TestGate()
            let current = bucket("current")
            var listCancelled = false
            var objectCancelled = false
            let vm = S3ViewModel(bucketLoader: {
                await listGate.wait()
                listCancelled = Task.isCancelled
                return [current, self.bucket("new")]
            }, objectLoader: { _, _, _ in
                await objectGate.wait()
                objectCancelled = Task.isCancelled
                return .init(objects: [self.object("prefix/file")])
            })
            vm.buckets = [current]
            vm.selectedBucket = current
            vm.refresh()
            await listGate.waitForEntry()
            let objects = Task { await vm.loadObjects(bucket: current.name, prefix: "prefix/") }
            await objectGate.waitForEntry()
            XCTAssertTrue(vm.isBucketsLoading)
            XCTAssertTrue(vm.isObjectsLoading)

            if finishObjectsFirst {
                await objectGate.open()
                await objects.value
                XCTAssertTrue(vm.isBucketsLoading)
                XCTAssertFalse(vm.isObjectsLoading)
                XCTAssertTrue(vm.isLoading)
                await listGate.open()
                await vm.waitForCurrentLoad()
            } else {
                await listGate.open()
                await vm.waitForCurrentLoad()
                XCTAssertFalse(vm.isBucketsLoading)
                XCTAssertTrue(vm.isObjectsLoading)
                XCTAssertTrue(vm.isLoading)
                await objectGate.open()
                await objects.value
            }

            XCTAssertFalse(listCancelled)
            XCTAssertFalse(objectCancelled)
            XCTAssertEqual(vm.buckets.map(\.name), ["current", "new"])
            XCTAssertEqual(vm.selectedBucket?.name, current.name)
            XCTAssertEqual(vm.currentPrefix, "prefix/")
            XCTAssertEqual(vm.objects.map(\.key), ["prefix/file"])
            XCTAssertFalse(vm.isLoading)
        }
    }

    func testRemovedBucketCancelsItsObjectsAndSelectsReplacementWithoutOldDetails() async {
        let objectGate = TestGate()
        var old = bucket("removed")
        old.region = "old-region"
        old.tags = ["old": "tag"]
        let replacement = bucket("replacement")
        var objectCancelled = false
        let vm = S3ViewModel(bucketLoader: { [replacement] }, objectLoader: { _, _, _ in
            await objectGate.wait()
            objectCancelled = Task.isCancelled
            return .init(objects: [self.object("old/file")], nextContinuationToken: "old-token")
        })
        vm.buckets = [old, replacement]
        vm.selectedBucket = old
        let objects = Task { await vm.loadObjects(bucket: old.name, prefix: "old/") }
        await objectGate.waitForEntry()

        await vm.loadBuckets()
        await objectGate.open()
        await objects.value

        XCTAssertTrue(objectCancelled)
        XCTAssertEqual(vm.selectedBucket, replacement)
        XCTAssertNil(vm.selectedBucket?.region)
        XCTAssertEqual(vm.selectedBucket?.tags, [:])
        XCTAssertTrue(vm.objects.isEmpty)
        XCTAssertNil(vm.selectedObject)
        XCTAssertNil(vm.nextObjectToken)
        XCTAssertEqual(vm.currentPrefix, "")
        XCTAssertFalse(vm.hasLoadedObjectPage)
        XCTAssertFalse(vm.isLoading)
    }

    func testCancellingEitherBrowserRequestLeavesTheOtherRequestRunning() async {
        for cancelBuckets in [false, true] {
            let listGate = TestGate()
            let objectGate = TestGate()
            let current = bucket("current")
            var listCancelled = false
            var objectCancelled = false
            let vm = S3ViewModel(bucketLoader: {
                await listGate.wait()
                listCancelled = Task.isCancelled
                return [current, self.bucket("new")]
            }, objectLoader: { _, _, _ in
                await objectGate.wait()
                objectCancelled = Task.isCancelled
                return .init(objects: [self.object("prefix/file")])
            })
            vm.buckets = [current]
            vm.selectedBucket = current
            vm.refresh()
            await listGate.waitForEntry()
            var waitingForList = false
            let listing = Task {
                waitingForList = true
                await vm.waitForCurrentLoad()
            }
            while !waitingForList { await Task.yield() }
            let objects = Task { await vm.loadObjects(bucket: current.name, prefix: "prefix/") }
            await objectGate.waitForEntry()

            if cancelBuckets {
                vm.cancelBucketLoading()
                XCTAssertFalse(vm.isBucketsLoading)
                XCTAssertTrue(vm.isObjectsLoading)
                await objectGate.open()
                await objects.value
                XCTAssertEqual(vm.objects.map(\.key), ["prefix/file"])
                await listGate.open()
                await listing.value
                XCTAssertEqual(vm.buckets, [current])
            } else {
                vm.cancelObjectLoading()
                XCTAssertTrue(vm.isBucketsLoading)
                XCTAssertFalse(vm.isObjectsLoading)
                await listGate.open()
                await listing.value
                XCTAssertEqual(vm.buckets.map(\.name), ["current", "new"])
                await objectGate.open()
                await objects.value
                XCTAssertTrue(vm.objects.isEmpty)
            }

            XCTAssertEqual(listCancelled, cancelBuckets)
            XCTAssertEqual(objectCancelled, !cancelBuckets)
            XCTAssertEqual(vm.selectedBucket?.name, current.name)
            XCTAssertFalse(vm.isLoading)
            XCTAssertNil(vm.error)
        }
    }

    func testEmptyRefreshedListClearsSelectionAndBrowser() async {
        let current = bucket("removed")
        let vm = S3ViewModel(bucketLoader: { [] }, objectLoader: { _, _, _ in
            .init(objects: [self.object("old/file")], nextContinuationToken: "next")
        })
        vm.buckets = [current]
        vm.selectedBucket = current
        await vm.loadObjects(bucket: current.name, prefix: "old/")

        await vm.loadBuckets()

        XCTAssertTrue(vm.buckets.isEmpty)
        XCTAssertNil(vm.selectedBucket)
        XCTAssertTrue(vm.objects.isEmpty)
        XCTAssertNil(vm.selectedObject)
        XCTAssertNil(vm.nextObjectToken)
        XCTAssertEqual(vm.currentPrefix, "")
    }

    func testRefreshFailureKeepsCurrentSelectionDetailsAndObjects() async {
        var current = bucket("current")
        current.region = "eu-west-1"
        let vm = S3ViewModel(bucketLoader: { throw RefreshError.failed }, objectLoader: { _, _, _ in
            .init(objects: [self.object("prefix/file")])
        })
        vm.buckets = [current]
        vm.selectedBucket = current
        await vm.loadObjects(bucket: current.name, prefix: "prefix/")

        await vm.loadBuckets()

        XCTAssertEqual(vm.buckets, [current])
        XCTAssertEqual(vm.selectedBucket, current)
        XCTAssertEqual(vm.objects.map(\.key), ["prefix/file"])
        XCTAssertEqual(vm.currentPrefix, "prefix/")
        XCTAssertNotNil(vm.error)
        XCTAssertFalse(vm.isLoading)
    }

    func testAsyncObjectEntryIsOwnedAndCancelledByCancelResetOrLeavingBrowser() async {
        for action in 0..<3 {
            let gate = TestGate()
            var wasCancelled = false
            let vm = S3ViewModel(objectLoader: { _, _, _ in
                await gate.wait()
                wasCancelled = Task.isCancelled
                return .init(objects: [self.object("late/file")])
            })
            let request = Task { await vm.loadObjects(bucket: "example") }
            await gate.waitForEntry()
            switch action {
            case 0: vm.cancelLoading()
            case 1: vm.reset()
            default: vm.leaveObjectBrowser()
            }
            await gate.open()
            await request.value

            XCTAssertTrue(wasCancelled)
            XCTAssertTrue(vm.objects.isEmpty)
            XCTAssertFalse(vm.isObjectsLoading)
            XCTAssertNil(vm.error)
        }
    }

    func testCancellingAsyncCallerCancelsItsOwnedObjectRequest() async {
        let gate = TestGate()
        var wasCancelled = false
        let vm = S3ViewModel(objectLoader: { _, _, _ in
            await gate.wait()
            wasCancelled = Task.isCancelled
            return .init(objects: [self.object("late/file")])
        })
        let request = Task { await vm.loadObjects(bucket: "example") }
        await gate.waitForEntry()
        request.cancel()
        await gate.open()
        await request.value

        XCTAssertTrue(wasCancelled)
        XCTAssertTrue(vm.objects.isEmpty)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.error)
    }

    func testReconfigurationCancelsOldInjectedRequestAndRejectsLateResult() async {
        let gate = TestGate()
        let provider = AWSServiceProvider()
        let profile = AWSProfile(name: "new-profile", region: "eu-west-1", ssoStartURL: nil,
                                 ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil)
        let scope = MonitoringScope(profile: profile, identity: .init(account: "222222222222",
            arn: "arn:aws:iam::222222222222:user/test", userID: "test"), region: profile.region)
        var wasCancelled = false
        let vm = S3ViewModel(objectLoader: { _, _, _ in
            await gate.wait()
            wasCancelled = Task.isCancelled
            return .init(objects: [self.object("old-account/file")])
        })
        let request = Task { await vm.loadObjects(bucket: "example") }
        await gate.waitForEntry()
        vm.configure(provider: provider, scope: scope, refreshImmediately: false)
        await gate.open()
        await request.value

        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(vm.scope, scope)
        XCTAssertTrue(vm.buckets.isEmpty)
        XCTAssertNil(vm.selectedBucket)
        XCTAssertTrue(vm.objects.isEmpty)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.error)
        await provider.shutdown()
    }

    func testBucketAndObjectErrorsDoNotClearOrMasqueradeAsEachOther() async {
        for failBucket in [false, true] {
            let current = bucket("current")
            let vm = S3ViewModel(bucketLoader: {
                if failBucket { throw RefreshError.failed }
                return [current]
            }, objectLoader: { _, _, _ in
                if !failBucket { throw RefreshError.failed }
                return .init(objects: [self.object("file")])
            })
            vm.buckets = [current]
            vm.selectedBucket = current
            if failBucket {
                await vm.loadBuckets()
                XCTAssertNotNil(vm.bucketListError)
                await vm.loadObjects(bucket: current.name)
            } else {
                await vm.loadObjects(bucket: current.name)
                XCTAssertNotNil(vm.objectLoadError)
                await vm.loadBuckets()
            }

            XCTAssertEqual(vm.bucketListError != nil, failBucket)
            XCTAssertEqual(vm.objectLoadError != nil, !failBucket)
            XCTAssertNotNil(vm.error)
            XCTAssertFalse(vm.isLoading)
        }
    }

    func testClearingSelectionCancelsDetailsAndObjectsWithoutCancellingBucketRefresh() async {
        let listGate = TestGate()
        let detailGate = TestGate()
        let objectGate = TestGate()
        let current = bucket("current")
        var listCancelled = false
        var detailCancelled = false
        var objectCancelled = false
        let vm = S3ViewModel(bucketLoader: {
            await listGate.wait()
            listCancelled = Task.isCancelled
            return []
        }, detailLoader: { bucket in
            await detailGate.wait()
            detailCancelled = Task.isCancelled
            return bucket
        }, objectLoader: { _, _, _ in
            await objectGate.wait()
            objectCancelled = Task.isCancelled
            return .init(objects: [self.object("late/file")])
        })
        vm.buckets = [current]
        vm.selectBucket(current)
        var waitingForDetails = false
        let details = Task {
            waitingForDetails = true
            await vm.waitForDetails()
        }
        while !waitingForDetails { await Task.yield() }
        await detailGate.waitForEntry()
        vm.refresh()
        await listGate.waitForEntry()
        let objects = Task { await vm.loadObjects(bucket: current.name) }
        await objectGate.waitForEntry()

        vm.clearBucketSelection()

        XCTAssertEqual(vm.buckets, [current])
        XCTAssertNil(vm.selectedBucket)
        XCTAssertTrue(vm.isBucketsLoading)
        XCTAssertFalse(vm.isObjectsLoading)
        XCTAssertTrue(vm.objects.isEmpty)
        await detailGate.open()
        await details.value
        await objectGate.open()
        await objects.value
        XCTAssertTrue(detailCancelled)
        XCTAssertTrue(objectCancelled)
        XCTAssertNil(vm.selectedBucket)
        XCTAssertTrue(vm.objects.isEmpty)
        await listGate.open()
        await vm.waitForCurrentLoad()
        XCTAssertFalse(listCancelled)
        XCTAssertFalse(vm.isLoading)
    }

    private func bucket(_ name: String) -> S3BucketModel {
        .init(name: name, region: nil, creationDate: nil, versioningEnabled: nil,
              encryptionEnabled: nil, publicAccessBlock: nil, tags: [:], detailError: nil)
    }

    private func object(_ key: String) -> S3ObjectModel {
        .init(key: key, size: nil, lastModified: nil, storageClass: nil, isPrefix: false)
    }

    private enum RefreshError: Error { case failed }
}
