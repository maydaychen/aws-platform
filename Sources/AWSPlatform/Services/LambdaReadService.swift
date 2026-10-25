import Foundation
import SotoCore
import SotoLambda

@MainActor
enum LambdaReadService {
    static func fetchCode(
        for function: LambdaFunctionModel,
        provider: AWSServiceProvider,
        scope: MonitoringScope
    ) async throws -> LambdaFunctionModel {
        let client = try await provider.lambdaClient(scope: scope)
        let response = try await client.getFunction(.init(functionName: function.functionName))
        try Task.checkCancellation()
        var updated = function
        updated.arn = response.configuration?.functionArn
        updated.runtime = response.configuration?.runtime?.rawValue
        updated.state = response.configuration?.state?.rawValue
        updated.lastUpdateStatus = response.configuration?.lastUpdateStatus?.rawValue
        updated.handler = response.configuration?.handler
        updated.role = response.configuration?.role
        updated.timeout = response.configuration?.timeout
        updated.memorySize = response.configuration?.memorySize
        updated.codeSize = response.configuration?.codeSize
        updated.environment = response.configuration?.environment?.variables ?? updated.environment
        updated.vpcConfig = response.configuration?.vpcConfig?.vpcId
        updated.packageType = response.configuration?.packageType?.rawValue ?? updated.packageType
        updated.codeLocation = response.code?.location
        updated.imageUri = response.code?.imageUri
        updated.tags = response.tags ?? updated.tags

        if updated.packageType == "Image" {
            updated.codeFiles = [
                LambdaCodeFile(
                    path: "Container Image",
                    content: updated.imageUri,
                    isBinary: true
                )
            ]
        } else if let location = response.code?.location {
            updated.codeFiles = try await LambdaCodePreview().load(from: location)
        }
        return updated
    }

    static func fetchFunctions(client: Lambda) async throws -> [LambdaFunctionModel] {
        let configurations: [Lambda.FunctionConfiguration] = try await LambdaPaginator.collect { marker in
            let response = try await client.listFunctions(.init(marker: marker))
            return (response.functions ?? [], response.nextMarker)
        }

        return configurations.map(LambdaResponseMapper.function)
    }

    static func fetchDetail(
        functionName: String,
        client: Lambda
    ) async throws -> LambdaFunctionDetailModel {
        let response = try await client.getFunction(.init(functionName: functionName))
        return try LambdaResponseMapper.detail(functionName: functionName, response: response)
    }

    static func fetchSection(
        functionName: String,
        section: LambdaDetailSection,
        client: Lambda
    ) async throws -> LambdaDetailSectionData {
        switch section {
        case .configuration:
            do {
                let response = try await client.getPolicy(.init(functionName: functionName))
                let statements: [LambdaPolicyStatementModel]
                if let policy = response.policy {
                    statements = try await LambdaResponseMapper.policyStatements(from: policy)
                } else {
                    statements = []
                }
                return LambdaDetailSectionData(policyRevisionId: response.revisionId, policyStatements: statements)
            } catch {
                try Task.checkCancellation()
                if errorCode(error) == "ResourceNotFoundException" { return LambdaDetailSectionData() }
                throw error
            }
        case .triggers:
            return try await LambdaDetailSectionReader.triggers(
                eventSources: { try await fetchEventSources(functionName: functionName, client: client) },
                asyncInvokeConfigs: { try await fetchAsyncInvokeConfigs(functionName: functionName, client: client) },
                functionURLs: { try await fetchFunctionURLs(functionName: functionName, client: client) }
            )
        case .versions:
            return try await LambdaDetailSectionReader.versions(
                versions: { try await fetchVersions(functionName: functionName, client: client) },
                aliases: { try await fetchAliases(functionName: functionName, client: client) },
                provisionedConcurrency: { try await fetchProvisionedConcurrency(functionName: functionName, client: client) }
            )
        }
    }

    private static func fetchEventSources(
        functionName: String,
        client: Lambda
    ) async throws -> [LambdaEventSourceModel] {
        let mappings: [Lambda.EventSourceMappingConfiguration] = try await LambdaPaginator.collect { marker in
            let response = try await client.listEventSourceMappings(
                .init(functionName: functionName, marker: marker)
            )
            return (response.eventSourceMappings ?? [], response.nextMarker)
        }

        return mappings.enumerated().map { index, mapping in
            let source = mapping.eventSourceArn
                ?? mapping.queues?.joined(separator: ", ")
                ?? mapping.topics?.joined(separator: ", ")
            return LambdaEventSourceModel(
                uuid: mapping.uuid
                    ?? mapping.eventSourceMappingArn
                    ?? "\(source ?? "event-source")-\(index)",
                type: eventSourceType(source),
                sourceARN: source,
                state: mapping.state,
                stateTransitionReason: mapping.stateTransitionReason,
                batchSize: mapping.batchSize,
                batchingWindowSeconds: mapping.maximumBatchingWindowInSeconds,
                parallelizationFactor: mapping.parallelizationFactor,
                maximumRetryAttempts: mapping.maximumRetryAttempts,
                maximumRecordAgeSeconds: mapping.maximumRecordAgeInSeconds,
                startingPosition: mapping.startingPosition?.rawValue,
                bisectBatchOnError: mapping.bisectBatchOnFunctionError,
                lastProcessingResult: mapping.lastProcessingResult,
                onFailureDestination: mapping.destinationConfig?.onFailure?.destination
            )
        }
    }

