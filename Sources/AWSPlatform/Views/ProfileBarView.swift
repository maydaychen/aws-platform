import SwiftUI

struct ProfileBarView: View {
    @ObservedObject var vm: ProfileViewModel
    let onRetry: () -> Void
    @State private var isCustomRegionPresented = false
    @State private var customRegion = ""
    @State private var regionError: String?

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
                Button {
                    customRegion = vm.selectedRegion
                    regionError = nil
                    isCustomRegionPresented = true
                } label: {
                    Image(systemName: "pencil")
                }
                .help("Enter another AWS region")
                .popover(isPresented: $isCustomRegionPresented) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("AWS Region").font(.headline)
                        TextField("Region code", text: $customRegion)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(applyCustomRegion)
                        if let regionError {
                            Text(regionError).font(.caption).foregroundColor(.orange)
                        }
                        Button("Use Region", action: applyCustomRegion)
                    }
                    .padding()
                    .frame(width: 280)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                Button("Retry Connection", action: onRetry)
                    .disabled(vm.isValidatingProfile)
                    .help("Reload profiles and revalidate credentials after signing in")
                if case .failed(let message) = vm.profileStatus {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func applyCustomRegion() {
        if vm.selectCustomRegion(customRegion) {
            isCustomRegionPresented = false
        } else {
            regionError = "Enter a region code such as eu-central-2."
        }
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
