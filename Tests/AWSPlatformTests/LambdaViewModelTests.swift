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

    private func makeFunction(name: String) -> LambdaFunctionModel {
        LambdaFunctionModel(
            functionName: name,
            runtime: "provided.al2023",
            lastModified: nil,
            memorySize: 128,
            arn: nil,
            handler: nil,
            role: nil,
            codeSize: nil,
            timeout: 3,
            environment: [:],
            vpcConfig: nil,
            packageType: "Zip",
            imageUri: nil,
            tags: [:],
            codeLocation: nil,
            codeFiles: []
        )
    }
}

private enum LambdaTestError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Lambda test operation failed."
    }
}
