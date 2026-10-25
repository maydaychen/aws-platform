import SwiftUI

struct RDSDatabaseDetailView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: RDSViewModel
    let insightsVM: RDSInsightsViewModel?
    let metricsVM: ResourceMetricsViewModel?
    @State private var selectedTab: RDSDatabaseDetailTab

    init(vm: RDSViewModel, insightsVM: RDSInsightsViewModel? = nil,
         metricsVM: ResourceMetricsViewModel? = nil, initialTab: RDSDatabaseDetailTab = .overview) {
        self.vm = vm
        self.insightsVM = insightsVM
        self.metricsVM = metricsVM
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        if let database = vm.selectedDatabase, vm.scope?.isValid == true, vm.databases.contains(database) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        Text(database.identifier).font(.title2.weight(.semibold))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button(action: vm.refresh) { Image(systemName: "arrow.clockwise") }
                            .disabled(vm.isLoading)
                            .help(L10n.text("Refresh RDS databases", locale: locale))
                            .accessibilityLabel(L10n.text("Refresh RDS databases", locale: locale))
                        if vm.isLoading { Button(L10n.text("Cancel", locale: locale), action: vm.cancelLoading) }
                    }
                    Text(L10n.text(database.kind.singularTitle, locale: locale))
                        .font(.caption).foregroundColor(.secondary)
                    Text(L10n.text("Database metadata · Read only", locale: locale))
                        .font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                Divider()
                if insightsVM != nil || metricsVM != nil {
                    TabView(selection: $selectedTab) {
                        overview(database).tabItem { Text(L10n.text("Overview", locale: locale)) }
                            .tag(RDSDatabaseDetailTab.overview)
                        if let metricsVM {
                            metrics(database, vm: metricsVM)
                                .tabItem { Text(L10n.text("Metrics", locale: locale)) }.tag(RDSDatabaseDetailTab.metrics)
                        }
                        if let insightsVM {
                            RDSDatabaseEventsView(vm: insightsVM, scope: vm.scope, database: database)
                                .tabItem { Text(L10n.text("Events", locale: locale)) }.tag(RDSDatabaseDetailTab.events)
                            RDSDatabaseSnapshotsView(vm: insightsVM, scope: vm.scope, database: database)
                                .tabItem { Text(L10n.text("Snapshots", locale: locale)) }.tag(RDSDatabaseDetailTab.snapshots)
                        }
                    }
                } else {
                    overview(database)
                }
            }
            .onAppear { configure() }
            .onChange(of: vm.scope) { _ in selectedTab = .overview; configure() }
            .onChange(of: vm.selectedDatabase) { _ in selectedTab = .overview; configure() }
            .onDisappear { insightsVM?.reset(); metricsVM?.reset() }
        } else {
            EmptyStateView(text: "Select an RDS DB instance or cluster", icon: "cylinder")
                .onAppear { insightsVM?.reset(); metricsVM?.reset() }
        }
    }

    private func overview(_ database: RDSDatabase) -> some View {
        ScrollView {
            RDSDatabaseFieldsView(database: database, scope: vm.scope)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
        .id(database.id)
    }

    @ViewBuilder
    private func metrics(_ database: RDSDatabase, vm: ResourceMetricsViewModel) -> some View {
        if database.metricTarget.isValid {
            VStack(spacing: 0) {
                if database.kind == .cluster {
                    Text(L10n.text("Aurora cluster storage metrics. CPU, memory and connection metrics belong to individual DB instances.", locale: locale))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(16)
                }
                ResourceMetricsView(vm: vm, scope: self.vm.scope, target: database.metricTarget)
            }
        } else {
            EmptyStateView(text: "Select a member DB instance to view CPU, memory and connection metrics. Cluster storage metrics are available here for Aurora only.", icon: "chart.xyaxis.line")
        }
    }

    private func configure() {
        let database = vm.selectedDatabase.flatMap { vm.databases.contains($0) ? $0 : nil }
        insightsVM?.configure(scope: vm.scope, database: database)
        metricsVM?.configure(scope: vm.scope, target: database?.metricTarget)
    }
}

enum RDSDatabaseDetailTab: Hashable {
    case overview, metrics, events, snapshots
}
