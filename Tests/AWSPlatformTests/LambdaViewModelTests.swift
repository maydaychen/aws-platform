import XCTest
@testable import AWSPlatform

final class LambdaViewModelTests: XCTestCase {
    @MainActor
    func testListWithoutStateIsEnrichedForFilteringAndTagSearch() async {
        var function = makeFunction(name: "example")
        function.state = nil
        function.lastUpdateStatus = nil
        let rows = [function]
        let vm = LambdaViewModel(functionLoader: { rows }, summaryLoader: { _ in
            LambdaFunctionSummary(state: "Failed", lastUpdateStatus: "Failed", tags: ["team": "billing"])
        })
        await vm.loadFunctions()
        XCTAssertEqual(vm.availableStates, ["All", "Failed"])
        vm.stateFilter = "Failed"
        vm.searchText = "billing"
        XCTAssertEqual(vm.filteredFunctions.map(\.functionName), ["example"])
        XCTAssertEqual(vm.selectedFunction?.lastUpdateStatus, "Failed")
        XCTAssertNil(vm.summaryWarning)
    }

    @MainActor
    func testSummaryPermissionFailureKeepsFunctionList() async {
        var denied = makeFunction(name: "denied")
        denied.state = nil
        let rows = [denied, makeFunction(name: "allowed")]
        let vm = LambdaViewModel(functionLoader: { rows }, summaryLoader: { name in
            if name == "denied" { throw LambdaTestError.failed }
            return LambdaFunctionSummary(state: "Active", lastUpdateStatus: "Successful", tags: [:])
        })
        await vm.loadFunctions()
        XCTAssertEqual(vm.functions.count, 2)
        XCTAssertNil(vm.error)
        XCTAssertNotNil(vm.summaryWarning)
        vm.stateFilter = "Active"
        XCTAssertEqual(vm.filteredFunctions.map(\.functionName), ["allowed"])
    }

    @MainActor
    func testResetRejectsLateSummaryAndWarning() async {
        let gate = TestGate()
        let rows = [makeFunction(name: "example")]
        let vm = LambdaViewModel(functionLoader: { rows }, summaryLoader: { _ in
            await gate.wait()
            throw LambdaTestError.failed
        })
        let request = Task { await vm.loadFunctions() }
        await gate.waitForEntry()
        vm.reset()
        await gate.open()
        await request.value
        XCTAssertTrue(vm.functions.isEmpty)
        XCTAssertNil(vm.summaryWarning)
        XCTAssertNil(vm.error)
    }

    func testLoadFunctionsSelectsFirstFunction() async {
        let function = makeFunction(name: "example")
        let vm = await MainActor.run {
            LambdaViewModel(functionLoader: { [function] in [function] })
        }

        await vm.loadFunctions()

        await MainActor.run {
            XCTAssertEqual(vm.functions, [function])
            XCTAssertEqual(vm.selectedFunction, function)
            XCTAssertNil(vm.error)
            XCTAssertFalse(vm.isLoading)
        }
    }

    @MainActor
    func testLoadFunctionsCanLeaveSelectionEmptyWithoutLoadingFirstDetail() async {
        let first = makeFunction(name: "first")
        var detailRequests: [String] = []
        let vm = LambdaViewModel(functionLoader: { [first] }, detailLoader: { name in
            detailRequests.append(name)
            return Self.makeDetail(functionName: name)
        })

        await vm.loadFunctions(selectFirstIfNeeded: false)
        await Task.yield()

        XCTAssertEqual(vm.functions, [first])
        XCTAssertNil(vm.selectedFunction)
        XCTAssertNil(vm.functionDetail)
        XCTAssertFalse(vm.isDetailLoading)
        XCTAssertTrue(detailRequests.isEmpty)
    }

