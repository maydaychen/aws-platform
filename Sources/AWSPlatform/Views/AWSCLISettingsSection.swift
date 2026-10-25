import SwiftUI

struct AWSCLISettingsSection: View {
    @Environment(\.locale) private var locale
    @ObservedObject var updates: AWSCLIUpdateViewModel

    var body: some View {
        Section {
            if let installation = updates.installation {
                LabeledContent(L10n.text("Version", locale: locale),
                               value: installation.version.description)
                LabeledContent(L10n.text("Installation source", locale: locale),
                               value: L10n.text(installation.source.displayName, locale: locale))
            }

            if updates.isChecking || updates.isUpdating {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L10n.text(progressText, locale: locale))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("aws-cli-progress")
            } else if needsManualUpdate, updates.error == nil, !updates.status.isEmpty {
                Text(L10n.text(updates.status, locale: locale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("aws-cli-status")
            }

            if let error = updates.error {
                Text(L10n.text(error, locale: locale))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("aws-cli-error")
            }

            HStack {
                Button(L10n.text("Check", locale: locale)) {
                    updates.check()
                }
                .disabled(!updates.canCheck)
                .help(L10n.text("Check AWS CLI version", locale: locale))
                .accessibilityIdentifier("check-aws-cli-version")

                Button(L10n.text("Update", locale: locale)) {
                    updates.update()
                }
                .disabled(!updates.canUpdate)
                .help(updateHelp)
                .accessibilityIdentifier("update-aws-cli")
            }

            if needsManualUpdate, !updates.isChecking {
                Link(L10n.text("AWS CLI installation guide", locale: locale),
                     destination: URL(string: "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html")!)
                    .accessibilityIdentifier("aws-cli-installation-guide")
            }
        } header: {
            Label("AWS CLI", systemImage: "terminal")
        }
        .task { updates.checkIfNeeded() }
    }

    private var needsManualUpdate: Bool {
        guard let installation = updates.installation else { return true }
        return !installation.source.supportsAutomaticUpdate || installation.version.major != 2
    }

    private var updateHelp: String {
        let help = L10n.text(explanation, locale: locale)
        guard let version = updates.latestVersion, let installation = updates.installation,
              version > installation.version else { return help }
        return L10n.format("Update AWS CLI to %@.", version.description, locale: locale) + "\n" + help
    }

    private var progressText: String {
        guard updates.isUpdating else { return "Checking AWS CLI version…" }
        switch updates.phase {
        case .downloading: return "Downloading AWS CLI…"
        case .verifyingPackage: return "Verifying the AWS CLI installer…"
        case .installing: return "Installing AWS CLI…"
        case .verifyingInstallation: return "Verifying the installed AWS CLI…"
        case .refreshingHomebrew: return "Refreshing Homebrew package information…"
        case nil: return "Preparing the AWS CLI update…"
        }
    }

    private var explanation: String {
        guard !needsManualUpdate else {
            return "This installation cannot be updated automatically. Follow the official guide to install or update AWS CLI, then check again."
        }
        switch updates.installation?.source {
        case .officialPackage:
            return "AWS CLI updates start only when you click Update. macOS may ask for administrator authorization. Quitting and app restarts wait until the update finishes."
        case .homebrew:
            return "AWS CLI updates use this Homebrew installation and may update required dependencies. Quitting and app restarts wait until the update finishes."
        case .unmanaged, nil:
            return "This installation cannot be updated automatically. Follow the official guide to install or update AWS CLI, then check again."
        }
    }
}
