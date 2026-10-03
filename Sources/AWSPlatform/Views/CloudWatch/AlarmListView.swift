import SwiftUI

struct AlarmListView: View {
    @ObservedObject var vm: AlarmViewModel

    var body: some View {
        VStack(spacing: 0) {
            ListToolbar(title: "CloudWatch Alarms", isLoading: vm.isLoading, searchText: $vm.searchText,
                        onRefresh: vm.refresh, onCancel: vm.cancelLoading)
            HStack(spacing: 8) {
                Picker("State", selection: $vm.stateFilter) {
                    ForEach(vm.availableStates, id: \.self) { state in
                        Text(state == "All" ? "All states" : state).tag(state)
                    }
                }
                Picker("Alarm type", selection: $vm.kindFilter) {
                    Text("All types").tag(Optional<AlarmKind>.none)
                    ForEach(AlarmKind.allCases) { kind in Text(kind.title).tag(Optional(kind)) }
                }
            }
            .labelsHidden()
            .padding(.horizontal, 12).padding(.bottom, 10)
            if let error = vm.error {
                NoticeBanner(message: vm.alarms.isEmpty ? error : "Showing the previous alarm list. \(error)")
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }
            Divider()
            List(vm.filteredAlarms, selection: $vm.selectedAlarm) { alarm in
                VStack(alignment: .leading, spacing: 6) {
                    Text(alarm.name).fontWeight(.medium).lineLimit(2).help(alarm.name)
                    HStack(spacing: 8) {
                        AlarmStateLabel(state: alarm.state)
                        Spacer(minLength: 0)
                        Text(alarm.kind.title).foregroundColor(.secondary)
                    }
                    .font(.caption)
                }
                .padding(.vertical, 5)
                .tag(alarm)
                .help(alarm.arn)
            }
            .listStyle(.inset)
            .overlay {
                if vm.isLoading && vm.alarms.isEmpty {
                    ProgressView("Loading alarms…")
                } else if !vm.isLoading && vm.filteredAlarms.isEmpty {
                    EmptyStateView(text: emptyMessage, icon: "bell")
                }
            }
            ResourceListFooter(visible: vm.filteredAlarms.count, total: vm.alarms.count)
        }
    }

    private var emptyMessage: String {
        if vm.scope == nil { return "Choose a profile to view alarms." }
        if vm.error != nil { return "No alarm list is available. Use Refresh to retry." }
        return vm.alarms.isEmpty ? "No metric or composite alarms in this region."
            : "No matching alarms. Try another search or filter."
    }
}

struct AlarmStateLabel: View {
    let state: String

    var body: some View {
        Label(state, systemImage: icon)
            .foregroundColor(color)
            .lineLimit(1)
            .help(state)
    }

    private var color: Color {
        switch state {
        case "ALARM": return .red
        case "OK": return .green
        case "INSUFFICIENT_DATA": return .orange
        default: return .secondary
        }
    }

    private var icon: String {
        switch state {
        case "ALARM": return "exclamationmark.triangle.fill"
        case "OK": return "checkmark.circle.fill"
        case "INSUFFICIENT_DATA": return "questionmark.circle"
        default: return "minus.circle"
        }
    }
}
