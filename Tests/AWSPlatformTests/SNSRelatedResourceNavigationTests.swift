import XCTest
@testable import AWSPlatform

@MainActor
final class SNSRelatedResourceNavigationTests: XCTestCase {
    func testNoProfileOrChangedScopeCannotStartNavigation() async throws {
        let nav = SNSRelatedResourceNavigation()
        let resource = try target(.lambda)
        var calls = 0
        let lambda = LambdaViewModel(functionLoader: { calls += 1; return [] })
        for current in [nil, scope(region: "eu-west-1"), scope(profileName: "other")] {
            XCTAssertFalse(nav.open(resource, currentScope: current, latestScope: { current },
                                    alarms: alarms(), lambda: lambda))
            XCTAssertNil(nav.target)
            XCTAssertNotNil(nav.error)
        }
        XCTAssertEqual(calls, 0)
    }

    func testCachedLambdaOpensWithoutListReadAndClearsFilters() async throws {
        var calls = 0
        let lambda = LambdaViewModel(functionLoader: { calls += 1; return [] })
        let row = function()
        lambda.functions = [row]
        lambda.searchText = "hidden"
        lambda.stateFilter = "Failed"
        lambda.packageFilter = "Image"
        let nav = SNSRelatedResourceNavigation()
        let scope = scope()
        let resource = try target(.lambda, qualifier: "live")
        XCTAssertTrue(nav.open(resource, currentScope: scope, latestScope: { scope },
                               alarms: alarms(), lambda: lambda))
        await nav.waitForNavigation()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(lambda.selectedFunction, row)
        XCTAssertEqual(lambda.filteredFunctions, [row])
        XCTAssertNil(nav.target)
        XCTAssertNil(nav.error)
        XCTAssertEqual(resource.qualifier, "live")
    }

    func testOnlyRequestedServiceLoadsWhenNotCached() async throws {
        var calls = 0
        let row = function()
        let lambda = LambdaViewModel(functionLoader: { calls += 1; return [row] })
        let alarmVM = AlarmViewModel(listLoader: { _ in XCTFail("Must not load alarms"); return [] },
                                     tagLoader: { _, _ in [:] }, historyLoader: { _, _ in [] })
        let nav = SNSRelatedResourceNavigation()
        let scope = scope()
        _ = nav.open(try target(.lambda), currentScope: scope, latestScope: { scope },
                     alarms: alarmVM, lambda: lambda)
        await nav.waitForNavigation()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(lambda.selectedFunction, row)
        XCTAssertNil(nav.error)
    }

    func testSameNameWrongAccountARNDoesNotOpen() async throws {
        let wrong = function(arn: "arn:aws:lambda:us-east-1:222222222222:function:handler")
        let lambda = LambdaViewModel(functionLoader: { [wrong] })
        lambda.functions = [wrong]
        let nav = SNSRelatedResourceNavigation()
        let scope = scope()
        _ = nav.open(try target(.lambda), currentScope: scope, latestScope: { scope },
                     alarms: alarms(), lambda: lambda)
        await nav.waitForNavigation()
        XCTAssertNil(lambda.selectedFunction)
        XCTAssertTrue(nav.error?.contains("not found") == true)
    }

    func testMissingTargetWithNonemptyListDoesNotOpenFirstFunction() async throws {
        var other = function()
        other.functionName = "other"
        other.arn = "arn:aws:lambda:us-east-1:111111111111:function:other"
        let rows = [other]
        let lambda = LambdaViewModel(functionLoader: { rows }, detailLoader: { _ in
            XCTFail("A missing relationship target must not request another function's details")
            throw CancellationError()
        })
        let nav = SNSRelatedResourceNavigation()
        let scope = scope()
        _ = nav.open(try target(.lambda), currentScope: scope, latestScope: { scope },
                     alarms: alarms(), lambda: lambda)
        await nav.waitForNavigation()
        XCTAssertNil(lambda.selectedFunction)
        XCTAssertTrue(nav.error?.contains("not found") == true)
    }

    func testImmediateCancelStartsNoAlarmQuery() async throws {
        let alarmVM = AlarmViewModel(listLoader: { _ in XCTFail("Cancelled navigation must not start a query"); return [] },
                                     tagLoader: { _, _ in [:] }, historyLoader: { _, _ in [] })
        let scope = scope()
        alarmVM.configure(scope: scope.alarmScope)
        let nav = SNSRelatedResourceNavigation()
        _ = nav.open(try target(.alarms), currentScope: scope, latestScope: { scope },
                     alarms: alarmVM, lambda: LambdaViewModel())
        nav.cancel()
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(alarmVM.isLoading)
        XCTAssertNil(alarmVM.selectedAlarm)
        XCTAssertNil(nav.error)
    }

    func testScopeChangesBeforeTaskStartsFailWithoutQuery() async throws {
        let alarmVM = AlarmViewModel(listLoader: { _ in XCTFail("Stale navigation must not start a query"); return [] },
                                     tagLoader: { _, _ in [:] }, historyLoader: { _, _ in [] })
        var current: SNSScope? = scope()
        alarmVM.configure(scope: current?.alarmScope)
        let nav = SNSRelatedResourceNavigation()
        _ = nav.open(try target(.alarms), currentScope: current, latestScope: { current },
                     alarms: alarmVM, lambda: LambdaViewModel())
        current = nil
        await nav.waitForNavigation()
        XCTAssertNil(nav.target)
        XCTAssertNotNil(nav.error)
        XCTAssertFalse(alarmVM.isLoading)
    }

