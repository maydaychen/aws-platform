import SwiftUI

struct RDSDatabaseEventsView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: RDSInsightsViewModel
    let scope: MonitoringScope?
    let database: RDSDatabase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text(L10n.text("Database events", locale: locale)).font(.headline)
                    Spacer(minLength: 0)
                    if canLoad && vm.isEventsLoading {
                        ProgressView().controlSize(.small)
                        Button(L10n.text("Cancel", locale: locale), action: vm.cancelEvents)
                    }
                    Button(L10n.text("Load events", locale: locale), action: vm.loadEvents)
                        .disabled(!canLoad || vm.isEventsLoading)
                }
                Text(L10n.text("Last 14 days · Selected database only · Manual requests", locale: locale))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if canLoad, let error = vm.eventsError { NoticeBanner(message: error) }
                if canLoad, let snapshot = vm.eventsSnapshot {
                    Text(L10n.format("%@ through %@", MonitoringDisplay.dateTime(snapshot.start),
                                     MonitoringDisplay.dateTime(snapshot.end), locale: locale))
                        .font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if snapshot.events.isEmpty {
                        Text(L10n.text("No database events returned for this time range.", locale: locale)).foregroundColor(.secondary)
                    }
                    ForEach(snapshot.events) { event in
                        VStack(alignment: .leading, spacing: 8) {
                            DetailFieldRows(items: [
                                ("Time", event.date.map(MonitoringDisplay.dateTime) ?? missing),
                                ("Source", event.sourceIdentifier),
                                ("ARN", event.sourceARN ?? missing),
                                ("Categories", event.categories.map { $0.isEmpty ? L10n.text("None", locale: locale) : $0.joined(separator: ", ") } ?? missing)
                            ])
                            Text(event.message ?? missing).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Divider()
                        }
                    }
                } else if canLoad && vm.isEventsLoading {
                    ProgressView(L10n.text("Loading database events…", locale: locale))
                } else if vm.eventsError == nil || !canLoad {
                    EmptyStateView(text: "Load recent events to review maintenance, restarts and failovers.", icon: "clock")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }

    private var canLoad: Bool { scope?.isValid == true && vm.scope == scope && vm.database == database }
    private var missing: String { L10n.text("Not returned", locale: locale) }
}
