import XCTest
@testable import AWSPlatform

@MainActor
final class Route53IntegrationTests: XCTestCase {
    private let profile = AWSProfile(name: "work", region: "eu-west-1", ssoStartURL: nil,
                                     ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil)
    private let identity = AWSIdentity(account: "111122223333", arn: "arn:aws:iam::111122223333:user/test", userID: "test")

    func testGlobalClientSurvivesResourceRegionChangeAndUsesPartitionEndpoints() async throws {
        let provider = AWSServiceProvider()
        let paths = AWSConfigurationPaths(environment: [:])
        for (partition, endpoint, signingRegion) in [
            ("aws", "https://route53.amazonaws.com", "us-east-1"),
            ("aws-cn", "https://route53.amazonaws.com.cn", "cn-northwest-1"),
            ("aws-us-gov", "https://route53.us-gov.amazonaws.com", "us-gov-west-1")
        ] {
            let scope = Route53Scope(profile: profile, identity: AWSIdentity(account: identity.account,
                arn: "arn:\(partition):iam::111122223333:user/test", userID: "test"), paths: paths)
            await provider.configure(profile: profile, region: "eu-west-1", paths: paths)
            let first = try await provider.route53Client(scope: scope)
            await provider.configure(profile: profile, region: "ap-northeast-1", paths: paths)
            let second = try await provider.route53Client(scope: scope)
            XCTAssertTrue(first.client === second.client)
            XCTAssertEqual(second.config.endpoint, endpoint)
            XCTAssertEqual(second.config.region.rawValue, signingRegion)
        }
        await provider.shutdown()
    }

