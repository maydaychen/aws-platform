import SwiftUI

struct EC2TargetGroupsView: View {
    @ObservedObject var vm: EC2TargetGroupsViewModel
    let scope: MonitoringScope?
    let instanceID: String
    let onOpen: (ELBResourceReference) -> Void

    private var canLoad: Bool {
        scope?.isValid == true && vm.scope == scope && vm.instanceID == instanceID
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                controls
                ELBScopeCaption(scope: scope)
                Text("Manual scan only. Lists target groups in this account and region, then requests target health for each instance-type group. Pagination and retries can add requests. IP and Lambda groups are excluded.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if canLoad, let error = vm.error { NoticeBanner(message: error) }
                if canLoad && vm.isLoading {
                    ProgressView("Checking instance-type target groups…").controlSize(.small)
                }
                if canLoad, let result = vm.result {
                    resultContent(result)
                } else if !vm.isLoading {
                    EmptyStateView(text: canLoad ? "Scan to find this instance's registered target groups and ports."
                                   : "Select an instance in a verified profile to scan its target groups.", icon: "target")
                        .frame(minHeight: 180)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
        .onAppear { configure() }
        .onChange(of: scope) { _ in configure() }
        .onChange(of: instanceID) { _ in configure() }
        .onDisappear { vm.reset() }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Text("Target group membership").font(.headline)
            Spacer(minLength: 0)
            if vm.isLoading {
                Button("Cancel", action: vm.cancel)
            }
            Button(vm.result == nil ? "Scan target groups" : "Scan again") {
                if vm.result == nil { vm.load() }
                else { vm.refresh() }
            }
            .disabled(!canLoad || vm.isLoading)
        }
    }

    @ViewBuilder
    private func resultContent(_ result: ELBMembershipResult) -> some View {
        Text("Successfully checked \(result.checkedGroupCount) of \(result.totalGroupCount) instance-type target groups")
            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        if !result.isComplete {
            NoticeBanner(message: "Scan incomplete. The matches below cover successfully checked groups only; additional registrations may exist.")
        }
        if !result.failures.isEmpty {
            DisclosureGroup("Failed groups (\(result.failures.count))") {
                ELBFieldRows(fields: result.failures).padding(.top, 8)
            }
            .font(.callout)
        }
        if result.matches.isEmpty {
            Text(result.isComplete ? "No registrations were found for this instance."
                 : "No registrations were found among the successfully checked groups.")
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(result.matches) { membership in
                VStack(alignment: .leading, spacing: 12) {
                    ELBLinkedResourceRow(arn: membership.group.arn, name: membership.group.name, service: .targetGroups,
                                         scope: canLoad ? scope : nil, onOpen: onOpen)
                    ForEach(membership.targets) { target in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 10) {
                                Text(target.port.map { "Registered port \(String($0))" } ?? "Registered port not returned").font(.callout)
                                Spacer(minLength: 0)
                                ELBHealthLabel(state: target.state)
                            }
                            if let reason = target.reason {
                                Text(reason).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let description = target.description {
                                Text(description).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func configure() { vm.configure(scope: scope, instanceID: instanceID) }
}
