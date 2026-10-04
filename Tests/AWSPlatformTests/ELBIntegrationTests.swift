import XCTest
@testable import AWSPlatform

@MainActor
final class ELBIntegrationTests: XCTestCase {
    private let profile = AWSProfile(name: "elb-work", region: "eu-west-1", ssoStartURL: nil,
                                     ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil)
    private let identity = AWSIdentity(account: "111122223333", arn: "arn:aws:iam::111122223333:user/test", userID: "test")
    private let paths = AWSConfigurationPaths(environment: [
        "AWS_CONFIG_FILE": "/example/elb-integration/config",
        "AWS_SHARED_CREDENTIALS_FILE": "/example/elb-integration/credentials"
    ])

    func testClientFollowsRegionWhileReusingTheSelectedProfilesAWSClient() async throws {
        let provider = AWSServiceProvider()
        let firstScope = makeScope()
        await provider.configure(profile: profile, region: firstScope.region, paths: paths)
        let first = try await provider.elbClient(scope: firstScope)
        let cost = try await provider.costExplorerClient(profile: profile, paths: paths, partition: .aws)
        XCTAssertEqual(first.config.region.rawValue, "eu-west-1")
        XCTAssertEqual(first.config.endpoint, "https://elasticloadbalancing.eu-west-1.amazonaws.com")

        let nextScope = makeScope(region: "ap-northeast-1")
        await provider.configure(profile: profile, region: nextScope.region, paths: paths)
        let next = try await provider.elbClient(scope: nextScope)
        XCTAssertTrue(first.client === next.client)
        XCTAssertTrue(cost.client === next.client)
        XCTAssertEqual(next.config.region.rawValue, "ap-northeast-1")
        XCTAssertEqual(next.config.endpoint, "https://elasticloadbalancing.ap-northeast-1.amazonaws.com")
        await assertClientRejected(provider, scope: firstScope)
        await provider.shutdown()
    }

    func testClientRejectsStaleProfilePathsRegionInvalidIdentityAndClearedProfile() async {
        let provider = AWSServiceProvider()
        await provider.configure(profile: profile, region: "eu-west-1", paths: paths)
        let other = AWSProfile(name: "elb-other", region: profile.region, ssoStartURL: nil,
                               ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil)
        let staleScopes = [
            makeScope(profile: other),
            makeScope(paths: AWSConfigurationPaths(environment: [
                "AWS_CONFIG_FILE": "/example/other/config", "AWS_SHARED_CREDENTIALS_FILE": paths.credentials
            ])),
            makeScope(paths: AWSConfigurationPaths(environment: [
                "AWS_CONFIG_FILE": paths.config, "AWS_SHARED_CREDENTIALS_FILE": "/example/other/credentials"
            ])),
            makeScope(region: "us-east-1"),
            makeScope(identity: AWSIdentity(account: "222222222222", arn: identity.arn, userID: "test")),
            makeScope(region: "global")
        ]
        for scope in staleScopes { await assertClientRejected(provider, scope: scope) }
        await provider.configure(profile: nil, region: "eu-west-1", paths: paths)
        await assertClientRejected(provider, scope: makeScope())
    }

    func testForcedRefreshAndChangedConfigurationReplaceSameNamedProfileClient() async throws {
        let provider = AWSServiceProvider()
        let scope = makeScope()
        await provider.configure(profile: profile, region: scope.region, paths: paths)
        let first = try await provider.elbClient(scope: scope)
        await provider.configure(profile: profile, region: scope.region, paths: paths)
        let reused = try await provider.elbClient(scope: scope)
        XCTAssertTrue(first.client === reused.client)
        await provider.configure(profile: profile, region: scope.region, forceRefresh: true, paths: paths)
        let refreshed = try await provider.elbClient(scope: scope)
        XCTAssertFalse(first.client === refreshed.client)

        let changed = AWSProfile(name: profile.name, region: "ap-northeast-1", ssoStartURL: nil,
                                 ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil)
        await provider.configure(profile: changed, region: scope.region, paths: paths)
        let changedClient = try await provider.elbClient(scope: makeScope(profile: changed))
        XCTAssertFalse(refreshed.client === changedClient.client)
        await assertClientRejected(provider, scope: scope)
        await provider.shutdown()
    }

