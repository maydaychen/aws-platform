import SwiftUI

struct HealthView: View {
    @ObservedObject var vm: HealthViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let scope = vm.scope {
                VStack(alignment: .leading, spacing: 5) {
                    Text(scope.profileName).font(.headline)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(scope.accountID) · Current account only · All regions")
                        .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 12)
                Divider()
            }
            HSplitView {
                HealthEventListView(vm: vm)
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 420)
                Group {
                    if let event = vm.selectedEvent, vm.scope != nil {
                        HealthEventDetailView(event: event, vm: vm)
                    } else {
                        EmptyStateView(
                            text: vm.scope == nil
                                ? "Select a profile and verify its connection to view this account's Health events."
                                : "Select an event to view its details and affected entities.",
                            icon: "heart.text.square"
                        )
                    }
                }
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { vm.loadIfNeeded() }
        .onChange(of: vm.scope) { _ in vm.loadIfNeeded() }
    }
}
