import Charts
import SwiftUI

struct ResourceMetricsView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: ResourceMetricsViewModel
    let scope: MonitoringScope?
    let target: ResourceMetricTarget?

    var body: some View {
        GeometryReader { geometry in
            let columnCount = geometry.size.width >= (280 * 2 + 12 + 16 * 2) ? 2 : 1
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    controls
                    Text(L10n.text("Manual requests only. CloudWatch API usage may incur charges; no automatic polling.", locale: locale))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if isLambda {
                        Text(L10n.text("Function-level metrics · All versions and aliases", locale: locale))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    if canLoad, let error = vm.error {
                        NoticeBanner(message: error)
                    }
                    if canLoad, let snapshot = vm.snapshot {
                        snapshotHeader(snapshot)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: columnCount), alignment: .leading, spacing: 12) {
                            ForEach(snapshot.series) { series in
                                ResourceMetricChart(series: series, snapshot: snapshot)
                            }
                        }
                    } else if canLoad && vm.isLoading {
                        ProgressView(L10n.text("Loading metrics…", locale: locale))
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        EmptyStateView(text: canLoad
                                       ? "Choose a time range and load metrics. Missing samples are never treated as zero."
                                       : "Select a resource in a verified profile to load metrics.", icon: "chart.xyaxis.line")
                            .frame(minHeight: 180)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { configure() }
        .onChange(of: scope) { _ in configure() }
        .onChange(of: target) { _ in configure() }
        .onDisappear { vm.reset() }
    }

    private var canLoad: Bool {
        scope?.isValid == true && target?.isValid == true && vm.scope == scope && vm.target == target
    }

    private var isLambda: Bool {
        guard let target else { return false }
        if case .lambda = target { return true }
        return false
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L10n.text("5-minute metrics", locale: locale)).font(.headline)
                Spacer(minLength: 0)
                if canLoad && vm.isLoading {
                    ProgressView().controlSize(.small)
                    Button(L10n.text("Cancel", locale: locale), action: vm.cancelLoading)
                }
                Button(L10n.text(vm.snapshot == nil ? "Load metrics" : "Refresh", locale: locale), action: vm.refresh)
                    .disabled(!canLoad || vm.isLoading)
            }
            Picker(L10n.text("Time range", locale: locale), selection: $vm.timeRange) {
                ForEach(MonitoringTimeRange.allCases, id: \.self) { range in
                    Text(L10n.text(range.title, locale: locale)).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private func snapshotHeader(_ snapshot: ResourceMetricsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.format("%@ through %@", MonitoringDisplay.dateTime(snapshot.start), MonitoringDisplay.dateTime(snapshot.end), locale: locale))
                .font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.format("Fetched %@ · %@-second aggregation", MonitoringDisplay.dateTime(snapshot.fetchedAt), String(snapshot.period), locale: locale))
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !snapshot.isComplete {
                NoticeBanner(message: "Some metric series are incomplete or unavailable. Check each chart's status; gaps are not zeros.")
            }
        }
    }

    private func configure() { vm.configure(scope: scope, target: target) }
}

private struct ResourceMetricChart: View {
    @Environment(\.locale) private var locale
    let series: ResourceMetricSeries
    let snapshot: ResourceMetricsSnapshot
    @State private var showsValues = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text(series.title, locale: locale)).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(L10n.format("%@ · %@ · every %@ minutes", series.statistic, series.unit, String(snapshot.period / 60), locale: locale))
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !series.status.isComplete {
                Label(L10n.text(series.status.title, locale: locale), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.orange)
            }
            if let message = series.message {
                Text(L10n.text(message, locale: locale)).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if series.points.isEmpty {
                Text(L10n.text("No datapoints returned. Missing data is not zero.", locale: locale))
                    .font(.callout).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .center)
                    .multilineTextAlignment(.center)
            } else {
                Chart(chartPoints) { point in
                    LineMark(x: .value(L10n.text("Time", locale: locale), point.timestamp), y: .value(series.unit, point.value),
                             series: .value(L10n.text("Segment", locale: locale), point.segment))
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                    PointMark(x: .value(L10n.text("Time", locale: locale), point.timestamp), y: .value(series.unit, point.value))
                        .symbolSize(10)
                        .accessibilityLabel(MonitoringDisplay.dateTime(point.timestamp))
                        .accessibilityValue("\(MonitoringDisplay.number(point.value)) \(series.unit)")
                }
                .chartXScale(domain: snapshot.start...snapshot.end)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(anchor: .top) {
                            if let date = value.as(Date.self) {
                                Text(verbatim: MonitoringDisplay.time(date))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(anchor: .trailing)
                    }
                }
                .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                .frame(height: 160)
                DisclosureGroup(L10n.format("%@ returned samples", String(series.points.count), locale: locale), isExpanded: $showsValues) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(series.points) { point in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(MonitoringDisplay.dateTime(point.timestamp)).foregroundColor(.secondary)
                                Text("\(MonitoringDisplay.number(point.value)) \(series.unit)")
                            }
                            .font(.caption.monospacedDigit()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.07)))
    }

    private var chartPoints: [MetricChartPoint] {
        var segment = 0
        var previous: Date?
        return series.points.map { point in
            if let previous, point.timestamp.timeIntervalSince(previous) > Double(snapshot.period) {
                segment += 1
            }
            previous = point.timestamp
            return MetricChartPoint(timestamp: point.timestamp, value: point.value, segment: segment)
        }
    }
}

private struct MetricChartPoint: Identifiable {
    let timestamp: Date
    let value: Double
    let segment: Int
    var id: Date { timestamp }
}

enum MonitoringDisplay {
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        return formatter.string(from: date)
    }

    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.significantDigits(1...6)))
    }
}