    func testFavoritesAndRecentsOpenExactLoadBalancerARNAndResetFilters() async {
        let saved = savedResource(service: .loadBalancers)
        let expected = ELBLoadBalancer(arn: saved.resourceID, name: "renamed", kind: "application")
        let sameName = ELBLoadBalancer(arn: savedResource(service: .loadBalancers, suffix: "other").resourceID,
                                       name: saved.displayName, kind: "network")
        let vm = makeVM(loadBalancers: [sameName, expected])
        vm.configure(scope: makeScope())
        await vm.loadLoadBalancers()
        for source in [FavoriteNavigation.Source.favorite, .recent] {
            vm.selectedLoadBalancer = nil
            vm.searchText = "hidden"
            vm.kindFilter = "gateway"
            let nav = FavoriteNavigation()
            XCTAssertTrue(nav.begin(saved, profiles: [profile], selectedProfileName: profile.name, source: source))
            XCTAssertTrue(nav.verifyAccount(identity.account))
            resolve(nav, elb: vm)
            XCTAssertEqual(vm.selectedLoadBalancer, expected)
            XCTAssertEqual(vm.searchText, "")
            XCTAssertEqual(vm.kindFilter, "All")
            XCTAssertEqual(vm.filteredLoadBalancers, [sameName, expected])
            XCTAssertNil(nav.target)
            XCTAssertNil(nav.error)
            await vm.waitForDetails()
        }
    }

    func testFavoritesAndRecentsOpenExactTargetGroupARNAndResetFilters() async {
        let saved = savedResource(service: .targetGroups)
        let expected = ELBTargetGroup(arn: saved.resourceID, name: "renamed", targetType: "instance")
        let sameName = ELBTargetGroup(arn: savedResource(service: .targetGroups, suffix: "other").resourceID,
                                      name: saved.displayName, targetType: "ip")
        let vm = makeVM(groups: [sameName, expected])
        vm.configure(scope: makeScope())
        await vm.loadTargetGroups()
        for source in [FavoriteNavigation.Source.favorite, .recent] {
            vm.selectedTargetGroup = nil
            vm.groupSearchText = "hidden"
            vm.targetTypeFilter = "lambda"
            let nav = FavoriteNavigation()
            XCTAssertTrue(nav.begin(saved, profiles: [profile], selectedProfileName: profile.name, source: source))
            XCTAssertTrue(nav.verifyAccount(identity.account))
            resolve(nav, elb: vm)
            XCTAssertEqual(vm.selectedTargetGroup, expected)
            XCTAssertEqual(vm.groupSearchText, "")
            XCTAssertEqual(vm.targetTypeFilter, "All")
            XCTAssertEqual(vm.filteredTargetGroups, [sameName, expected])
            XCTAssertNil(nav.target)
            XCTAssertNil(nav.error)
            await vm.waitForDetails()
        }
    }

    func testMissingResourcesAndMissingViewModelNeverSelectAnotherDestination() async {
        let lb = ELBLoadBalancer(arn: savedResource(service: .loadBalancers, suffix: "other").resourceID,
                                 name: "other", kind: "application")
        let group = ELBTargetGroup(arn: savedResource(service: .targetGroups, suffix: "other").resourceID,
                                   name: "other", targetType: "instance")
        let vm = makeVM(loadBalancers: [lb], groups: [group])
        vm.configure(scope: makeScope())
        await vm.loadLoadBalancers()
        await vm.loadTargetGroups()
        for service in [AWSService.loadBalancers, .targetGroups] {
            for source in [FavoriteNavigation.Source.favorite, .recent] {
                for suppliedVM in [vm, nil] as [ELBViewModel?] {
                    vm.selectedLoadBalancer = suppliedVM == nil ? nil : lb
                    vm.selectedTargetGroup = suppliedVM == nil ? nil : group
                    await vm.waitForDetails()
                    let nav = FavoriteNavigation()
                    XCTAssertTrue(nav.begin(savedResource(service: service), profiles: [profile],
                                            selectedProfileName: profile.name, source: source))
                    XCTAssertTrue(nav.verifyAccount(identity.account))
                    resolve(nav, elb: suppliedVM)
                    if service == .loadBalancers { XCTAssertNil(vm.selectedLoadBalancer) }
                    else { XCTAssertNil(vm.selectedTargetGroup) }
                    XCTAssertNil(nav.target)
                    XCTAssertTrue(nav.error?.contains("not found") == true)
                    XCTAssertTrue(nav.error?.contains("\(source.noun) is still saved") == true)
                }
            }
        }
        vm.reset()
    }

