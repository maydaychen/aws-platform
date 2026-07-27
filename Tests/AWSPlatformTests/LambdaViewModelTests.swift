import XCTest
@testable import AWSPlatform

final class LambdaViewModelTests: XCTestCase {
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
