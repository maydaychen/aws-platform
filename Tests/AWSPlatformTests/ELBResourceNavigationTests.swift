import XCTest
@testable import AWSPlatform

@MainActor
final class ELBResourceNavigationTests: XCTestCase {
    private let services: [AWSService] = [.loadBalancers, .targetGroups, .ec2, .lambda]

    func testSupportedReferencesRequireExactScopeAndUnsupportedTargetsHaveNoLink() throws {
        let current = scope()
        for service in services {
            let reference = try reference(service)
            XCTAssertTrue(reference.isValid(in: current))
            XCTAssertFalse(reference.isValid(in: nil))
            XCTAssertFalse(reference.isValid(in: scope(profile: "other")))
            XCTAssertFalse(reference.isValid(in: scope(account: "222222222222")))
            XCTAssertFalse(reference.isValid(in: scope(region: "eu-west-1")))
        }
        let ipGroup = ELBTargetGroup(arn: group().arn, name: "IP targets", targetType: "ip")
        XCTAssertNil(ELBResourceReference.target(ELBTargetHealth(targetID: "10.0.0.1", state: "healthy"),
                                                group: ipGroup, scope: current))
        XCTAssertNil(ELBResourceReference.target(ELBTargetHealth(targetID: instance().instanceId, state: "unused",
                                                                reason: "Target.NotRegistered"),
                                                group: group(), scope: current))
        for invalid in ["10.0.0.1", "i-1234567", "i-12345678\n", "i-12345678-other"] {
            XCTAssertNil(ELBResourceReference(scope: current, service: .ec2, resourceID: invalid, name: invalid))
        }
        for service in [AWSService.s3, .sns, .alarms] {
            XCTAssertNil(ELBResourceReference(scope: current, service: service, resourceID: "unsupported", name: "unsupported"))
        }
        for arn in ["arn:aws:lambda:eu-west-1:111111111111:function:handler",
                    "arn:aws:lambda:us-east-1:222222222222:function:handler",
                    "arn:aws-cn:lambda:us-east-1:111111111111:function:handler"] {
            XCTAssertNil(ELBResourceReference(scope: current, service: .lambda, resourceID: arn, name: "handler"))
        }
    }

    func testMissingOrChangedCurrentAndLatestScopesStartNoCalls() async throws {
        let models = models()
        let nav = ELBResourceNavigation()
        for service in services {
            let destination = try reference(service)
            for invalid: MonitoringScope? in [nil, scope(profile: "other"), scope(account: "222222222222"),
                                              scope(region: "eu-west-1"), scope(principal: "another")] {
                let current = scope()
                XCTAssertFalse(nav.open(destination, currentScope: invalid, latestScope: { current },
                                        elb: models.elb, ec2: models.ec2, lambda: models.lambda))
                XCTAssertFalse(open(nav, destination, models: models, latest: { invalid }))
                XCTAssertNil(nav.target)
                XCTAssertNotNil(nav.error)
            }
        }
        await Task.yield()
        XCTAssertEqual(models.calls.total, 0)
    }

    func testELBNavigationRequiresAlreadyConfiguredMatchingScope() throws {
        let models = models()
        models.elb.configure(scope: nil)
        let nav = ELBResourceNavigation()
        for service in [AWSService.loadBalancers, .targetGroups] {
            XCTAssertFalse(open(nav, try reference(service), models: models))
            XCTAssertNil(nav.target)
        }
        XCTAssertNil(models.elb.scope)
        XCTAssertEqual(models.calls.total, 0)
    }

    func testEachDestinationLoadsOnlyItsListAndSelectsExactResource() async throws {
        for service in services {
            let models = models()
            let nav = ELBResourceNavigation()
            hideRows(models)
            XCTAssertTrue(open(nav, try reference(service), models: models))
            await nav.waitForNavigation()

            XCTAssertEqual(selectedID(service, models: models), try reference(service).resourceID)
            XCTAssertNil(nav.target)
            XCTAssertNil(nav.error)
            XCTAssertEqual(models.calls.lists, [service: 1])
            switch service {
            case .loadBalancers:
                XCTAssertEqual(models.elb.filteredLoadBalancers, [loadBalancer()])
            case .targetGroups:
                XCTAssertEqual(models.elb.filteredTargetGroups, [group()])
            case .ec2:
                XCTAssertEqual(models.ec2.filteredInstances, [instance()])
            case .lambda:
                XCTAssertEqual(models.lambda.filteredFunctions, [function()])
            default: XCTFail("Unexpected service")
            }
            await models.elb.waitForDetails()
        }
    }