    func testAlarmLoadsAndOpensByARNInConfiguredScope() async throws {
        let row = alarm()
        let alarmVM = alarms(rows: [row])
        let scope = scope()
        alarmVM.configure(scope: scope.alarmScope)
        alarmVM.searchText = "hidden"
        alarmVM.stateFilter = "OK"
        alarmVM.kindFilter = .composite
        let nav = SNSRelatedResourceNavigation()
        _ = nav.open(try target(.alarms), currentScope: scope, latestScope: { scope },
                     alarms: alarmVM, lambda: LambdaViewModel())
        await nav.waitForNavigation()
        XCTAssertEqual(alarmVM.selectedAlarm, row)
        XCTAssertEqual(alarmVM.filteredAlarms, [row])
        XCTAssertNil(nav.error)
        await alarmVM.waitForDetails()
    }

    func testAlarmRequiresMatchingConfiguredScope() throws {
        let nav = SNSRelatedResourceNavigation()
        let scope = scope()
        XCTAssertFalse(nav.open(try target(.alarms), currentScope: scope, latestScope: { scope },
                                alarms: alarms(), lambda: LambdaViewModel()))
        XCTAssertNil(nav.target)
        XCTAssertNotNil(nav.error)
    }

    func testChangedIdentityWhileLoadingNeverSelectsResource() async throws {
        let gate = TestGate()
        let row = function()
        let lambda = LambdaViewModel(functionLoader: { await gate.wait(); return [row] })
        let nav = SNSRelatedResourceNavigation()
        var current: SNSScope? = scope()
        _ = nav.open(try target(.lambda), currentScope: current, latestScope: { current },
                     alarms: alarms(), lambda: lambda)
        await gate.waitForEntry()
        current = nil
        await gate.open()
        await nav.waitForNavigation()
        XCTAssertNil(lambda.selectedFunction)
        XCTAssertNotNil(nav.error)
    }

    func testCancelledLateResponseDoesNotSelectOrReportError() async throws {
        let gate = TestGate()
        let row = function()
        let lambda = LambdaViewModel(functionLoader: { await gate.wait(); return [row] })
        let nav = SNSRelatedResourceNavigation()
        let scope = scope()
        _ = nav.open(try target(.lambda), currentScope: scope, latestScope: { scope },
                     alarms: alarms(), lambda: lambda)
        await gate.waitForEntry()
        let completion = Task { await nav.waitForNavigation() }
        await Task.yield()
        nav.cancel()
        await gate.open()
        await completion.value
        XCTAssertNil(lambda.selectedFunction)
        XCTAssertNil(nav.target)
        XCTAssertNil(nav.error)
    }

    func testFailureDoesNotLeakRawErrorOrLeaveOldSelection() async throws {
        let lambda = LambdaViewModel(functionLoader: {
            throw NSError(domain: "sensitive-endpoint-value", code: 403)
        })
        lambda.selectedFunction = function(arn: "arn:aws:lambda:us-east-1:111111111111:function:other")
        let nav = SNSRelatedResourceNavigation()
        let scope = scope()
        _ = nav.open(try target(.lambda), currentScope: scope, latestScope: { scope },
                     alarms: alarms(), lambda: lambda)
        await nav.waitForNavigation()
        XCTAssertNil(lambda.selectedFunction)
        XCTAssertTrue(nav.error?.contains("Check Lambda access") == true)
        XCTAssertFalse(nav.error?.contains("sensitive") == true)
    }

    private func scope(region: String = "us-east-1", profileName: String = "work") -> SNSScope {
        SNSScope(profile: AWSProfile(name: profileName, region: region, ssoStartURL: nil,
                                     ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil),
                 identity: AWSIdentity(account: "111111111111", arn: "arn:aws:iam::111111111111:user/test", userID: "test"),
                 region: region)
    }

    private func target(_ service: AWSService, qualifier: String? = nil) throws -> SNSRelatedResource {
        let arn = service == .alarms ? alarm().arn : function().arn! + (qualifier.map { ":" + $0 } ?? "")
        return try XCTUnwrap(SNSRelatedResource(scope: scope(), service: service, arn: arn))
    }

    private func alarm() -> CloudWatchAlarm {
        CloudWatchAlarm(arn: "arn:aws:cloudwatch:us-east-1:111111111111:alarm:HighCPU",
                        name: "HighCPU", kind: .metric, state: "ALARM")
    }

    private func alarms(rows: [CloudWatchAlarm] = []) -> AlarmViewModel {
        AlarmViewModel(listLoader: { _ in rows }, tagLoader: { _, _ in [:] }, historyLoader: { _, _ in [] })
    }

    private func function(arn: String = "arn:aws:lambda:us-east-1:111111111111:function:handler") -> LambdaFunctionModel {
        LambdaFunctionModel(functionName: "handler", runtime: "provided.al2023", state: "Active",
                            lastUpdateStatus: nil, lastModified: nil, memorySize: 128, arn: arn,
                            handler: nil, role: nil, codeSize: nil, timeout: 3, environment: [:],
                            vpcConfig: nil, packageType: "Zip", imageUri: nil, tags: [:],
                            codeLocation: nil, codeFiles: [])
    }
}
