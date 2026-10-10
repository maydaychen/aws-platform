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
        VStack(alignment: .leading, spacing: WorkspaceLayout.controlSpacing) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: WorkspaceLayout.contextSpacing) {
                    sessionAndProfileControls
                    regionControls
                    connectionControls
                }
                VStack(alignment: .leading, spacing: WorkspaceLayout.controlSpacing) {
                    HStack(spacing: WorkspaceLayout.contextSpacing) {
                        sessionAndProfileControls
                        connectionControls
                    }
                    regionControls
                }
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
        .padding(.vertical, WorkspaceLayout.controlSpacing)
        .background(.bar)
    }

    private var sessionAndProfileControls: some View {
        HStack(spacing: WorkspaceLayout.controlSpacing) {
            Text(L10n.text("Session", locale: locale)).font(.caption).foregroundColor(.secondary)
            Picker(L10n.text("SSO Session", locale: locale), selection: Binding(
                get: { vm.profileSource }, set: { vm.selectSource($0) }
            )) {
                Text(L10n.text("Select session", locale: locale)).tag(Optional<AWSProfileSource>.none)
                ForEach(vm.sessions) { session in
                    Text(session.name).tag(Optional(AWSProfileSource.session(session.id)))
                }
                Divider()
                Text(L10n.text("Other profiles", locale: locale)).tag(Optional(AWSProfileSource.other))
            }
            .labelsHidden()
            .frame(minWidth: WorkspaceLayout.sessionMinimum, maxWidth: WorkspaceLayout.sessionMaximum)
            if vm.isSigningIn {
                Button(L10n.text("Cancel Login", locale: locale), action: onCancelLogin)
            } else if vm.selectedSession != nil {
                Button(L10n.text("SSO Login", locale: locale), action: onLogin)
                    .disabled(!vm.canSignIn)
                    .help(L10n.text("Sign in to this session. Choose a profile afterwards to load resources.", locale: locale))
            }
            Text(L10n.text("Profile", locale: locale)).font(.caption).foregroundColor(.secondary)
            ProfilePickerView(vm: vm)
                .frame(minWidth: WorkspaceLayout.profileMinimum, maxWidth: WorkspaceLayout.profileMaximum)
        }
    }

    @ViewBuilder
    private var regionControls: some View {
        if showsResourceRegion {
            resourceRegionControls
        } else {
            Label(L10n.text(globalScopeMessage, locale: locale), systemImage: "globe")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var connectionControls: some View {
        HStack(spacing: WorkspaceLayout.controlSpacing) {
            profileStatusView.labelStyle(.iconOnly)
            Button(action: onRetry) { Image(systemName: "arrow.clockwise") }
                .disabled(vm.isValidatingProfile || vm.isSigningIn)
                .accessibilityLabel(L10n.text(vm.selectedProfile == nil ? "Reload Config" : "Retry Connection", locale: locale))
                .help(L10n.text("Reload profiles and revalidate credentials after signing in", locale: locale))
        }
    }

    @ViewBuilder
    private var resourceRegionControls: some View {
        HStack(spacing: WorkspaceLayout.controlSpacing) {
            Text(L10n.text("Region", locale: locale)).font(.caption).foregroundColor(.secondary)
            Picker(L10n.text("Region", locale: locale), selection: $vm.selectedRegion) {
                ForEach(vm.availableRegions, id: \.self) { region in
                    Text(AWSRegionCatalog.displayName(for: region, locale: locale)).tag(region)
                }
            }
            .labelsHidden()
            .frame(width: WorkspaceLayout.regionWidth)
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
            ProgressView().controlSize(.small)
                .accessibilityLabel(L10n.text("Waiting for browser authorization…", locale: locale))
        } else {
            switch vm.profileStatus {
            case .idle:
                if let session = vm.selectedSession, vm.signedInSessionID == session.id {
                    Label(L10n.text("Session signed in · Select profile", locale: locale), systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundColor(.green)
                }
            case .checking:
                ProgressView().controlSize(.small)
                    .accessibilityLabel(L10n.text("Checking connection…", locale: locale))
                    .help(L10n.text("Checking AWS profile", locale: locale))
            case .valid(let identity):
                Label(vm.selectedProfile.flatMap { vm.accountName(for: $0) } ?? identity.account, systemImage: "checkmark.circle.fill")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.green)
                    .help([vm.selectedProfile.flatMap { vm.accountName(for: $0) }, identity.account, identity.arn].compactMap { $0 }.joined(separator: "\n"))
            case .failed(let message):
                Label(L10n.text(vm.requiresSSOLogin ? "Login required" : "Connection failed", locale: locale), systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .help(L10n.text(message, locale: locale))
            }
        }
    }
}
