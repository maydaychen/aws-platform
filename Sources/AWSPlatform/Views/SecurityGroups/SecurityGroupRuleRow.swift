import SwiftUI

struct SecurityGroupRuleRow: View {
    let rule: SecurityGroupRule
    let inbound: Bool

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                DetailGrid(items: [("Protocol", rule.protocolName), ("Ports / ICMP type and code", rule.portRange)])
                VStack(alignment: .leading, spacing: 5) {
                    Text(inbound ? "Source" : "Destination").font(.caption).foregroundColor(.secondary)
                    Text(verbatim: rule.target).font(.callout.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let description = rule.description, !description.isEmpty {
                    Text(verbatim: description).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if rule.referencedGroupID != nil || rule.referencedAccountID != nil {
                    DetailGrid(items: [
                        ("Referenced group", rule.referencedGroupID ?? "Not returned"),
                        ("Referenced account", rule.referencedAccountID ?? "Not returned")
                    ])
                }
                if !rule.fields.isEmpty { SecurityGroupFieldRows(fields: rule.fields) }
            }
            .padding(.top, 10)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(rule.protocolName) · \(rule.portRange)").font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(rule.target).font(.caption).foregroundColor(.secondary).lineLimit(2).help(rule.target)
            }
            .padding(.vertical, 2)
        }
        .padding(12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SecurityGroupFieldRows: View {
    let fields: [ELBField]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(fields.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: fields[index].name).font(.caption).foregroundColor(.secondary)
                    Text(verbatim: fields[index].value.isEmpty ? "(empty)" : fields[index].value)
                        .font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                if index != fields.indices.last { Divider() }
            }
        }
        .padding(.horizontal, 12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}
