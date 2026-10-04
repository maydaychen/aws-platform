import SwiftUI

struct LambdaListView: View {
    @Environment(\.locale) private var locale
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
                Picker(L10n.text("State", locale: locale), selection: $vm.stateFilter) {
                    ForEach(vm.availableStates, id: \.self) { state in
                        Text(state == "All" ? L10n.text("All states", locale: locale) : state).tag(state)
                    }
                }
                Picker(L10n.text("Package", locale: locale), selection: $vm.packageFilter) {
                    ForEach(vm.availablePackageTypes, id: \.self) { packageType in
                        Text(packageType == "All" ? L10n.text("All packages", locale: locale) : packageType)
                            .tag(packageType)
                    }
                }
            }
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            if let warning = vm.summaryWarning {
                NoticeBanner(message: warning)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

            List(vm.filteredFunctions, selection: $vm.selectedFunction) { function in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(function.functionName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .help(function.functionName)
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
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                }
                .padding(.vertical, 4)
                .tag(function)
            }
            .listStyle(.inset)
            .overlay {
                if !vm.isLoading, let error = vm.error {
                    EmptyStateView(text: error, icon: "exclamationmark.triangle")
                } else if !vm.isLoading && vm.filteredFunctions.isEmpty {
                    EmptyStateView(text: vm.functions.isEmpty ? "No Lambda functions in this region" : "No matching functions. Try another search or filter.", icon: "function")
                }
            }
            ResourceListFooter(visible: vm.filteredFunctions.count, total: vm.functions.count)
        }
    }

    @ViewBuilder
    private func statusIndicator(for function: LambdaFunctionModel) -> some View {
        if function.state == "Failed" || function.lastUpdateStatus == "Failed" {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .help(L10n.text("Function state or last update failed", locale: locale))
        } else if function.state == "Pending" || function.lastUpdateStatus == "InProgress" {
            Image(systemName: "clock.fill")
                .foregroundColor(.orange)
                .help(L10n.text("Function update is in progress", locale: locale))
        } else if function.state == "Active" {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .help(L10n.text("Function is active", locale: locale))
        } else {
            Image(systemName: "minus.circle")
                .foregroundColor(.secondary)
                .help(function.state ?? L10n.text("Function state unavailable", locale: locale))
        }
    }
}
