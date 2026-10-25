import Foundation
import XCTest
@testable import AWSPlatform

@MainActor
final class S3VersionsViewModelTests: XCTestCase {
    func testConfigureIsManualAndLoadRequiresContextAndKey() async {
        let fixture = S3VersionsFixture()
        let service = fixture.service
        let vm = S3VersionsViewModel(resolver: { try await service.resolve(context: $0, key: $1) },
                                    loader: { try await service.load(target: $0, cursor: $1) })
        vm.load()
        vm.configure(context: versionsContext(), key: "reports/summary.csv")
        await vm.waitForLoading()
        let before = await fixture.inputs.count
        XCTAssertEqual(before, 0)
        XCTAssertFalse(vm.hasLoaded)
        vm.load()
        await vm.waitForLoading()
        XCTAssertTrue(vm.hasLoaded)
        XCTAssertTrue(vm.versions.isEmpty)
        let after = await fixture.inputs.count
        XCTAssertEqual(after, 1)
    }

    func testLoadMoreUsesFixedRegionAndCursorWithoutResolvingAgain() async {
        let fixture = S3VersionsFixture(pages: [
            .init(isTruncated: true, name: "example-bucket", nextKeyMarker: "reports/summary.csv", nextVersionIdMarker: "v1", prefix: "reports/summary.csv"),
            .init(isTruncated: false, keyMarker: "reports/summary.csv", name: "example-bucket", prefix: "reports/summary.csv",
                  versionIdMarker: "v1", versions: [
                .init(key: "reports/summary.csv", versionId: "v1")
            ])
        ])
        let service = fixture.service
        let vm = S3VersionsViewModel(resolver: { try await service.resolve(context: $0, key: $1) },
                                    loader: { try await service.load(target: $0, cursor: $1) })
        vm.configure(context: versionsContext(region: nil), key: "reports/summary.csv")
        vm.load()
        await vm.waitForLoading()
        XCTAssertTrue(vm.hasMore)
        vm.loadMore()
        await vm.waitForLoading()
        XCTAssertEqual(vm.versions.map(\.versionID), ["v1"])
        XCTAssertFalse(vm.hasMore)
        let resolutions = await fixture.regionContexts.count
        XCTAssertEqual(resolutions, 1)
        let targets = await fixture.targets
        XCTAssertEqual(targets.map(\.region), ["eu-west-1", "eu-west-1"])
    }

    func testSecondPageFailureKeepsFirstPageAndIncompleteState() async {
        let target = versionsTarget()
        let vm = S3VersionsViewModel(resolver: { _, _ in target }, loader: { target, cursor in
            if cursor != nil { throw LogsVersionsFixtureError("AccessDenied") }
            return .init(target: target, versions: [fixtureObjectVersion("v1")], cursor: cursorFor(target))
        })
        vm.configure(context: target.context, key: target.key)
        vm.load(); await vm.waitForLoading()
        vm.loadMore(); await vm.waitForLoading()
        XCTAssertEqual(vm.versions.map(\.versionID), ["v1"])
        XCTAssertTrue(vm.hasMore)
        XCTAssertNotNil(vm.error)
        XCTAssertFalse(vm.error!.contains("private-test-content"))
    }

    func testScopeKeyBucketPrefixAndRegionChangesClearVersions() async {
        let vm = makeVM()
        let original = versionsContext()
        vm.configure(context: original, key: "reports/summary.csv")
        vm.load(); await vm.waitForLoading()
        XCTAssertFalse(vm.versions.isEmpty)
        let contexts = [versionsContext(scope: logsVersionsScope(profile: "other")),
                        versionsContext(scope: logsVersionsScope(role: "Other")),
                        versionsContext(scope: logsVersionsScope(configPath: "/other/config")),
                        versionsContext(region: "us-east-1"),
                        S3TransferContext(scope: original.scope, bucket: "other-bucket", prefix: "reports/", knownRegion: "eu-west-1"),
                        S3TransferContext(scope: original.scope, bucket: original.bucket, prefix: "", knownRegion: "eu-west-1")]
        for context in contexts {
            vm.configure(context: context, key: "reports/summary.csv")
            XCTAssertTrue(vm.versions.isEmpty)
            XCTAssertFalse(vm.hasMore)
            XCTAssertFalse(vm.hasLoaded)
        }
        vm.configure(context: original, key: "reports/different.csv")
        XCTAssertTrue(vm.versions.isEmpty)
        vm.reset()
        XCTAssertNil(vm.context)
        XCTAssertNil(vm.key)
    }

