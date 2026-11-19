import AppKit
import Foundation

struct EC2SSMConnectionRequest: Equatable {
    let scope: MonitoringScope
    let instanceID: String
    let principalID: String

    init(scope: MonitoringScope?, instance: EC2InstanceModel) throws {
        guard let scope, scope.isValid,
              let principalID = scope.principalID, Self.safeValue(principalID),
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
        self.principalID = principalID
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
    case credentialsUnavailable = "Unable to obtain valid credentials for the selected Profile. Sign in again or update AWS CLI v2."
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
    var gate: AWSCLIOperationGate = .shared

    func connect(_ request: EC2SSMConnectionRequest, locale: Locale) throws {
        let root = temporaryDirectory
        Task { await SSMScriptLease.cleanupOrphans(in: root) }
        let lease = try gate.beginOperation()
        defer { gate.endOperation(lease) }
        guard let cli = cli() else { throw EC2SSMConnectionError.cliMissing }
        guard let plugin = plugin() else { throw EC2SSMConnectionError.pluginMissing }
        var scriptLease: SSMScriptLease?
        do {
            let pending = try SSMScriptLease(root: temporaryDirectory)
            scriptLease = pending
            let script = Self.script(request, cli: cli, plugin: plugin, home: homeDirectory,
                                     directory: pending.directory, directoryIdentity: pending.directoryIdentity, locale: locale)
            try pending.writeScript(script)
            try pending.releaseForHandoff()
            guard open(pending.scriptURL) else { throw EC2SSMConnectionError.openFailed }
        } catch let failure as EC2SSMConnectionError {
            scriptLease?.discard()
            throw failure
        } catch {
            scriptLease?.discard()
            throw EC2SSMConnectionError.prepareFailed
        }
    }

    static func script(_ request: EC2SSMConnectionRequest, cli: URL, plugin: URL, home: URL,
                       directory: URL, directoryIdentity: String, locale: Locale) -> String {
        let scope = request.scope
        let path = [plugin.deletingLastPathComponent().path, cli.deletingLastPathComponent().path,
                    "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        let identityError = L10n.text("CLI identity does not match the verified Profile. Reverify the Profile in AWSPlatform before connecting.", locale: locale)
        let credentialsError = L10n.text(EC2SSMConnectionError.credentialsUnavailable.rawValue, locale: locale)
        let dependencyError = L10n.text("SSM requires AWS CLI 2.37.9 or newer and Session Manager plugin newer than 1.2.497.0. Update both tools before connecting.", locale: locale)
        let cleanupWarning = L10n.text("SSM temporary files could not be fully removed. The connection will continue. Remaining directory:", locale: locale)
        // Single-quote every dynamic value. Neither shell interpolation nor terminal
        // environment credentials may replace the explicitly selected Profile.
        return """
        #!/bin/bash
        set +x
        set -euo pipefail
        unset connect_json connect_access connect_secret connect_token
        for connect_name in "${!AWS_@}"; do unset "$connect_name"; done
        connect_directory=\(quote(directory.path))
        connect_directory_identity=\(quote(directoryIdentity))
        connect_marker=\(quote(SSMScriptLease.markerName))
        connect_check_directory() (
            cd -P -- "$connect_directory" || exit 1
            [[ "$(/usr/bin/stat -f '%d:%i' .)" == "$connect_directory_identity" ]]
        )
        if [[ "${1:-}" != --awsplatform-ssm-locked ]]; then
            connect_check_directory || exit 1
            exec /usr/bin/lockf -k -n -t 0 "$connect_directory/$connect_marker" \\
                /bin/bash --noprofile --norc "$0" --awsplatform-ssm-locked
        fi
        shift
        connect_cleanup() (
            [[ -d "$connect_directory" ]] || exit 0
            cd -P -- "$connect_directory" || exit 1
            [[ "$(/usr/bin/stat -f '%d:%i' .)" == "$connect_directory_identity" ]] || exit 1
            if ! /bin/rm -f -- \(quote(SSMScriptLease.scriptName)) || ! /bin/rm -f -- "$connect_marker"; then
                printf '%s\\n' \(quote(cleanupWarning)) "$connect_directory" >&2
                exit 0
            fi
            [[ ! -L "$connect_directory" && "$(/usr/bin/stat -f '%d:%i' "$connect_directory" 2>/dev/null)" == "$connect_directory_identity" ]] || exit 0
            if ! /bin/rmdir -- "$connect_directory" 2>/dev/null && [[ -d "$connect_directory" ]]; then
                printf '%s\\n' \(quote(cleanupWarning)) "$connect_directory" >&2
            fi
            exit 0
        )
        trap 'connect_exit=$?; connect_cleanup || :; exit "$connect_exit"' EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        cd /
        connect_cleanup
        dependencies_failed() {
            printf '%s\\n' \(quote(dependencyError)) >&2
            exit 1
        }
        # Older CLI/plugin combinations can expose the SSM session response in argv.
        # Check both selected executables before exporting any Profile credentials.
        connect_cli_version=$(/usr/bin/env -i HOME=\(quote(home.path)) PATH=\(quote(path)) \(quote(cli.path)) --version 2>/dev/null) || dependencies_failed
        [[ "$connect_cli_version" =~ ^aws-cli/([0-9]{1,4})\\.([0-9]{1,4})\\.([0-9]{1,4})([[:space:]].*)?$ ]] || dependencies_failed
        connect_major=$((10#${BASH_REMATCH[1]}))
        connect_minor=$((10#${BASH_REMATCH[2]}))
        connect_patch=$((10#${BASH_REMATCH[3]}))
        (( connect_major == 2 && (connect_minor > 37 || (connect_minor == 37 && connect_patch >= 9)) )) || dependencies_failed
        connect_plugin_version=$(/usr/bin/env -i HOME=\(quote(home.path)) PATH=\(quote(path)) \(quote(plugin.path)) --version 2>/dev/null) || dependencies_failed
        [[ "$connect_plugin_version" =~ ^([0-9]{1,4})\\.([0-9]{1,4})\\.([0-9]{1,4})\\.([0-9]{1,4})$ ]] || dependencies_failed
        connect_major=$((10#${BASH_REMATCH[1]}))
        connect_minor=$((10#${BASH_REMATCH[2]}))
        connect_patch=$((10#${BASH_REMATCH[3]}))
        connect_build=$((10#${BASH_REMATCH[4]}))
        (( connect_major == 1 && (connect_minor > 2 || (connect_minor == 2 && (connect_patch > 497 || (connect_patch == 497 && connect_build > 0)))) )) || dependencies_failed
        unset connect_cli_version connect_plugin_version connect_major connect_minor connect_patch connect_build
        credentials_failed() {
            printf '%s\\n' \(quote(credentialsError)) >&2
            exit 1
        }
        connect_json=$(
            /usr/bin/env -i HOME=\(quote(home.path)) PATH=\(quote(path)) TERM="${TERM:-xterm-256color}" \\
                AWS_CONFIG_FILE=\(quote(scope.configPath)) AWS_SHARED_CREDENTIALS_FILE=\(quote(scope.credentialsPath)) \\
                AWS_CLI_AUTO_PROMPT=off AWS_PAGER='' AWS_CLI_HISTORY_FILE=/dev/null \\
                AWS_IGNORE_CONFIGURED_ENDPOINT_URLS=true AWS_EC2_METADATA_DISABLED=true \\
                \(quote(cli.path)) configure export-credentials --format process \\
                --profile \(quote(scope.profile.name)) --region \(quote(scope.region)) \\
                --no-cli-pager --no-cli-auto-prompt 2>/dev/null
        ) || credentials_failed
        credential_field() {
            printf '%s' "$connect_json" | /usr/bin/plutil -extract "$1" raw -expect "$2" -n -o - - 2>/dev/null || return
            printf '.'
        }
        [[ "$(credential_field Version integer)" == 1. ]] || credentials_failed
        connect_access=$(credential_field AccessKeyId string) || credentials_failed
        connect_access=${connect_access%.}
        connect_secret=$(credential_field SecretAccessKey string) || credentials_failed
        connect_secret=${connect_secret%.}
        connect_token_type=$(printf '%s' "$connect_json" | /usr/bin/plutil -type SessionToken - 2>/dev/null) || connect_token_type=''
        case "$connect_token_type" in
            string) connect_token=$(credential_field SessionToken string) || credentials_failed
                    connect_token=${connect_token%.}
                    [[ -n "$connect_token" ]] || credentials_failed ;;
            '') connect_token='' ;;
            *) credentials_failed ;;
        esac
        for connect_value in "$connect_access" "$connect_secret"; do
            [[ -n "$connect_value" && "$connect_value" != *[[:space:][:cntrl:]]* ]] || credentials_failed
        done
        [[ "$connect_token" != *[[:space:][:cntrl:]]* ]] || credentials_failed
        unset connect_json connect_value
        connect_aws() (
            export HOME=\(quote(home.path)) PATH=\(quote(path))
            export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null BOTO_CONFIG=/dev/null
            export AWS_CLI_AUTO_PROMPT=off AWS_PAGER='' AWS_CLI_HISTORY_FILE=/dev/null
            export AWS_IGNORE_CONFIGURED_ENDPOINT_URLS=true AWS_EC2_METADATA_DISABLED=true
            export AWS_ACCESS_KEY_ID="$connect_access" AWS_SECRET_ACCESS_KEY="$connect_secret"
            if [[ -n "$connect_token" ]]; then export AWS_SESSION_TOKEN="$connect_token"; fi
            \(quote(cli.path)) "$@" --region \(quote(scope.region)) --no-cli-pager --no-cli-auto-prompt
        )
        printf '%s\\n' \(quote("SSM · \(scope.profile.name) · \(scope.accountID) · \(scope.region) · \(request.instanceID)"))
        connect_identity=$(connect_aws sts get-caller-identity --query '[Account,Arn,UserId]' --output text --cli-connect-timeout 10 --cli-read-timeout 20)
        IFS=$'\\t' read -r connect_account connect_arn connect_user_id connect_extra <<< "$connect_identity"
        identity_failed() {
            printf '%s\\n' \(quote(identityError)) >&2
            exit 1
        }
        [[ "$connect_identity" != *$'\\n'* && "$connect_identity" == "$connect_account"$'\\t'"$connect_arn"$'\\t'"$connect_user_id" ]] || identity_failed
        case "$connect_arn" in
            arn:*:sts::*:assumed-role/*/*)
                connect_arn="${connect_arn%/*}"
                connect_user_id="${connect_user_id%%:*}" ;;
        esac
        [[ "$connect_account" == \(quote(scope.accountID)) && "$connect_arn" == \(quote(AWSStablePrincipal.normalizedARN(scope.principalARN))) &&
            "$connect_user_id" == \(quote(request.principalID)) ]] || identity_failed
        connect_aws ssm start-session --target \(quote(request.instanceID))

        """
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