    func testClientRejectsStaleProfilePathsInvalidIdentityAndClearedProfile() async throws {
        let provider = AWSServiceProvider()
        let paths = AWSConfigurationPaths(environment: [:])
        await provider.configure(profile: profile, region: "eu-west-1", paths: paths)
        let other = AWSProfile(name: "other", region: profile.region, ssoStartURL: nil,
                               ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil)
        let invalidScopes = [
            Route53Scope(profile: other, identity: identity, paths: paths),
            Route53Scope(profile: profile, identity: identity, paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/example/other"])),
            Route53Scope(profile: profile, identity: AWSIdentity(account: "222222222222", arn: identity.arn, userID: "test"), paths: paths)
        ]
        for scope in invalidScopes {
            do { _ = try await provider.route53Client(scope: scope); XCTFail("Invalid scope must not borrow a client") }
            catch { XCTAssertEqual(error as? Route53Error, .invalidScope) }
        }
        await provider.configure(profile: nil, region: "eu-west-1", paths: paths)
        do {
            _ = try await provider.route53Client(scope: Route53Scope(profile: profile, identity: identity, paths: paths))
            XCTFail("No Profile must mean no client")
        } catch { XCTAssertEqual(error as? Route53Error, .invalidScope) }
    }

    func testSavedZoneRequiresCanonicalGlobalIdentity() {
        XCTAssertTrue(savedZone().isValid)
        XCTAssertFalse(savedZone(region: "us-east-1").isValid)
        XCTAssertFalse(savedZone(id: "/hostedzone/ZEXAMPLE").isValid)
        XCTAssertFalse(savedZone(id: "../invalid").isValid)
        XCTAssertEqual(Route53HostedZone.normalizedID("/hostedzone/ZEXAMPLE"), "ZEXAMPLE")
    }

    func testSavedZoneMatchesAnyResourceRegionButNeverAnotherProfileOrAccount() {
        let nav = FavoriteNavigation()
        XCTAssertFalse(nav.begin(savedZone(), profiles: [profile], selectedProfileName: nil))
        XCTAssertTrue(nav.begin(savedZone(), profiles: [profile], selectedProfileName: "work"))
        XCTAssertTrue(nav.matches(profileName: "work", region: "eu-west-1"))
        XCTAssertTrue(nav.matches(profileName: "work", region: "ap-northeast-1"))
        XCTAssertFalse(nav.matches(profileName: "other", region: "eu-west-1"))
        XCTAssertFalse(nav.verifyAccount("222222222222"))
        XCTAssertNil(nav.target)
    }

    func testFavoriteAndRecentOpenExactZoneAndClearFilters() async {
        let zone = Route53HostedZone(id: "ZEXAMPLE", name: "example.test.", isPrivate: false)
        let vm = makeVM(zones: [zone])
        vm.configure(scope: Route53Scope(profile: profile, identity: identity))
        await vm.loadZones()
        for source in [FavoriteNavigation.Source.favorite, .recent] {
            vm.searchText = "hidden"
            vm.privateFilter = true
            let nav = FavoriteNavigation()
            XCTAssertTrue(nav.begin(savedZone(), profiles: [profile], selectedProfileName: "work", source: source))
            XCTAssertTrue(nav.verifyAccount(identity.account))
            resolve(nav, route53: vm)
            XCTAssertEqual(vm.selectedZone, zone)
            XCTAssertEqual(vm.filteredZones, [zone])
            XCTAssertNil(nav.target)
            XCTAssertNil(nav.error)
            await vm.waitForDetails()
        }
    }

    func testMissingZoneDoesNotSelectAnotherAndKeepsSavedEntry() async throws {
        let zone = Route53HostedZone(id: "ZOTHER", name: "other.test.", isPrivate: true)
        let vm = makeVM(zones: [zone])
        vm.configure(scope: Route53Scope(profile: profile, identity: identity))
        await vm.loadZones()
        vm.selectedZone = zone
        let nav = FavoriteNavigation()
        XCTAssertTrue(nav.begin(savedZone(), profiles: [profile], selectedProfileName: "work", source: .recent))
        resolve(nav, route53: vm)
        XCTAssertNil(vm.selectedZone)
        XCTAssertNil(nav.target)
        XCTAssertTrue(nav.error?.contains("recent resource is still saved") == true)
        await vm.waitForDetails()
    }

    func testFailedRefreshDoesNotOpenCachedZoneAndClearsSelectionForFavoriteAndRecent() async throws {
        let zone = Route53HostedZone(id: "ZEXAMPLE", name: "example.test.", isPrivate: false)
        for source in [FavoriteNavigation.Source.favorite, .recent] {
            for initiallySelected in [false, true] {
                let probe = Route53NavigationProbe(zone: zone)
                let vm = Route53ViewModel(listLoader: { _ in try await probe.loadZones() },
                                         detailLoader: { _, zone in await probe.loadDetails(zone) },
                                         recordLoader: { _, _ in [] }, tagLoader: { _, _ in [:] })
                vm.configure(scope: Route53Scope(profile: profile, identity: identity))
                await vm.loadZones()
                XCTAssertEqual(vm.zones, [zone])
                if initiallySelected {
                    vm.selectedZone = zone
                    await vm.waitForDetails()
                }
                let detailCallsBeforeNavigation = await probe.detailCallCount
                XCTAssertEqual(detailCallsBeforeNavigation, initiallySelected ? 1 : 0)

                vm.refresh()
                await vm.waitForCurrentLoad()
                let loadError = try XCTUnwrap(vm.error)
                XCTAssertTrue(vm.isListStale)
                XCTAssertEqual(vm.zones, [zone], "A failed refresh retains the last complete list")
                let nav = FavoriteNavigation()
                XCTAssertTrue(nav.begin(savedZone(), profiles: [profile], selectedProfileName: "work", source: source))
                XCTAssertTrue(nav.verifyAccount(identity.account))
                resolve(nav, route53: vm)
                await vm.waitForDetails()

                XCTAssertNil(vm.selectedZone, "A failed navigation must not select a cached zone")
                XCTAssertNil(vm.details)
                XCTAssertEqual(vm.error, loadError)
                XCTAssertNil(nav.target)
                XCTAssertEqual(nav.error, "Unable to open example.test.: \(loadError) The \(source.noun) is still saved.")
                let detailCallsAfterNavigation = await probe.detailCallCount
                XCTAssertEqual(detailCallsAfterNavigation, detailCallsBeforeNavigation,
                               "A failed navigation must not issue another detail request")
            }
        }
    }

    func testMissingRoute53ViewModelDoesNotOpenSavedZone() {
        let nav = FavoriteNavigation()
        XCTAssertTrue(nav.begin(savedZone(), profiles: [profile], selectedProfileName: "work", source: .recent))
        resolve(nav, route53: nil)
        XCTAssertNil(nav.target)
        XCTAssertTrue(nav.error?.contains("recent resource is still saved") == true)
    }

    func testZoneHistoryAndFavoritesPersistWithoutCrossAccountExposure() throws {
        let suite = "Route53IntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scope = RecentResourceScope(profileName: profile.name, accountID: identity.account)
        let saved = savedZone()
        let favorites = FavoritesViewModel(defaults: defaults)
        let recents = RecentResourcesViewModel(defaults: defaults)
        favorites.toggle(saved)
        recents.recordVisit(saved, scope: scope)
        recents.recordVisit(saved, scope: scope)
        XCTAssertEqual(recents.entries.count, 1)
        XCTAssertEqual(recents.entries.first?.resource.region, "global")
        XCTAssertEqual(RecentResourcesViewModel(defaults: defaults).entries(for: scope).map(\.resource), [saved])
        XCTAssertTrue(recents.entries(for: RecentResourceScope(profileName: profile.name, accountID: "222222222222")).isEmpty)
        XCTAssertEqual(FavoritesViewModel(defaults: defaults).favorites, [saved])
    }

    private func savedZone(id: String = "ZEXAMPLE", region: String = "global") -> ResourceFavorite {
        ResourceFavorite(profileName: profile.name, accountID: identity.account, region: region,
                         service: .route53, resourceID: id, displayName: "example.test.")
    }

    private func makeVM(zones: [Route53HostedZone]) -> Route53ViewModel {
        Route53ViewModel(listLoader: { _ in zones },
                         detailLoader: { _, zone in Route53ZoneDetails(zone: zone, callerReference: "test") },
                         recordLoader: { _, _ in [] }, tagLoader: { _, _ in [:] })
    }

    private func resolve(_ nav: FavoriteNavigation, route53: Route53ViewModel?) {
        nav.resolve(ec2: EC2ViewModel(), lambda: LambdaViewModel(), s3: S3ViewModel(),
                    alarms: AlarmViewModel(listLoader: { _ in [] }, tagLoader: { _, _ in [:] }, historyLoader: { _, _ in [] }),
                    sns: SNSViewModel(listLoader: { _ in [] }, attributeLoader: { _, _ in [:] },
                                      tagLoader: { _, _ in [:] }, subscriptionLoader: { _, _ in [] }), route53: route53)
    }
}

private actor Route53NavigationProbe {
    private let zone: Route53HostedZone
    private var listCallCount = 0
    private(set) var detailCallCount = 0

    init(zone: Route53HostedZone) {
        self.zone = zone
    }

    func loadZones() throws -> [Route53HostedZone] {
        listCallCount += 1
        guard listCallCount == 1 else { throw AWSRoute53Service.RequestError.network }
        return [zone]
    }

    func loadDetails(_ zone: Route53HostedZone) -> Route53ZoneDetails {
        detailCallCount += 1
        return Route53ZoneDetails(zone: zone, callerReference: "test")
    }
}