    func testFailedRefreshAndPendingRetryNeverOpenCachedResourcesOrStartDetails() async throws {
        for service in [AWSService.loadBalancers, .targetGroups] {
            for source in [FavoriteNavigation.Source.favorite, .recent] {
                let saved = savedResource(service: service)
                let lb = ELBLoadBalancer(arn: savedResource(service: .loadBalancers).resourceID,
                                         name: "saved", kind: "application")
                let group = ELBTargetGroup(arn: savedResource(service: .targetGroups).resourceID,
                                           name: "saved", targetType: "instance")
                let probe = ELBIntegrationProbe(loadBalancer: lb, group: group)
                let vm = ELBViewModel(loadBalancerLoader: { _ in try await probe.loadLoadBalancers() },
                                     targetGroupLoader: { _ in try await probe.loadTargetGroups() },
                                     listenerLoader: { _, _ in await probe.loadListeners() },
                                     ruleLoader: { _, _ in [] }, healthLoader: { _, _ in await probe.loadHealth() })
                vm.configure(scope: makeScope())
                if service == .loadBalancers {
                    await vm.loadLoadBalancers()
                    vm.selectedLoadBalancer = lb
                } else {
                    await vm.loadTargetGroups()
                    vm.selectedTargetGroup = group
                }
                await vm.waitForDetails()
                let callsBefore = await probe.detailCallCount
                XCTAssertEqual(callsBefore, 1)
                if service == .loadBalancers { await vm.loadLoadBalancers() }
                else { await vm.loadTargetGroups() }
                let loadError = try XCTUnwrap(service == .loadBalancers ? vm.loadBalancersError : vm.targetGroupsError)
                XCTAssertTrue(service == .loadBalancers ? vm.isLoadBalancersStale : vm.isTargetGroupsStale)
                XCTAssertTrue(service == .loadBalancers ? vm.loadBalancers.contains(lb) : vm.targetGroups.contains(group))

                let nav = FavoriteNavigation()
                XCTAssertTrue(nav.begin(saved, profiles: [profile], selectedProfileName: profile.name, source: source))
                XCTAssertTrue(nav.verifyAccount(identity.account))
                resolve(nav, elb: vm)
                XCTAssertNil(vm.selectedLoadBalancer)
                XCTAssertNil(vm.selectedTargetGroup)
                XCTAssertEqual(nav.error, "Unable to open \(saved.displayName): \(loadError) The \(source.noun) is still saved.")

                if service == .loadBalancers { vm.refreshLoadBalancers() }
                else { vm.refreshTargetGroups() }
                XCTAssertNil(service == .loadBalancers ? vm.loadBalancersError : vm.targetGroupsError)
                XCTAssertTrue(service == .loadBalancers ? vm.isLoadBalancersStale : vm.isTargetGroupsStale)
                XCTAssertTrue(nav.begin(saved, profiles: [profile], selectedProfileName: profile.name, source: source))
                XCTAssertTrue(nav.verifyAccount(identity.account))
                resolve(nav, elb: vm)
                XCTAssertNil(vm.selectedLoadBalancer)
                XCTAssertNil(vm.selectedTargetGroup)
                XCTAssertNil(nav.target)
                XCTAssertNotNil(nav.error)
                vm.cancelLoadBalancers()
                vm.cancelTargetGroups()
                await vm.waitForDetails()
                let callsAfter = await probe.detailCallCount
                XCTAssertEqual(callsAfter, callsBefore)
                vm.reset()
            }
        }
    }

