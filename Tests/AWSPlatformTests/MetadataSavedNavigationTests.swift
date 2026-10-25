import XCTest
@testable import AWSPlatform

@MainActor
final class MetadataSavedNavigationTests: XCTestCase {
    func testFavoritesAndRecentsRequireManualProfileForEveryMetadataService() {
        let scope = rdsStateScope()
        for service in [AWSService.codeCommit, .rds, .autoScaling] {
            for source in [FavoriteNavigation.Source.favorite, .recent] {
                let nav = FavoriteNavigation()
                let saved = favorite(service, id: "stable-resource")
                XCTAssertFalse(nav.begin(saved, profiles: [scope.profile], selectedProfileName: nil, source: source))
                XCTAssertNil(nav.target)
                XCTAssertTrue(nav.error?.contains("No profile was selected automatically") == true)
                XCTAssertFalse(nav.begin(saved, profiles: [], selectedProfileName: scope.profile.name, source: source))
                XCTAssertNil(nav.target)
            }
        }
    }

    func testCodeCommitFavoritesAndRecentsResolveStableIDAfterRenameAndClearFilter() async {
        let repository = CodeCommitRepository(id: "11111111-1111-4111-8111-111111111111", name: "renamed")
        let substitute = CodeCommitRepository(id: "22222222-2222-4222-8222-222222222222", name: "old-name")
        let vm = codeCommit(rows: [substitute, repository])
        vm.configure(scope: rdsStateScope()); vm.loadIfNeeded(); await vm.waitForLoading()
        for source in [FavoriteNavigation.Source.favorite, .recent] {
            vm.searchText = "hidden"
            vm.selectedRepository = substitute
            let nav = begin(.codeCommit, id: repository.id, source: source)
            resolve(nav, codeCommit: vm)
            await vm.waitForDetails()
            XCTAssertEqual(vm.selectedRepository, repository)
            XCTAssertEqual(vm.searchText, "")
            XCTAssertNil(nav.target)
            XCTAssertNil(nav.error)
        }
        vm.reset()
    }

    func testCodeCommitNeverFallsBackToOldNameOrDifferentUUID() async {
        let vm = codeCommit(rows: [.init(id: "replacement-id", name: "old-name")])
        vm.configure(scope: rdsStateScope()); vm.loadIfNeeded(); await vm.waitForLoading()
        vm.selectedRepository = vm.repositories[0]
        let nav = begin(.codeCommit, id: "deleted-repository-id")
        resolve(nav, codeCommit: vm)
        XCTAssertNil(vm.selectedRepository)
        XCTAssertTrue(nav.error?.contains("was not found") == true)
        vm.reset()
    }

    func testRDSFavoritesAndRecentsSelectExactKindARNAndClearFilters() async {
        let instance = rdsStateDatabase("same-name")
        let cluster = rdsStateDatabase("same-name", kind: .cluster)
        let vm = rds(instances: [instance], clusters: [cluster])
        vm.configure(scope: rdsStateScope()); vm.loadIfNeeded(); await vm.waitForLoading()
        for source in [FavoriteNavigation.Source.favorite, .recent] {
            for resource in [instance, cluster] {
                vm.searchText = "hidden"
                vm.kindFilter = resource.kind == .instance ? .cluster : .instance
                let nav = begin(.rds, id: resource.arn, source: source)
                resolve(nav, rds: vm)
                XCTAssertEqual(vm.selectedDatabase, resource)
                XCTAssertEqual(vm.searchText, "")
                XCTAssertNil(vm.kindFilter)
                XCTAssertNil(nav.error)
            }
        }
    }

    func testRDSOtherCategoryFailureDoesNotBlockLoadedFavorite() async {
        for kind in [RDSResourceKind.instance, .cluster] {
            let row = rdsStateDatabase("target", kind: kind)
            let vm = RDSViewModel(instanceLoader: { _ in
                if kind == .cluster { throw RDSError.invalidResponse }
                return [row]
            }, clusterLoader: { _ in
                if kind == .instance { throw RDSError.invalidResponse }
                return [row]
            })
            vm.configure(scope: rdsStateScope()); vm.loadIfNeeded(); await vm.waitForLoading()
            XCTAssertNotNil(vm.error)
            let nav = begin(.rds, id: row.arn)
            resolve(nav, rds: vm)
            XCTAssertEqual(vm.selectedDatabase, row)
            XCTAssertNil(nav.error)
        }
    }

