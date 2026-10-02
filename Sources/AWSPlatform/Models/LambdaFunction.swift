import Foundation

struct LambdaFunctionModel: Identifiable, Hashable {
    var functionName: String
    var runtime: String?
    var state: String?
    var lastUpdateStatus: String?
    var lastModified: String?
    var memorySize: Int?
    var arn: String?
    var handler: String?
    var role: String?
    var codeSize: Int64?
    var timeout: Int?
    var environment: [String: String]
    var vpcConfig: String?
    var packageType: String?
    var imageUri: String?
    var tags: [String: String]
    var codeLocation: String?
    var codeFiles: [LambdaCodeFile]

    var id: String { functionName }
}

struct LambdaCodeFile: Identifiable, Hashable {
    let path: String
    let content: String?
    let isBinary: Bool

    var id: String { path }
}

struct LambdaFunctionSummary: Sendable {
    let state: String?
    let lastUpdateStatus: String?
    let tags: [String: String]
}
