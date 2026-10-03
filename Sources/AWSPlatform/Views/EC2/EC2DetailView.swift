import AppKit
import SwiftUI

struct EC2DetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case network = "Network"
        case storage = "Storage"
        case security = "Security"
        case status = "Status"
        case metrics = "Metrics"

        var id: String { rawValue }
    }

    let instance: EC2InstanceModel
    @ObservedObject var vm: EC2ViewModel
    let monitoringScope: MonitoringScope?
    let metricsVM: ResourceMetricsViewModel?
    @State private var selectedTab: Tab = .overview

    init(instance: EC2InstanceModel, vm: EC2ViewModel, tab: Tab = .overview,
         monitoringScope: MonitoringScope? = nil, metricsVM: ResourceMetricsViewModel? = nil) {
        self.instance = instance
        self.vm = vm
        self.monitoringScope = monitoringScope
        self.metricsVM = metricsVM
        _selectedTab = State(initialValue: tab)
    }

    private var detail: EC2InstanceDetailModel? {
        guard vm.instanceDetail?.instanceId == instance.instanceId else { return nil }
        return vm.instanceDetail
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            DetailTabPicker(tabs: Tab.allCases.filter { $0 != .metrics || metricsVM != nil }, selection: $selectedTab)
            .padding()

            if let detail, !detail.warnings.isEmpty {
                warningBanner(detail.warnings)
            }

            ZStack {
                tabContent
                if selectedTab != .metrics && vm.isDetailLoading && detail == nil {
                    ProgressView("Loading EC2 details…")
                        .padding()
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .onChange(of: instance.instanceId) { _ in
            selectedTab = .overview
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(instance.name)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .help(instance.name)
                    HStack(spacing: 6) {
                        Text(instance.instanceId)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                        copyButton(instance.instanceId, label: "Copy instance ID")
                    }
                }
                Spacer()
                statusBadge
                    .fixedSize()
            }

            if let detailError = vm.detailError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(detailError)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Retry") {
                        vm.loadDetailForSelection()
                    }
                }
            }
        }
        .padding()
    }

    @ViewBuilder
    private var statusBadge: some View {
        let health = detail?.health ?? vm.instanceHealth[instance.instanceId]
        HStack(spacing: 6) {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
            Text(instance.state)
            if health?.needsAttention == true {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .help(health?.summary ?? "Needs attention")
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .overview:
            overviewTab
        case .network:
            networkTab
        case .storage:
            storageTab
        case .security:
            securityTab
        case .status:
            statusTab
        case .metrics:
            if let metricsVM {
                ResourceMetricsView(vm: metricsVM, scope: monitoringScope, target: .ec2(instance.instanceId))
            }
        }
    }

    private var overviewTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailGrid(items: [
                    ("Instance ID", instance.instanceId),
                    ("State", instance.state),
                    ("Type", instance.instanceType),
                    ("OS", instance.imageName ?? instance.platformDetails ?? "-"),
                    ("Architecture", instance.architecture ?? "-"),
                    ("AMI", instance.imageId ?? "-"),
                    ("Key Pair", instance.keyName ?? "-"),
                    ("Launch Time", format(instance.launchTime)),
                    ("Availability Zone", instance.availabilityZone ?? "-"),
                    ("Monitoring", detail?.monitoringState ?? "-"),
                    ("IAM Profile", detail?.iamProfileARN ?? "-"),
                    ("Lifecycle", detail?.lifecycle ?? "on-demand"),
                    ("Root Device", detail?.rootDeviceName ?? "-"),
                    ("Root Device Type", detail?.rootDeviceType ?? "-"),
                    ("Virtualization", detail?.virtualizationType ?? "-"),
                    ("Hypervisor", detail?.hypervisor ?? "-"),
                    ("CPU Cores", number(detail?.cpuCoreCount)),
                    ("Threads per Core", number(detail?.threadsPerCore)),
                    ("EBS Optimized", boolean(detail?.ebsOptimized)),
                    ("ENA Support", boolean(detail?.enaSupport)),
                    ("Capacity Reservation", detail?.capacityReservationId ?? "-"),
                    ("Spot Request", detail?.spotRequestId ?? "-")
                ])

                if !instance.tags.isEmpty {
                    sectionTitle("Tags")
                    keyValueRows(instance.tags)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private var networkTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailGrid(items: [
                    ("Private IP", instance.privateIP ?? "-"),
                    ("Public IP", instance.publicIP ?? "-"),
                    ("IPv6", detail?.ipv6Address ?? "-"),
                    ("Private DNS", detail?.privateDNSName ?? "-"),
                    ("Public DNS", detail?.publicDNSName ?? "-"),
                    ("VPC", instance.vpcId ?? "-"),
                    ("Subnet", instance.subnetId ?? "-"),
                    ("Availability Zone", instance.availabilityZone ?? "-"),
                    ("Source/Destination Check", boolean(detail?.sourceDestCheck))
                ])

                sectionTitle("Network Interfaces")
                if let interfaces = detail?.networkInterfaces, !interfaces.isEmpty {
                    ForEach(interfaces) { interface in
                        GroupBox {
                            DetailGrid(items: [
                                ("Interface ID", interface.interfaceId),
                                ("Status", interface.status ?? "-"),
                                ("Type", interface.interfaceType ?? "-"),
                                ("Device Index", number(interface.deviceIndex)),
                                ("MAC Address", interface.macAddress ?? "-"),
                                ("Private IP", interface.privateIP ?? "-"),
                                ("Public IP / EIP", interface.publicIP ?? "-"),
                                ("Private DNS", interface.privateDNSName ?? "-"),
                                ("Public DNS", interface.publicDNSName ?? "-"),
                                ("Private IPv4 Addresses", joined(interface.privateIPs)),
                                ("IPv6 Addresses", joined(interface.ipv6Addresses)),
                                ("VPC", interface.vpcId ?? "-"),
                                ("Subnet", interface.subnetId ?? "-"),
                                ("Security Groups", joined(interface.securityGroupIds)),
                                ("Delete on Termination", boolean(interface.deleteOnTermination)),
                                ("Source/Destination Check", boolean(interface.sourceDestCheck))
                            ])
                        } label: {
                            HStack {
                                Text(nonEmpty(interface.description) ?? interface.interfaceId)
                                Spacer()
                                copyButton(interface.interfaceId, label: "Copy interface ID")
                            }
                        }
                    }
                } else {
                    emptyDetail("No network interface details")
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private var storageTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle("EBS Volumes")
                if let volumes = detail?.volumes, !volumes.isEmpty {
                    ForEach(volumes) { volume in
                        GroupBox {
                            DetailGrid(items: [
                                ("Volume ID", volume.volumeId),
                                ("Device", volume.device ?? "-"),
                                ("State", volume.state ?? "-"),
                                ("Type", volume.type ?? "-"),
                                ("Size", volume.sizeGiB.map { "\($0) GiB" } ?? "-"),
                                ("IOPS", number(volume.iops)),
                                ("Throughput", volume.throughputMiBps.map { "\($0) MiB/s" } ?? "-"),
                                ("Encrypted", boolean(volume.encrypted)),
                                ("Delete on Termination", boolean(volume.deleteOnTermination)),
                                ("Availability Zone", volume.availabilityZone ?? "-"),
                                ("Snapshot", volume.snapshotId ?? "-")
                            ])
                        } label: {
                            HStack {
                                Text(nonEmpty(volume.name) ?? volume.volumeId)
                                Spacer()
                                copyButton(volume.volumeId, label: "Copy volume ID")
                            }
                        }
                    }
                } else {
                    emptyDetail("No EBS volume details")
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private var securityTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle("Instance Metadata Service")
                DetailGrid(items: [
                    ("HTTP Endpoint", detail?.metadataHttpEndpoint ?? "-"),
                    ("IMDSv2 Tokens", detail?.metadataHttpTokens ?? "-"),
                    ("Response Hop Limit", number(detail?.metadataHopLimit)),
                    ("Metadata Tags", detail?.metadataTags ?? "-")
                ])

                sectionTitle("Security Groups")
                if let groups = detail?.securityGroups, !groups.isEmpty {
                    ForEach(groups) { group in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 14) {
                                DetailGrid(items: [
                                    ("Group ID", group.groupId),
                                    ("Name", group.name ?? "-"),
                                    ("VPC", group.vpcId ?? "-"),
                                    ("Description", group.description ?? "-")
                                ])
                                securityRuleSection("Inbound rules", rules: group.inboundRules)
                                securityRuleSection("Outbound rules", rules: group.outboundRules)
                            }
                        } label: {
                            HStack {
                                Text(group.name ?? group.groupId)
                                Spacer()
                                copyButton(group.groupId, label: "Copy security group ID")
                            }
                        }
                    }
                } else {
                    emptyDetail("No security group rule details")
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private var statusTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                let health = detail?.health ?? vm.instanceHealth[instance.instanceId]
                DetailGrid(items: [
                    ("System Status", health?.systemStatus ?? "-"),
                    ("Instance Status", health?.instanceStatus ?? "-"),
                    ("Attached EBS Status", health?.attachedEBSStatus ?? "-"),
                    ("Detailed Monitoring", detail?.monitoringState ?? "-"),
                    ("State Transition Reason", detail?.stateTransitionReason ?? "-")
                ])

                sectionTitle("Scheduled Events")
                if let events = health?.events, !events.isEmpty {
                    ForEach(events) { event in
                        GroupBox(event.code) {
                            DetailGrid(items: [
                                ("Event ID", event.eventId),
                                ("Description", event.description ?? "-"),
                                ("Not Before", format(event.notBefore)),
                                ("Not After", format(event.notAfter))
                            ])
                        }
                    }
                } else {
                    emptyDetail("No scheduled events")
                }
            }
            .padding()
        }
    }

    private func warningBanner(_ warnings: [String]) -> some View {
        ScrollView {
            NoticeBanner(message: (["Some EC2 details could not be loaded"] + warnings).joined(separator: "\n"))
        }
        .frame(maxHeight: 100)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func securityRuleSection(
        _ title: String,
        rules: [EC2SecurityRuleModel]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            if rules.isEmpty {
                Text("None")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(rules.enumerated()), id: \.offset) { _, rule in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(rule.protocolName) · \(rule.portRange) · \(rule.source)")
                            .font(.caption)
                        if let description = rule.description, !description.isEmpty {
                            Text(description)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        DetailSectionTitle(title: title)
    }

    private func keyValueRows(_ values: [String: String]) -> some View {
        DetailKeyValueRows(values: values)
    }

    private func emptyDetail(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func copyButton(_ value: String, label: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    private var stateColor: Color {
        switch instance.state {
        case "running":
            return .green
        case "pending", "stopping":
            return .orange
        case "shutting-down", "terminated":
            return .red
        default:
            return .gray
        }
    }

    private func boolean(_ value: Bool?) -> String {
        value.map { $0 ? "Yes" : "No" } ?? "-"
    }

    private func number(_ value: Int?) -> String {
        value.map(String.init) ?? "-"
    }

    private func joined(_ values: [String]) -> String {
        values.isEmpty ? "-" : values.joined(separator: ", ")
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func format(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .standard) ?? "-"
    }
}
