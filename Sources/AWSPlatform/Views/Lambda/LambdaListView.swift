import SwiftUI

struct LambdaListView: View {
    @ObservedObject var vm: LambdaViewModel

    var body: some View {
        VStack(spacing: 0) {
            ListToolbar(
                title: "Lambda Functions",
                isLoading: vm.isLoading,
                searchText: $vm.searchText,
                onRefresh: { vm.refresh() },
                onCancel: { vm.cancelLoading() }
            )
            HStack(spacing: 8) {
                Picker("State", selection: $vm.stateFilter) {
                    ForEach(vm.availableStates, id: \.self) { state in
                        Text(state == "All" ? "All states" : state).tag(state)
                    }
                }
                Picker("Package", selection: $vm.packageFilter) {
                    ForEach(vm.availablePackageTypes, id: \.self) { packageType in
                        Text(packageType == "All" ? "All packages" : packageType)
                            .tag(packageType)
                    }
                }
            }
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            if let warning = vm.summaryWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

            List(vm.filteredFunctions, selection: $vm.selectedFunction) { function in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(function.functionName)
                            .fontWeight(.medium)
                        Spacer()
                        statusIndicator(for: function)
                    }
                    HStack(spacing: 8) {
                        Text(function.runtime ?? "-")
                        if let packageType = function.packageType {
                            Text(packageType)
                        }
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
                if !vm.isLoading, let error = vm.error {
                    EmptyStateView(text: error)
                } else if !vm.isLoading && vm.filteredFunctions.isEmpty {
                    EmptyStateView(text: "No Lambda functions")
                }
            }
        }
    }

    @ViewBuilder
    private func statusIndicator(for function: LambdaFunctionModel) -> some View {
        if function.state == "Failed" || function.lastUpdateStatus == "Failed" {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .help("Function state or last update failed")
        } else if function.state == "Pending" || function.lastUpdateStatus == "InProgress" {
            Image(systemName: "clock.fill")
                .foregroundColor(.orange)
                .help("Function update is in progress")
        } else if function.state == "Active" {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .help("Function is active")
        } else {
            Image(systemName: "minus.circle")
                .foregroundColor(.secondary)
                .help(function.state ?? "Function state unavailable")
        }
    }
}
