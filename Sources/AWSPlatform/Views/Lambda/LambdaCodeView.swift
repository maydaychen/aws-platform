import SwiftUI

struct LambdaCodeView: View {
    let function: LambdaFunctionModel

    var body: some View {
        Group {
            if function.packageType == "Image" {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Container Image")
                        .font(.headline)
                    Text("This function is packaged as a container image.")
                        .foregroundColor(.secondary)
                    if let imageUri = function.imageUri {
                        Text(imageUri)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding()
            } else if function.codeFiles.isEmpty {
                EmptyStateView(text: "Code metadata not loaded")
            } else {
                List(function.codeFiles) { file in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(file.path)
                            .font(.caption)
                            .fontWeight(.semibold)
                        if let content = file.content {
                            Text(content)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}
