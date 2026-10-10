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

    private var profiles: [AWSProfile] { vm.filteredProfiles(matching: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceLayout.controlSpacing) {
            Text(L10n.text("Select profile", locale: locale)).font(.headline)
            TextField(L10n.text("Search profiles, account IDs or roles", locale: locale), text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityIdentifier("profile.search")
                .onSubmit {
                    if profiles.count == 1 { onSelect(profiles[0].id) }
                }
            List {
                Button { onSelect(nil) } label: {
                    Label(L10n.text("Clear profile selection", locale: locale), systemImage: "minus.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                ForEach(profiles) { profile in
                    Button { onSelect(profile.id) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name).fontWeight(.medium)
                                    .lineLimit(1).truncationMode(.middle)
                                if !vm.profileSubtitle(profile).isEmpty {
                                    Text(vm.profileSubtitle(profile)).font(.caption).foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                            if vm.selectedProfileID == profile.id { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                        }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(vm.profileSubtitle(profile))
                }
            }
            .listStyle(.inset)
            .frame(height: WorkspaceLayout.profileListHeight)
            if profiles.isEmpty {
                Text(L10n.text("No matching profiles", locale: locale)).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(width: WorkspaceLayout.profilePopoverWidth)
        .onAppear { searchFocused = true }
    }
}
