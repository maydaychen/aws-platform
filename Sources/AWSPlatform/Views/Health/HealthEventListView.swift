import SwiftUI

struct HealthEventListView: View {
    @ObservedObject var vm: HealthViewModel

    var body: some View {
        VStack(spacing: 0) {
            ListToolbar(title: "Health events", isLoading: vm.isLoading, searchText: $vm.searchText,
                        onRefresh: vm.refresh, onCancel: vm.cancelLoading, searchPlaceholder: "Search events")
                .disabled(vm.scope == nil)
            filters
                .disabled(vm.scope == nil)
            if let error = vm.error {
                NoticeBanner(message: error)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }
            Divider()
            List(vm.filteredEvents, selection: $vm.selectedEvent) { event in
                eventRow(event).tag(event)
            }
            .listStyle(.inset)
            .overlay {
                if vm.isLoading && vm.events.isEmpty {
                    ProgressView("Loading Health events…")
                } else if !vm.isLoading && vm.filteredEvents.isEmpty {
                    EmptyStateView(text: emptyMessage, icon: "heart.text.square")
                }
            }
            footer
        }
    }

    private var filters: some View {
        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], alignment: .leading, spacing: 8) {
            filter("Status", selection: $vm.statusFilter, values: vm.availableStatuses)
            filter("Category", selection: $vm.categoryFilter, values: vm.availableCategories)
            filter("Service", selection: $vm.serviceFilter, values: vm.availableServices)
            filter("Event region", selection: $vm.regionFilter, values: vm.availableRegions)
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    private func filter(_ title: String, selection: Binding<String>, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Picker(title, selection: selection) {
                ForEach(values, id: \.self) { value in
                    Text(HealthDisplay.label(value)).tag(value)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .help(title == "Event region" ? "Filter event regions within this account. Independent of the resource region." : title)
        }
    }

    private func eventRow(_ event: HealthEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(HealthDisplay.returned(event.typeCode)).fontWeight(.medium)
                .lineLimit(2).help(event.typeCode)
            HStack(spacing: 8) {
                Text("\(HealthDisplay.returned(event.service)) · \(HealthDisplay.returned(event.region))")
                    .foregroundColor(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                HealthStatusLabel(status: event.status)
            }
            .font(.caption)
            Text("Updated \(HealthDisplay.date(event.lastUpdatedTime))")
                .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                .lineLimit(1)
                .help(HealthDisplay.date(event.lastUpdatedTime))
        }
        .padding(.vertical, 5)
        .help(event.arn)
    }

    private var footer: some View {
        HStack {
            Text(vm.filteredEvents.count == vm.events.count
                 ? "\(vm.events.count) \(vm.events.count == 1 ? "event" : "events")"
                 : "\(vm.filteredEvents.count) of \(vm.events.count) events")
            Spacer(minLength: 0)
            Text("UTC")
        }
        .font(.caption).foregroundColor(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(alignment: .top) { Divider() }
    }

    private var emptyMessage: String {
        if vm.scope == nil { return "Choose a profile to view Health events." }
        if vm.error != nil { return "No event list is available. Use Refresh to retry." }
        return vm.events.isEmpty ? "No account-specific Health events were returned."
            : "No matching events. Try another search or filter."
    }
}

struct HealthStatusLabel: View {
    let status: String

    var body: some View {
        Label(HealthDisplay.label(status), systemImage: icon)
            .foregroundColor(color).lineLimit(1).help(HealthDisplay.returned(status))
    }

    private var icon: String {
        switch status.lowercased() {
        case "open": return "exclamationmark.circle"
        case "upcoming", "pending": return "clock"
        case "closed", "resolved": return "checkmark.circle"
        case "impaired": return "exclamationmark.triangle"
        default: return "questionmark.circle"
        }
    }

    private var color: Color {
        switch status.lowercased() {
        case "open", "impaired": return .orange
        case "upcoming", "pending": return .blue
        case "resolved", "unimpaired": return .green
        default: return .secondary
        }
    }
}

enum HealthDisplay {
    static func returned(_ value: String?) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Not returned" }
        return value
    }

    static func label(_ value: String) -> String {
        switch value {
        case "open": return "Open"
        case "upcoming": return "Upcoming"
        case "closed": return "Closed"
        case "issue": return "Issue"
        case "scheduledChange": return "Scheduled change"
        case "accountNotification": return "Account notification"
        case "investigation": return "Investigation"
        default: return returned(value)
        }
    }

    static func date(_ value: Date?) -> String {
        guard let value else { return "Not returned" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        return formatter.string(from: value)
    }
}