    @MainActor
    func testLoadFunctionsWithoutFirstSelectionClearsMissingPreviousSelection() async {
        let first = makeFunction(name: "first")
        let removed = makeFunction(name: "removed")
        var detailRequests: [String] = []
        let vm = LambdaViewModel(functionLoader: { [first] }, detailLoader: { name in
            detailRequests.append(name)
            return Self.makeDetail(functionName: name)
        })
        vm.selectedFunction = removed
        while vm.isDetailLoading { await Task.yield() }
        XCTAssertEqual(detailRequests, ["removed"])

        await vm.loadFunctions(selectFirstIfNeeded: false)
        await Task.yield()

        XCTAssertEqual(vm.functions, [first])
        XCTAssertNil(vm.selectedFunction)
        XCTAssertNil(vm.functionDetail)
        XCTAssertFalse(vm.isDetailLoading)
        XCTAssertEqual(detailRequests, ["removed"], "A missing selection must not load an unrelated first function")
    }

    @MainActor
    func testLoadFunctionsWithoutFirstSelectionPreservesAndRefreshesValidSelection() async {
        let first = makeFunction(name: "first")
        let selected = makeFunction(name: "selected")
        var detailRequests: [String] = []
        let vm = LambdaViewModel(functionLoader: { [first, selected] }, detailLoader: { name in
            detailRequests.append(name)
            return Self.makeDetail(functionName: name)
        })
        vm.selectedFunction = selected
        while vm.isDetailLoading { await Task.yield() }
        XCTAssertEqual(detailRequests, ["selected"])

        await vm.loadFunctions(selectFirstIfNeeded: false)
        while vm.isDetailLoading { await Task.yield() }

        XCTAssertEqual(vm.functions, [first, selected])
        XCTAssertEqual(vm.selectedFunction, selected)
        XCTAssertEqual(vm.functionDetail?.functionName, "selected")
        XCTAssertEqual(detailRequests, ["selected", "selected"], "An existing valid selection must still refresh its detail")
    }

    func testLoadFunctionsFailureClearsStateAndShowsError() async {
        let vm = await MainActor.run {
            LambdaViewModel(functionLoader: { throw LambdaTestError.failed })
        }

        await vm.loadFunctions()

        await MainActor.run {
            XCTAssertTrue(vm.functions.isEmpty)
            XCTAssertNil(vm.selectedFunction)
            XCTAssertEqual(vm.error, "Lambda test operation failed.")
            XCTAssertFalse(vm.isLoading)
        }
    }

    func testStateAndPackageFiltersAreCombined() async {
        let activeZip = makeFunction(
            name: "active-zip",
            state: "Active",
            packageType: "Zip"
        )
        let failedImage = makeFunction(
            name: "failed-image",
            state: "Failed",
            packageType: "Image"
        )
        let activeImage = makeFunction(
            name: "active-image",
            state: "Active",
            packageType: "Image"
        )
        let vm = await MainActor.run {
            LambdaViewModel(functionLoader: { [activeZip, failedImage, activeImage] in
                [activeZip, failedImage, activeImage]
            })
        }

        await vm.loadFunctions()

        await MainActor.run {
            vm.stateFilter = "Active"
            vm.packageFilter = "Image"
            XCTAssertEqual(vm.filteredFunctions.map(\.functionName), ["active-image"])
        }
    }

    func testDetailWarningsDoNotBecomeDetailError() async {
        let function = makeFunction(name: "example")
        let detail = Self.makeDetail(
            functionName: function.functionName,
            warnings: ["Aliases: permission denied"]
        )
        let vm = await MainActor.run {
            LambdaViewModel(
                functionLoader: { [function] in [function] },
                detailLoader: { _ in detail }
            )
        }

        await vm.loadFunctions()
        await vm.loadDetail(functionName: function.functionName)

        await MainActor.run {
            XCTAssertEqual(vm.functionDetail, detail)
            XCTAssertNil(vm.detailError)
            XCTAssertEqual(vm.functions, [function])
        }
    }

