import SwiftUI

struct RDSDatabaseSnapshotsView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: RDSInsightsViewModel
    let scope: MonitoringScope?
    let database: RDSDatabase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text(L10n.text("Database snapshots", locale: locale)).font(.headline)
                    Spacer(minLength: 0)
                    if canLoad && vm.isSnapshotsLoading {
                        ProgressView().controlSize(.small)
                        Button(L10n.text("Cancel", locale: locale), action: vm.cancelSnapshots)
                    }
                    Button(L10n.text("Load snapshots", locale: locale), action: vm.loadSnapshots)
                        .disabled(!canLoad || vm.isSnapshotsLoading)
                }
                Text(L10n.text("Current account owned snapshots only. Listing does not create snapshots or verify restore readiness.", locale: locale))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if canLoad, let error = vm.snapshotsError { NoticeBanner(message: error) }
                if canLoad && vm.hasLoadedSnapshots {
                    if vm.snapshots.isEmpty {
                        Text(L10n.text("No snapshots returned for this database.", locale: locale)).foregroundColor(.secondary)
                    }
                    ForEach(vm.snapshots) { snapshot in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(snapshot.identifier).font(.headline).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            DetailFieldRows(items: fields(snapshot))
                            Divider()
                        }
                    }
                } else if canLoad && vm.isSnapshotsLoading {
                    ProgressView(L10n.text("Loading database snapshots…", locale: locale))
                } else if vm.snapshotsError == nil || !canLoad {
                    EmptyStateView(text: "Load automatic and manual snapshots for the selected database.", icon: "camera")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }

    private var canLoad: Bool { scope?.isValid == true && vm.scope == scope && vm.database == database }
    private var missing: String { L10n.text("Not returned", locale: locale) }

    private func fields(_ snapshot: RDSDatabaseSnapshot) -> [(String, String)] {
        [
            ("ARN", snapshot.arn), ("Source", snapshot.databaseIdentifier),
            ("Snapshot type", snapshot.type ?? missing), ("Status", snapshot.status ?? missing),
            ("Created", snapshot.createdAt.map(MonitoringDisplay.dateTime) ?? missing),
            ("Engine", snapshot.engine ?? missing), ("Engine version", snapshot.engineVersion ?? missing),
            ("Allocated storage", snapshot.allocatedStorageGB.map { "\($0) GiB" } ?? missing),
            ("Encrypted", snapshot.encrypted.map { L10n.text($0 ? "Yes" : "No", locale: locale) } ?? L10n.text("Unknown", locale: locale)),
            ("KMS Key", snapshot.kmsKeyID ?? missing),
            ("Progress", snapshot.progress.map { "\($0)%" } ?? missing)
        ]
    }
}