    func testValidCachedResourcesDoNotReloadLists() async throws {
        let models = models()
        await models.elb.loadLoadBalancers()
        await models.elb.loadTargetGroups()
        await models.ec2.loadInstances(selectFirstIfNeeded: false)
        await models.lambda.loadFunctions(selectFirstIfNeeded: false)
        let original = models.calls.lists
        let nav = ELBResourceNavigation()
        for service in services {
            XCTAssertTrue(open(nav, try reference(service), models: models))
            XCTAssertNil(selectedID(service, models: models))
            await nav.waitForNavigation()
            XCTAssertEqual(selectedID(service, models: models), try reference(service).resourceID)
            XCTAssertNil(nav.error)
        }
        XCTAssertEqual(models.calls.lists, original)
        await models.elb.waitForDetails()
    }

    func testMissingDestinationDoesNotSelectOtherRowOrFetchItsDetails() async throws {
        for service in services {
            let models = models(missing: true)
            let nav = ELBResourceNavigation()
            XCTAssertTrue(open(nav, try reference(service), models: models))
            await nav.waitForNavigation()
            XCTAssertNil(selectedID(service, models: models))
            XCTAssertTrue(nav.error?.contains("not found") == true)
            XCTAssertEqual(models.calls.lists, [service: 1])
            XCTAssertEqual(models.calls.details, 0)
        }
    }

    func testLoaderFailuresDoNotSelectCachedRowsOrExposeRawErrors() async throws {
        for service in services {
            let models = models()
            switch service {
            case .loadBalancers: await models.elb.loadLoadBalancers()
            case .targetGroups: await models.elb.loadTargetGroups()
            case .ec2: await models.ec2.loadInstances(selectFirstIfNeeded: false)
            case .lambda: await models.lambda.loadFunctions(selectFirstIfNeeded: false)
            default: break
            }
            models.calls.fail = true
            switch service {
            case .loadBalancers: await models.elb.loadLoadBalancers()
            case .targetGroups: await models.elb.loadTargetGroups()
            case .ec2: models.ec2.error = "Previous list failed"
            case .lambda: models.lambda.error = "Previous list failed"
            default: break
            }
            let nav = ELBResourceNavigation()
            XCTAssertTrue(open(nav, try reference(service), models: models))
            await nav.waitForNavigation()
            XCTAssertNil(selectedID(service, models: models))
            XCTAssertNotNil(nav.error)
            XCTAssertFalse(nav.error?.contains("sensitive-endpoint") == true)
            XCTAssertEqual(models.calls.details, 0)
            if service == .loadBalancers {
                XCTAssertTrue(models.elb.isLoadBalancersStale)
                XCTAssertEqual(models.elb.loadBalancers, [loadBalancer()])
            } else if service == .targetGroups {
                XCTAssertTrue(models.elb.isTargetGroupsStale)
                XCTAssertEqual(models.elb.targetGroups, [group()])
            }
        }
    }

    func testLambdaQualifierRemainsOnReferenceAndOpensFunctionLevelARN() async throws {
        let models = models()
        let destination = try XCTUnwrap(ELBResourceReference(scope: scope(), service: .lambda,
                                                            resourceID: function().arn! + ":production", name: "handler"))
        let nav = ELBResourceNavigation()
        XCTAssertTrue(open(nav, destination, models: models))
        XCTAssertEqual(nav.target?.qualifier, "production")
        await nav.waitForNavigation()
        XCTAssertEqual(models.lambda.selectedFunction, function())
        XCTAssertEqual(destination.qualifier, "production")
        XCTAssertNil(nav.error)
    }

    func testLambdaSameNameWithWrongFullARNNeverMatches() async throws {
        for arn in ["arn:aws:lambda:eu-west-1:111111111111:function:handler",
                    "arn:aws:lambda:us-east-1:222222222222:function:handler",
                    "arn:aws-cn:lambda:us-east-1:111111111111:function:handler",
                    "arn:aws:lambda:us-east-1:111111111111:function:handler:production"] {
            let models = models()
            let wrong = function(arn: arn)
            let lambda = LambdaViewModel(functionLoader: { [wrong] })
            lambda.functions = [wrong]
            let nav = ELBResourceNavigation()
            let current = scope()
            XCTAssertTrue(nav.open(try reference(.lambda), currentScope: current, latestScope: { current },
                                   elb: models.elb, ec2: models.ec2, lambda: lambda))
            await nav.waitForNavigation()
            XCTAssertNil(lambda.selectedFunction)
            XCTAssertTrue(nav.error?.contains("not found") == true)
        }
    }

