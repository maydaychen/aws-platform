import SwiftUI

struct ResourceRelationshipsView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: ResourceRelationshipsViewModel
    let onOpen: (ResourceRelationReference) -> Void
    let onClose: () -> Void
    @State private var queryRegion = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let reference = vm.reference {
                        selectedResource(reference)
                        if reference.isGlobal { regionControls(reference) }
                        if reference.canScanReverse { reverseControls }
                    }
                    if let error = vm.error { NoticeBanner(message: error) }
                    if vm.isLoading {
                        ProgressView(L10n.text(vm.includesReverse ? "Scanning configured reverse relationships…" : "Loading direct relationships…", locale: locale))
                            .frame(maxWidth: .infinity, minHeight: 140)
                    } else if let result = vm.result {
                        if result.sections.isEmpty {
                            EmptyStateView(text: "No direct relationships were returned.", icon: "point.3.connected.trianglepath.dotted")
                                .frame(minHeight: 160)
                        } else {
                            ForEach(result.sections) { section in sectionView(section) }
                        }
                    } else if vm.error == nil {
                        EmptyStateView(text: "Select a supported resource to view its relationships.", icon: "point.3.connected.trianglepath.dotted")
                            .frame(minHeight: 160)
                    }
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 720, idealWidth: 920, minHeight: 500, idealHeight: 720)
        .onAppear {
            queryRegion = vm.reference?.scope.region ?? ""
            vm.load()
        }
        .onChange(of: vm.reference) { reference in queryRegion = reference?.scope.region ?? "" }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: vm.back) { Label(L10n.text("Back", locale: locale), systemImage: "chevron.left") }
                .disabled(!vm.canGoBack)
                .help(L10n.text("Restore the previously loaded view without making new requests", locale: locale))
            Text(L10n.text("Resource relationships", locale: locale)).font(.headline)
            Spacer(minLength: 0)
            if vm.isLoading { Button(L10n.text("Cancel", locale: locale), action: vm.cancel) }
            Button(action: vm.refresh) { Image(systemName: "arrow.clockwise") }
                .disabled(vm.reference == nil || vm.isLoading)
                .help(L10n.text("Refresh this resource's relationships", locale: locale)).accessibilityLabel(L10n.text("Refresh relationships", locale: locale))
            Button(L10n.text("Close", locale: locale), action: onClose).keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private func selectedResource(_ reference: ResourceRelationReference) -> some View {
        VStack(spacing: 10) {
            Image(systemName: reference.service.icon).font(.title2).foregroundColor(.secondary)
            Text(reference.name).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text("\(reference.service.rawValue) · \(reference.isGlobal ? L10n.text("Global resource", locale: locale) : reference.scope.region)")
                .font(.caption).foregroundColor(.secondary)
            Text("\(reference.scope.profile.name) · \(reference.scope.accountID)")
                .font(.caption.monospacedDigit()).foregroundColor(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("Configured relationships only. No DNS resolution or traffic tracing.", locale: locale))
                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
            Text(L10n.text("Back restores a saved view. Use Refresh to request updated relationships.", locale: locale))
                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
            Button(L10n.text("Open resource", locale: locale)) { onOpen(reference) }.disabled(vm.isLoading || !reference.isValid)
        }
        .frame(maxWidth: .infinity).padding(18)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func regionControls(_ reference: ResourceRelationReference) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(L10n.text("Load balancer query region", locale: locale)).font(.callout)
                TextField(L10n.text("AWS region", locale: locale), text: $queryRegion).textFieldStyle(.roundedBorder).frame(maxWidth: 210)
                    .onSubmit { vm.queryRegion(queryRegion) }
                Button(L10n.text("Query region", locale: locale)) { vm.queryRegion(queryRegion) }.disabled(vm.isLoading)
            }
            Text(L10n.format("DNS is global. Matching checks only %@ in this profile; no other regions are scanned automatically.", reference.scope.region, locale: locale))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .disabled(vm.isLoading)
    }

    private var reverseControls: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(L10n.text(reverseDescription, locale: locale)).font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(L10n.text(vm.includesReverse ? "Scan again" : "Scan reverse links", locale: locale), action: vm.scanReverse)
                .disabled(vm.isLoading)
        }
    }

    private var reverseDescription: String {
        switch vm.reference?.service {
        case .loadBalancers: return "Optional scan: read hosted zone records in this account to find matching DNS references."
        case .ec2: return "Optional scan: check instance-type target groups in this region for this exact instance and its registered ports."
        case .securityGroups: return "Optional scan: find EC2 and load balancer usage of this security group in this region."
        default: return "Reverse relationships are queried only when requested."
        }
    }

    private func sectionView(_ section: ResourceRelationSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            DetailSectionTitle(title: section.title)
            if let note = section.note {
                Text(L10n.text(note, locale: locale)).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let checked = section.checkedCount, let total = section.totalCount {
                Text(L10n.format("Successfully checked %@ of %@", String(checked), String(total), locale: locale))
                    .font(.caption).foregroundColor(.secondary)
            }
            if !section.resourceFailures.isEmpty {
                ForEach(section.resourceFailures.indices, id: \.self) { index in
                    let failure = section.resourceFailures[index]
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "\(failure.resourceName) (\(failure.resourceID))")
                            .font(.caption).textSelection(.enabled)
                        NoticeBanner(message: failure.message)
                    }
                }
            } else if let error = section.error {
                NoticeBanner(message: error)
            }
            if section.isIncomplete {
                NoticeBanner(message: "Incomplete results. Additional relationships may exist in sources that could not be checked.")
            }
            if section.nodes.isEmpty {
                Text(L10n.text(section.requiresScan ? "Use Scan reverse links to load this section."
                     : section.error != nil || section.isIncomplete ? "No confirmed relationships are available from the completed checks."
                     : "No related resources were returned.", locale: locale))
                    .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(columns: [.init(.adaptive(minimum: 300), alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(section.nodes) { node in
                        ResourceRelationNodeCard(node: node, onExplore: { vm.explore(reference: $0) }, onOpen: onOpen)
                    }
                }
            }
        }
    }
}
