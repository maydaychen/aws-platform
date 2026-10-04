import SwiftUI

struct ProfileBarView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: ProfileViewModel
    let onRetry: () -> Void
    var onLogin: () -> Void = {}
    var onCancelLogin: () -> Void = {}
    var showsResourceRegion = true
    var globalScopeMessage = "Global service · Current account"
    @State private var isCustomRegionPresented = false
    @State private var customRegion = ""
    @State private var regionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Label(L10n.text("AWS Platform", locale: locale), systemImage: "cloud.fill")
                    .font(.headline)
                Spacer()
                profileStatusView
            }
            HStack(spacing: 12) {
                Picker(L10n.text("SSO Session", locale: locale), selection: Binding(
                    get: { vm.profileSource },
                    set: { vm.selectSource($0) }
                )) {
                    Text(L10n.text("Select session", locale: locale)).tag(Optional<AWSProfileSource>.none)
                    ForEach(vm.sessions) { session in
                        Text(session.name).tag(Optional(AWSProfileSource.session(session.id)))
                    }
                    Divider()
                    Text(L10n.text("Other profiles", locale: locale)).tag(Optional(AWSProfileSource.other))
                }
                .frame(minWidth: 250, idealWidth: 380, maxWidth: 440)
                if vm.isSigningIn {
                    Button(L10n.text("Cancel Login", locale: locale), action: onCancelLogin)
                } else if vm.selectedSession != nil {
                    Button(L10n.text("SSO Login", locale: locale), action: onLogin)
                        .disabled(!vm.canSignIn)
                        .help(L10n.text("Sign in to this session. Choose a profile afterwards to load resources.", locale: locale))
                }
                Spacer()
            }
            HStack(spacing: 12) {
                Picker(L10n.text("Profile", locale: locale), selection: Binding(
                    get: { vm.selectedProfileID ?? "" },
                    set: { vm.selectProfile(id: $0.isEmpty ? nil : $0) }
                )) {
                    Text(L10n.text("Select profile", locale: locale)).tag("")
                    ForEach(vm.availableProfiles) { profile in
                        Text(profile.displayName).tag(profile.id)
                    }
                }
                .frame(minWidth: 180, idealWidth: 250, maxWidth: 320)
                .disabled(vm.availableProfiles.isEmpty || vm.isSigningIn)

                if showsResourceRegion {
                    resourceRegionControls
                } else {
                    Label(L10n.text(globalScopeMessage, locale: locale), systemImage: "globe")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
                Button(L10n.text(vm.selectedProfile == nil ? "Reload Config" : "Retry Connection", locale: locale), action: onRetry)
                    .disabled(vm.isValidatingProfile || vm.isSigningIn)
                    .help(L10n.text("Reload profiles and revalidate credentials after signing in", locale: locale))
            }
            if vm.isSigningIn {
                Text(L10n.text("Complete SSO authorization in your browser. This may take up to 5 minutes. If no browser opens, cancel and sign in from Terminal.", locale: locale))
                    .font(.caption).foregroundColor(.secondary)
            } else if let message = vm.loginMessage {
                NoticeBanner(message: message)
            } else if case .failed(let message) = vm.profileStatus {
                NoticeBanner(message: message)
            } else if vm.selectedProfile == nil {
                Text(L10n.text(vm.selectionPrompt, locale: locale)).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var resourceRegionControls: some View {
        Picker(L10n.text("Region", locale: locale), selection: $vm.selectedRegion) {
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
        .help(L10n.text("Enter another AWS region", locale: locale))
        .disabled(vm.selectedProfile == nil || vm.isSigningIn)
        .accessibilityLabel(L10n.text("Enter another AWS region", locale: locale))
        .popover(isPresented: $isCustomRegionPresented) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("AWS Region", locale: locale)).font(.headline)
                TextField(L10n.text("Region code", locale: locale), text: $customRegion)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(applyCustomRegion)
                if let regionError {
                    Text(L10n.text(regionError, locale: locale)).font(.caption).foregroundColor(.orange)
                }
                Button(L10n.text("Use Region", locale: locale), action: applyCustomRegion)
            }
            .padding()
            .frame(width: 280)
        }
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
                Text(L10n.text("Waiting for browser authorization…", locale: locale)).font(.caption).foregroundColor(.secondary)
            }
        } else {
            switch vm.profileStatus {
            case .idle:
                if let session = vm.selectedSession, vm.signedInSessionID == session.id {
                    Label(L10n.text("Session signed in · Select profile", locale: locale), systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundColor(.green)
                }
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("Checking connection…", locale: locale)).font(.caption).foregroundColor(.secondary)
                }
                    .help(L10n.text("Checking AWS profile", locale: locale))
            case .valid(let identity):
                Label(identity.account, systemImage: "checkmark.circle.fill")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.green)
                    .help(identity.arn)
            case .failed(let message):
                Label(L10n.text(vm.requiresSSOLogin ? "Login required" : "Connection failed", locale: locale), systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .help(L10n.text(message, locale: locale))
            }
        }
    }
}
