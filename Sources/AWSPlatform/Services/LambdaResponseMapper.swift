import Foundation
import SotoLambda

enum LambdaResponseMapper {
    static func function(_ function: Lambda.FunctionConfiguration) -> LambdaFunctionModel {
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

    static func detail(functionName: String, response: Lambda.GetFunctionResponse) throws -> LambdaFunctionDetailModel {
        guard let configuration = response.configuration else { throw LambdaDetailError.missingConfiguration }
        var warnings: [String] = []
        if let tagsError = response.tagsError {
            warnings.append("Tags: \(tagsError.errorCode): \(tagsError.message)")
        }
        if let error = configuration.environment?.error {
            warnings.append("Environment: \(error.errorCode ?? "Unknown"): \(error.message ?? "Unable to load variables.")")
        }
        if let error = configuration.runtimeVersionConfig?.error {
            warnings.append("Runtime version: \(error.errorCode ?? "Unknown"): \(error.message ?? "Unable to load runtime version.")")
        }
        if let error = configuration.imageConfigResponse?.error {
            warnings.append("Image config: \(error.errorCode ?? "Unknown"): \(error.message ?? "Unable to load image configuration.")")
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
                return LambdaLayerModel(arn: arn, codeSize: layer.codeSize,
                                        signingJobARN: layer.signingJobArn, signingProfileVersionARN: layer.signingProfileVersionArn)
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
            eventSources: [], asyncInvokeConfigs: [], functionURLs: [], versions: [], aliases: [], provisionedConcurrency: [],
            policyRevisionId: nil, policyStatements: [], warnings: warnings
        )
    }

    static func asyncInvokeConfig(_ config: Lambda.FunctionEventInvokeConfig, functionName: String) -> LambdaAsyncInvokeConfigModel? {
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

    static func functionURL(_ config: Lambda.FunctionUrlConfig) -> LambdaFunctionURLModel {
        LambdaFunctionURLModel(
            functionARN: config.functionArn, url: config.functionUrl, authType: config.authType.rawValue,
            invokeMode: config.invokeMode?.rawValue, creationTime: config.creationTime, lastModifiedTime: config.lastModifiedTime,
            allowCredentials: config.cors?.allowCredentials, allowedOrigins: config.cors?.allowOrigins ?? [],
            allowedMethods: config.cors?.allowMethods ?? []
        )
    }

    static func provisionedConcurrency(
        _ config: Lambda.ProvisionedConcurrencyConfigListItem, functionName: String
    ) -> LambdaProvisionedConcurrencyModel? {
        guard let functionARN = config.functionArn else { return nil }
        return LambdaProvisionedConcurrencyModel(
            functionARN: functionARN,
            qualifier: qualifier(from: functionARN, functionName: functionName),
            requested: config.requestedProvisionedConcurrentExecutions,
            allocated: config.allocatedProvisionedConcurrentExecutions,
            available: config.availableProvisionedConcurrentExecutions,
            status: config.status?.rawValue, statusReason: config.statusReason, lastModified: config.lastModified
        )
    }

    // This nonisolated async boundary keeps synchronous policy JSON work off the main actor.
    static func policyStatements(from policy: String) async throws -> [LambdaPolicyStatementModel] {
        try Task.checkCancellation()
        let statements = try LambdaPolicyParser.parse(policy)
        try Task.checkCancellation()
        return statements
    }

    private static func qualifier(from arn: String, functionName: String) -> String {
        let components = arn.split(separator: ":").map(String.init)
        guard let nameIndex = components.lastIndex(of: functionName), nameIndex + 1 < components.count else { return "$LATEST" }
        return components[nameIndex + 1]
    }
}
