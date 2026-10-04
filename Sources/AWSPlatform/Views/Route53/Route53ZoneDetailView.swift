import AppKit
import SwiftUI

struct Route53ZoneDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", records = "Records", tags = "Tags"
        var id: Self { self }
    }

    let zone: Route53HostedZone
    @ObservedObject var vm: Route53ViewModel
    @State private var selectedTab: Tab

    init(zone: Route53HostedZone, vm: Route53ViewModel, tab: Tab = .overview) {
        self.zone = zone
        self.vm = vm
        _selectedTab = State(initialValue: tab)
    }

    private var isCurrentSelection: Bool { vm.scope != nil && vm.selectedZone?.id == zone.id }
    private var details: Route53ZoneDetails? {
        guard isCurrentSelection, vm.details?.zone.id == zone.id else { return nil }
        return vm.details
    }
    private var displayedZone: Route53HostedZone { details?.zone ?? zone }
    private var isLoading: Bool { isCurrentSelection && (vm.isDetailsLoading || vm.isRecordsLoading || vm.isTagsLoading) }
    private var recordTypes: [String] { ["All"] + Set(vm.records.map(\.type)).sorted() }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            DetailTabPicker(tabs: Tab.allCases, selection: $selectedTab).padding(12)
            if selectedTab == .records { recordFilters }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selectedTab {
                    case .overview: overview
                    case .records: records
                    case .tags: tags
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
        .onChange(of: zone.id) { _ in selectedTab = .overview }
        .onChange(of: vm.scope) { _ in selectedTab = .overview }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text(displayedZone.name).font(.title2.weight(.semibold))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if isLoading {
                    Button(action: vm.cancelDetails) { Image(systemName: "xmark.circle") }
                        .help("Cancel loading zone details, records and tags")
                        .accessibilityLabel("Cancel loading hosted zone details")
                }
                Button(action: vm.refreshDetails) { Image(systemName: "arrow.clockwise") }
                    .disabled(!isCurrentSelection || isLoading)
                    .help("Refresh zone details, records and tags")
                    .accessibilityLabel("Refresh hosted zone details")
            }
            Label(displayedZone.isPrivate ? "Private hosted zone · Global" : "Public hosted zone · Global",
                  systemImage: displayedZone.isPrivate ? "lock" : "globe")
                .font(.caption).foregroundColor(.secondary)
            HStack(spacing: 6) {
                Text(zone.id).font(.caption.monospaced()).foregroundColor(.secondary).textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(zone.id, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy hosted zone ID").accessibilityLabel("Copy hosted zone ID")
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var overview: some View {
        DetailGrid(items: [
            ("Hosted zone ID", zone.id),
            ("Visibility", displayedZone.isPrivate ? "Private" : "Public"),
            ("Record sets", displayedZone.recordCount.map(String.init) ?? "Not returned"),
            ("Account", vm.scope?.accountID ?? "Not returned")
        ])
        if let comment = displayedZone.comment, !comment.isEmpty {
            Text(comment).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        if isCurrentSelection && vm.isDetailsLoading {
            ProgressView("Loading hosted zone details…").controlSize(.small)
        } else if isCurrentSelection, let error = vm.detailsError {
            NoticeBanner(message: error)
            retryButton
        } else if let details {
            DetailSectionTitle(title: "Configuration")
            DetailGrid(items: [("Caller reference", Route53Display.returned(details.callerReference))])
            if displayedZone.isPrivate || !details.vpcs.isEmpty {
                DetailSectionTitle(title: "VPC associations")
                Text("Associations returned for this hosted zone. VPC settings and DNS resolution are not queried.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if details.vpcs.isEmpty {
                    Text("No VPC associations returned.").font(.callout).foregroundColor(.secondary)
                } else {
                    Route53FieldRows(fields: details.vpcs.map { .init(name: $0.region, value: $0.id) })
                }
            }
            if !displayedZone.isPrivate || !details.nameServers.isEmpty {
                DetailSectionTitle(title: "Delegation name servers")
                Text("Configured delegation name servers. This does not verify live DNS delegation or propagation.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if details.nameServers.isEmpty {
                    Text("No delegation name servers returned.").font(.callout).foregroundColor(.secondary)
                } else {
                    Route53ValueBlock(values: details.nameServers)
                }
                if let id = details.delegationSetID {
                    DetailGrid(items: [("Delegation set ID", Route53Display.returned(id))])
                }
            }
            if !details.linkedService.isEmpty {
                DetailSectionTitle(title: "Linked service")
                Route53FieldRows(fields: details.linkedService)
            }
        } else {
            Text("No hosted zone details returned.").font(.callout).foregroundColor(.secondary)
        }
    }

    private var recordFilters: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ResourceSearchField(text: $vm.recordSearchText, placeholder: "Search records")
                Picker("Record type", selection: $vm.recordTypeFilter) {
                    ForEach(recordTypes, id: \.self) { type in Text(type == "All" ? "All types" : type).tag(type) }
                }
                .labelsHidden().frame(width: 120)
            }
            Text(vm.filteredRecords.count == vm.records.count
                 ? "\(vm.records.count) \(vm.records.count == 1 ? "record set" : "record sets")"
                 : "\(vm.filteredRecords.count) of \(vm.records.count) record sets")
                .font(.caption).foregroundColor(.secondary)
        }
        .disabled(!isCurrentSelection)
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    @ViewBuilder
    private var records: some View {
        if isCurrentSelection && vm.isRecordsLoading {
            ProgressView("Loading DNS records…").controlSize(.small)
        } else if isCurrentSelection, let error = vm.recordsError {
            NoticeBanner(message: error)
            retryButton
        } else if isCurrentSelection && !vm.filteredRecords.isEmpty {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(vm.filteredRecords) { record in Route53RecordRow(record: record) }
            }
        } else {
            EmptyStateView(text: vm.records.isEmpty ? "No DNS records returned." : "No matching records. Try another search or type.", icon: "list.bullet.rectangle")
                .frame(minHeight: 180)
        }
    }

    @ViewBuilder
    private var tags: some View {
        if isCurrentSelection && vm.isTagsLoading {
            ProgressView("Loading tags…").controlSize(.small)
        } else if isCurrentSelection, let error = vm.tagsError {
            NoticeBanner(message: error)
            retryButton
        } else if isCurrentSelection && !vm.tags.isEmpty {
            DetailKeyValueRows(values: vm.tags)
        } else {
            Text("No tags returned.").font(.callout).foregroundColor(.secondary)
        }
    }

    private var retryButton: some View {
        Button("Retry zone details", action: vm.refreshDetails)
            .disabled(!isCurrentSelection || isLoading)
            .help("Retry zone details, records and tags")
    }
}

enum Route53Display {
    static func returned(_ value: String) -> String { value.isEmpty ? "(empty)" : value }
}
