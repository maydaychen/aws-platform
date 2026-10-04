import SwiftUI

struct HealthEventListView: View {
    @ObservedObject var vm: HealthViewModel
    @Environment(\.locale) private var locale

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
                    ProgressView(L10n.text("Loading Health events…", locale: locale))
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
            Text(L10n.text(title, locale: locale)).font(.caption).foregroundColor(.secondary)
            Picker(L10n.text(title, locale: locale), selection: selection) {
                ForEach(values, id: \.self) { value in
                    Text(value == "All" || title == "Status" || title == "Category"
                         ? HealthDisplay.label(value, locale: locale)
                         : HealthDisplay.returned(value, locale: locale)).tag(value)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .help(L10n.text(title == "Event region" ? "Filter event regions within this account. Independent of the resource region." : title, locale: locale))
        }
    }

    private func eventRow(_ event: HealthEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(HealthDisplay.returned(event.typeCode, locale: locale)).fontWeight(.medium)
                .lineLimit(2).help(event.typeCode)
            HStack(spacing: 8) {
                Text("\(HealthDisplay.returned(event.service, locale: locale)) · \(HealthDisplay.returned(event.region, locale: locale))")
                    .foregroundColor(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                HealthStatusLabel(status: event.status)
            }
            .font(.caption)
            Text(L10n.format("Updated %@", HealthDisplay.date(event.lastUpdatedTime, locale: locale), locale: locale))
                .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                .lineLimit(1)
                .help(HealthDisplay.date(event.lastUpdatedTime, locale: locale))
        }
        .padding(.vertical, 5)
        .help(event.arn)
    }

    private var footer: some View {
        HStack {
            Text(vm.filteredEvents.count == vm.events.count
                 ? L10n.format(vm.events.count == 1 ? "%@ event" : "%@ events", String(vm.events.count), locale: locale)
                 : L10n.format("%@ of %@ events", String(vm.filteredEvents.count), String(vm.events.count), locale: locale))
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
    @Environment(\.locale) private var locale

    var body: some View {
        Label(HealthDisplay.label(status, locale: locale), systemImage: icon)
            .foregroundColor(color).lineLimit(1).help(HealthDisplay.returned(status, locale: locale))
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
    static func returned(_ value: String?, locale: Locale) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return L10n.text("Not returned", locale: locale) }
        return value
    }

    static func label(_ value: String, locale: Locale) -> String {
        switch value.lowercased() {
        case "all": return L10n.text("All", locale: locale)
        case "open": return L10n.text("Ongoing", locale: locale)
        case "upcoming": return L10n.text("Upcoming", locale: locale)
        case "closed": return L10n.text("Closed", locale: locale)
        case "pending": return L10n.text("Pending", locale: locale)
        case "resolved": return L10n.text("Resolved", locale: locale)
        case "impaired": return L10n.text("Impaired", locale: locale)
        case "unimpaired": return L10n.text("Unimpaired", locale: locale)
        case "issue": return L10n.text("Issue", locale: locale)
        case "scheduledchange": return L10n.text("Scheduled change", locale: locale)
        case "accountnotification": return L10n.text("Account notification", locale: locale)
        case "investigation": return L10n.text("Investigation", locale: locale)
        default: return returned(value, locale: locale)
        }
    }

    static func date(_ value: Date?, locale: Locale) -> String {
        guard let value else { return L10n.text("Not returned", locale: locale) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        return formatter.string(from: value)
    }
}