    func testSavedLoadBalancingResourcesRequireExplicitProfileAndMatchingAccountAndRegion() async {
        let lb = ELBLoadBalancer(arn: savedResource(service: .loadBalancers).resourceID,
                                 name: "saved", kind: "application")
        let group = ELBTargetGroup(arn: savedResource(service: .targetGroups).resourceID,
                                   name: "saved", targetType: "instance")
        let vm = makeVM(loadBalancers: [lb], groups: [group])
        vm.configure(scope: makeScope())
        await vm.loadLoadBalancers()
        await vm.loadTargetGroups()
        for service in [AWSService.loadBalancers, .targetGroups] {
            for source in [FavoriteNavigation.Source.favorite, .recent] {
                let saved = savedResource(service: service)
                let nav = FavoriteNavigation()
                for selectedProfile in [nil, "other"] as [String?] {
                    XCTAssertFalse(nav.begin(saved, profiles: [profile], selectedProfileName: selectedProfile, source: source))
                    XCTAssertNil(nav.target)
                }
                XCTAssertTrue(nav.begin(saved, profiles: [profile], selectedProfileName: profile.name, source: source))
                XCTAssertTrue(nav.matches(profileName: profile.name, region: saved.region))
                XCTAssertFalse(nav.matches(profileName: profile.name, region: "ap-northeast-1"))
                XCTAssertFalse(nav.matches(profileName: "other", region: saved.region))
                XCTAssertFalse(nav.verifyAccount("222222222222"))
                resolve(nav, elb: vm)
                XCTAssertNil(nav.target)
                XCTAssertNil(vm.selectedLoadBalancer)
                XCTAssertNil(vm.selectedTargetGroup)
                XCTAssertTrue(nav.error?.contains("It was not opened") == true)
            }
        }
    }

    func testBothServicesPersistAlongsideExistingServicesWithoutCrossScopeExposure() throws {
        let suite = "ELBIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let currentScope = RecentResourceScope(profileName: profile.name, accountID: identity.account)
        let otherProfileScope = RecentResourceScope(profileName: "elb-other", accountID: identity.account)
        let otherAccountScope = RecentResourceScope(profileName: profile.name, accountID: "222222222222")
        let legacy = AWSService.allCases.filter { $0 != .loadBalancers && $0 != .targetGroups }.map { service in
            ResourceFavorite(profileName: profile.name, accountID: identity.account,
                             region: service == .route53 ? "global" : "eu-west-1", service: service,
                             resourceID: service == .route53 ? "ZEXAMPLE" : "existing-\(service.rawValue)",
                             displayName: "Existing \(service.rawValue)")
        }
        var saved = legacy
        for service in [AWSService.loadBalancers, .targetGroups] {
            saved += [savedResource(service: service), savedResource(service: service, region: "ap-northeast-1"),
                      savedResource(service: service, profileName: otherProfileScope.profileName),
                      savedResource(service: service, accountID: otherAccountScope.accountID)]
        }
        let favorites = FavoritesViewModel(defaults: defaults)
        let recents = RecentResourcesViewModel(defaults: defaults)
        for resource in saved {
            favorites.toggle(resource)
            recents.recordVisit(resource, scope: RecentResourceScope(profileName: resource.profileName, accountID: resource.accountID))
        }
        let restoredFavorites = FavoritesViewModel(defaults: defaults)
        let restoredRecents = RecentResourcesViewModel(defaults: defaults)
        XCTAssertNil(restoredFavorites.storageError)
        XCTAssertNil(restoredRecents.storageError)
        XCTAssertEqual(Set(restoredFavorites.favorites.map(\.id)), Set(saved.map(\.id)))
        XCTAssertEqual(Set(restoredRecents.entries.map(\.resource.id)), Set(saved.map(\.id)))
        XCTAssertEqual(restoredRecents.entries(for: currentScope).count, legacy.count + 4)
        XCTAssertEqual(restoredRecents.entries(for: otherProfileScope).count, 2)
        XCTAssertEqual(restoredRecents.entries(for: otherAccountScope).count, 2)
        for service in [AWSService.loadBalancers, .targetGroups] {
            let resources = restoredRecents.entries(for: currentScope).map(\.resource).filter { $0.service == service }
            XCTAssertEqual(Set(resources.map(\.region)), ["eu-west-1", "ap-northeast-1"])
            XCTAssertEqual(Set(resources.map(\.id)).count, 2)
            XCTAssertTrue(resources.allSatisfy { $0.resourceID.contains(":\($0.region):\($0.accountID):") })
        }
        let originalFavorites = defaults.data(forKey: FavoritesViewModel.storageKey)
        restoredRecents.clear(scope: currentScope)
        XCTAssertTrue(restoredRecents.entries(for: currentScope).isEmpty)
        XCTAssertEqual(restoredRecents.entries.count, 4)
        XCTAssertEqual(defaults.data(forKey: FavoritesViewModel.storageKey), originalFavorites)
        XCTAssertEqual(Set(FavoritesViewModel(defaults: defaults).favorites.map(\.id)), Set(saved.map(\.id)))
        XCTAssertEqual(RecentResourcesViewModel(defaults: defaults).entries.count, 4)
    }

