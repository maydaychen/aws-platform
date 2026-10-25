import Foundation

/// Production aggregation shared by the AWS loaders and isolated permission-failure tests.
@MainActor
enum LambdaDetailSectionReader {
    static func triggers(
        eventSources: () async throws -> [LambdaEventSourceModel],
        asyncInvokeConfigs: () async throws -> [LambdaAsyncInvokeConfigModel],
        functionURLs: () async throws -> [LambdaFunctionURLModel]
    ) async throws -> LambdaDetailSectionData {
        var result = LambdaDetailSectionData()
        var issues: [LambdaDetailSectionIssue] = []
        result.eventSources = try await read(.eventSources, issues: &issues, loader: eventSources)
        result.asyncInvokeConfigs = try await read(.asyncInvokeConfigs, issues: &issues, loader: asyncInvokeConfigs)
        result.functionURLs = try await read(.functionURLs, issues: &issues, loader: functionURLs)
        result.issues = issues
        return result
    }

    static func versions(
        versions: () async throws -> [LambdaVersionModel],
        aliases: () async throws -> [LambdaAliasModel],
        provisionedConcurrency: () async throws -> [LambdaProvisionedConcurrencyModel]
    ) async throws -> LambdaDetailSectionData {
        var result = LambdaDetailSectionData()
        var issues: [LambdaDetailSectionIssue] = []
        result.versions = try await read(.versions, issues: &issues, loader: versions)
        result.aliases = try await read(.aliases, issues: &issues, loader: aliases)
        result.provisionedConcurrency = try await read(.provisionedConcurrency, issues: &issues, loader: provisionedConcurrency)
        result.issues = issues
        return result
    }

    private static func read<Value>(
        _ component: LambdaDetailComponent,
        issues: inout [LambdaDetailSectionIssue],
        loader: () async throws -> [Value]
    ) async throws -> [Value] {
        try Task.checkCancellation()
        do {
            let values = try await loader()
            try Task.checkCancellation()
            return values
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            issues.append(LambdaDetailSectionIssue(component: component, message: UserFacingError.message(for: error)))
            return []
        }
    }
}
