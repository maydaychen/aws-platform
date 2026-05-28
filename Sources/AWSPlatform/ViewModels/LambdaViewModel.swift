import Foundation
import SotoLambda

@MainActor
final class LambdaViewModel: ObservableObject {
    @Published var functions: [LambdaFunctionModel] = []
    @Published var selectedFunction: LambdaFunctionModel?
    @Published var isLoading = false
    @Published var error: String?

    private var provider: AWSServiceProvider?

    func configure(provider: AWSServiceProvider) {
        self.provider = provider
        Task { await loadFunctions() }
    }

    func loadFunctions() async {
        guard let provider else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let client = try await provider.lambdaClient()
            let response = try await client.listFunctions(.init())
            functions = (response.functions ?? []).map { function in
                LambdaFunctionModel(
                    functionName: function.functionName ?? "unknown",
                    runtime: function.runtime?.rawValue,
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

            if selectedFunction == nil {
                selectedFunction = functions.first
            }
        } catch {
            functions = []
            selectedFunction = nil
            self.error = error.localizedDescription
        }
    }

    func loadCodeForSelection() async {
        guard let selectedFunction else { return }
        await loadCode(for: selectedFunction.functionName)
    }

    func loadCode(for functionName: String) async {
        guard let provider, let index = functions.firstIndex(where: { $0.functionName == functionName }) else { return }

        do {
            let client = try await provider.lambdaClient()
            let response = try await client.getFunction(.init(functionName: functionName))

            var updated = functions[index]
            updated.arn = response.configuration?.functionArn
            updated.handler = response.configuration?.handler
            updated.role = response.configuration?.role
            updated.timeout = response.configuration?.timeout
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
                updated.codeFiles = [
                    LambdaCodeFile(
                        path: "Download URL",
                        content: location,
                        isBinary: false
                    )
                ]
            }

            functions[index] = updated
            if selectedFunction?.functionName == functionName {
                selectedFunction = updated
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