    func testImmediateCancelForEveryServiceStartsZeroCalls() async throws {
        for service in services {
            let models = models()
            let nav = ELBResourceNavigation()
            XCTAssertTrue(open(nav, try reference(service), models: models))
            nav.cancel()
            await Task.yield()
            await Task.yield()
            XCTAssertEqual(models.calls.total, 0)
            XCTAssertNil(selectedID(service, models: models))
            XCTAssertNil(nav.target)
            XCTAssertNil(nav.error)
        }
    }

    func testScopeChangesBeforeTaskStartsMakeZeroCalls() async throws {
        for service in services {
            let models = models()
            let nav = ELBResourceNavigation()
            var current: MonitoringScope? = scope()
            XCTAssertTrue(open(nav, try reference(service), models: models, latest: { current }))
            current = nil
            await nav.waitForNavigation()
            XCTAssertEqual(models.calls.total, 0)
            XCTAssertNil(selectedID(service, models: models))
            XCTAssertNotNil(nav.error)
        }
    }

    func testScopeChangesDuringAnyListLoadNeverSelectDestination() async throws {
        for service in services {
            let gate = TestGate()
            let models = models(gate: gate, gatedService: service)
            let nav = ELBResourceNavigation()
            var current: MonitoringScope? = scope()
            XCTAssertTrue(open(nav, try reference(service), models: models, latest: { current }))
            await gate.waitForEntry()
            current = scope(profile: "other")
            await gate.open()
            await nav.waitForNavigation()
            XCTAssertNil(selectedID(service, models: models))
            XCTAssertNotNil(nav.error)
            XCTAssertEqual(models.calls.details, 0)
        }
    }

    func testCancelledLateResponsesNeverSelectOrReportFailure() async throws {
        for service in services {
            let gate = TestGate()
            let models = models(gate: gate, gatedService: service)
            let nav = ELBResourceNavigation()
            XCTAssertTrue(open(nav, try reference(service), models: models))
            await gate.waitForEntry()
            let completion = Task { await nav.waitForNavigation() }
            await Task.yield()
            nav.cancel()
            await gate.open()
            await completion.value
            XCTAssertNil(selectedID(service, models: models))
            XCTAssertNil(nav.target)
            XCTAssertNil(nav.error)
            XCTAssertEqual(models.calls.details, 0)
        }
    }

    func testOldRequestCannotOverwriteNewNavigation() async throws {
        let gate = TestGate()
        let models = models(gate: gate, gatedService: .loadBalancers)
        let nav = ELBResourceNavigation()
        XCTAssertTrue(open(nav, try reference(.loadBalancers), models: models))
        await gate.waitForEntry()
        let previous = Task { await nav.waitForNavigation() }
        await Task.yield()
        XCTAssertTrue(open(nav, try reference(.ec2), models: models))
        await nav.waitForNavigation()
        XCTAssertEqual(models.ec2.selectedInstance, instance())
        await gate.open()
        await previous.value
        XCTAssertNil(models.elb.selectedLoadBalancer)
        XCTAssertEqual(models.ec2.selectedInstance, instance())
        XCTAssertNil(nav.target)
        XCTAssertNil(nav.error)
    }

    func testCancellingNavigationLeavesPreexistingELBListRequestRunning() async throws {
        for service in [AWSService.loadBalancers, .targetGroups] {
            let gate = TestGate()
            let models = models(gate: gate, gatedService: service)
            if service == .loadBalancers {
                models.elb.refreshLoadBalancers()
            } else {
                models.elb.refreshTargetGroups()
            }
            await gate.waitForEntry()
            let nav = ELBResourceNavigation()
            XCTAssertTrue(open(nav, try reference(service), models: models))
            await Task.yield()
            let completion = Task { await nav.waitForNavigation() }
            await Task.yield()
            nav.cancel()
            await gate.open()
            await completion.value
            await models.elb.waitForLoadBalancers()
            await models.elb.waitForTargetGroups()
            XCTAssertEqual(models.calls.lists, [service: 1])
            XCTAssertNil(selectedID(service, models: models))
            if service == .loadBalancers {
                XCTAssertEqual(models.elb.loadBalancers, [loadBalancer()])
                XCTAssertNil(models.elb.loadBalancersError)
            } else {
                XCTAssertEqual(models.elb.targetGroups, [group()])
                XCTAssertNil(models.elb.targetGroupsError)
            }
        }
    }

