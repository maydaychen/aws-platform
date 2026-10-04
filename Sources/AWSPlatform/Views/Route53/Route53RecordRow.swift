import SwiftUI

struct Route53RecordRow: View {
    let record: Route53Record
    private let externalExpansion: Binding<Bool>?
    let onShowRelationships: (() -> Void)?
    @State private var internalExpansion = false

    init(record: Route53Record, isExpanded: Binding<Bool>? = nil, onShowRelationships: (() -> Void)? = nil) {
        self.record = record
        externalExpansion = isExpanded
        self.onShowRelationships = onShowRelationships
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(isExpanded: externalExpansion ?? $internalExpansion) {
                Route53RecordDetails(record: record).padding(.top, 10)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(record.name).font(.callout.weight(.medium)).lineLimit(2).help(record.name)
                        Spacer(minLength: 0)
                        Text(record.type).font(.caption.weight(.semibold)).foregroundColor(.secondary)
                    }
                    Text(summary).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
            if (record.alias != nil || record.type == "CNAME"), let onShowRelationships {
                Button("View relationships", action: onShowRelationships)
                    .help("Inspect configured targets for this exact record set")
            }
        }
        .padding(12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private var summary: String {
        let value = record.alias != nil ? "Alias" : record.ttl.map { "TTL \($0)s" } ?? "TTL not returned"
        return "\(value) · \(record.routingPolicy)\(record.setIdentifier.map { " · \($0)" } ?? "")"
    }
}

struct Route53RecordDetails: View {
    let record: Route53Record

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(record.name).font(.caption.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            DetailGrid(items: [
                ("Record type", record.type),
                ("TTL", record.alias != nil ? "Alias" : record.ttl.map { "\($0) seconds" } ?? "Not returned"),
                ("Routing policy", record.routingPolicy)
            ])
            if let identifier = record.setIdentifier {
                DetailGrid(items: [("Set identifier", Route53Display.returned(identifier))])
            }
            if let alias = record.alias {
                DetailSectionTitle(title: "Alias target")
                Route53FieldRows(fields: [
                    .init(name: "DNS name", value: alias.dnsName),
                    .init(name: "Hosted zone ID", value: alias.hostedZoneID),
                    .init(name: "Evaluate target health", value: alias.evaluateTargetHealth ? "Yes" : "No")
                ])
            }
            if !record.values.isEmpty {
                DetailSectionTitle(title: "Values")
                Route53ValueBlock(values: record.values)
            } else if record.alias == nil {
                Text("No record values returned.").font(.callout).foregroundColor(.secondary)
            }
            if !record.routingFields.isEmpty {
                DetailSectionTitle(title: "Routing configuration")
                Route53FieldRows(fields: record.routingFields)
            }
        }
    }
}

struct Route53FieldRows: View {
    let fields: [Route53Field]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(fields.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 4) {
                    Text(fields[index].name).font(.caption).foregroundColor(.secondary)
                    Text(Route53Display.returned(fields[index].value)).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                if index != fields.indices.last { Divider() }
            }
        }
        .padding(.horizontal, 12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct Route53ValueBlock: View {
    let values: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(values.indices, id: \.self) { index in
                Text(Route53Display.returned(values[index])).font(.caption.monospaced())
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if index != values.indices.last { Divider() }
            }
        }
        .padding(12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}
