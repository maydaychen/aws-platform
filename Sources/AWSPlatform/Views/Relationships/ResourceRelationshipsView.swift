import SwiftUI

struct ResourceRelationshipsView: View {
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
                        ProgressView(vm.includesReverse ? "Scanning configured reverse relationships…" : "Loading direct relationships…")
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
            Button(action: vm.back) { Label("Back", systemImage: "chevron.left") }
                .disabled(!vm.canGoBack)
                .help("Restore the previously loaded view without making new requests")
            Text("Resource relationships").font(.headline)
            Spacer(minLength: 0)
            if vm.isLoading { Button("Cancel", action: vm.cancel) }
            Button(action: vm.refresh) { Image(systemName: "arrow.clockwise") }
                .disabled(vm.reference == nil || vm.isLoading)
                .help("Refresh this resource's relationships").accessibilityLabel("Refresh relationships")
            Button("Close", action: onClose).keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private func selectedResource(_ reference: ResourceRelationReference) -> some View {
        VStack(spacing: 10) {
            Image(systemName: reference.service.icon).font(.title2).foregroundColor(.secondary)
            Text(reference.name).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text("\(reference.service.rawValue) · \(reference.isGlobal ? "Global resource" : reference.scope.region)")
                .font(.caption).foregroundColor(.secondary)
            Text("\(reference.scope.profile.name) · \(reference.scope.accountID)")
                .font(.caption.monospacedDigit()).foregroundColor(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("Configured relationships only. No DNS resolution or traffic tracing.")
                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
            Text("Back restores a saved view. Use Refresh to request updated relationships.")
                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
            Button("Open resource") { onOpen(reference) }.disabled(vm.isLoading || !reference.isValid)
        }
        .frame(maxWidth: .infinity).padding(18)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func regionControls(_ reference: ResourceRelationReference) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Load balancer query region").font(.callout)
                TextField("AWS region", text: $queryRegion).textFieldStyle(.roundedBorder).frame(maxWidth: 210)
                    .onSubmit { vm.queryRegion(queryRegion) }
                Button("Query region") { vm.queryRegion(queryRegion) }.disabled(vm.isLoading)
            }
            Text("DNS is global. Matching checks only \(reference.scope.region) in this profile; no other regions are scanned automatically.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .disabled(vm.isLoading)
    }

    private var reverseControls: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(reverseDescription).font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(vm.includesReverse ? "Scan again" : "Scan reverse links", action: vm.scanReverse)
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
                Text(note).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let checked = section.checkedCount, let total = section.totalCount {
                Text("Successfully checked \(String(checked)) of \(String(total))")
                    .font(.caption).foregroundColor(.secondary)
            }
            if let error = section.error { NoticeBanner(message: error) }
            if section.isIncomplete {
                NoticeBanner(message: "Incomplete results. Additional relationships may exist in sources that could not be checked.")
            }
            if section.nodes.isEmpty {
                Text(section.requiresScan ? "Use Scan reverse links to load this section."
                     : section.error != nil || section.isIncomplete ? "No confirmed relationships are available from the completed checks."
                     : "No related resources were returned.")
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
