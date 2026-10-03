import SwiftUI

struct AlarmMetricView: View {
    let metric: AlarmMetricQuery

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(metric.label ?? metric.id).font(.headline).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            DetailGrid(items: properties)
            if let expression = metric.expression {
                Text("Expression").font(.caption).foregroundColor(.secondary)
                AlarmTextBlock(text: expression, monospaced: true)
            }
            if !metric.dimensions.isEmpty {
                Text("Dimensions").font(.caption).foregroundColor(.secondary)
                DetailGrid(items: metric.dimensions.map { ($0.label, $0.value) })
            }
        }
        .padding(12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private var properties: [(String, String)] {
        var properties = [("Query ID", metric.id)]
        if let account = metric.accountID { properties.append(("Metric account", account)) }
        if let returnData = metric.returnData { properties.append(("Return data", AlarmDisplay.boolean(returnData))) }
        if let namespace = metric.namespace { properties.append(("Namespace", namespace)) }
        if let name = metric.metricName { properties.append(("Metric name", name)) }
        if let statistic = metric.statistic { properties.append(("Statistic", statistic)) }
        if let period = metric.period { properties.append(("Period", "\(period) seconds")) }
        if let unit = metric.unit { properties.append(("Unit", unit)) }
        return properties
    }
}

struct AlarmTextBlock: View {
    let text: String
    var monospaced = false

    var body: some View {
        Text(text)
            .font(monospaced ? .system(.caption, design: .monospaced) : .callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}
