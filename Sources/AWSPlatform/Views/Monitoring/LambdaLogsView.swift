import SwiftUI

struct LambdaLogsView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: LambdaLogsViewModel
    let scope: MonitoringScope?
    let context: LambdaLogContext?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                controls
                Text(L10n.text("Manual search only. CloudWatch Logs pricing applies; there is no automatic polling and results stay in memory.", locale: locale))
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let context {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.logGroup).font(.caption.monospaced()).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if context.isCustomGroup {
                            Text(L10n.text("Shared group: only streams belonging to this function are searched.", locale: locale))
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
                Text(L10n.text("Lambda logs", locale: locale)).font(.headline)
                Spacer(minLength: 0)
                if canSearch && vm.isLoading {
                    ProgressView().controlSize(.small)
                    Button(L10n.text("Cancel", locale: locale), action: vm.cancelLoading)
                }
                Button(L10n.text("Search", locale: locale), action: vm.search).disabled(!canSearch || vm.isLoading)
            }
            Picker(L10n.text("Time range", locale: locale), selection: $vm.timeRange) {
                ForEach(MonitoringTimeRange.allCases, id: \.self) { range in Text(L10n.text(range.title, locale: locale)).tag(range) }
            }
            .pickerStyle(.segmented).labelsHidden()
            TextField(L10n.text("AWS filter pattern (optional)", locale: locale), text: $vm.filterPattern)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if canSearch && !vm.isLoading { vm.search() } }
            Text(L10n.text("Uses AWS filter-pattern syntax. Changing the range or filter clears the previous search.", locale: locale))
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func queryHeader(_ query: LambdaLogQuery) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.format("%@ through %@", MonitoringDisplay.dateTime(query.startTime), MonitoringDisplay.dateTime(query.endTime), locale: locale))
                .font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !query.filterPattern.isEmpty {
                Text(L10n.format("Applied filter: %@", query.filterPattern, locale: locale)).font(.caption.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.format("%@ loaded events · Newest among loaded events shown first", String(vm.events.count), locale: locale))
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if vm.limitReached {
                Label(L10n.text("Display limit reached · Incomplete results", locale: locale), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundColor(.orange)
            } else if vm.hasMore {
                Label(L10n.text("Partial results · More pages available", locale: locale), systemImage: "ellipsis.circle")
                    .font(.caption).foregroundColor(.secondary)
            } else if vm.error != nil {
                Text(L10n.text("Search incomplete", locale: locale)).font(.caption).foregroundColor(.orange)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if canSearch && vm.isLoading {
            ProgressView(L10n.text("Searching log events…", locale: locale)).frame(maxWidth: .infinity, minHeight: 140)
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
                    Text(L10n.text("Partial results. More pages remain in the selected time range.", locale: locale))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(L10n.text(vm.isLoading ? "Loading…" : "Load more", locale: locale), action: vm.loadMore)
                            .disabled(vm.isLoading || !canSearch)
                        if vm.isLoading { Button(L10n.text("Cancel", locale: locale), action: vm.cancelLoading) }
                    }
                }
            } else if vm.hasSearched && !vm.isLoading && vm.error == nil {
                Text(L10n.text("All available pages for this search have been read. New events can arrive later.", locale: locale))
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func configure() { vm.configure(scope: scope, context: context) }
}

private struct LambdaLogEventView: View {
    @Environment(\.locale) private var locale
    let event: LambdaLogEvent
    @State private var showsFullMessage = false
    private let previewLength = 2_000

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(MonitoringDisplay.dateTime(event.timestamp)).font(.caption.monospacedDigit())
            Text(event.streamName).font(.caption.monospaced()).foregroundColor(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let ingestionTime = event.ingestionTime {
                Text(L10n.format("Ingested %@", MonitoringDisplay.dateTime(ingestionTime), locale: locale)).font(.caption).foregroundColor(.secondary)
            }
            Divider()
            Text(message).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if event.message.count > previewLength {
                Button(showsFullMessage ? L10n.text("Show preview", locale: locale) : L10n.format("Show full message (%@ characters)", String(event.message.count), locale: locale)) {
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
        if event.message.isEmpty { return L10n.text("(empty message)", locale: locale) }
        guard !showsFullMessage, event.message.count > previewLength else { return event.message }
        return String(event.message.prefix(previewLength)) + "\n" + L10n.text("[Preview truncated. Expand to read the full message.]", locale: locale)
    }
}
