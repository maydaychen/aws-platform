import SwiftUI

struct ProfilePickerView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: ProfileViewModel
    @State private var isPresented = false
    @State private var query = ""

    var body: some View {
        Button { query = ""; isPresented = true } label: {
            HStack {
                Text(vm.selectedProfile?.name ?? L10n.text("Select profile", locale: locale))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .disabled(vm.availableProfiles.isEmpty || vm.isSigningIn)
        .accessibilityLabel(L10n.text("Profile", locale: locale))
        .help(vm.selectedProfile.map(vm.profileSubtitle) ?? L10n.text("Select profile", locale: locale))
        .popover(isPresented: $isPresented) {
            ProfileSearchPopover(vm: vm, query: $query) { id in
                vm.selectProfile(id: id)
                isPresented = false
            }
            .onExitCommand { isPresented = false }
        }
    }
}

struct ProfileSearchPopover: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: ProfileViewModel
    @Binding var query: String
    let onSelect: (AWSProfile.ID?) -> Void
    @FocusState private var searchFocused: Bool
    @State private var hoveredID: AWSProfile.ID?
    @State private var highlightedID: AWSProfile.ID?

    private var profiles: [AWSProfile] { vm.filteredProfiles(matching: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceLayout.controlSpacing) {
            Text(L10n.text("Select profile", locale: locale)).font(.headline)
            TextField(L10n.text("Search profiles, account IDs or roles", locale: locale), text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityIdentifier("profile.search")
                .onSubmit {
                    if let highlightedID, profiles.contains(where: { $0.id == highlightedID }) {
                        onSelect(highlightedID)
                    } else if profiles.count == 1 {
                        onSelect(profiles[0].id)
                    }
                }
            List {
                Button { onSelect(nil) } label: {
                    Label(L10n.text("Clear profile selection", locale: locale), systemImage: "minus.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                ForEach(profiles) { profile in
                    let subtitle = vm.profileSubtitle(profile)
                    let isHighlighted = highlightedID == profile.id || hoveredID == profile.id
                    Button { onSelect(profile.id) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name).fontWeight(.medium)
                                    .lineLimit(1).truncationMode(.middle)
                                if !subtitle.isEmpty {
                                    Text(subtitle).font(.caption).foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                            if vm.selectedProfileID == profile.id { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isHighlighted ? Color.accentColor.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(subtitle)
                    .onHover { hovering in
                        hoveredID = hovering ? profile.id : (hoveredID == profile.id ? nil : hoveredID)
                    }
                }
            }
            .listStyle(.inset)
            .frame(height: WorkspaceLayout.profileListHeight)
            .onMoveCommand(perform: moveSelection)
            if profiles.isEmpty {
                Text(L10n.text("No matching profiles", locale: locale)).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(width: WorkspaceLayout.profilePopoverWidth)
        .onMoveCommand(perform: moveSelection)
        .onAppear { searchFocused = true }
        .onChange(of: query) { _ in
            if profiles.isEmpty {
                highlightedID = nil
            } else if let current = highlightedID, !profiles.contains(where: { $0.id == current }) {
                highlightedID = profiles.first?.id
            }
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !profiles.isEmpty else { return }
        let currentIndex = highlightedID.flatMap { id in profiles.firstIndex { $0.id == id } }
            ?? vm.selectedProfileID.flatMap { id in profiles.firstIndex { $0.id == id } }
        let nextIndex: Int
        switch direction {
        case .down:
            nextIndex = currentIndex.map { min($0 + 1, profiles.count - 1) } ?? 0
        case .up:
            nextIndex = currentIndex.map { max($0 - 1, 0) } ?? (profiles.count - 1)
        default:
            return
        }
        highlightedID = profiles[nextIndex].id
    }
}