    func testCancellingOwnedELBRequestDiscardsItsLateRows() async throws {
        for service in [AWSService.loadBalancers, .targetGroups] {
            let gate = TestGate()
            let models = models(gate: gate, gatedService: service)
            let nav = ELBResourceNavigation()
            XCTAssertTrue(open(nav, try reference(service), models: models))
            await gate.waitForEntry()
            let completion = Task { await nav.waitForNavigation() }
            await Task.yield()
            nav.cancel()
            await gate.open()
            await completion.value
            XCTAssertTrue(models.elb.loadBalancers.isEmpty)
            XCTAssertTrue(models.elb.targetGroups.isEmpty)
            XCTAssertNil(selectedID(service, models: models))
            XCTAssertNil(nav.error)
        }
    }

    func testCancellingOldELBNavigationDoesNotCancelLaterRefresh() async throws {
        for service in [AWSService.loadBalancers, .targetGroups] {
            let firstGate = TestGate()
            let secondGate = TestGate()
            let lb = loadBalancer()
            let tg = group()
            let calls = Calls()
            let beforeLoad: @MainActor @Sendable () async -> Void = {
                calls.lists[service, default: 0] += 1
                if calls.lists[service] == 1 { await firstGate.wait() } else { await secondGate.wait() }
            }
            let elb = ELBViewModel(
                loadBalancerLoader: { _ in await beforeLoad(); return [lb] },
                targetGroupLoader: { _ in await beforeLoad(); return [tg] },
                listenerLoader: { _, _ in [] }, ruleLoader: { _, _ in [] }, healthLoader: { _, _ in [] }
            )
            let current = scope()
            elb.configure(scope: current)
            let nav = ELBResourceNavigation()
            XCTAssertTrue(nav.open(try reference(service), currentScope: current, latestScope: { current },
                                   elb: elb, ec2: EC2ViewModel(), lambda: LambdaViewModel()))
            await firstGate.waitForEntry()
            let previous = Task { await nav.waitForNavigation() }
            await Task.yield()
            if service == .loadBalancers { elb.refreshLoadBalancers() } else { elb.refreshTargetGroups() }
            await secondGate.waitForEntry()
            nav.cancel()
            await firstGate.open()
            await secondGate.open()
            await previous.value
            await elb.waitForLoadBalancers()
            await elb.waitForTargetGroups()
            if service == .loadBalancers {
                XCTAssertEqual(elb.loadBalancers, [lb])
                XCTAssertNil(elb.loadBalancersError)
            } else {
                XCTAssertEqual(elb.targetGroups, [tg])
                XCTAssertNil(elb.targetGroupsError)
            }
            XCTAssertNil(nav.error)
        }
    }

    func testBackgroundEC2LoadCannotAutoSelectAfterMissingNavigation() async throws {
        let gate = TestGate()
        var calls = 0
        let row = instance(id: "i-87654321")
        let ec2 = EC2ViewModel(instanceLoader: {
            calls += 1
            if calls == 1 { await gate.wait() }
            return [row]
        })
        let background = Task { await ec2.loadInstances() }
        await gate.waitForEntry()
        let models = models()
        let nav = ELBResourceNavigation()
        let current = scope()
        XCTAssertTrue(nav.open(try reference(.ec2), currentScope: current, latestScope: { current },
                               elb: models.elb, ec2: ec2, lambda: models.lambda))
        await nav.waitForNavigation()
        await gate.open()
        await background.value
        XCTAssertEqual(calls, 2)
        XCTAssertNil(ec2.selectedInstance)
        XCTAssertTrue(nav.error?.contains("not found") == true)
    }