    func testRDSMatchingCategoryFailureClearsPriorSelectionAndCannotOpen() async {
        for kind in [RDSResourceKind.instance, .cluster] {
            let other = rdsStateDatabase("available", kind: kind == .instance ? .cluster : .instance)
            let vm = RDSViewModel(instanceLoader: { _ in
                if kind == .instance { throw RDSError.invalidResponse }
                return [other]
            }, clusterLoader: { _ in
                if kind == .cluster { throw RDSError.invalidResponse }
                return [other]
            })
            vm.configure(scope: rdsStateScope()); vm.loadIfNeeded(); await vm.waitForLoading()
            vm.selectedDatabase = other
            let nav = begin(.rds, id: rdsStateDatabase("failed", kind: kind).arn)
            resolve(nav, rds: vm)
            XCTAssertNil(vm.selectedDatabase)
            XCTAssertNotNil(nav.error)
            XCTAssertFalse(nav.error?.contains("was not found") == true)
        }
    }

    func testRDSOtherCategoryLoadingDoesNotBlockButMatchingCategoryLoadingDoes() async {
        let gate = TestGate()
        let instance = rdsStateDatabase("loaded")
        let cluster = rdsStateDatabase("pending", kind: .cluster)
        let vm = RDSViewModel(instanceLoader: { _ in [instance] }, clusterLoader: { _ in
            await gate.wait()
            return [cluster]
        })
        vm.configure(scope: rdsStateScope()); vm.loadIfNeeded()
        await gate.waitForEntry()
        for _ in 0..<100 where vm.isInstancesLoading { await Task.yield() }
        XCTAssertFalse(vm.isInstancesLoading)
        XCTAssertTrue(vm.isClustersLoading)
        let instanceNavigation = begin(.rds, id: instance.arn)
        resolve(instanceNavigation, rds: vm)
        XCTAssertEqual(vm.selectedDatabase, instance)
        XCTAssertNil(instanceNavigation.error)
        let clusterNavigation = begin(.rds, id: cluster.arn)
        resolve(clusterNavigation, rds: vm)
        XCTAssertNil(vm.selectedDatabase)
        XCTAssertTrue(clusterNavigation.error?.contains("not ready") == true)
        await gate.open(); await vm.waitForLoading()
    }