    func testDetailFailureIsScopedToDetailPane() async {
        let function = makeFunction(name: "example")
        let vm = await MainActor.run {
            LambdaViewModel(
                functionLoader: { [function] in [function] },
                detailLoader: { _ in throw LambdaTestError.failed }
            )
        }

        await vm.loadFunctions()
        await vm.loadDetail(functionName: function.functionName)

        await MainActor.run {
            XCTAssertEqual(vm.functions, [function])
            XCTAssertEqual(vm.detailError, "Lambda test operation failed.")
            XCTAssertNil(vm.error)
            XCTAssertFalse(vm.isDetailLoading)
        }
    }

    func testRapidSelectionChangeKeepsLatestDetail() async throws {
        let first = makeFunction(name: "first")
        let second = makeFunction(name: "second")
        let vm = await MainActor.run {
            LambdaViewModel(
                functionLoader: { [first, second] in [first, second] },
                detailLoader: { functionName in
                    if functionName == first.functionName {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                    }
                    return Self.makeDetail(functionName: functionName)
                }
            )
        }

        await vm.loadFunctions()
        await MainActor.run {
            vm.selectedFunction = second
        }
        try await Task.sleep(nanoseconds: 250_000_000)

        await MainActor.run {
            XCTAssertEqual(vm.functionDetail?.functionName, second.functionName)
            XCTAssertNil(vm.detailError)
            XCTAssertFalse(vm.isDetailLoading)
        }
    }

    @MainActor
    func testLateCodeRequestDoesNotClearNewRequestLoading() async {
        let oldGate = TestGate()
        let newGate = TestGate()
        var requestCount = 0
        let function = makeFunction(name: "example")
        let vm = LambdaViewModel(codeLoader: { function in
            requestCount += 1
            if requestCount == 1 {
                await oldGate.wait()
            } else {
                await newGate.wait()
            }
            return Self.withCode(function, content: "source")
        })
        vm.functions = [function]
        vm.selectedFunction = function

        let oldRequest = Task { await vm.loadCode(for: function.functionName) }
        await oldGate.waitForEntry()
        let newRequest = Task { await vm.loadCode(for: function.functionName) }
        await newGate.waitForEntry()
        await oldGate.open()
        await oldRequest.value

        XCTAssertTrue(vm.isCodeLoading, "A superseded request must not clear the current request's loading state")
        XCTAssertTrue(vm.selectedFunction?.codeFiles.isEmpty == true)
        await newGate.open()
        await newRequest.value
        XCTAssertFalse(vm.isCodeLoading)
        XCTAssertEqual(vm.selectedFunction?.codeFiles.first?.content, "source")
    }

    @MainActor
    func testLateCodeFailureDoesNotReplaceNewRequestState() async {
        let oldGate = TestGate()
        let newGate = TestGate()
        var requestCount = 0
        let function = makeFunction(name: "example")
        let vm = LambdaViewModel(codeLoader: { function in
            requestCount += 1
            if requestCount == 1 {
                await oldGate.wait()
                throw LambdaTestError.failed
            }
            await newGate.wait()
            return Self.withCode(function, content: "latest")
        })
        vm.functions = [function]
        vm.selectedFunction = function

        let oldRequest = Task { await vm.loadCode(for: function.functionName) }
        await oldGate.waitForEntry()
        let newRequest = Task { await vm.loadCode(for: function.functionName) }
        await newGate.waitForEntry()
        await oldGate.open()
        await oldRequest.value

        XCTAssertTrue(vm.isCodeLoading)
        XCTAssertNil(vm.codeError)
        await newGate.open()
        await newRequest.value
        XCTAssertNil(vm.codeError)
        XCTAssertEqual(vm.selectedFunction?.codeFiles.first?.content, "latest")
    }

