import SwiftUI

struct ProfileBarView: View {
    @ObservedObject var vm: ProfileViewModel

    var body: some View {
        HStack(spacing: 12) {
            Label("AWS Platform", systemImage: "cloud.fill")
                .font(.headline)
            Spacer()
            Text("Profile")
                .foregroundColor(.secondary)
            Picker("Profile", selection: Binding(
                get: { vm.selectedProfileID ?? "" },
                set: { vm.selectProfile(id: $0) }
            )) {
                if vm.profiles.isEmpty {
                    Text("No profiles").tag("")
                } else {
                    ForEach(vm.profiles) { profile in
                        Text(profile.displayName).tag(profile.id)
                    }
                }
            }
            .frame(width: 220)
            .disabled(vm.profiles.isEmpty)

            Text("Region")
                .foregroundColor(.secondary)
            Picker("Region", selection: $vm.selectedRegion) {
                ForEach(vm.availableRegions, id: \.self) { region in
                    Text(region).tag(region)
                }
            }
            .frame(width: 160)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}
