import AppKit
import SwiftUI

struct Route53ZoneDetailView: View {
    @Environment(\.locale) private var locale
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", records = "Records", tags = "Tags"
        var id: Self { self }
    }

    let zone: Route53HostedZone
    @ObservedObject var vm: Route53ViewModel
    let onShowRelationships: ((Route53Record) -> Void)?
    @State private var selectedTab: Tab
    @State private var expandedRecordIDs: Set<Route53Record.ID> = []
    @State private var focusRevision = 0

    init(zone: Route53HostedZone, vm: Route53ViewModel, tab: Tab = .overview,
         onShowRelationships: ((Route53Record) -> Void)? = nil) {
        self.zone = zone
        self.vm = vm
        self.onShowRelationships = onShowRelationships
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
            .id(focusRevision)
        }
        .onReceive(vm.$focusedRecordID) { id in
            guard isCurrentSelection, let id, vm.records.contains(where: { $0.id == id }) else { return }
            selectedTab = .records
            expandedRecordIDs.insert(id)
            vm.recordSearchText = ""
            vm.recordTypeFilter = "All"
            focusRevision += 1
        }
        .onChange(of: zone.id) { _ in selectedTab = .overview; expandedRecordIDs = [] }
        .onChange(of: vm.scope) { _ in selectedTab = .overview; expandedRecordIDs = [] }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text(displayedZone.name).font(.title2.weight(.semibold))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if isLoading {
                    Button(action: vm.cancelDetails) { Image(systemName: "xmark.circle") }
                        .help(L10n.text("Cancel loading zone details, records and tags", locale: locale))
                        .accessibilityLabel(L10n.text("Cancel loading hosted zone details", locale: locale))
                }
                Button(action: vm.refreshDetails) { Image(systemName: "arrow.clockwise") }
                    .disabled(!isCurrentSelection || isLoading)
                    .help(L10n.text("Refresh zone details, records and tags", locale: locale))
                    .accessibilityLabel(L10n.text("Refresh hosted zone details", locale: locale))
            }
            Label(L10n.text(displayedZone.isPrivate ? "Private hosted zone · Global" : "Public hosted zone · Global", locale: locale),
                  systemImage: displayedZone.isPrivate ? "lock" : "globe")
                .font(.caption).foregroundColor(.secondary)
            HStack(spacing: 6) {
                Text(zone.id).font(.caption.monospaced()).foregroundColor(.secondary).textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(zone.id, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help(L10n.text("Copy hosted zone ID", locale: locale)).accessibilityLabel(L10n.text("Copy hosted zone ID", locale: locale))
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var overview: some View {
        DetailGrid(items: [
            ("Hosted zone ID", zone.id),
            ("Visibility", L10n.text(displayedZone.isPrivate ? "Private" : "Public", locale: locale)),
            ("Record sets", displayedZone.recordCount.map(String.init) ?? L10n.text("Not returned", locale: locale)),
            ("Account", vm.scope?.accountID ?? L10n.text("Not returned", locale: locale))
        ])
        if let comment = displayedZone.comment, !comment.isEmpty {
            Text(comment).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        if isCurrentSelection && vm.isDetailsLoading {
            ProgressView(L10n.text("Loading hosted zone details…", locale: locale)).controlSize(.small)
        } else if isCurrentSelection, let error = vm.detailsError {
            NoticeBanner(message: error)
            retryButton
        } else if let details {
            DetailSectionTitle(title: "Configuration")
            DetailGrid(items: [("Caller reference", Route53Display.returned(details.callerReference, locale: locale))])
            if displayedZone.isPrivate || !details.vpcs.isEmpty {
                DetailSectionTitle(title: "VPC associations")
                Text(L10n.text("Associations returned for this hosted zone. VPC settings and DNS resolution are not queried.", locale: locale))
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if details.vpcs.isEmpty {
                    Text(L10n.text("No VPC associations returned.", locale: locale)).font(.callout).foregroundColor(.secondary)
                } else {
                    Route53FieldRows(fields: details.vpcs.map { .init(name: $0.region, value: $0.id) }, isVerbatimLabels: true)
                }
            }
            if !displayedZone.isPrivate || !details.nameServers.isEmpty {
                DetailSectionTitle(title: "Delegation name servers")
                Text(L10n.text("Configured delegation name servers. This does not verify live DNS delegation or propagation.", locale: locale))
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if details.nameServers.isEmpty {
                    Text(L10n.text("No delegation name servers returned.", locale: locale)).font(.callout).foregroundColor(.secondary)
                } else {
                    Route53ValueBlock(values: details.nameServers)
                }
                if let id = details.delegationSetID {
                    DetailGrid(items: [("Delegation set ID", Route53Display.returned(id, locale: locale))])
                }
            }
            if !details.linkedService.isEmpty {
                DetailSectionTitle(title: "Linked service")
                Route53FieldRows(fields: details.linkedService)
            }
        } else {
            Text(L10n.text("No hosted zone details returned.", locale: locale)).font(.callout).foregroundColor(.secondary)
        }
    }

    private var recordFilters: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ResourceSearchField(text: $vm.recordSearchText, placeholder: "Search records")
                Picker(L10n.text("Record type", locale: locale), selection: $vm.recordTypeFilter) {
                    ForEach(recordTypes, id: \.self) { type in
                        Text(type == "All" ? L10n.text("All types", locale: locale) : type).tag(type)
                    }
                }
                .labelsHidden().frame(width: 120)
            }
            Text(vm.filteredRecords.count == vm.records.count
                 ? L10n.format(vm.records.count == 1 ? "%@ record set" : "%@ record sets", String(vm.records.count), locale: locale)
                 : L10n.format("%@ of %@ record sets", String(vm.filteredRecords.count), String(vm.records.count), locale: locale))
                .font(.caption).foregroundColor(.secondary)
        }
        .disabled(!isCurrentSelection)
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    @ViewBuilder
    private var records: some View {
        if isCurrentSelection && vm.isRecordsLoading {
            ProgressView(L10n.text("Loading DNS records…", locale: locale)).controlSize(.small)
        } else if isCurrentSelection, let error = vm.recordsError {
            NoticeBanner(message: error)
            retryButton
        } else if isCurrentSelection && !vm.filteredRecords.isEmpty {
            let focused = vm.filteredRecords.first { $0.id == vm.focusedRecordID }
            if let focused {
                DetailSectionTitle(title: "Related record")
                recordRow(focused)
                if vm.filteredRecords.count > 1 { DetailSectionTitle(title: "Other records") }
            }
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(vm.filteredRecords.filter { $0.id != focused?.id }) { record in
                    recordRow(record)
                }
            }
        } else {
            EmptyStateView(text: vm.records.isEmpty ? "No DNS records returned." : "No matching records. Try another search or type.", icon: "list.bullet.rectangle")
                .frame(minHeight: 180)
        }
    }

    private func recordRow(_ record: Route53Record) -> some View {
        Route53RecordRow(record: record, isExpanded: Binding(
            get: { expandedRecordIDs.contains(record.id) },
            set: { expanded in
                if expanded { expandedRecordIDs.insert(record.id) }
                else { expandedRecordIDs.remove(record.id) }
            }
        ), onShowRelationships: onShowRelationships.map { callback in { callback(record) } })
    }

    @ViewBuilder
    private var tags: some View {
        if isCurrentSelection && vm.isTagsLoading {
            ProgressView(L10n.text("Loading tags…", locale: locale)).controlSize(.small)
        } else if isCurrentSelection, let error = vm.tagsError {
            NoticeBanner(message: error)
            retryButton
        } else if isCurrentSelection && !vm.tags.isEmpty {
            DetailKeyValueRows(values: vm.tags)
        } else {
            Text(L10n.text("No tags returned.", locale: locale)).font(.callout).foregroundColor(.secondary)
        }
    }

    private var retryButton: some View {
        Button(L10n.text("Retry zone details", locale: locale), action: vm.refreshDetails)
            .disabled(!isCurrentSelection || isLoading)
            .help(L10n.text("Retry zone details, records and tags", locale: locale))
    }
}

enum Route53Display {
    static func returned(_ value: String, locale: Locale) -> String {
        value.isEmpty ? L10n.text("(empty)", locale: locale) : value
    }

    static func routingPolicy(_ value: String, locale: Locale) -> String {
        value.components(separatedBy: ", ").map { L10n.text($0, locale: locale) }.joined(separator: ", ")
    }
}