    @MainActor
    func testManualCodeCancellationCancelsManagedTaskAndRejectsLateSource() async {
        let gate = TestGate()
        let finished = expectation(description: "Cancelled loader returned")
        var wasCancelled = false
        let function = makeFunction(name: "example")
        let vm = LambdaViewModel(codeLoader: { function in
            await gate.wait()
            wasCancelled = Task.isCancelled
            defer { finished.fulfill() }
            return Self.withCode(function, content: "cancelled")
        })
        vm.functions = [function]
        vm.selectedFunction = function
        vm.loadCodeForSelection()
        await gate.waitForEntry()

        vm.cancelCodeLoading()
        XCTAssertFalse(vm.isCodeLoading)
        XCTAssertNil(vm.codeError)
        await gate.open()
        await fulfillment(of: [finished], timeout: 1)
        await Task.yield()

        XCTAssertTrue(wasCancelled)
        XCTAssertFalse(vm.isCodeLoading)
        XCTAssertNil(vm.codeError)
        XCTAssertTrue(vm.selectedFunction?.codeFiles.isEmpty == true)
    }

    @MainActor
    func testSelectionChangesRejectLateCodeWhenSameFunctionIsSelectedAgain() async {
        let gate = TestGate()
        let first = makeFunction(name: "first")
        let second = makeFunction(name: "second")
        let vm = LambdaViewModel(codeLoader: { function in
            await gate.wait()
            return Self.withCode(function, content: "outdated")
        })
        vm.functions = [first, second]
        vm.selectedFunction = first
        let request = Task { await vm.loadCode(for: first.functionName) }
        await gate.waitForEntry()

        vm.selectedFunction = second
        vm.selectedFunction = first
        await gate.open()
        await request.value

        XCTAssertEqual(vm.selectedFunction?.functionName, "first")
        XCTAssertTrue(vm.selectedFunction?.codeFiles.isEmpty == true)
        XCTAssertNil(vm.codeError)
        XCTAssertFalse(vm.isCodeLoading)
    }

    @MainActor
    func testProfileReconfigurationRejectsLateCodeSuccessForSameFunctionName() async {
        let gate = TestGate()
        let oldFunction = makeFunction(name: "example")
        let vm = LambdaViewModel(codeLoader: { function in
            await gate.wait()
            return Self.withCode(function, content: "old-profile")
        })
        vm.functions = [oldFunction]
        vm.selectedFunction = oldFunction
        let request = Task { await vm.loadCode(for: oldFunction.functionName) }
        await gate.waitForEntry()

        vm.configure(provider: AWSServiceProvider(), refreshImmediately: false)
        var currentFunction = oldFunction
        currentFunction.arn = "arn:aws:lambda:us-east-1:222222222222:function:example"
        vm.functions = [currentFunction]
        vm.selectedFunction = currentFunction
        await gate.open()
        await request.value

        XCTAssertEqual(vm.selectedFunction?.arn, currentFunction.arn)
        XCTAssertEqual(vm.functions, [currentFunction])
        XCTAssertTrue(vm.selectedFunction?.codeFiles.isEmpty == true)
        XCTAssertNil(vm.codeError)
        XCTAssertFalse(vm.isCodeLoading)
    }

    @MainActor
    func testResetRejectsLateCodeFailureForSameFunctionName() async {
        let gate = TestGate()
        let function = makeFunction(name: "example")
        let vm = LambdaViewModel(codeLoader: { _ in
            await gate.wait()
            throw LambdaTestError.failed
        })
        vm.functions = [function]
        vm.selectedFunction = function
        let request = Task { await vm.loadCode(for: function.functionName) }
        await gate.waitForEntry()

        vm.reset()
        vm.functions = [function]
        vm.selectedFunction = function
        await gate.open()
        await request.value

        XCTAssertNil(vm.codeError)
        XCTAssertTrue(vm.selectedFunction?.codeFiles.isEmpty == true)
        XCTAssertFalse(vm.isCodeLoading)
    }

