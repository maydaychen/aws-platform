import SwiftUI

struct ProfileBarView: View {
    @ObservedObject var vm: ProfileViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Label("AWS Platform", systemImage: "cloud.fill")
                    .font(.headline)
                profileStatusView
                Spacer()
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

                Picker("Region", selection: $vm.selectedRegion) {
                    ForEach(vm.availableRegions, id: \.self) { region in
                        Text(region).tag(region)
                    }
                }
                .frame(width: 160)
            }
            if case .failed(let message) = vm.profileStatus {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var profileStatusView: some View {
        switch vm.profileStatus {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView()
                .controlSize(.small)
                .help("Checking AWS profile")
        case .valid(let identity):
            Label(identity.account, systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
                .help(identity.arn)
        case .failed(let message):
            Label("Login required", systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .help(message)
        }
    }
}
