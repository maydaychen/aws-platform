import SwiftUI

struct ResourceRelationNodeCard: View {
    let node: ResourceRelationNode
    let onExplore: (ResourceRelationReference) -> Void
    let onOpen: (ResourceRelationReference) -> Void

    var body: some View {
        DisclosureGroup {
            ResourceRelationNodeDetails(node: node, onExplore: onExplore, onOpen: onOpen).padding(.top, 10)
        } label: {
            Text(node.name).font(.callout.weight(.medium)).lineLimit(2).help(node.name)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.06)))
    }
}

struct ResourceRelationNodeDetails: View {
    @Environment(\.locale) private var locale
    let node: ResourceRelationNode
    let onExplore: (ResourceRelationReference) -> Void
    let onOpen: (ResourceRelationReference) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(node.name).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(L10n.text(node.relation, locale: locale)).font(.caption).foregroundColor(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let note = node.note {
                Text(L10n.text(note, locale: locale)).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !node.fields.isEmpty { ELBFieldRows(fields: node.fields) }
            if let reference = node.reference, reference.isValid {
                if reference.service == .lambda, reference.resourceID.split(separator: ":").count == 8 {
                    Text(L10n.text("Open shows function-level details. The registered alias or version is retained above as configuration.", locale: locale))
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    if reference.canExplore { Button(L10n.text("Explore", locale: locale)) { onExplore(reference) } }
                    Button(L10n.text("Open", locale: locale)) { onOpen(reference) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
