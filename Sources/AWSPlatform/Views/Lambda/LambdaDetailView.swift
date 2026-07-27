import SwiftUI

struct LambdaDetailView: View {
    let function: LambdaFunctionModel
    let isCodeLoading: Bool
    let onLoadCode: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(function.functionName)
                        .font(.title2)
                        .fontWeight(.semibold)

                    DetailGrid(items: [
                        ("ARN", function.arn ?? "-"),
                        ("Runtime", function.runtime ?? "-"),
                        ("Handler", function.handler ?? "-"),
                        ("Role", function.role ?? "-"),
                        ("Memory", function.memorySize.map { "\($0) MB" } ?? "-"),
                        ("Timeout", function.timeout.map { "\($0)s" } ?? "-"),
                        ("Code Size", function.codeSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "-"),
                        ("Last Modified", function.lastModified ?? "-"),
                        ("Package Type", function.packageType ?? "-"),
                        ("VPC", function.vpcConfig ?? "-")
                    ])

                    if !function.environment.isEmpty {
                        Text("Environment")
                            .font(.headline)
                        ForEach(function.environment.keys.sorted(), id: \.self) { key in
                            Text("\(key)=\(function.environment[key] ?? "")")
                                .font(.caption)
                        }
                    }

                    if !function.tags.isEmpty {
                        Text("Tags")
                            .font(.headline)
                        ForEach(function.tags.keys.sorted(), id: \.self) { key in
                            Text("\(key): \(function.tags[key] ?? "")")
                                .font(.caption)
                        }
                    }

                    Button(isCodeLoading ? "Loading Code..." : "Load Code", action: onLoadCode)
                        .buttonStyle(.borderedProminent)
                        .disabled(isCodeLoading)
                }
                .padding()
            }
            Divider()
            LambdaCodeView(function: function)
                .frame(minHeight: 180)
                .overlay {
                    if isCodeLoading {
                        ProgressView()
                    }
                }
        }
    }
}
