import SwiftUI

struct ProfileBarView: View {
    @ObservedObject var vm: ProfileViewModel
    let onRetry: () -> Void
    var onLogin: () -> Void = {}
    var onCancelLogin: () -> Void = {}
    @State private var isCustomRegionPresented = false
    @State private var customRegion = ""
    @State private var regionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Label("AWS Platform", systemImage: "cloud.fill")
                    .font(.headline)
                Spacer()
                profileStatusView
            }
            HStack(spacing: 12) {
                Picker("SSO Session", selection: Binding(
                    get: { vm.profileSource },
                    set: { vm.selectSource($0) }
                )) {
                    Text("Select session").tag(Optional<AWSProfileSource>.none)
                    ForEach(vm.sessions) { session in
                        Text(session.name).tag(Optional(AWSProfileSource.session(session.id)))
                    }
                    Divider()
                    Text("Other profiles").tag(Optional(AWSProfileSource.other))
                }
                .frame(minWidth: 250, idealWidth: 380, maxWidth: 440)
                if vm.isSigningIn {
                    Button("Cancel Login", action: onCancelLogin)
                } else if vm.selectedSession != nil {
                    Button("SSO Login", action: onLogin)
                        .disabled(!vm.canSignIn)
                        .help("Sign in to this session. Choose a profile afterwards to load resources.")
                }
                Spacer()
            }
            HStack(spacing: 12) {
                Picker("Profile", selection: Binding(
                    get: { vm.selectedProfileID ?? "" },
                    set: { vm.selectProfile(id: $0.isEmpty ? nil : $0) }
                )) {
                    Text("Select profile").tag("")
                    ForEach(vm.availableProfiles) { profile in
                        Text(profile.displayName).tag(profile.id)
                    }
                }
                .frame(minWidth: 180, idealWidth: 250, maxWidth: 320)
                .disabled(vm.availableProfiles.isEmpty || vm.isSigningIn)

                Picker("Region", selection: $vm.selectedRegion) {
                    ForEach(vm.availableRegions, id: \.self) { region in
                        Text(region).tag(region)
                    }
                }
                .frame(width: 210)
                .disabled(vm.selectedProfile == nil || vm.isSigningIn)
                Button {
                    customRegion = vm.selectedRegion
                    regionError = nil
                    isCustomRegionPresented = true
                } label: {
                    Image(systemName: "pencil")
                }
                .help("Enter another AWS region")
                .disabled(vm.selectedProfile == nil || vm.isSigningIn)
                .accessibilityLabel("Enter another AWS region")
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
                Spacer(minLength: 0)
                Button(vm.selectedProfile == nil ? "Reload Config" : "Retry Connection", action: onRetry)
                    .disabled(vm.isValidatingProfile || vm.isSigningIn)
                    .help("Reload profiles and revalidate credentials after signing in")
            }
            if vm.isSigningIn {
                Text("Complete SSO authorization in your browser. This may take up to 5 minutes. If no browser opens, cancel and sign in from Terminal.")
                    .font(.caption).foregroundColor(.secondary)
            } else if let message = vm.loginMessage {
                NoticeBanner(message: message)
            } else if case .failed(let message) = vm.profileStatus {
                NoticeBanner(message: message)
            } else if vm.selectedProfile == nil {
                Text(vm.selectionPrompt).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
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
        if vm.isSigningIn {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for browser authorization…").font(.caption).foregroundColor(.secondary)
            }
        } else {
            switch vm.profileStatus {
            case .idle:
                if let session = vm.selectedSession, vm.signedInSessionID == session.id {
                    Label("Session signed in · Select profile", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundColor(.green)
                }
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking connection…").font(.caption).foregroundColor(.secondary)
                }
                    .help("Checking AWS profile")
            case .valid(let identity):
                Label(identity.account, systemImage: "checkmark.circle.fill")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.green)
                    .help(identity.arn)
            case .failed(let message):
                Label(vm.requiresSSOLogin ? "Login required" : "Connection failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .help(message)
            }
        }
    }
}