    @MainActor
    func testCodeLoadingRequiresCurrentSelection() async {
        var requests = 0
        let function = makeFunction(name: "example")
        let vm = LambdaViewModel(codeLoader: { function in
            requests += 1
            return Self.withCode(function, content: "source")
        })
        vm.functions = [function]
        await vm.loadCode(for: function.functionName)
        vm.loadCodeForSelection()
        await Task.yield()

        XCTAssertEqual(requests, 0)
        XCTAssertFalse(vm.isCodeLoading)
        XCTAssertTrue(vm.functions[0].codeFiles.isEmpty)
        XCTAssertNil(vm.codeError)
    }

    @MainActor
    func testCodeLoaderPreservesUpdatedFunctionMetadata() async {
        let function = makeFunction(name: "example")
        var updated = Self.withCode(function, content: "source")
        updated.runtime = "nodejs22.x"
        updated.arn = "arn:aws:lambda:us-east-1:123456789012:function:example"
        updated.tags = ["environment": "test"]
        updated.memorySize = 512
        let result = updated
        let vm = LambdaViewModel(codeLoader: { _ in result })
        vm.functions = [function]
        vm.selectedFunction = function

        await vm.loadCode(for: function.functionName)

        XCTAssertEqual(vm.functions, [updated])
        XCTAssertEqual(vm.selectedFunction, updated)
        XCTAssertNil(vm.codeError)
        XCTAssertFalse(vm.isCodeLoading)
    }

    @MainActor
    func testCodeFailureStaysInCodePaneAndCancellationHasNoError() async {
        let function = makeFunction(name: "example")
        var requests = 0
        let vm = LambdaViewModel(codeLoader: { _ in
            requests += 1
            if requests == 1 { throw LambdaTestError.failed }
            throw CancellationError()
        })
        vm.functions = [function]
        vm.selectedFunction = function

        await vm.loadCode(for: function.functionName)
        XCTAssertEqual(vm.codeError, "Lambda test operation failed.")
        XCTAssertNil(vm.error)
        XCTAssertNil(vm.detailError)
        XCTAssertFalse(vm.isCodeLoading)

        await vm.loadCode(for: function.functionName)
        XCTAssertNil(vm.codeError)
        XCTAssertFalse(vm.isCodeLoading)
        XCTAssertEqual(vm.functions, [function])
    }

    func testPaginatorCollectsEveryPageInOrder() async throws {
        let values: [Int] = try await LambdaPaginator.collect { marker in
            switch marker {
            case nil:
                return ([1, 2], "next")
            case "next":
                return ([3, 4], nil)
            default:
                XCTFail("Unexpected marker: \(marker ?? "nil")")
                return ([], nil)
            }
        }

        XCTAssertEqual(values, [1, 2, 3, 4])
    }

