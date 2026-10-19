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

        return configurations.map { function in
            LambdaFunctionModel(
                functionName: function.functionName ?? "unknown",
                runtime: function.runtime?.rawValue,
                state: function.state?.rawValue,
                lastUpdateStatus: function.lastUpdateStatus?.rawValue,
                lastModified: function.lastModified,
                memorySize: function.memorySize,
                arn: function.functionArn,
                handler: function.handler,
                role: function.role,
                codeSize: function.codeSize,
                timeout: function.timeout,
                environment: function.environment?.variables ?? [:],
                vpcConfig: function.vpcConfig?.vpcId,
                packageType: function.packageType?.rawValue,
                imageUri: nil,
                tags: [:],
                codeLocation: nil,
                codeFiles: []
            )
        }
    }

    static func fetchDetail(
        functionName: String,
        client: Lambda
    ) async throws -> LambdaFunctionDetailModel {
        let response = try await client.getFunction(.init(functionName: functionName))
        guard let configuration = response.configuration else {
            throw LambdaDetailError.missingConfiguration
        }

        var warnings: [String] = []
        if let tagsError = response.tagsError {
            warnings.append("Tags: \(tagsError.errorCode): \(tagsError.message)")
        }
        if let error = configuration.environment?.error {
            warnings.append(
                "Environment: \(error.errorCode ?? "Unknown"): \(error.message ?? "Unable to load variables.")"
            )
        }
        if let error = configuration.runtimeVersionConfig?.error {
            warnings.append(
                "Runtime version: \(error.errorCode ?? "Unknown"): \(error.message ?? "Unable to load runtime version.")"
            )
        }
        if let error = configuration.imageConfigResponse?.error {
            warnings.append(
                "Image config: \(error.errorCode ?? "Unknown"): \(error.message ?? "Unable to load image configuration.")"
            )
        }

        let imageConfig = configuration.imageConfigResponse?.imageConfig
        return LambdaFunctionDetailModel(
            functionName: functionName,
            description: configuration.description,
            state: configuration.state?.rawValue,
            stateReason: configuration.stateReason,
            stateReasonCode: configuration.stateReasonCode?.rawValue,
            lastUpdateStatus: configuration.lastUpdateStatus?.rawValue,
            lastUpdateStatusReason: configuration.lastUpdateStatusReason,
            lastUpdateStatusReasonCode: configuration.lastUpdateStatusReasonCode?.rawValue,
            version: configuration.version,
            architectures: configuration.architectures?.map(\.rawValue) ?? [],
            runtimeVersionARN: configuration.runtimeVersionConfig?.runtimeVersionArn,
            revisionId: configuration.revisionId,
            codeSHA256: configuration.codeSha256,
            configSHA256: configuration.configSha256,
            ephemeralStorageMB: configuration.ephemeralStorage?.size,
            environment: configuration.environment?.variables ?? [:],
            environmentError: configuration.environment?.error?.message,
            vpcId: configuration.vpcConfig?.vpcId,
            subnetIds: configuration.vpcConfig?.subnetIds ?? [],
            securityGroupIds: configuration.vpcConfig?.securityGroupIds ?? [],
            ipv6AllowedForDualStack: configuration.vpcConfig?.ipv6AllowedForDualStack,
            layers: (configuration.layers ?? []).compactMap { layer in
                guard let arn = layer.arn else { return nil }
                return LambdaLayerModel(
                    arn: arn,
                    codeSize: layer.codeSize,
                    signingJobARN: layer.signingJobArn,
                    signingProfileVersionARN: layer.signingProfileVersionArn
                )
            },
            fileSystems: (configuration.fileSystemConfigs ?? []).map {
                LambdaFileSystemModel(arn: $0.arn, localMountPath: $0.localMountPath)
            },
            deadLetterTargetARN: configuration.deadLetterConfig?.targetArn,
            tracingMode: configuration.tracingConfig?.mode?.rawValue,
            logGroup: configuration.loggingConfig?.logGroup,
            logFormat: configuration.loggingConfig?.logFormat?.rawValue,
            applicationLogLevel: configuration.loggingConfig?.applicationLogLevel?.rawValue,
            systemLogLevel: configuration.loggingConfig?.systemLogLevel?.rawValue,
            kmsKeyARN: configuration.kmsKeyArn,
            sourceKMSKeyARN: response.code?.sourceKMSKeyArn,
            snapStartApplyOn: configuration.snapStart?.applyOn?.rawValue,
            snapStartOptimizationStatus: configuration.snapStart?.optimizationStatus?.rawValue,
            imageEntryPoint: imageConfig?.entryPoint ?? [],
            imageCommand: imageConfig?.command ?? [],
            imageWorkingDirectory: imageConfig?.workingDirectory,
            codeLocation: response.code?.location,
            imageURI: response.code?.imageUri,
            resolvedImageURI: response.code?.resolvedImageUri,
            repositoryType: response.code?.repositoryType,
            reservedConcurrency: response.concurrency?.reservedConcurrentExecutions,
            tags: response.tags ?? [:],
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

    static func fetchSection(
        functionName: String,
        section: LambdaDetailSection,
        client: Lambda
    ) async throws -> LambdaDetailSectionData {
        switch section {
        case .configuration:
            do {
                let response = try await client.getPolicy(.init(functionName: functionName))
                let statements = try response.policy.map(LambdaPolicyParser.parse) ?? []
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

        return configs.compactMap { config in
            guard let functionARN = config.functionArn else { return nil }
            return LambdaAsyncInvokeConfigModel(
                functionARN: functionARN,
                qualifier: qualifier(from: functionARN, functionName: functionName),
                maximumEventAgeSeconds: config.maximumEventAgeInSeconds,
                maximumRetryAttempts: config.maximumRetryAttempts,
                onSuccessDestination: config.destinationConfig?.onSuccess?.destination,
                onFailureDestination: config.destinationConfig?.onFailure?.destination,
                lastModified: config.lastModified
            )
        }
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

        return configurations.map { config in
            LambdaFunctionURLModel(
                functionARN: config.functionArn,
                url: config.functionUrl,
                authType: config.authType.rawValue,
                invokeMode: config.invokeMode?.rawValue,
                creationTime: config.creationTime,
                lastModifiedTime: config.lastModifiedTime,
                allowCredentials: config.cors?.allowCredentials,
                allowedOrigins: config.cors?.allowOrigins ?? [],
                allowedMethods: config.cors?.allowMethods ?? []
            )
        }
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

        return configurations.compactMap { config in
            guard let functionARN = config.functionArn else { return nil }
            return LambdaProvisionedConcurrencyModel(
                functionARN: functionARN,
                qualifier: qualifier(from: functionARN, functionName: functionName),
                requested: config.requestedProvisionedConcurrentExecutions,
                allocated: config.allocatedProvisionedConcurrentExecutions,
                available: config.availableProvisionedConcurrentExecutions,
                status: config.status?.rawValue,
                statusReason: config.statusReason,
                lastModified: config.lastModified
            )
        }
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

    private static func qualifier(from arn: String, functionName: String) -> String {
        let components = arn.split(separator: ":").map(String.init)
        guard let nameIndex = components.lastIndex(of: functionName),
              nameIndex + 1 < components.count else {
            return "$LATEST"
        }
        return components[nameIndex + 1]
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


enum LambdaDetailError: LocalizedError {
    case missingConfiguration

    var errorDescription: String? {
        "The selected Lambda function configuration is unavailable."
    }
}

@MainActor
enum LambdaPaginator {
    static func collect<Item>(
        _ loadPage: (String?) async throws -> ([Item], String?)
    ) async throws -> [Item] {
        var result: [Item] = []
        var marker: String?

        repeat {
            try Task.checkCancellation()
            let page = try await loadPage(marker)
            result += page.0
            marker = page.1
        } while marker != nil

        return result
    }
}