    func testLateSuccessAndFailureCannotReappearAfterObjectChange() async {
        for failure in [false, true] {
            let gate = LogsVersionsGate()
            let target = versionsTarget()
            let vm = S3VersionsViewModel(resolver: { _, _ in target }, loader: { target, _ in
                await gate.enter()
                if failure { throw LogsVersionsFixtureError("AccessDenied") }
                return .init(target: target, versions: [fixtureObjectVersion("old")], cursor: nil)
            })
            vm.configure(context: target.context, key: target.key)
            vm.load()
            await gate.waitForEntry()
            vm.configure(context: target.context, key: "reports/new.csv")
            await gate.open()
            for _ in 0..<10 { await Task.yield() }
            XCTAssertTrue(vm.versions.isEmpty)
            XCTAssertNil(vm.error)
            XCTAssertFalse(vm.isLoading)
        }
    }

    func testCancelledRegionResolutionCannotStartVersionRequest() async {
        let gate = LogsVersionsGate()
        let fixture = S3VersionsFixture()
        let service = fixture.service
        let vm = S3VersionsViewModel(resolver: { context, key in
            await gate.enter()
            return versionsTarget(context: context, key: key)
        }, loader: { try await service.load(target: $0, cursor: $1) })
        vm.configure(context: versionsContext(), key: "reports/summary.csv")
        vm.load()
        await gate.waitForEntry()
        vm.cancelLoading()
        await gate.open()
        for _ in 0..<10 { await Task.yield() }
        let count = await fixture.inputs.count
        XCTAssertEqual(count, 0)
        XCTAssertNotNil(vm.error)
        XCTAssertFalse(vm.isLoading)
    }

    func testMismatchedResolvedTargetAndPageNeverDisplay() async {
        let original = versionsTarget()
        let foreign = versionsTarget(context: versionsContext(scope: logsVersionsScope(account: "444455556666")))
        for badResolver in [true, false] {
            let vm = S3VersionsViewModel(resolver: { _, _ in badResolver ? foreign : original },
                loader: { _, _ in .init(target: foreign, versions: [fixtureObjectVersion("foreign")], cursor: nil) })
            vm.configure(context: original.context, key: original.key)
            vm.load(); await vm.waitForLoading()
            XCTAssertTrue(vm.versions.isEmpty)
            XCTAssertNotNil(vm.error)
        }
    }

    func testLocalSearchUsesOnlyLoadedVersionMetadata() async {
        let vm = makeVM()
        vm.configure(context: versionsContext(), key: "reports/summary.csv")
        vm.load(); await vm.waitForLoading()
        vm.searchText = "V1"
        XCTAssertEqual(vm.filteredVersions.map(\.versionID), ["v1"])
        vm.searchText = "not-loaded"
        XCTAssertTrue(vm.filteredVersions.isEmpty)
        XCTAssertEqual(vm.versions.count, 1)
    }

    private func makeVM() -> S3VersionsViewModel {
        S3VersionsViewModel(resolver: { versionsTarget(context: $0, key: $1) },
                            loader: { target, _ in .init(target: target, versions: [fixtureObjectVersion("v1")], cursor: nil) })
    }
}

private func fixtureObjectVersion(_ id: String) -> S3ObjectVersion {
    .init(versionID: id, kind: .version, isLatest: nil, lastModified: nil, size: nil, eTag: nil, storageClass: nil)
}

private func cursorFor(_ target: S3VersionsTarget) -> S3VersionsCursor {
    let marker = S3VersionsMarker(key: target.key, versionID: "next")
    return .init(target: target, marker: marker, seenMarkers: [marker], pagesRead: 1)
}
