import SwiftUI

struct LambdaListView: View {
    @ObservedObject var vm: LambdaViewModel

    var body: some View {
        List(vm.functions, selection: $vm.selectedFunction) { function in
            VStack(alignment: .leading, spacing: 4) {
                Text(function.functionName)
                    .fontWeight(.medium)
                HStack(spacing: 8) {
                    Text(function.runtime ?? "-")
                    if let memorySize = function.memorySize {
                        Text("\(memorySize) MB")
                    }
                    if let lastModified = function.lastModified {
                        Text(lastModified)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
        .overlay {
            if vm.isLoading {
                ProgressView()
            } else if let error = vm.error {
                EmptyStateView(text: error)
            } else if vm.functions.isEmpty {
                EmptyStateView(text: "No Lambda functions")
            }
        }
    }
}