    func testPaginatorPropagatesCancellation() async {
        let task = Task {
            try await LambdaPaginator.collect { _ -> ([Int], String?) in
                try await Task.sleep(nanoseconds: 100_000_000)
                return ([1], nil)
            }
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPolicyParserHandlesMixedPrincipalAndSourceArnShapes() throws {
        let policy = """
        {
          "Version": "2012-10-17",
          "Statement": [{
            "Sid": "AllowInvoke",
            "Effect": "Allow",
            "Principal": {
              "AWS": "arn:aws:iam::123456789012:root",
              "Service": ["events.amazonaws.com", "sns.amazonaws.com"]
            },
            "Action": ["lambda:InvokeFunction", "lambda:GetFunction"],
            "Resource": "arn:aws:lambda:us-east-1:123456789012:function:example",
            "Condition": {
              "ArnLike": {
                "AWS:SourceArn": "arn:aws:events:us-east-1:123456789012:rule/example"
              }
            }
          }]
        }
        """

        let statements = try LambdaPolicyParser.parse(policy)

        XCTAssertEqual(statements.count, 1)
        XCTAssertEqual(statements[0].statementId, "AllowInvoke")
        XCTAssertEqual(
            statements[0].principals,
            [
                "arn:aws:iam::123456789012:root",
                "events.amazonaws.com",
                "sns.amazonaws.com"
            ]
        )
        XCTAssertEqual(
            statements[0].actions,
            ["lambda:InvokeFunction", "lambda:GetFunction"]
        )
        XCTAssertEqual(
            statements[0].sourceARNs,
            ["arn:aws:events:us-east-1:123456789012:rule/example"]
        )
    }

    func testPolicyParserAcceptsSingleStatementObject() throws {
        let policy = """
        {
          "Statement": {
            "Effect": "Allow",
            "Principal": "*",
            "Action": "lambda:InvokeFunction"
          }
        }
        """

        let statements = try LambdaPolicyParser.parse(policy)

        XCTAssertEqual(statements.count, 1)
        XCTAssertEqual(statements[0].statementId, "Statement 1")
        XCTAssertEqual(statements[0].principals, ["*"])
        XCTAssertEqual(statements[0].actions, ["lambda:InvokeFunction"])
    }

    func testPolicyParserRejectsDocumentWithoutStatements() {
        XCTAssertThrowsError(try LambdaPolicyParser.parse(#"{"Version":"2012-10-17"}"#))
    }

    private func makeFunction(
        name: String,
        state: String = "Active",
        packageType: String = "Zip"
    ) -> LambdaFunctionModel {
        LambdaFunctionModel(
            functionName: name,
            runtime: "provided.al2023",
            state: state,
            lastUpdateStatus: "Successful",
            lastModified: nil,
            memorySize: 128,
            arn: nil,
            handler: nil,
            role: nil,
            codeSize: nil,
            timeout: 3,
            environment: [:],
            vpcConfig: nil,
            packageType: packageType,
            imageUri: nil,
            tags: [:],
            codeLocation: nil,
            codeFiles: []
        )
    }

    private static func withCode(_ function: LambdaFunctionModel, content: String) -> LambdaFunctionModel {
        var updated = function
        updated.codeFiles = [LambdaCodeFile(path: "index.js", content: content, isBinary: false)]
        return updated
    }

    private static func makeDetail(
        functionName: String,
        warnings: [String] = []
    ) -> LambdaFunctionDetailModel {
        LambdaFunctionDetailModel(
            functionName: functionName,
            description: nil,
            state: "Active",
            stateReason: nil,
            stateReasonCode: nil,
            lastUpdateStatus: "Successful",
            lastUpdateStatusReason: nil,
            lastUpdateStatusReasonCode: nil,
            version: "$LATEST",
            architectures: ["arm64"],
            runtimeVersionARN: nil,
            revisionId: nil,
            codeSHA256: nil,
            configSHA256: nil,
            ephemeralStorageMB: 512,
            environment: [:],
            environmentError: nil,
            vpcId: nil,
            subnetIds: [],
            securityGroupIds: [],
            ipv6AllowedForDualStack: nil,
            layers: [],
            fileSystems: [],
            deadLetterTargetARN: nil,
            tracingMode: "PassThrough",
            logGroup: nil,
            logFormat: "Text",
            applicationLogLevel: nil,
            systemLogLevel: nil,
            kmsKeyARN: nil,
            sourceKMSKeyARN: nil,
            snapStartApplyOn: nil,
            snapStartOptimizationStatus: nil,
            imageEntryPoint: [],
            imageCommand: [],
            imageWorkingDirectory: nil,
            codeLocation: nil,
            imageURI: nil,
            resolvedImageURI: nil,
            repositoryType: nil,
            reservedConcurrency: nil,
            tags: [:],
            eventSources: [],
            asyncInvokeConfigs: [],
            functionURLs: [],
            versions: [],
            aliases: [],
            provisionedConcurrency: [],
            policyRevisionId: nil,
            policyStatements: [],
            warnings: warnings
        )
    }
}

private enum LambdaTestError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Lambda test operation failed."
    }
}
