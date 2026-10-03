import AppKit
import SwiftUI

struct HealthEventDetailView: View {
    let event: HealthEvent
    @ObservedObject var vm: HealthViewModel

    private var isCurrentSelection: Bool { vm.scope != nil && vm.selectedEvent?.arn == event.arn }
    private var details: HealthEventDetails? {
        guard isCurrentSelection, vm.details?.event.arn == event.arn else { return nil }
        return vm.details
    }
    private var displayedEvent: HealthEvent { details?.event ?? event }
    private var isLoading: Bool { isCurrentSelection && (vm.isDetailLoading || vm.isEntitiesLoading) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DetailSectionTitle(title: "Overview")
                    DetailGrid(items: [
                        ("Service", HealthDisplay.returned(displayedEvent.service)),
                        ("Category", HealthDisplay.label(displayedEvent.category)),
                        ("Event region", HealthDisplay.returned(displayedEvent.region)),
                        ("Availability zone", HealthDisplay.returned(displayedEvent.availabilityZone)),
                        ("Start time", HealthDisplay.date(displayedEvent.startTime)),
                        ("End time", HealthDisplay.date(displayedEvent.endTime)),
                        ("Last updated", HealthDisplay.date(displayedEvent.lastUpdatedTime))
                    ])
                    description
                    if let details, !details.metadata.isEmpty {
                        DisclosureGroup("Event metadata") {
                            DetailKeyValueRows(values: details.metadata).padding(.top, 8)
                        }
                        .font(.callout)
                    }
                    affectedEntities
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text(HealthDisplay.returned(displayedEvent.typeCode)).font(.title2.weight(.semibold))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if isLoading {
                    Button(action: vm.cancelDetails) { Image(systemName: "xmark.circle") }
                        .help("Cancel loading event details and affected entities")
                        .accessibilityLabel("Cancel loading Health event details")
                }
                Button(action: vm.refreshDetails) { Image(systemName: "arrow.clockwise") }
                    .disabled(!isCurrentSelection || isLoading)
                    .help("Refresh event details and affected entities")
                    .accessibilityLabel("Refresh Health event details")
            }
            HStack(spacing: 10) {
                HealthStatusLabel(status: displayedEvent.status)
                Text("All times in UTC").foregroundColor(.secondary)
            }
            .font(.caption)
            HStack(alignment: .top, spacing: 6) {
                Text(event.arn).font(.caption.monospaced()).foregroundColor(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(event.arn, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy event ARN").accessibilityLabel("Copy event ARN")
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var description: some View {
        DetailSectionTitle(title: "Description")
        if isCurrentSelection && vm.isDetailLoading {
            ProgressView("Loading event description…").controlSize(.small)
        } else if isCurrentSelection, let error = vm.detailError {
            NoticeBanner(message: error)
            retryButton
        } else {
            Text(HealthDisplay.returned(details?.description))
                .font(.callout).foregroundColor(details?.description == nil ? .secondary : .primary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var affectedEntities: some View {
        DetailSectionTitle(title: "Affected entities")
        if isCurrentSelection && vm.isEntitiesLoading {
            ProgressView("Loading affected entities…").controlSize(.small)
        } else if isCurrentSelection, let error = vm.entitiesError {
            NoticeBanner(message: error)
            retryButton
        } else if isCurrentSelection && !vm.entities.isEmpty {
            Text("\(vm.entities.count) \(vm.entities.count == 1 ? "entity" : "entities")")
                .font(.caption).foregroundColor(.secondary)
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(vm.entities) { entity in entityRow(entity) }
            }
        } else {
            Text("No affected entities were returned.").font(.callout).foregroundColor(.secondary)
        }
    }

    private var retryButton: some View {
        Button("Retry details", action: vm.refreshDetails)
            .disabled(!isCurrentSelection || isLoading)
            .help("Retry the event description and affected entities")
    }

    private func entityRow(_ entity: HealthAffectedEntity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(HealthDisplay.returned(entity.value)).font(.callout.weight(.medium))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HealthStatusLabel(status: entity.status).font(.caption)
            Text("Account: \(HealthDisplay.returned(entity.accountID))")
                .font(.caption).foregroundColor(.secondary).textSelection(.enabled)
            Text("Updated \(HealthDisplay.date(entity.lastUpdatedTime))")
                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}
