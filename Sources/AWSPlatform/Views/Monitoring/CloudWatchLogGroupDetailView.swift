import SwiftUI

struct CloudWatchLogGroupDetailView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: CloudWatchLogsBrowserViewModel

    var body: some View {
        if let group = vm.selectedGroup, vm.groups.contains(group), vm.scope?.isValid == true {
            ScrollView {
                VStack(alignment: .leading, spacing: WorkspaceLayout.contextSpacing) {
                    Text(group.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    DetailFieldRows(items: [
                        ("ARN", group.arn), ("Log class", group.logClass ?? missing),
                        ("Retention (days)", group.retentionDays.map(String.init) ?? missing),
                        ("Stored bytes", group.storedBytes.map(String.init) ?? missing),
                        ("Created", group.createdAt.map(MonitoringDisplay.dateTime) ?? missing),
                        ("KMS Key", group.kmsKeyID ?? missing)
                    ])
                    streams
                    controls
                    if let error = vm.eventError { NoticeBanner(message: error) }
                    eventResults
                }.padding(WorkspaceLayout.contextSpacing).frame(maxWidth: .infinity, alignment: .leading)
            }.id(group.id)
        } else {
            EmptyStateView(text: "Select a log group to browse streams and events.", icon: "doc.text.magnifyingglass")
        }
    }

    private var missing: String { L10n.text("Not returned", locale: locale) }

    var streamSelection: Binding<Data?> {
        Binding(get: { vm.selectedStream.map { Data($0.utf8) } }, set: { id in
            vm.selectedStream = id.flatMap { id in vm.streams.first(where: { $0.id == id })?.name }
        })
    }

    private var streams: some View {
        VStack(alignment: .leading, spacing: WorkspaceLayout.controlSpacing) {
            HStack {
                DetailSectionTitle(title: "Log streams")
                Button(L10n.text("Refresh streams", locale: locale), action: vm.loadStreams).disabled(vm.isStreamsLoading)
            }
            if vm.isStreamsLoading { ProgressView().controlSize(.small) }
            if let error = vm.streamError { NoticeBanner(message: error) }
            Picker(L10n.text("Log stream", locale: locale), selection: streamSelection) {
                Text(L10n.text("All streams", locale: locale)).tag(Data?.none)
                ForEach(vm.streams) { stream in Text(stream.name).tag(Optional(stream.id)) }
            }.pickerStyle(.menu)
            Text(L10n.format("%@ streams loaded", String(vm.streams.count), locale: locale))
                .font(.caption).foregroundColor(.secondary)
            if let stream = vm.streams.first(where: { $0.id == vm.selectedStream.map { Data($0.utf8) } }) {
                DetailFieldRows(items: [("First event", stream.firstEventAt.map(MonitoringDisplay.dateTime) ?? missing),
                                        ("Last event", stream.lastEventAt.map(MonitoringDisplay.dateTime) ?? missing)])
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: WorkspaceLayout.controlSpacing) {
            DetailSectionTitle(title: "Log events")
            Picker(L10n.text("Time range", locale: locale), selection: $vm.timeRange) {
                ForEach(MonitoringTimeRange.allCases) { Text(L10n.text($0.title, locale: locale)).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            TextField(L10n.text("AWS filter pattern (optional)", locale: locale), text: $vm.filterPattern)
                .textFieldStyle(.roundedBorder)
            Text(L10n.text("Uses AWS filter-pattern syntax. Changing the range or filter clears the previous search.", locale: locale))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("Manual search only. CloudWatch Logs pricing applies; there is no automatic polling and results stay in memory.", locale: locale))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.text("Search", locale: locale)) { vm.searchEvents() }.disabled(!vm.canSearch)
                if vm.isEventsLoading {
                    ProgressView().controlSize(.small)
                    Button(L10n.text("Cancel", locale: locale), action: vm.cancelLoading)
                }
            }
        }
    }

    @ViewBuilder private var eventResults: some View {
        if let query = vm.query {
            Text(L10n.format("%@ through %@", MonitoringDisplay.dateTime(query.startTime), MonitoringDisplay.dateTime(query.endTime), locale: locale))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if vm.limitReached {
            NoticeBanner(message: "The display limit has been reached. Results are incomplete; narrow the time range or filter and search again.")
        }
        if vm.hasSearched {
            Text(L10n.format("%@ loaded events · Newest among loaded events shown first", String(vm.events.count), locale: locale))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        LazyVStack(alignment: .leading, spacing: WorkspaceLayout.controlSpacing) {
            ForEach(vm.events) { event in
                VStack(alignment: .leading, spacing: WorkspaceLayout.controlSpacing) {
                    Text(MonitoringDisplay.dateTime(event.timestamp)).font(.caption.monospacedDigit())
                    Text(event.streamName).font(.caption).foregroundColor(.secondary)
                    Text(event.message.isEmpty ? L10n.text("(empty message)", locale: locale) : String(event.message.prefix(2_000)))
                        .font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if event.message.count > 2_000 {
                        Text(L10n.text("Message preview limited to 2,000 characters.", locale: locale)).font(.caption).foregroundColor(.secondary)
                    }
                    Divider()
                }
            }
        }
        if vm.events.isEmpty, !vm.isEventsLoading {
            Text(L10n.text(!vm.hasSearched ? "Choose a time range and search this log group." :
                vm.hasMoreEvents ? "No matching events in the pages loaded so far. More pages remain; use Load more to continue." :
                vm.eventError == nil ? "No matching events were returned for this time range and filter." :
                "The search is incomplete. Review the message above and retry.", locale: locale))
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if vm.hasMoreEvents {
            Text(L10n.text("Partial results. More pages remain in the selected time range.", locale: locale))
                .font(.caption).foregroundColor(.secondary)
            Button(L10n.text("Load more", locale: locale), action: vm.loadMoreEvents).disabled(vm.isEventsLoading)
        } else if vm.hasSearched, !vm.isEventsLoading, vm.eventError == nil, !vm.limitReached {
            Text(L10n.text("All available pages for this search have been read. New events can arrive later.", locale: locale))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
