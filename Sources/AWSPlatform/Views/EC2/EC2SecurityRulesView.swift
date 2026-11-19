import SwiftUI

struct EC2SecurityRulesView: View {
    @Environment(\.locale) private var locale
    let groups: [EC2SecurityGroupModel]
    private let summary: EC2SecurityRuleSummary

    private enum Layout {
        static let protocolWidth: CGFloat = 80
        static let portWidth: CGFloat = 96
        static let targetWidth: CGFloat = 220
        static let groupWidth: CGFloat = 220
        static let descriptionWidth: CGFloat = 240
        static let columnSpacing: CGFloat = 12
        static let rowSpacing: CGFloat = 8
    }

    init(groups: [EC2SecurityGroupModel]) {
        self.groups = groups
        summary = EC2SecurityRuleSummary(groups: groups)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            groupMetadata
            ruleSection("Inbound rules", rows: summary.inbound, inbound: true)
            ruleSection("Outbound rules", rows: summary.outbound, inbound: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var groupMetadata: some View {
        VStack(alignment: .leading, spacing: 16) {
            DetailSectionTitle(title: "Security Groups")
            if groups.isEmpty {
                Text(L10n.text("No security group rule details", locale: locale))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(groups) { group in
                    GroupBox {
                        DetailGrid(items: [
                            ("Group ID", group.groupId),
                            ("Name", group.name ?? "-"),
                            ("VPC", group.vpcId ?? "-"),
                            ("Description", group.description ?? "-")
                        ])
                    } label: {
                        HStack(alignment: .top, spacing: Layout.rowSpacing) {
                            Text(verbatim: group.name ?? group.groupId)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            CopyButton(value: group.groupId, label: "Copy security group ID")
                        }
                    }
                }
            }
        }
    }

    private func ruleSection(_ title: String, rows: [EC2SecurityRuleSummaryRow], inbound: Bool) -> some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: Layout.rowSpacing) {
                Text(L10n.text(title, locale: locale))
                    .font(.headline)
                Text(L10n.format(rows.count == 1 ? "%@ rule" : "%@ rules", String(rows.count), locale: locale))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if rows.isEmpty {
                Text(L10n.text(inbound ? "No inbound rules returned." : "No outbound rules returned.", locale: locale))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        tableHeader(inbound: inbound)
                        Divider()
                        ForEach(rows) { row in
                            tableRow(row)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func tableHeader(inbound: Bool) -> some View {
        HStack(alignment: .top, spacing: Layout.columnSpacing) {
            headerCell("Protocol", width: Layout.protocolWidth)
            headerCell("Ports / ICMP type and code", width: Layout.portWidth)
            headerCell(inbound ? "Source" : "Destination", width: Layout.targetWidth)
            headerCell("Security group", width: Layout.groupWidth)
            headerCell("Description", width: Layout.descriptionWidth)
        }
        .padding(.vertical, Layout.rowSpacing)
    }

    private func tableRow(_ row: EC2SecurityRuleSummaryRow) -> some View {
        HStack(alignment: .top, spacing: Layout.columnSpacing) {
            valueCell(row.rule.protocolName, width: Layout.protocolWidth)
            valueCell(row.rule.portRange, width: Layout.portWidth)
            valueCell(row.rule.source, width: Layout.targetWidth)
            VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                Text(verbatim: row.groupName ?? "-")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: row.groupId)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: Layout.groupWidth, alignment: .leading)
            .textSelection(.enabled)
            valueCell(row.rule.description.flatMap { $0.isEmpty ? nil : $0 } ?? "-", width: Layout.descriptionWidth)
        }
        .padding(.vertical, Layout.rowSpacing)
    }

    private func headerCell(_ title: String, width: CGFloat) -> some View {
        Text(L10n.text(title, locale: locale))
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .leading)
    }

    private func valueCell(_ value: String, width: CGFloat) -> some View {
        Text(verbatim: value)
            .font(.callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .leading)
    }
}
