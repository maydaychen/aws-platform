import Charts
import SwiftUI

struct ResourceMetricsView: View {
    @ObservedObject var vm: ResourceMetricsViewModel
    let scope: MonitoringScope?
    let target: ResourceMetricTarget?

    var body: some View {
        GeometryReader { geometry in
            let columnCount = geometry.size.width >= (280 * 2 + 12 + 16 * 2) ? 2 : 1
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    controls
                    Text("Manual requests only. CloudWatch API usage may incur charges; no automatic polling.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if isLambda {
                        Text("Function-level metrics · All versions and aliases")
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
                        ProgressView("Loading metrics…")
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
                Text("5-minute metrics").font(.headline)
                Spacer(minLength: 0)
                if canLoad && vm.isLoading {
                    ProgressView().controlSize(.small)
                    Button("Cancel", action: vm.cancelLoading)
                }
                Button(vm.snapshot == nil ? "Load metrics" : "Refresh", action: vm.refresh)
                    .disabled(!canLoad || vm.isLoading)
            }
            Picker("Time range", selection: $vm.timeRange) {
                ForEach(MonitoringTimeRange.allCases, id: \.self) { range in
                    Text(range.title).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private func snapshotHeader(_ snapshot: ResourceMetricsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(MonitoringDisplay.dateTime(snapshot.start)) through \(MonitoringDisplay.dateTime(snapshot.end))")
                .font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("Fetched \(MonitoringDisplay.dateTime(snapshot.fetchedAt)) · \(snapshot.period)-second aggregation")
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
    let series: ResourceMetricSeries
    let snapshot: ResourceMetricsSnapshot
    @State private var showsValues = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(series.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text("\(series.statistic) · \(series.unit) · every \(snapshot.period / 60) minutes")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !series.status.isComplete {
                Label(series.status.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.orange)
            }
            if let message = series.message {
                Text(message).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if series.points.isEmpty {
                Text("No datapoints returned. Missing data is not zero.")
                    .font(.callout).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .center)
                    .multilineTextAlignment(.center)
            } else {
                Chart(chartPoints) { point in
                    LineMark(x: .value("Time", point.timestamp), y: .value(series.unit, point.value),
                             series: .value("Segment", point.segment))
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                    PointMark(x: .value("Time", point.timestamp), y: .value(series.unit, point.value))
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
                DisclosureGroup("\(series.points.count) returned samples", isExpanded: $showsValues) {
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
