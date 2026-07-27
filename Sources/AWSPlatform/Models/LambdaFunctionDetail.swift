import Foundation

struct LambdaFunctionDetailModel: Hashable {
    let functionName: String
    let description: String?
    let state: String?
    let stateReason: String?
    let stateReasonCode: String?
    let lastUpdateStatus: String?
    let lastUpdateStatusReason: String?
    let lastUpdateStatusReasonCode: String?
    let version: String?
    let architectures: [String]
    let runtimeVersionARN: String?
    let revisionId: String?
    let codeSHA256: String?
    let configSHA256: String?
    let ephemeralStorageMB: Int?
    let environment: [String: String]
    let environmentError: String?
    let vpcId: String?
    let subnetIds: [String]
    let securityGroupIds: [String]
    let ipv6AllowedForDualStack: Bool?
    let layers: [LambdaLayerModel]
    let fileSystems: [LambdaFileSystemModel]
    let deadLetterTargetARN: String?
    let tracingMode: String?
    let logGroup: String?
    let logFormat: String?
    let applicationLogLevel: String?
    let systemLogLevel: String?
    let kmsKeyARN: String?
    let sourceKMSKeyARN: String?
    let snapStartApplyOn: String?
    let snapStartOptimizationStatus: String?
    let imageEntryPoint: [String]
    let imageCommand: [String]
    let imageWorkingDirectory: String?
    let codeLocation: String?
    let imageURI: String?
    let resolvedImageURI: String?
    let repositoryType: String?
    let reservedConcurrency: Int?
    let tags: [String: String]
    let eventSources: [LambdaEventSourceModel]
    let asyncInvokeConfigs: [LambdaAsyncInvokeConfigModel]
    let functionURLs: [LambdaFunctionURLModel]
    let versions: [LambdaVersionModel]
    let aliases: [LambdaAliasModel]
    let provisionedConcurrency: [LambdaProvisionedConcurrencyModel]
    let policyRevisionId: String?
    let policyStatements: [LambdaPolicyStatementModel]
    let warnings: [String]
}

struct LambdaLayerModel: Identifiable, Hashable {
    let arn: String
    let codeSize: Int64?
    let signingJobARN: String?
    let signingProfileVersionARN: String?

    var id: String { arn }
}

struct LambdaFileSystemModel: Identifiable, Hashable {
    let arn: String
    let localMountPath: String

    var id: String { arn }
}

struct LambdaEventSourceModel: Identifiable, Hashable {
    let uuid: String
    let type: String
    let sourceARN: String?
    let state: String?
    let stateTransitionReason: String?
    let batchSize: Int?
    let batchingWindowSeconds: Int?
    let parallelizationFactor: Int?
    let maximumRetryAttempts: Int?
    let maximumRecordAgeSeconds: Int?
    let startingPosition: String?
    let bisectBatchOnError: Bool?
    let lastProcessingResult: String?
    let onFailureDestination: String?

    var id: String { uuid }
}

struct LambdaAsyncInvokeConfigModel: Identifiable, Hashable {
    let functionARN: String
    let qualifier: String
    let maximumEventAgeSeconds: Int?
    let maximumRetryAttempts: Int?
    let onSuccessDestination: String?
    let onFailureDestination: String?
    let lastModified: Date?

    var id: String { functionARN }
}

struct LambdaFunctionURLModel: Identifiable, Hashable {
    let functionARN: String
    let url: String
    let authType: String
    let invokeMode: String?
    let creationTime: String
    let lastModifiedTime: String
    let allowCredentials: Bool?
    let allowedOrigins: [String]
    let allowedMethods: [String]

    var id: String { functionARN }
}

struct LambdaVersionModel: Identifiable, Hashable {
    let version: String
    let state: String?
    let runtime: String?
    let architectures: [String]
    let description: String?
    let lastModified: String?
    let codeSize: Int64?
    let memorySize: Int?
    let timeout: Int?

    var id: String { version }
}

struct LambdaAliasModel: Identifiable, Hashable {
    let name: String
    let functionVersion: String?
    let description: String?
    let revisionId: String?
    let additionalVersionWeights: [String: Double]

    var id: String { name }
}

struct LambdaProvisionedConcurrencyModel: Identifiable, Hashable {
    let functionARN: String
    let qualifier: String
    let requested: Int?
    let allocated: Int?
    let available: Int?
    let status: String?
    let statusReason: String?
    let lastModified: String?

    var id: String { functionARN }
}

struct LambdaPolicyStatementModel: Identifiable, Hashable {
    let id: Int
    let statementId: String
    let effect: String?
    let principals: [String]
    let actions: [String]
    let resources: [String]
    let sourceARNs: [String]
}

enum LambdaPolicyParser {
    static func parse(_ policy: String) throws -> [LambdaPolicyStatementModel] {
        guard let data = policy.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LambdaPolicyParseError.invalidDocument
        }

        let rawStatements: [[String: Any]]
        if let statements = root["Statement"] as? [[String: Any]] {
            rawStatements = statements
        } else if let statement = root["Statement"] as? [String: Any] {
            rawStatements = [statement]
        } else {
            throw LambdaPolicyParseError.missingStatements
        }

        return rawStatements.enumerated().map { index, statement in
            LambdaPolicyStatementModel(
                id: index,
                statementId: statement["Sid"] as? String ?? "Statement \(index + 1)",
                effect: statement["Effect"] as? String,
                principals: stringValues(statement["Principal"]),
                actions: stringValues(statement["Action"]),
                resources: stringValues(statement["Resource"]),
                sourceARNs: sourceARNValues(statement["Condition"])
            )
        }
    }

    private static func stringValues(_ value: Any?) -> [String] {
        switch value {
        case let string as String:
            return [string]
        case let strings as [String]:
            return strings
        case let values as [Any]:
            return values.flatMap { stringValues($0) }
        case let dictionary as [String: Any]:
            return dictionary.keys.sorted().flatMap { key in
                stringValues(dictionary[key])
            }
        default:
            return []
        }
    }

    private static func sourceARNValues(_ value: Any?) -> [String] {
        guard let dictionary = value as? [String: Any] else {
            return []
        }

        return dictionary.keys.sorted().flatMap { key -> [String] in
            let child = dictionary[key]
            if key.lowercased().contains("sourcearn") {
                return stringValues(child)
            }
            if let nested = child as? [String: Any] {
                return sourceARNValues(nested)
            }
            return []
        }
    }
}

private enum LambdaPolicyParseError: LocalizedError {
    case invalidDocument
    case missingStatements

    var errorDescription: String? {
        switch self {
        case .invalidDocument:
            return "Lambda resource policy is not valid JSON."
        case .missingStatements:
            return "Lambda resource policy does not contain statements."
        }
    }
}
