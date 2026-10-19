import XCTest
@testable import AWSPlatform

final class LambdaDetailSectionReaderTests: XCTestCase {
    @MainActor
    func testEachTriggerPermissionFailureKeepsOtherAPIResults() async throws {
        for failing in [LambdaDetailComponent.eventSources, .asyncInvokeConfigs, .functionURLs] {
            var calls: [LambdaDetailComponent] = []
            let result = try await LambdaDetailSectionReader.triggers(
                eventSources: {
                    calls.append(.eventSources)
                    if failing == .eventSources { throw LambdaSectionReaderError.denied }
                    return [Self.mapping]
                },
                asyncInvokeConfigs: {
                    calls.append(.asyncInvokeConfigs)
                    if failing == .asyncInvokeConfigs { throw LambdaSectionReaderError.denied }
                    return [Self.asyncConfig]
                },
                functionURLs: {
                    calls.append(.functionURLs)
                    if failing == .functionURLs { throw LambdaSectionReaderError.denied }
                    return [Self.functionURL]
                }
            )
            XCTAssertEqual(calls, [.eventSources, .asyncInvokeConfigs, .functionURLs])
            XCTAssertEqual(result.eventSources.count, failing == .eventSources ? 0 : 1)
            XCTAssertEqual(result.asyncInvokeConfigs.count, failing == .asyncInvokeConfigs ? 0 : 1)
            XCTAssertEqual(result.functionURLs.count, failing == .functionURLs ? 0 : 1)
            XCTAssertEqual(result.issues, [LambdaDetailSectionIssue(component: failing, message: "Permission denied.")])
        }
    }

    @MainActor
    func testEachVersionPermissionFailureKeepsOtherAPIResults() async throws {
        for failing in [LambdaDetailComponent.versions, .aliases, .provisionedConcurrency] {
            var calls: [LambdaDetailComponent] = []
            let result = try await LambdaDetailSectionReader.versions(
                versions: {
                    calls.append(.versions)
                    if failing == .versions { throw LambdaSectionReaderError.denied }
                    return [Self.version]
                },
                aliases: {
                    calls.append(.aliases)
                    if failing == .aliases { throw LambdaSectionReaderError.denied }
                    return [Self.alias]
                },
                provisionedConcurrency: {
                    calls.append(.provisionedConcurrency)
                    if failing == .provisionedConcurrency { throw LambdaSectionReaderError.denied }
                    return [Self.concurrency]
                }
            )
            XCTAssertEqual(calls, [.versions, .aliases, .provisionedConcurrency])
            XCTAssertEqual(result.versions.count, failing == .versions ? 0 : 1)
            XCTAssertEqual(result.aliases.count, failing == .aliases ? 0 : 1)
            XCTAssertEqual(result.provisionedConcurrency.count, failing == .provisionedConcurrency ? 0 : 1)
            XCTAssertEqual(result.issues, [LambdaDetailSectionIssue(component: failing, message: "Permission denied.")])
        }
    }

    @MainActor
    func testAllFailuresRemainExplicitRatherThanSuccessfulEmptyResults() async throws {
        let triggers = try await LambdaDetailSectionReader.triggers(
            eventSources: { throw LambdaSectionReaderError.denied },
            asyncInvokeConfigs: { throw LambdaSectionReaderError.denied },
            functionURLs: { throw LambdaSectionReaderError.denied }
        )
        let versions = try await LambdaDetailSectionReader.versions(
            versions: { throw LambdaSectionReaderError.denied },
            aliases: { throw LambdaSectionReaderError.denied },
            provisionedConcurrency: { throw LambdaSectionReaderError.denied }
        )
        XCTAssertEqual(triggers.issues.map(\.component), [.eventSources, .asyncInvokeConfigs, .functionURLs])
        XCTAssertEqual(versions.issues.map(\.component), [.versions, .aliases, .provisionedConcurrency])
    }

    @MainActor
    func testActualEmptyResultsHaveNoIssues() async throws {
        let triggers = try await LambdaDetailSectionReader.triggers(
            eventSources: { [] }, asyncInvokeConfigs: { [] }, functionURLs: { [] }
        )
        let versions = try await LambdaDetailSectionReader.versions(
            versions: { [] }, aliases: { [] }, provisionedConcurrency: { [] }
        )
        XCTAssertTrue(triggers.issues.isEmpty)
        XCTAssertTrue(versions.issues.isEmpty)
    }

    @MainActor
    func testCancellationStopsLaterSubqueriesAndIsNotAPartialFailure() async {
        var laterCalls = 0
        do {
            _ = try await LambdaDetailSectionReader.triggers(
                eventSources: { throw CancellationError() },
                asyncInvokeConfigs: { laterCalls += 1; return [] },
                functionURLs: { laterCalls += 1; return [] }
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
        do {
            _ = try await LambdaDetailSectionReader.versions(
                versions: { [] },
                aliases: { throw CancellationError() },
                provisionedConcurrency: { laterCalls += 1; return [] }
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(laterCalls, 0)
    }

    private static var mapping: LambdaEventSourceModel {
        LambdaEventSourceModel(
            uuid: "mapping", type: "SQS", sourceARN: "source", state: "Enabled",
            stateTransitionReason: nil, batchSize: nil, batchingWindowSeconds: nil,
            parallelizationFactor: nil, maximumRetryAttempts: nil, maximumRecordAgeSeconds: nil,
            startingPosition: nil, bisectBatchOnError: nil, lastProcessingResult: nil,
            onFailureDestination: nil
        )
    }

    private static var asyncConfig: LambdaAsyncInvokeConfigModel {
        LambdaAsyncInvokeConfigModel(
            functionARN: "function", qualifier: "$LATEST", maximumEventAgeSeconds: nil,
            maximumRetryAttempts: nil, onSuccessDestination: nil, onFailureDestination: nil,
            lastModified: nil
        )
    }

    private static var functionURL: LambdaFunctionURLModel {
        LambdaFunctionURLModel(
            functionARN: "function", url: "https://example.invalid/", authType: "AWS_IAM",
            invokeMode: nil, creationTime: "", lastModifiedTime: "", allowCredentials: nil,
            allowedOrigins: [], allowedMethods: []
        )
    }

    private static var version: LambdaVersionModel {
        LambdaVersionModel(
            version: "2", state: "Active", runtime: nil, architectures: [], description: nil,
            lastModified: nil, codeSize: nil, memorySize: nil, timeout: nil
        )
    }

    private static var alias: LambdaAliasModel {
        LambdaAliasModel(name: "live", functionVersion: "2", description: nil,
                         revisionId: nil, additionalVersionWeights: [:])
    }

    private static var concurrency: LambdaProvisionedConcurrencyModel {
        LambdaProvisionedConcurrencyModel(
            functionARN: "function", qualifier: "live", requested: 1, allocated: 1,
            available: 1, status: "READY", statusReason: nil, lastModified: nil
        )
    }
}

private enum LambdaSectionReaderError: LocalizedError {
    case denied
    var errorDescription: String? { "Permission denied." }
}