    func testBackgroundLambdaLoadCannotAutoSelectAfterMissingNavigation() async throws {
        let gate = TestGate()
        var calls = 0
        let row = function(name: "other")
        let lambda = LambdaViewModel(functionLoader: {
            calls += 1
            if calls == 1 { await gate.wait() }
            return [row]
        })
        let background = Task { await lambda.loadFunctions() }
        await gate.waitForEntry()
        let models = models()
        let nav = ELBResourceNavigation()
        let current = scope()
        XCTAssertTrue(nav.open(try reference(.lambda), currentScope: current, latestScope: { current },
                               elb: models.elb, ec2: models.ec2, lambda: lambda))
        await nav.waitForNavigation()
        await gate.open()
        await background.value
        XCTAssertEqual(calls, 2)
        XCTAssertNil(lambda.selectedFunction)
        XCTAssertTrue(nav.error?.contains("not found") == true)
    }

    func testCancelDoesNotStopLaterIndependentEC2Refresh() async throws {
        let navigationGate = TestGate()
        let refreshGate = TestGate()
        var calls = 0
        let row = instance()
        let ec2 = EC2ViewModel(instanceLoader: {
            calls += 1
            if calls == 1 { await navigationGate.wait() } else { await refreshGate.wait() }
            return [row]
        })
        let models = models()
        let nav = ELBResourceNavigation()
        let current = scope()
        XCTAssertTrue(nav.open(try reference(.ec2), currentScope: current, latestScope: { current },
                               elb: models.elb, ec2: ec2, lambda: models.lambda))
        await navigationGate.waitForEntry()
        let navigation = Task { await nav.waitForNavigation() }
        await Task.yield()
        let refresh = Task { await ec2.loadInstances() }
        await refreshGate.waitForEntry()
        nav.cancel()
        await navigationGate.open()
        await refreshGate.open()
        await navigation.value
        await refresh.value
        XCTAssertEqual(ec2.selectedInstance, row)
        XCTAssertNil(nav.error)
    }

    func testEC2OptOutNeverFallsBackToFirstInstanceAndDefaultStillSelectsIt() async {
        let row = instance()
        var detailCalls = 0
        let ec2 = EC2ViewModel(instanceLoader: { [row] }, detailLoader: { _ in
            detailCalls += 1
            throw CancellationError()
        })
        await ec2.loadInstances(selectFirstIfNeeded: false)
        XCTAssertEqual(ec2.instances, [row])
        XCTAssertNil(ec2.selectedInstance)
        XCTAssertEqual(detailCalls, 0)
        ec2.selectedInstance = instance(id: "i-87654321")
        await ec2.loadInstances(selectFirstIfNeeded: false)
        XCTAssertNil(ec2.selectedInstance)
        await ec2.loadInstances()
        XCTAssertEqual(ec2.selectedInstance, row)
    }

    func testEC2OptOutRetainsExistingExactSelection() async {
        let row = instance()
        let ec2 = EC2ViewModel(instanceLoader: { [row] })
        ec2.selectedInstance = row
        await ec2.loadInstances(selectFirstIfNeeded: false)
        XCTAssertEqual(ec2.selectedInstance, row)
    }

    @MainActor
    private final class Calls {
        var lists: [AWSService: Int] = [:]
        var details = 0
        var fail = false
        var total: Int { lists.values.reduce(0, +) + details }
        func recordDetail() { details += 1 }
    }

    private struct Models {
        let elb: ELBViewModel
        let ec2: EC2ViewModel
        let lambda: LambdaViewModel
        let calls: Calls
    }

    private func models(missing: Bool = false, gate: TestGate? = nil, gatedService: AWSService? = nil) -> Models {
        let calls = Calls()
        let lb = loadBalancer(name: missing ? "other" : "web")
        let tg = group(name: missing ? "other" : "web")
        let ec2Row = instance(id: missing ? "i-87654321" : "i-12345678")
        let lambdaRow = function(name: missing ? "other" : "handler")
        let beforeLoad: @MainActor @Sendable (AWSService) async throws -> Void = { service in
            calls.lists[service, default: 0] += 1
            if service == gatedService { await gate?.wait() }
            if calls.fail { throw NSError(domain: "sensitive-endpoint", code: 403) }
        }
        let elb = ELBViewModel(
            loadBalancerLoader: { _ in try await beforeLoad(.loadBalancers); return [lb] },
            targetGroupLoader: { _ in try await beforeLoad(.targetGroups); return [tg] },
            listenerLoader: { _, _ in await calls.recordDetail(); return [] },
            ruleLoader: { _, _ in await calls.recordDetail(); return [] },
            healthLoader: { _, _ in await calls.recordDetail(); return [] }
        )
        elb.configure(scope: scope())
        let ec2 = EC2ViewModel(instanceLoader: { try await beforeLoad(.ec2); return [ec2Row] })
        let lambda = LambdaViewModel(functionLoader: { try await beforeLoad(.lambda); return [lambdaRow] })
        return Models(elb: elb, ec2: ec2, lambda: lambda, calls: calls)
    }