    private static func fetchAsyncInvokeConfigs(
        functionName: String,
        client: Lambda
    ) async throws -> [LambdaAsyncInvokeConfigModel] {
        let configs: [Lambda.FunctionEventInvokeConfig] = try await LambdaPaginator.collect { marker in
            let response = try await client.listFunctionEventInvokeConfigs(
                .init(functionName: functionName, marker: marker)
            )
            return (response.functionEventInvokeConfigs ?? [], response.nextMarker)
        }

        return configs.compactMap { LambdaResponseMapper.asyncInvokeConfig($0, functionName: functionName) }
    }

    private static func fetchFunctionURLs(
        functionName: String,
        client: Lambda
    ) async throws -> [LambdaFunctionURLModel] {
        let configurations: [Lambda.FunctionUrlConfig] = try await LambdaPaginator.collect { marker in
            let response = try await client.listFunctionUrlConfigs(
                .init(functionName: functionName, marker: marker)
            )
            return (response.functionUrlConfigs, response.nextMarker)
        }

        return configurations.map(LambdaResponseMapper.functionURL)
    }

    private static func fetchVersions(
        functionName: String,
        client: Lambda
    ) async throws -> [LambdaVersionModel] {
        let configurations: [Lambda.FunctionConfiguration] = try await LambdaPaginator.collect { marker in
            let response = try await client.listVersionsByFunction(
                .init(functionName: functionName, marker: marker)
            )
            return (response.versions ?? [], response.nextMarker)
        }

        return configurations.map { version in
            LambdaVersionModel(
                version: version.version ?? "unknown",
                state: version.state?.rawValue,
                runtime: version.runtime?.rawValue,
                architectures: version.architectures?.map(\.rawValue) ?? [],
                description: version.description,
                lastModified: version.lastModified,
                codeSize: version.codeSize,
                memorySize: version.memorySize,
                timeout: version.timeout
            )
        }
    }

    private static func fetchAliases(
        functionName: String,
        client: Lambda
    ) async throws -> [LambdaAliasModel] {
        let configurations: [Lambda.AliasConfiguration] = try await LambdaPaginator.collect { marker in
            let response = try await client.listAliases(
                .init(functionName: functionName, marker: marker)
            )
            return (response.aliases ?? [], response.nextMarker)
        }

        return configurations.compactMap { alias in
            guard let name = alias.name else { return nil }
            return LambdaAliasModel(
                name: name,
                functionVersion: alias.functionVersion,
                description: alias.description,
                revisionId: alias.revisionId,
                additionalVersionWeights: alias.routingConfig?.additionalVersionWeights ?? [:]
            )
        }
    }

    private static func fetchProvisionedConcurrency(
        functionName: String,
        client: Lambda
    ) async throws -> [LambdaProvisionedConcurrencyModel] {
        let configurations: [Lambda.ProvisionedConcurrencyConfigListItem] =
            try await LambdaPaginator.collect { marker in
                let response = try await client.listProvisionedConcurrencyConfigs(
                    .init(functionName: functionName, marker: marker)
                )
                return (response.provisionedConcurrencyConfigs ?? [], response.nextMarker)
            }

        return configurations.compactMap { LambdaResponseMapper.provisionedConcurrency($0, functionName: functionName) }
    }

    private static func eventSourceType(_ source: String?) -> String {
        guard let source = source?.lowercased() else { return "Other" }
        if source.contains(":sqs:") { return "SQS" }
        if source.contains(":kinesis:") { return "Kinesis" }
        if source.contains(":dynamodb:") { return "DynamoDB Streams" }
        if source.contains(":kafka:") { return "MSK / Kafka" }
        if source.contains(":mq:") { return "Amazon MQ" }
        if source.contains(":rds:") || source.contains(":docdb:") {
            return "DocumentDB"
        }
        return "Other"
    }

    private static func errorCode(_ error: Error) -> String? {
        if let error = error as? LambdaErrorType {
            return error.errorCode
        }
        if let error = error as? AWSResponseError {
            return error.errorCode
        }
        if let error = error as? AWSErrorType {
            return error.errorCode
        }
        return nil
    }
}


enum LambdaDetailError: LocalizedError, Equatable {
    case missingConfiguration
    case incompletePagination

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "The selected Lambda function configuration is unavailable."
        case .incompletePagination:
            return "Lambda pagination could not be completed. Partial results were not displayed. Refresh to try again."
        }
    }
}

@MainActor
enum LambdaPaginator {
    static func collect<Item>(
        maxPages: Int = 1_000,
        _ loadPage: (String?) async throws -> ([Item], String?)
    ) async throws -> [Item] {
        var result: [Item] = []
        var marker: String?
        var seenMarkers: Set<String> = []

        guard maxPages > 0 else { throw LambdaDetailError.incompletePagination }
        for _ in 0..<maxPages {
            try Task.checkCancellation()
            let page = try await loadPage(marker)
            try Task.checkCancellation()
            result += page.0
            guard let next = page.1, !next.isEmpty else { return result }
            guard !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seenMarkers.insert(next).inserted else { throw LambdaDetailError.incompletePagination }
            marker = next
        }
        throw LambdaDetailError.incompletePagination
    }
}
