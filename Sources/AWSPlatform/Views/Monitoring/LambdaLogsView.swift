import SwiftUI

struct LambdaLogsView: View {
    @ObservedObject var vm: LambdaLogsViewModel
    let scope: MonitoringScope?
    let context: LambdaLogContext?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                controls
                Text("Manual search only. CloudWatch Logs pricing applies; there is no automatic polling and results stay in memory.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let context {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.logGroup).font(.caption.monospaced()).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if context.isCustomGroup {
                            Text("Shared group: only streams belonging to this function are searched.")
                                .font(.caption).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if canSearch, let query = vm.query { queryHeader(query) }
                if canSearch, let error = vm.error { NoticeBanner(message: error) }
                if !canSearch || vm.events.isEmpty {
                    emptyState
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(vm.events) { event in LambdaLogEventView(event: event) }
                    }
                }
                pagination
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { configure() }
        .onChange(of: scope) { _ in configure() }
        .onChange(of: context) { _ in configure() }
        .onDisappear { vm.reset() }
    }

    private var canSearch: Bool {
        scope?.isValid == true && context?.isValid == true && vm.scope == scope && vm.context == context
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Lambda logs").font(.headline)
                Spacer(minLength: 0)
                if canSearch && vm.isLoading {
                    ProgressView().controlSize(.small)
                    Button("Cancel", action: vm.cancelLoading)
                }
                Button("Search", action: vm.search).disabled(!canSearch || vm.isLoading)
            }
            Picker("Time range", selection: $vm.timeRange) {
                ForEach(MonitoringTimeRange.allCases, id: \.self) { range in Text(range.title).tag(range) }
            }
            .pickerStyle(.segmented).labelsHidden()
            TextField("AWS filter pattern (optional)", text: $vm.filterPattern)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if canSearch && !vm.isLoading { vm.search() } }
            Text("Uses AWS filter-pattern syntax. Changing the range or filter clears the previous search.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func queryHeader(_ query: LambdaLogQuery) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(MonitoringDisplay.dateTime(query.startTime)) through \(MonitoringDisplay.dateTime(query.endTime))")
                .font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !query.filterPattern.isEmpty {
                Text("Applied filter: \(query.filterPattern)").font(.caption.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("\(vm.events.count) loaded events · Newest among loaded events shown first")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if vm.limitReached {
                Label("Display limit reached · Incomplete results", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundColor(.orange)
            } else if vm.hasMore {
                Label("Partial results · More pages available", systemImage: "ellipsis.circle")
                    .font(.caption).foregroundColor(.secondary)
            } else if vm.error != nil {
                Text("Search incomplete").font(.caption).foregroundColor(.orange)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if canSearch && vm.isLoading {
            ProgressView("Searching log events…").frame(maxWidth: .infinity, minHeight: 140)
        } else if !canSearch {
            EmptyStateView(text: "Load the selected function's details in a verified profile before searching logs.", icon: "doc.text.magnifyingglass")
                .frame(minHeight: 160)
        } else if vm.error != nil {
            EmptyStateView(text: "The search is incomplete. Review the message above and retry.", icon: "exclamationmark.triangle")
                .frame(minHeight: 140)
        } else if !vm.hasSearched {
            EmptyStateView(text: "Choose a time range and search this function's logs.", icon: "doc.text.magnifyingglass")
                .frame(minHeight: 160)
        } else if vm.limitReached {
            EmptyStateView(text: "The display limit was reached before any events could be shown. Narrow the time range or filter and search again.", icon: "exclamationmark.triangle")
                .frame(minHeight: 140)
        } else if vm.hasMore {
            EmptyStateView(text: "No matching events in the pages loaded so far. More pages remain; use Load more to continue.", icon: "doc.text.magnifyingglass")
                .frame(minHeight: 140)
        } else {
            EmptyStateView(text: "No matching events were returned for this time range and filter.", icon: "doc.text.magnifyingglass")
                .frame(minHeight: 140)
        }
    }

    @ViewBuilder
    private var pagination: some View {
        if canSearch {
            if vm.limitReached {
                NoticeBanner(message: "The display limit has been reached. Results are incomplete; narrow the time range or filter and search again.")
            } else if vm.hasMore {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Partial results. More pages remain in the selected time range.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(vm.isLoading ? "Loading…" : "Load more", action: vm.loadMore)
                            .disabled(vm.isLoading || !canSearch)
                        if vm.isLoading { Button("Cancel", action: vm.cancelLoading) }
                    }
                }
            } else if vm.hasSearched && !vm.isLoading && vm.error == nil {
                Text("All available pages for this search have been read. New events can arrive later.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func configure() { vm.configure(scope: scope, context: context) }
}

private struct LambdaLogEventView: View {
    let event: LambdaLogEvent
    @State private var showsFullMessage = false
    private let previewLength = 2_000

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(MonitoringDisplay.dateTime(event.timestamp)).font(.caption.monospacedDigit())
            Text(event.streamName).font(.caption.monospaced()).foregroundColor(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let ingestionTime = event.ingestionTime {
                Text("Ingested \(MonitoringDisplay.dateTime(ingestionTime))").font(.caption).foregroundColor(.secondary)
            }
            Divider()
            Text(message).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if event.message.count > previewLength {
                Button(showsFullMessage ? "Show preview" : "Show full message (\(event.message.count) characters)") {
                    showsFullMessage.toggle()
                }
                .font(.caption)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.07)))
    }

    private var message: String {
        if event.message.isEmpty { return "(empty message)" }
        guard !showsFullMessage, event.message.count > previewLength else { return event.message }
        return String(event.message.prefix(previewLength)) + "\n[Preview truncated. Expand to read the full message.]"
    }
}