    private func open(_ nav: ELBResourceNavigation, _ reference: ELBResourceReference, models: Models,
                      latest: (@MainActor () -> MonitoringScope?)? = nil) -> Bool {
        let current = scope()
        return nav.open(reference, currentScope: current, latestScope: latest ?? { current },
                        elb: models.elb, ec2: models.ec2, lambda: models.lambda)
    }

    private func selectedID(_ service: AWSService, models: Models) -> String? {
        switch service {
        case .loadBalancers: return models.elb.selectedLoadBalancer?.arn
        case .targetGroups: return models.elb.selectedTargetGroup?.arn
        case .ec2: return models.ec2.selectedInstance?.instanceId
        case .lambda: return models.lambda.selectedFunction?.arn
        default: return nil
        }
    }

    private func hideRows(_ models: Models) {
        models.elb.searchText = "hidden"
        models.elb.kindFilter = "network"
        models.elb.groupSearchText = "hidden"
        models.elb.targetTypeFilter = "ip"
        models.ec2.searchText = "hidden"
        models.ec2.stateFilter = "stopped"
        models.ec2.healthFilter = .attention
        models.lambda.searchText = "hidden"
        models.lambda.stateFilter = "Failed"
        models.lambda.packageFilter = "Image"
    }

    private func reference(_ service: AWSService) throws -> ELBResourceReference {
        let id: String
        switch service {
        case .loadBalancers: id = loadBalancer().arn
        case .targetGroups: id = group().arn
        case .ec2: id = instance().instanceId
        case .lambda: id = function().arn!
        default: throw ELBError.invalidScope
        }
        return try XCTUnwrap(ELBResourceReference(scope: scope(), service: service, resourceID: id, name: id))
    }

    private func scope(profile: String = "work", account: String = "111111111111", region: String = "us-east-1",
                       principal: String = "test") -> MonitoringScope {
        MonitoringScope(profile: AWSProfile(name: profile, region: region, ssoStartURL: nil, ssoRegion: nil,
                                            ssoAccountID: nil, ssoRoleName: nil),
                        identity: AWSIdentity(account: account, arn: "arn:aws:iam::\(account):user/\(principal)", userID: principal),
                        region: region)
    }

    private func loadBalancer(name: String = "web") -> ELBLoadBalancer {
        ELBLoadBalancer(arn: "arn:aws:elasticloadbalancing:us-east-1:111111111111:loadbalancer/app/\(name)/1234567890abcdef",
                        name: name, kind: "application")
    }

    private func group(name: String = "web") -> ELBTargetGroup {
        ELBTargetGroup(arn: "arn:aws:elasticloadbalancing:us-east-1:111111111111:targetgroup/\(name)/1234567890abcdef",
                       name: name, targetType: "instance")
    }

    private func instance(id: String = "i-12345678") -> EC2InstanceModel {
        EC2InstanceModel(instanceId: id, name: "web", instanceType: "t3.small", state: "running", privateIP: nil,
                         publicIP: nil, platformDetails: nil, architecture: nil, vpcId: nil, subnetId: nil,
                         availabilityZone: nil, securityGroups: [], imageId: nil, imageName: nil,
                         keyName: nil, launchTime: nil, tags: [:])
    }

    private func function(name: String = "handler", arn: String? = nil) -> LambdaFunctionModel {
        LambdaFunctionModel(functionName: name, runtime: "provided.al2023", state: "Active", lastUpdateStatus: nil,
                            lastModified: nil, memorySize: 128,
                            arn: arn ?? "arn:aws:lambda:us-east-1:111111111111:function:\(name)",
                            handler: nil, role: nil, codeSize: nil, timeout: 3, environment: [:], vpcConfig: nil,
                            packageType: "Zip", imageUri: nil, tags: [:], codeLocation: nil, codeFiles: [])
    }
}
