import SwiftUI

/// A presentation of already available values. Section actions are the only loading entry points.
struct EC2OverviewSummaryView: View {
    @Environment(\.locale) private var locale
    let instance: EC2InstanceModel
    let detail: EC2InstanceDetailModel?
    let sectionStates: [EC2DetailSection: EC2DetailSectionState]
    let cpuCreditFields: [(String, String)]
    let availableWidth: CGFloat
    let onShowStorage: () -> Void
    let onShowSecurity: () -> Void

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), alignment: .topLeading),
              count: availableWidth >= WorkspaceLayout.summaryWideMinimum ? 2 : 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceLayout.summarySpacing) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: WorkspaceLayout.summarySpacing) {
                EC2SummaryCard(title: "Identity and system", symbol: "server.rack") {
                    EC2SummaryFieldRows(items: [
                        ("Type", instance.instanceType),
                        ("Architecture", instance.architecture ?? "-"),
                        ("AMI", instance.imageId ?? "-"), ("Launch Time", format(instance.launchTime))
                    ])
                }
                EC2SummaryCard(title: "Network and addresses", symbol: "network") {
                    EC2SummaryFieldRows(items: [
                        ("Private IP", instance.privateIP ?? "-"), ("Public IP", instance.publicIP ?? "-"),
                        ("VPC", instance.vpcId ?? "-"), ("Subnet", instance.subnetId ?? "-")
                    ])
                }
                EC2SummaryCard(title: "CPU and access", symbol: "cpu") {
                    EC2SummaryFieldRows(items: [
                        ("CPU Cores", number(detail?.cpuCoreCount)),
                        ("Threads per Core", number(detail?.threadsPerCore))
                    ] + cpuCreditFields + [
                        ("Key Pair", instance.keyName ?? "-"),
                        ("IAM Profile", detail?.iamProfileARN ?? "-")
                    ])
                }
                EC2SummaryCard(title: "Storage and security", symbol: "externaldrive") {
                    EC2SummaryFieldRows(items: [
                        ("Root Device", detail?.rootDeviceName ?? "-"),
                        ("Root Device Type", detail?.rootDeviceType ?? "-"),
                        ("EBS Optimized", boolean(detail?.ebsOptimized))
                    ])
                    sectionSummary("EBS Volumes", state: sectionStates[.storage],
                                   values: detail?.volumes.map { volume in
                        [volume.volumeId, volume.sizeGiB.map { "\($0) GiB" }, volume.type]
                            .compactMap { $0 }.joined(separator: " · ")
                    } ?? [], emptyText: "No EBS volume details", actionTitle: "View storage", action: onShowStorage)
                    Divider()
                    sectionSummary("Security Groups", state: sectionStates[.security],
                                   values: detail?.securityGroups.map { group in
                        [group.name, group.groupId].compactMap { $0 }.joined(separator: " · ")
                    } ?? [], emptyText: "No security group details", actionTitle: "View security", action: onShowSecurity)
                }
            }
            DisclosureGroup(L10n.text("More configuration", locale: locale)) {
                EC2SummaryFieldRows(items: [
                    ("Instance ID", instance.instanceId), ("State", instance.state),
                    ("OS", instance.imageName ?? instance.platformDetails ?? "-"),
                    ("Availability Zone", instance.availabilityZone ?? "-"),
                    ("Lifecycle", detail?.lifecycle ?? (detail == nil ? "-" : "on-demand")),
                    ("IPv6", detail?.ipv6Address ?? "-"),
                    ("Private DNS", detail?.privateDNSName ?? "-"),
                    ("Public DNS", detail?.publicDNSName ?? "-"),
                    ("Source/Destination Check", boolean(detail?.sourceDestCheck)),
                    ("Virtualization", detail?.virtualizationType ?? "-"),
                    ("Hypervisor", detail?.hypervisor ?? "-"),
                    ("Monitoring", detail?.monitoringState ?? "-"),
                    ("ENA Support", boolean(detail?.enaSupport)),
                    ("Capacity Reservation", detail?.capacityReservationId ?? "-"),
                    ("Spot Request", detail?.spotRequestId ?? "-")
                ])
            }
            .accessibilityIdentifier("ec2.moreConfiguration")
            if !instance.tags.isEmpty {
                EC2SummaryCard(title: "Tags", symbol: "tag") {
                    EC2SummaryFieldRows(items: instance.tags.sorted { $0.key < $1.key }.map { ($0.key, $0.value) },
                                        localizesLabels: false)
                }
            }
        }
    }

    private func sectionSummary(_ title: String, state: EC2DetailSectionState?, values: [String],
                                emptyText: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: WorkspaceLayout.detailTitleSpacing) {
            HStack {
                Text(L10n.text(title, locale: locale)).font(.caption).foregroundColor(.secondary)
                Spacer(minLength: 0)
                Button(L10n.text(actionTitle, locale: locale), action: action)
                    .buttonStyle(.borderless)
            }
            switch state ?? .notLoaded {
            case .notLoaded:
                Text(L10n.text("Not loaded", locale: locale)).foregroundColor(.secondary)
            case .loading:
                HStack(spacing: WorkspaceLayout.detailTitleSpacing) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("Loading…", locale: locale)).foregroundColor(.secondary)
                }
            case .failed(let message):
                Label(L10n.text(message, locale: locale), systemImage: "exclamationmark.triangle")
                    .foregroundColor(.secondary)
            case .loaded:
                if values.isEmpty {
                    Text(L10n.text(emptyText, locale: locale)).foregroundColor(.secondary)
                } else {
                    ForEach(values.indices, id: \.self) { index in Text(values[index]) }
                }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func boolean(_ value: Bool?) -> String {
        value.map { L10n.text($0 ? "Yes" : "No", locale: locale) } ?? "-"
    }

    private func number(_ value: Int?) -> String { value.map(String.init) ?? "-" }

    private func format(_ date: Date?) -> String {
        date?.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(locale)) ?? "-"
    }
}

struct EC2SummaryCard<Content: View>: View {
    @Environment(\.locale) private var locale
    let title: String
    let symbol: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceLayout.summaryFieldSpacing) {
            Label(L10n.text(title, locale: locale), systemImage: symbol)
                .font(.headline).symbolRenderingMode(.monochrome)
            content()
        }
        .padding(WorkspaceLayout.summaryPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: WorkspaceLayout.summaryCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: WorkspaceLayout.summaryCornerRadius)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

struct EC2SummaryFieldRows: View {
    @Environment(\.locale) private var locale
    let items: [(String, String)]
    var localizesLabels = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: WorkspaceLayout.summaryFieldSpacing) {
                    Text(localizesLabels ? L10n.text(items[index].0, locale: locale) : items[index].0)
                        .font(.caption).foregroundColor(.secondary)
                        .frame(width: WorkspaceLayout.summaryLabelWidth, alignment: .leading)
                    Text(items[index].1).font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, WorkspaceLayout.summaryRowPadding)
                if index != items.count - 1 { Divider() }
            }
        }
    }
}
