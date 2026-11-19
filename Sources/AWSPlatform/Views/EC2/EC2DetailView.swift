import SwiftUI

struct EC2DetailView: View {
    @Environment(\.locale) private var locale
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case network = "Network"
        case storage = "Storage"
        case security = "Security"
        case status = "Status"
        case metrics = "Metrics"
        case targetGroups = "Target Groups"

        var id: String { rawValue }
    }

    let instance: EC2InstanceModel
    @ObservedObject var vm: EC2ViewModel
    let monitoringScope: MonitoringScope?
    let metricsVM: ResourceMetricsViewModel?
    let membershipsVM: EC2TargetGroupsViewModel?
    let onOpenELB: (ELBResourceReference) -> Void
    let isFavorite: Bool
    let canToggleFavorite: Bool
    let onToggleFavorite: (() -> Void)?
    let onShowRelationships: (() -> Void)?
    @State private var selectedTab: Tab = .overview

    init(instance: EC2InstanceModel, vm: EC2ViewModel, tab: Tab = .overview,
         monitoringScope: MonitoringScope? = nil, metricsVM: ResourceMetricsViewModel? = nil,
         membershipsVM: EC2TargetGroupsViewModel? = nil, onOpenELB: @escaping (ELBResourceReference) -> Void = { _ in },
         isFavorite: Bool = false, canToggleFavorite: Bool = true,
         onToggleFavorite: (() -> Void)? = nil, onShowRelationships: (() -> Void)? = nil) {
        self.instance = instance
        self.vm = vm
        self.monitoringScope = monitoringScope
        self.metricsVM = metricsVM
        self.membershipsVM = membershipsVM
        self.onOpenELB = onOpenELB
        self.isFavorite = isFavorite
        self.canToggleFavorite = canToggleFavorite
        self.onToggleFavorite = onToggleFavorite
        self.onShowRelationships = onShowRelationships
        _selectedTab = State(initialValue: tab)
    }

    private var detail: EC2InstanceDetailModel? {
        guard vm.instanceDetail?.instanceId == instance.instanceId else { return nil }
        return vm.instanceDetail
    }

    var cpuCreditFields: [(String, String)] {
        guard EC2CPUCreditMode.applies(to: instance.instanceType) else { return [] }
        let value: String
        if let detail {
            value = (detail.cpuCreditMode ?? .unknown).rawValue
        } else {
            value = vm.detailError == nil ? "Loading…" : EC2CPUCreditMode.readFailed.rawValue
        }
        return [("CPU Credit mode", value)]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            DetailTabPicker(tabs: Tab.allCases.filter { ($0 != .metrics || metricsVM != nil) && ($0 != .targetGroups || membershipsVM != nil) }, selection: $selectedTab)
            .padding()

            if let detail, !detail.warnings.isEmpty {
                warningBanner(detail.warnings)
            }

            ZStack {
                tabContent
                    .id(instance.instanceId)
                if (selectedTab == .overview || selectedTab == .network) && vm.isDetailLoading && detail == nil {
                    ProgressView(L10n.text("Loading EC2 details…", locale: locale))
                        .padding()
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { requestSelectedSection() }
        .onChange(of: selectedTab) { _ in requestSelectedSection() }
        .onChange(of: instance.instanceId) { _ in
            selectedTab = .overview
            vm.showDetailSection(nil)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: WorkspaceLayout.detailTitleSpacing) {
            EC2DetailHeaderView(instance: instance, scope: monitoringScope,
                                isCurrentSelection: vm.scope == monitoringScope && vm.selectedInstance == instance,
                                isFavorite: isFavorite, canToggleFavorite: canToggleFavorite,
                                onToggleFavorite: onToggleFavorite, onShowRelationships: onShowRelationships)

            if let detailError = vm.detailError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(L10n.text(detailError, locale: locale))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(L10n.text("Retry", locale: locale)) {
                        vm.loadDetailForSelection()
                    }
                }
            }
        }
        .padding()
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .overview:
            overviewTab
        case .network:
            networkTab
        case .storage:
            detailSection(.storage) { storageTab }
        case .security:
            detailSection(.security) { securityTab }
        case .status:
            statusTab
        case .metrics:
            if let metricsVM {
                ResourceMetricsView(vm: metricsVM, scope: monitoringScope, target: .ec2(instance.instanceId))
            }
        case .targetGroups:
            if let membershipsVM {
                EC2TargetGroupsView(vm: membershipsVM, scope: monitoringScope, instanceID: instance.instanceId, onOpen: onOpenELB)
            }
        }
    }

    private func requestSelectedSection() {
        let section: EC2DetailSection?
        switch selectedTab {
        case .storage: section = .storage
        case .security: section = .security
        default: section = nil
        }
        vm.showDetailSection(section)
    }

    @ViewBuilder
    private func detailSection<Content: View>(_ section: EC2DetailSection, @ViewBuilder content: () -> Content) -> some View {
        switch vm.sectionStates[section] ?? .notLoaded {
        case .loaded:
            content()
        case .failed(let message):
            VStack {
                NoticeBanner(message: message)
                Button(L10n.text("Retry", locale: locale)) { vm.retryDetailSection(section) }
            }
            .padding()
        case .notLoaded, .loading:
            if let error = vm.detailError {
                EmptyDetailNote(text: error)
            } else {
                ProgressView(L10n.text("Loading EC2 details…", locale: locale))
                    .padding()
            }
        }
    }

    private var overviewTab: some View {
        GeometryReader { geometry in
            ScrollView {
                EC2OverviewSummaryView(instance: instance, detail: detail,
                                       sectionStates: detail == nil ? [:] : vm.sectionStates,
                                       cpuCreditFields: cpuCreditFields.map { ($0.0, L10n.text($0.1, locale: locale)) },
                                       availableWidth: geometry.size.width,
                                       onShowStorage: { selectedTab = .storage },
                                       onShowSecurity: { selectedTab = .security })
                    .padding()
            }
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
                                CopyButton(value: interface.interfaceId, label: "Copy interface ID")
                            }
                        }
                    }
                } else {
                    EmptyDetailNote(text: "No network interface details")
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
                                CopyButton(value: volume.volumeId, label: "Copy volume ID")
                            }
                        }
                    }
                } else {
                    EmptyDetailNote(text: "No EBS volume details")
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

                EC2SecurityRulesView(groups: detail?.securityGroups ?? [])
            }
            .padding()
        }
    }

    @ViewBuilder
    private var statusTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailGrid(items: [
                    ("State", instance.state),
                    ("Detailed Monitoring", detail?.monitoringState ?? "-"),
                    ("State Transition Reason", detail?.stateTransitionReason ?? "-"),
                    ("Launch Time", format(instance.launchTime)),
                    ("Lifecycle", detail?.lifecycle ?? (detail == nil ? "-" : "on-demand")),
                    ("Availability Zone", instance.availabilityZone ?? "-")
                ])
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

    private func sectionTitle(_ title: String) -> some View {
        DetailSectionTitle(title: title)
    }

    private func boolean(_ value: Bool?) -> String {
        value.map { L10n.text($0 ? "Yes" : "No", locale: locale) } ?? "-"
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
        date?.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(locale)) ?? "-"
    }
}