    private func makeScope(profile: AWSProfile? = nil, identity: AWSIdentity? = nil,
                           region: String = "eu-west-1", paths: AWSConfigurationPaths? = nil) -> MonitoringScope {
        MonitoringScope(profile: profile ?? self.profile, identity: identity ?? self.identity,
                        region: region, paths: paths ?? self.paths)
    }

    private func assertClientRejected(_ provider: AWSServiceProvider, scope: MonitoringScope,
                                      file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await provider.elbClient(scope: scope)
            XCTFail("An invalid or stale scope must not borrow an ELB client", file: file, line: line)
        } catch { XCTAssertEqual(error as? ELBError, .invalidScope, file: file, line: line) }
    }

    private func savedResource(service: AWSService, suffix: String = "saved", region: String = "eu-west-1",
                               profileName: String = "elb-work", accountID: String = "111122223333") -> ResourceFavorite {
        let path = service == .loadBalancers ? "loadbalancer/app/\(suffix)/0123456789abcdef" : "targetgroup/\(suffix)/0123456789abcdef"
        return ResourceFavorite(profileName: profileName, accountID: accountID, region: region, service: service,
                                resourceID: "arn:aws:elasticloadbalancing:\(region):\(accountID):\(path)", displayName: "Saved resource")
    }

    private func makeVM(loadBalancers: [ELBLoadBalancer] = [], groups: [ELBTargetGroup] = []) -> ELBViewModel {
        ELBViewModel(loadBalancerLoader: { _ in loadBalancers }, targetGroupLoader: { _ in groups },
                     listenerLoader: { _, _ in [] }, ruleLoader: { _, _ in [] }, healthLoader: { _, _ in [] })
    }

    private func resolve(_ nav: FavoriteNavigation, elb: ELBViewModel?) {
        nav.resolve(ec2: EC2ViewModel(), lambda: LambdaViewModel(), s3: S3ViewModel(),
                    alarms: AlarmViewModel(listLoader: { _ in [] }, tagLoader: { _, _ in [:] }, historyLoader: { _, _ in [] }),
                    sns: SNSViewModel(listLoader: { _ in [] }, attributeLoader: { _, _ in [:] },
                                      tagLoader: { _, _ in [:] }, subscriptionLoader: { _, _ in [] }), elb: elb)
    }
}

private actor ELBIntegrationProbe {
    private let loadBalancer: ELBLoadBalancer
    private let group: ELBTargetGroup
    private var loadBalancerCalls = 0
    private var targetGroupCalls = 0
    private(set) var detailCallCount = 0

    init(loadBalancer: ELBLoadBalancer, group: ELBTargetGroup) {
        self.loadBalancer = loadBalancer
        self.group = group
    }

    func loadLoadBalancers() throws -> [ELBLoadBalancer] {
        loadBalancerCalls += 1
        guard loadBalancerCalls == 1 else { throw ELBError.invalidResponse }
        return [loadBalancer]
    }

    func loadTargetGroups() throws -> [ELBTargetGroup] {
        targetGroupCalls += 1
        guard targetGroupCalls == 1 else { throw ELBError.invalidResponse }
        return [group]
    }

    func loadListeners() -> [ELBListener] {
        detailCallCount += 1
        return []
    }

    func loadHealth() -> [ELBTargetHealth] {
        detailCallCount += 1
        return []
    }
}