    func testASGFavoritesAndRecentsUseExactARNAndClearSearch() async {
        let target = asgStateGroup("same-name")
        let other = asgStateGroup("another-group", token: "22222222-2222-4222-8222-222222222222")
        let vm = autoScaling(rows: [other, target])
        vm.configure(scope: rdsStateScope()); vm.loadIfNeeded(); await vm.waitForLoading()
        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.groups.count, 2)
        for source in [FavoriteNavigation.Source.favorite, .recent] {
            vm.searchText = "hidden"
            vm.selectedGroup = other
            let nav = begin(.autoScaling, id: target.arn, source: source)
            resolve(nav, autoScaling: vm)
            await vm.waitForDetails()
            XCTAssertEqual(vm.selectedGroup, target)
            XCTAssertEqual(vm.searchText, "")
            XCTAssertNil(nav.error)
        }
        vm.reset()
    }

    func testASGNeverUsesSameNameReplacementWhenSavedARNWasRemoved() async {
        let removed = asgStateGroup("same-name")
        let replacement = asgStateGroup("same-name", token: "22222222-2222-4222-8222-222222222222")
        let vm = autoScaling(rows: [replacement])
        vm.configure(scope: rdsStateScope()); vm.loadIfNeeded(); await vm.waitForLoading()
        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.groups, [replacement])
        XCTAssertEqual(removed.name, replacement.name)
        XCTAssertNotEqual(removed.arn, replacement.arn)
        for source in [FavoriteNavigation.Source.favorite, .recent] {
            vm.selectedGroup = replacement
            vm.searchText = "hidden"
            let nav = begin(.autoScaling, id: removed.arn, source: source)
            resolve(nav, autoScaling: vm)
            XCTAssertNil(vm.selectedGroup)
            XCTAssertEqual(vm.searchText, "")
            XCTAssertTrue(nav.error?.contains("was not found") == true)
        }
        vm.reset()
    }

    func testSavedMetadataRejectsDifferentSavedProfileAccountAndRegion() async {
        for scope in [rdsStateScope(profile: "other"), rdsStateScope(account: "444455556666"),
                      rdsStateScope(region: "eu-west-1")] {
            await assertAllNotReady(vmScope: scope, currentScope: scope)
        }
    }

    func testSavedMetadataRejectsMissingCurrentScopeRoleOrEitherConfigurationPathChange() async {
        let paths = AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/example/changed-config"])
        let credentials = AWSConfigurationPaths(environment: ["AWS_SHARED_CREDENTIALS_FILE": "/example/changed-credentials"])
        for current in [nil, rdsStateScope(role: "OtherRole"), rdsStateScope(paths: paths),
                        rdsStateScope(paths: credentials), rdsStateScope(region: "eu-west-1")] {
            await assertAllNotReady(vmScope: rdsStateScope(), currentScope: current)
        }
    }

    func testMetadataListFailureReportsLoadErrorAndNeverSelectsResource() async {
        let cc = codeCommit(rows: [], fail: true)
        let asg = autoScaling(rows: [], fail: true)
        cc.configure(scope: rdsStateScope()); cc.loadIfNeeded(); await cc.waitForLoading()
        asg.configure(scope: rdsStateScope()); asg.loadIfNeeded(); await asg.waitForLoading()
        let ccNav = begin(.codeCommit, id: "missing")
        resolve(ccNav, codeCommit: cc)
        XCTAssertNotNil(ccNav.error)
        XCTAssertFalse(ccNav.error?.contains("was not found") == true)
        XCTAssertNil(cc.selectedRepository)
        let asgNav = begin(.autoScaling, id: asgStateGroup().arn)
        resolve(asgNav, autoScaling: asg)
        XCTAssertNotNil(asgNav.error)
        XCTAssertFalse(asgNav.error?.contains("was not found") == true)
        XCTAssertNil(asg.selectedGroup)
    }

    func testPendingCodeCommitAndASGListsDoNotResolveSavedTargets() async {
        let ccGate = TestGate()
        let asgGate = TestGate()
        let cc = CodeCommitViewModel(listLoader: { _ in
            await ccGate.wait()
            return [.init(id: "stable", name: "name")]
        }, repositoryLoader: { _, _ in throw CodeCommitError.invalidResponse }, branchesLoader: { _, _ in [] },
        commitLoader: { _, _, _ in throw CodeCommitError.invalidResponse })
        let asg = AutoScalingViewModel(groupLoader: { _ in
            await asgGate.wait()
            return [asgStateGroup()]
        }, policyLoader: { _, _ in [] }, activityLoader: { _, _ in [] })
        cc.configure(scope: rdsStateScope()); cc.loadIfNeeded()
        asg.configure(scope: rdsStateScope()); asg.loadIfNeeded()
        await ccGate.waitForEntry(); await asgGate.waitForEntry()
        for (service, id) in [(AWSService.codeCommit, "stable"), (.autoScaling, asgStateGroup().arn)] {
            let nav = begin(service, id: id)
            resolve(nav, codeCommit: cc, autoScaling: asg)
            XCTAssertTrue(nav.error?.contains("not ready") == true)
        }
        XCTAssertNil(cc.selectedRepository)
        XCTAssertNil(asg.selectedGroup)
        await ccGate.open(); await asgGate.open()
        await cc.waitForLoading(); await asg.waitForLoading()
        // A late list success never reopens a failed saved destination automatically.
        XCTAssertNil(cc.selectedRepository)
        XCTAssertNil(asg.selectedGroup)
        cc.reset(); asg.reset()
    }

    func testMissingRDSInstanceCannotFallBackToSameNamedCluster() async {
        let vm = rds(instances: [], clusters: [rdsStateDatabase("same-name", kind: .cluster)])
        vm.configure(scope: rdsStateScope()); vm.loadIfNeeded(); await vm.waitForLoading()
        vm.selectedDatabase = vm.clusters[0]
        let nav = begin(.rds, id: rdsStateDatabase("same-name").arn)
        resolve(nav, rds: vm)
        XCTAssertNil(vm.selectedDatabase)
        XCTAssertTrue(nav.error?.contains("was not found") == true)
    }

    func testClearedMetadataModelsRejectSavedTargetsWithoutSelection() async {
        let cc = codeCommit(rows: [.init(id: "stable", name: "name")])
        let rds = rds(instances: [rdsStateDatabase()], clusters: [])
        let asg = autoScaling(rows: [asgStateGroup()])
        cc.configure(scope: rdsStateScope()); cc.loadIfNeeded(); await cc.waitForLoading()
        rds.configure(scope: rdsStateScope()); rds.loadIfNeeded(); await rds.waitForLoading()
        asg.configure(scope: rdsStateScope()); asg.loadIfNeeded(); await asg.waitForLoading()
        cc.reset(); rds.reset(); asg.reset()
        for (service, id) in [(AWSService.codeCommit, "stable"), (.rds, rdsStateDatabase().arn), (.autoScaling, asgStateGroup().arn)] {
            let nav = begin(service, id: id)
            resolve(nav, codeCommit: cc, rds: rds, autoScaling: asg)
            XCTAssertTrue(nav.error?.contains("not ready") == true)
        }
        XCTAssertNil(cc.selectedRepository)
        XCTAssertNil(rds.selectedDatabase)
        XCTAssertNil(asg.selectedGroup)
    }

    private func assertAllNotReady(vmScope: MonitoringScope, currentScope: MonitoringScope?) async {
        let repository = CodeCommitRepository(id: "stable", name: "name")
        let database = rdsStateDatabase(scope: vmScope)
        let group = asgStateGroup(scope: vmScope)
        let cc = codeCommit(rows: [repository])
        let rds = rds(instances: [database], clusters: [])
        let asg = autoScaling(rows: [group])
        cc.configure(scope: vmScope); cc.loadIfNeeded(); await cc.waitForLoading()
        rds.configure(scope: vmScope); rds.loadIfNeeded(); await rds.waitForLoading()
        asg.configure(scope: vmScope); asg.loadIfNeeded(); await asg.waitForLoading()
        cc.selectedRepository = repository; rds.selectedDatabase = database; asg.selectedGroup = group
        for (service, id) in [(AWSService.codeCommit, repository.id), (.rds, database.arn), (.autoScaling, group.arn)] {
            let nav = begin(service, id: id)
            resolve(nav, codeCommit: cc, rds: rds, autoScaling: asg, scope: currentScope)
            XCTAssertTrue(nav.error?.contains("not ready") == true, "\(service): \(nav.error ?? "none")")
        }
        XCTAssertNil(cc.selectedRepository)
        XCTAssertNil(rds.selectedDatabase)
        XCTAssertNil(asg.selectedGroup)
        cc.reset(); asg.reset()
    }

    private func favorite(_ service: AWSService, id: String) -> ResourceFavorite {
        let scope = rdsStateScope()
        return ResourceFavorite(profileName: scope.profile.name, accountID: scope.accountID, region: scope.region,
                                service: service, resourceID: id, displayName: "old-name")
    }

    private func begin(_ service: AWSService, id: String, source: FavoriteNavigation.Source = .favorite) -> FavoriteNavigation {
        let nav = FavoriteNavigation()
        let scope = rdsStateScope()
        XCTAssertTrue(nav.begin(favorite(service, id: id), profiles: [scope.profile], selectedProfileName: scope.profile.name, source: source))
        XCTAssertTrue(nav.verifyAccount(scope.accountID))
        return nav
    }

    private func codeCommit(rows: [CodeCommitRepository], fail: Bool = false) -> CodeCommitViewModel {
        CodeCommitViewModel(listLoader: { _ in
            if fail { throw CodeCommitError.invalidResponse }
            return rows
        }, repositoryLoader: { _, _ in throw CodeCommitError.invalidResponse }, branchesLoader: { _, _ in [] },
        commitLoader: { _, _, _ in throw CodeCommitError.invalidResponse })
    }

    private func rds(instances: [RDSDatabase], clusters: [RDSDatabase]) -> RDSViewModel {
        RDSViewModel(instanceLoader: { _ in instances }, clusterLoader: { _ in clusters })
    }

    private func autoScaling(rows: [ASGGroup], fail: Bool = false) -> AutoScalingViewModel {
        AutoScalingViewModel(groupLoader: { _ in
            if fail { throw AutoScalingError.invalidResponse }
            return rows
        }, policyLoader: { _, _ in [] }, activityLoader: { _, _ in [] })
    }

    private func resolve(_ nav: FavoriteNavigation, codeCommit: CodeCommitViewModel? = nil,
                         rds: RDSViewModel? = nil, autoScaling: AutoScalingViewModel? = nil,
                         scope: MonitoringScope? = rdsStateScope()) {
        nav.resolve(ec2: EC2ViewModel(), lambda: LambdaViewModel(), s3: S3ViewModel(),
                    alarms: AlarmViewModel(listLoader: { _ in [] }, tagLoader: { _, _ in [:] }, historyLoader: { _, _ in [] }),
                    sns: SNSViewModel(listLoader: { _ in [] }, attributeLoader: { _, _ in [:] }, tagLoader: { _, _ in [:] }, subscriptionLoader: { _, _ in [] }),
                    codeCommit: codeCommit, rds: rds, autoScaling: autoScaling, currentScope: scope)
    }
}
