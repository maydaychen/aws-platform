import SwiftUI

struct SecurityGroupRuleRow: View {
    @Environment(\.locale) private var locale
    let rule: SecurityGroupRule
    let inbound: Bool

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                DetailGrid(items: [("Protocol", L10n.text(rule.protocolName, locale: locale)),
                                   ("Ports / ICMP type and code", L10n.text(rule.portRange, locale: locale))])
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text(inbound ? "Source" : "Destination", locale: locale)).font(.caption).foregroundColor(.secondary)
                    Text(verbatim: rule.target).font(.callout.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let description = rule.description, !description.isEmpty {
                    Text(verbatim: description).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if rule.referencedGroupID != nil || rule.referencedAccountID != nil {
                    DetailGrid(items: [
                        ("Referenced group", rule.referencedGroupID ?? L10n.text("Not returned", locale: locale)),
                        ("Referenced account", rule.referencedAccountID ?? L10n.text("Not returned", locale: locale))
                    ])
                }
                if !rule.fields.isEmpty { SecurityGroupFieldRows(fields: rule.fields) }
            }
            .padding(.top, 10)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(L10n.text(rule.protocolName, locale: locale)) · \(L10n.text(rule.portRange, locale: locale))").font(.callout.weight(.medium))
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
    @Environment(\.locale) private var locale
    let fields: [ELBField]
    var isVerbatimLabels = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(fields.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: isVerbatimLabels ? fields[index].name : L10n.text(fields[index].name, locale: locale))
                        .font(.caption).foregroundColor(.secondary)
                    Text(verbatim: displayedValue(fields[index]))
                        .font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                if index != fields.indices.last { Divider() }
            }
        }
        .padding(.horizontal, 12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func displayedValue(_ field: ELBField) -> String {
        if field.value.isEmpty { return L10n.text("(empty)", locale: locale) }
        if !isVerbatimLabels && field.name == "Target type" { return L10n.text(field.value, locale: locale) }
        return field.value
    }
}
