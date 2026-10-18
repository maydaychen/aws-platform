import XCTest
@testable import AWSPlatform

@MainActor
final class EBSNavigationTests: XCTestCase {
    func testEC2GroupContainsEachServiceExactlyOnceWithoutChangingStoredEC2Key() {
        XCTAssertEqual(AWSService.ec2Services, [.ec2, .autoScaling, .ebsVolumes, .ebsSnapshots, .loadBalancers, .targetGroups, .securityGroups])
        XCTAssertEqual(Set(AWSService.ec2Services + AWSService.standaloneServices), Set(AWSService.allCases))
        XCTAssertEqual(AWSService.ec2Services.count + AWSService.standaloneServices.count, AWSService.allCases.count)
        XCTAssertEqual(AWSService.ec2.rawValue, "EC2")
        XCTAssertEqual(AWSService.ec2.sidebarTitle, "Instances")
    }

    func testNewFavoritesRoundTripAndRejectInvalidResourceIDs() throws {
        for kind in [EBSResource.Kind.volume, .snapshot] {
            let resource = favorite(kind)
            XCTAssertTrue(resource.isValid)
            XCTAssertEqual(try JSONDecoder().decode(ResourceFavorite.self, from: JSONEncoder().encode(resource)), resource)
            XCTAssertFalse(favorite(kind, id: "i-wrong-kind").isValid)
        }
    }

    func testFavoritesRequireManualProfileAndResolveExactVolumeAndSnapshot() async {
        for kind in [EBSResource.Kind.volume, .snapshot] {
            let scope = ebsScope()
            let vm = EBSViewModel(kind: kind) { _, _ in [ebsRow(kind), ebsRow(kind, id: kind == .volume ? "vol-87654321" : "snap-87654321")] }
            vm.configure(scope: scope); await vm.loadResources()
            vm.searchText = "hidden"; vm.stateFilter = "hidden"
            let navigation = FavoriteNavigation()
            XCTAssertFalse(navigation.begin(favorite(kind), profiles: [scope.profile], selectedProfileName: nil))
            XCTAssertNil(navigation.target)
            XCTAssertTrue(navigation.begin(favorite(kind), profiles: [scope.profile], selectedProfileName: scope.profile.name, source: .recent))
            XCTAssertTrue(navigation.verifyAccount(scope.accountID))
            resolve(navigation, kind: kind, vm: vm)
            XCTAssertEqual(vm.selectedResource?.id, ebsRow(kind).id)
            XCTAssertEqual(vm.searchText, "")
            XCTAssertEqual(vm.stateFilter, "All")
            XCTAssertNil(navigation.error)
        }
    }

    func testWrongScopeOrMissingResourceNeverSelectsSubstitute() async {
        for scope in [ebsScope(region: "eu-west-1"), ebsScope(profile: "different"), ebsScope(account: "444455556666"), ebsScope()] {
            let vm = EBSViewModel(kind: .volume) { _, _ in [ebsRow(id: "vol-87654321", account: scope.accountID)] }
            vm.configure(scope: scope); await vm.loadResources()
            let navigation = FavoriteNavigation()
            XCTAssertTrue(navigation.begin(favorite(.volume), profiles: [ebsScope().profile], selectedProfileName: ebsScope().profile.name))
            resolve(navigation, kind: .volume, vm: vm)
            XCTAssertNil(vm.selectedResource)
            XCTAssertNotNil(navigation.error)
        }
    }

    func testEBSMessagesAndNavigationTitlesAreLocalized() {
        let errors: [EBSError] = [.invalidScope, .invalidResponse, .pagination, .volumesPermission, .snapshotsPermission,
                                 .credentials, .network, .throttled, .failed, .cancelled]
        for key in errors.map(\.rawValue) + AWSService.ec2Services.map(\.sidebarTitle) {
            XCTAssertNotEqual(L10n.text(key, locale: Locale(identifier: "zh-Hans")), key, key)
        }
    }

    private func favorite(_ kind: EBSResource.Kind, id: String? = nil) -> ResourceFavorite {
        ResourceFavorite(profileName: ebsScope().profile.name, accountID: ebsScope().accountID, region: ebsScope().region,
                         service: kind.service, resourceID: id ?? ebsRow(kind).id, displayName: "offline")
    }

    private func resolve(_ navigation: FavoriteNavigation, kind: EBSResource.Kind, vm: EBSViewModel) {
        navigation.resolve(ec2: EC2ViewModel(), lambda: LambdaViewModel(), s3: S3ViewModel(),
                           alarms: AlarmViewModel(listLoader: { _ in [] }, tagLoader: { _, _ in [:] }, historyLoader: { _, _ in [] }),
                           sns: SNSViewModel(listLoader: { _ in [] }, attributeLoader: { _, _ in [:] }, tagLoader: { _, _ in [:] }, subscriptionLoader: { _, _ in [] }),
                           volumes: kind == .volume ? vm : nil, snapshots: kind == .snapshot ? vm : nil)
    }
}
