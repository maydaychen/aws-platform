import AppKit
import SwiftUI

struct HealthEventDetailView: View {
    let event: HealthEvent
    @ObservedObject var vm: HealthViewModel
    @Environment(\.locale) private var locale

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
                        ("Service", HealthDisplay.returned(displayedEvent.service, locale: locale)),
                        ("Category", HealthDisplay.label(displayedEvent.category, locale: locale)),
                        ("Event region", HealthDisplay.returned(displayedEvent.region, locale: locale)),
                        ("Availability zone", HealthDisplay.returned(displayedEvent.availabilityZone, locale: locale)),
                        ("Start time", HealthDisplay.date(displayedEvent.startTime, locale: locale)),
                        ("End time", HealthDisplay.date(displayedEvent.endTime, locale: locale)),
                        ("Last updated", HealthDisplay.date(displayedEvent.lastUpdatedTime, locale: locale))
                    ])
                    description
                    if let details, !details.metadata.isEmpty {
                        DisclosureGroup(L10n.text("Event metadata", locale: locale)) {
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
                Text(HealthDisplay.returned(displayedEvent.typeCode, locale: locale)).font(.title2.weight(.semibold))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if isLoading {
                    Button(action: vm.cancelDetails) { Image(systemName: "xmark.circle") }
                        .help(L10n.text("Cancel loading event details and affected entities", locale: locale))
                        .accessibilityLabel(L10n.text("Cancel loading Health event details", locale: locale))
                }
                Button(action: vm.refreshDetails) { Image(systemName: "arrow.clockwise") }
                    .disabled(!isCurrentSelection || isLoading)
                    .help(L10n.text("Refresh event details and affected entities", locale: locale))
                    .accessibilityLabel(L10n.text("Refresh Health event details", locale: locale))
            }
            HStack(spacing: 10) {
                HealthStatusLabel(status: displayedEvent.status)
                Text(L10n.text("All times in UTC", locale: locale)).foregroundColor(.secondary)
            }
            .font(.caption)
            HStack(alignment: .top, spacing: 6) {
                Text(event.arn).font(.caption.monospaced()).foregroundColor(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(event.arn, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help(L10n.text("Copy event ARN", locale: locale)).accessibilityLabel(L10n.text("Copy event ARN", locale: locale))
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var description: some View {
        DetailSectionTitle(title: "Description")
        if isCurrentSelection && vm.isDetailLoading {
            ProgressView(L10n.text("Loading event description…", locale: locale)).controlSize(.small)
        } else if isCurrentSelection, let error = vm.detailError {
            NoticeBanner(message: error)
            retryButton
        } else {
            Text(HealthDisplay.returned(details?.description, locale: locale))
                .font(.callout).foregroundColor(details?.description == nil ? .secondary : .primary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var affectedEntities: some View {
        DetailSectionTitle(title: "Affected entities")
        if isCurrentSelection && vm.isEntitiesLoading {
            ProgressView(L10n.text("Loading affected entities…", locale: locale)).controlSize(.small)
        } else if isCurrentSelection, let error = vm.entitiesError {
            NoticeBanner(message: error)
            retryButton
        } else if isCurrentSelection && !vm.entities.isEmpty {
            Text(L10n.format(vm.entities.count == 1 ? "%@ entity" : "%@ entities", String(vm.entities.count), locale: locale))
                .font(.caption).foregroundColor(.secondary)
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(vm.entities) { entity in entityRow(entity) }
            }
        } else {
            Text(L10n.text("No affected entities were returned.", locale: locale)).font(.callout).foregroundColor(.secondary)
        }
    }

    private var retryButton: some View {
        Button(L10n.text("Retry details", locale: locale), action: vm.refreshDetails)
            .disabled(!isCurrentSelection || isLoading)
            .help(L10n.text("Retry the event description and affected entities", locale: locale))
    }

    private func entityRow(_ entity: HealthAffectedEntity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(HealthDisplay.returned(entity.value, locale: locale)).font(.callout.weight(.medium))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HealthStatusLabel(status: entity.status).font(.caption)
            Text(L10n.format("Account: %@", HealthDisplay.returned(entity.accountID, locale: locale), locale: locale))
                .font(.caption).foregroundColor(.secondary).textSelection(.enabled)
            Text(L10n.format("Updated %@", HealthDisplay.date(entity.lastUpdatedTime, locale: locale), locale: locale))
                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}
