import AppKit
import Foundation

struct EC2SSMConnectionRequest: Equatable {
    let scope: MonitoringScope
    let instanceID: String

    init(scope: MonitoringScope?, instance: EC2InstanceModel) throws {
        guard let scope, scope.isValid,
              Self.safeValue(scope.profile.name),
              [scope.configPath, scope.credentialsPath].allSatisfy({
                  $0.hasPrefix("/") && Self.safeValue($0)
              }),
              instance.instanceId.range(of: "^i-(?:[0-9a-f]{8}|[0-9a-f]{17})$", options: .regularExpression) != nil,
              Self.safeValue(instance.instanceId) else { throw EC2SSMConnectionError.invalidScope }
        guard instance.state == "running" else { throw EC2SSMConnectionError.notRunning }
        if let zone = instance.availabilityZone {
            let ordinaryZone = "^" + NSRegularExpression.escapedPattern(for: scope.region) + "[a-z]$"
            guard zone.range(of: ordinaryZone, options: .regularExpression) != nil || zone.hasPrefix(scope.region + "-") else {
                throw EC2SSMConnectionError.invalidScope
            }
        }
        self.scope = scope
        instanceID = instance.instanceId
    }

    private static func safeValue(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

enum EC2SSMConnectionError: String, LocalizedError, CaseIterable {
    case invalidScope = "Select and verify the current Profile and instance before connecting."
    case notRunning = "SSM connections require a running instance."
    case cliMissing = "Install AWS CLI v2 in /opt/homebrew/bin or /usr/local/bin to connect with SSM."
    case pluginMissing = "Install the Session Manager plugin to connect with SSM."
    case prepareFailed = "Unable to prepare the SSM connection script."
    case openFailed = "Unable to open the connection script. Check the default app for .command files."

    var errorDescription: String? { rawValue }
}

/// A small handoff to the system's .command association. No AWS calls or credentials here.
@MainActor
struct EC2SSMConnectionService {
    var cli: () -> URL? = { AWSCLIConfiguration.executable() }
    var plugin: () -> URL? = {
        AWSCLIConfiguration.executable(candidates: [
            "/opt/homebrew/bin/session-manager-plugin", "/usr/local/bin/session-manager-plugin",
            "/usr/local/sessionmanagerplugin/bin/session-manager-plugin"
        ])
    }
    var open: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var temporaryDirectory: URL = FileManager.default.temporaryDirectory
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser

    func connect(_ request: EC2SSMConnectionRequest, locale: Locale) throws {
        guard let cli = cli() else { throw EC2SSMConnectionError.cliMissing }
        guard let plugin = plugin() else { throw EC2SSMConnectionError.pluginMissing }
        let directory = temporaryDirectory.appendingPathComponent("AWSPlatform-SSM-\(UUID().uuidString)", isDirectory: true)
        let scriptURL = directory.appendingPathComponent("Connect.command")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let script = Self.script(request, cli: cli, plugin: plugin, home: homeDirectory, locale: locale)
            try Data(script.utf8).write(to: scriptURL, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw EC2SSMConnectionError.prepareFailed
        }
        guard open(scriptURL) else {
            try? FileManager.default.removeItem(at: directory)
            throw EC2SSMConnectionError.openFailed
        }
    }

    static func script(_ request: EC2SSMConnectionRequest, cli: URL, plugin: URL, home: URL, locale: Locale) -> String {
        let scope = request.scope
        let path = [plugin.deletingLastPathComponent().path, cli.deletingLastPathComponent().path,
                    "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        let identityError = L10n.text("CLI identity does not match the verified Profile. Reverify the Profile in AWSPlatform before connecting.", locale: locale)
        // Single-quote every dynamic value. Neither shell interpolation nor terminal
        // environment credentials may replace the explicitly selected Profile.
        return """
        #!/bin/bash
        set -euo pipefail
        trap '/bin/rm -f -- "$0"; /bin/rmdir -- "${0%/*}"' EXIT
        connect_aws() {
            /usr/bin/env -i HOME=\(quote(home.path)) PATH=\(quote(path)) TERM="${TERM:-xterm-256color}" \\
                AWS_CONFIG_FILE=\(quote(scope.configPath)) AWS_SHARED_CREDENTIALS_FILE=\(quote(scope.credentialsPath)) \\
                AWS_CLI_AUTO_PROMPT=off AWS_PAGER='' AWS_CLI_HISTORY_FILE=/dev/null \\
                AWS_IGNORE_CONFIGURED_ENDPOINT_URLS=true AWS_EC2_METADATA_DISABLED=true \\
                \(quote(cli.path)) "$@" --profile \(quote(scope.profile.name)) --region \(quote(scope.region)) \\
                --no-cli-pager --no-cli-auto-prompt
        }
        printf '%s\\n' \(quote("SSM · \(scope.profile.name) · \(scope.accountID) · \(scope.region) · \(request.instanceID)"))
        connect_identity=$(connect_aws sts get-caller-identity --query '[Account,Arn]' --output text --cli-connect-timeout 10 --cli-read-timeout 20)
        IFS=$'\\t' read -r connect_account connect_arn connect_extra <<< "$connect_identity"
        case "$connect_arn" in
            arn:*:sts::*:assumed-role/*/*) connect_arn="${connect_arn%/*}" ;;
        esac
        if [[ "$connect_account" != \(quote(scope.accountID)) || "$connect_arn" != \(quote(AWSStablePrincipal.normalizedARN(scope.principalARN))) || -n "$connect_extra" || "$connect_identity" == *$'\\n'* ]]; then
            printf '%s\\n' \(quote(identityError)) >&2
            exit 1
        fi
        connect_aws ssm start-session --target \(quote(request.instanceID))

        """
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
