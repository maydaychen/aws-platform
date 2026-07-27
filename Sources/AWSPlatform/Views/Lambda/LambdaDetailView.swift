import AppKit
import SwiftUI

struct LambdaDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case configuration = "Configuration"
        case triggers = "Triggers"
        case versions = "Versions"
        case code = "Code"

        var id: String { rawValue }
    }

    let function: LambdaFunctionModel
    @ObservedObject var vm: LambdaViewModel
    @State private var selectedTab: Tab = .overview
    @State private var revealedEnvironmentKeys: Set<String> = []

    private var detail: LambdaFunctionDetailModel? {
        guard vm.functionDetail?.functionName == function.functionName else { return nil }
        return vm.functionDetail
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("Section", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding()

            if let detail, !detail.warnings.isEmpty {
                warningBanner(detail.warnings)
            }

            ZStack {
                tabContent
                if vm.isDetailLoading && detail == nil {
                    ProgressView("Loading Lambda details…")
                        .padding()
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .onChange(of: function.functionName) { _ in
            selectedTab = .overview
            revealedEnvironmentKeys = []
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(function.functionName)
                        .font(.title2)
                        .fontWeight(.semibold)
                    if let arn = function.arn {
                        HStack(spacing: 6) {
                            Text(arn)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            copyButton(arn, label: "Copy function ARN")
                        }
                    }
                }
                Spacer()
                statusBadge
            }

            if let detailError = vm.detailError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(detailError)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Retry") {
                        vm.loadDetailForSelection()
                    }
                }
            }
        }
        .padding()
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(detail?.state ?? function.state ?? "Unknown")
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .overview:
            overviewTab
        case .configuration:
            configurationTab
        case .triggers:
            triggersTab
        case .versions:
            versionsTab
        case .code:
            codeTab
        }
    }

    private var overviewTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let description = nonEmpty(detail?.description) {
                    Text(description)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }

                DetailGrid(items: [
                    ("State", detail?.state ?? function.state ?? "-"),
                    ("State Reason", detail?.stateReason ?? "-"),
                    ("State Reason Code", detail?.stateReasonCode ?? "-"),
                    ("Last Update", detail?.lastUpdateStatus ?? function.lastUpdateStatus ?? "-"),
                    ("Update Reason", detail?.lastUpdateStatusReason ?? "-"),
                    ("Update Reason Code", detail?.lastUpdateStatusReasonCode ?? "-"),
                    ("Runtime", function.runtime ?? "-"),
                    ("Runtime Version", detail?.runtimeVersionARN ?? "-"),
                    ("Version", detail?.version ?? "$LATEST"),
                    ("Architectures", joined(detail?.architectures ?? [])),
                    ("Package Type", function.packageType ?? "-"),
                    ("Memory", function.memorySize.map { "\($0) MB" } ?? "-"),
                    ("Timeout", function.timeout.map { "\($0)s" } ?? "-"),
                    ("Ephemeral Storage", detail?.ephemeralStorageMB.map { "\($0) MB" } ?? "-"),
                    ("Code Size", bytes(function.codeSize)),
                    ("Last Modified", function.lastModified ?? "-"),
                    ("Revision ID", detail?.revisionId ?? "-"),
                    ("Code SHA256", detail?.codeSHA256 ?? "-"),
                    ("Config SHA256", detail?.configSHA256 ?? "-")
                ])

                if let tags = detail?.tags, !tags.isEmpty {
                    sectionTitle("Tags")
                    keyValueRows(tags)
                }
            }
            .padding()
        }
    }

    private var configurationTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle("Runtime and Permissions")
                DetailGrid(items: [
                    ("Handler", function.handler ?? "-"),
                    ("Execution Role", function.role ?? "-"),
                    ("Reserved Concurrency", number(detail?.reservedConcurrency)),
                    ("Tracing", detail?.tracingMode ?? "-"),
                    ("Dead Letter Target", detail?.deadLetterTargetARN ?? "-"),
                    ("KMS Key", detail?.kmsKeyARN ?? "-"),
                    ("Source KMS Key", detail?.sourceKMSKeyARN ?? "-"),
                    ("SnapStart", detail?.snapStartApplyOn ?? "-"),
                    ("SnapStart Status", detail?.snapStartOptimizationStatus ?? "-")
                ])

                sectionTitle("Network")
                DetailGrid(items: [
                    ("VPC", detail?.vpcId ?? function.vpcConfig ?? "-"),
                    ("Subnets", joined(detail?.subnetIds ?? [])),
                    ("Security Groups", joined(detail?.securityGroupIds ?? [])),
                    ("IPv6 Dual Stack", boolean(detail?.ipv6AllowedForDualStack))
                ])

                sectionTitle("Logging")
                DetailGrid(items: [
                    ("Log Group", detail?.logGroup ?? "-"),
                    ("Log Format", detail?.logFormat ?? "-"),
                    ("Application Level", detail?.applicationLogLevel ?? "-"),
                    ("System Level", detail?.systemLogLevel ?? "-")
                ])

                environmentSection
                layerSection
                fileSystemSection
                imageConfigurationSection
                policySection
            }
            .padding()
        }
    }

    private var triggersTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle("Event Source Mappings")
                if let sources = detail?.eventSources, !sources.isEmpty {
                    ForEach(sources) { source in
                        GroupBox {
                            DetailGrid(items: [
                                ("Source", source.sourceARN ?? "-"),
                                ("State", source.state ?? "-"),
                                ("State Reason", source.stateTransitionReason ?? "-"),
                                ("Batch Size", number(source.batchSize)),
                                ("Batching Window", seconds(source.batchingWindowSeconds)),
                                ("Parallelization", number(source.parallelizationFactor)),
                                ("Maximum Retries", retryValue(source.maximumRetryAttempts)),
                                ("Maximum Record Age", retryValue(source.maximumRecordAgeSeconds)),
                                ("Starting Position", source.startingPosition ?? "-"),
                                ("Bisect on Error", boolean(source.bisectBatchOnError)),
                                ("Last Result", source.lastProcessingResult ?? "-"),
                                ("Failure Destination", source.onFailureDestination ?? "-")
                            ])
                        } label: {
                            HStack {
                                Text(source.type)
                                Spacer()
                                copyButton(source.uuid, label: "Copy mapping UUID")
                            }
                        }
                    }
                } else {
                    emptyDetail("No event source mappings")
                }

                sectionTitle("Asynchronous Invocation")
                if let configs = detail?.asyncInvokeConfigs, !configs.isEmpty {
                    ForEach(configs) { config in
                        GroupBox(config.qualifier) {
                            DetailGrid(items: [
                                ("Maximum Event Age", seconds(config.maximumEventAgeSeconds)),
                                ("Maximum Retries", number(config.maximumRetryAttempts)),
                                ("Success Destination", config.onSuccessDestination ?? "-"),
                                ("Failure Destination", config.onFailureDestination ?? "-"),
                                ("Last Modified", format(config.lastModified))
                            ])
                        }
                    }
                } else {
                    emptyDetail("No asynchronous invocation configuration")
                }

                sectionTitle("Function URLs")
                if let urls = detail?.functionURLs, !urls.isEmpty {
                    ForEach(urls) { url in
                        GroupBox {
                            DetailGrid(items: [
                                ("URL", url.url),
                                ("Authentication", url.authType),
                                ("Invoke Mode", url.invokeMode ?? "-"),
                                ("Allowed Origins", joined(url.allowedOrigins)),
                                ("Allowed Methods", joined(url.allowedMethods)),
                                ("Allow Credentials", boolean(url.allowCredentials)),
                                ("Created", url.creationTime),
                                ("Last Modified", url.lastModifiedTime)
                            ])
                        } label: {
                            HStack {
                                Text(qualifier(from: url.functionARN))
                                if url.authType == "NONE" {
                                    Label("Public", systemImage: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                }
                                Spacer()
                                copyButton(url.url, label: "Copy function URL")
                            }
                        }
                    }
                } else {
                    emptyDetail("No function URLs")
                }
            }
            .padding()
        }
    }

    private var versionsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailGrid(items: [
                    ("Reserved Concurrency", number(detail?.reservedConcurrency)),
                    ("Published Versions", "\(detail?.versions.filter { $0.version != "$LATEST" }.count ?? 0)"),
                    ("Aliases", "\(detail?.aliases.count ?? 0)"),
                    ("Provisioned Configs", "\(detail?.provisionedConcurrency.count ?? 0)")
                ])

                sectionTitle("Aliases")
                if let aliases = detail?.aliases, !aliases.isEmpty {
                    ForEach(aliases) { alias in
                        GroupBox(alias.name) {
                            DetailGrid(items: [
                                ("Primary Version", alias.functionVersion ?? "-"),
                                ("Additional Weights", weights(alias.additionalVersionWeights)),
                                ("Description", alias.description ?? "-"),
                                ("Revision ID", alias.revisionId ?? "-")
                            ])
                        }
                    }
                } else {
                    emptyDetail("No aliases")
                }

                sectionTitle("Provisioned Concurrency")
                if let configs = detail?.provisionedConcurrency, !configs.isEmpty {
                    ForEach(configs) { config in
                        GroupBox(config.qualifier) {
                            DetailGrid(items: [
                                ("Status", config.status ?? "-"),
                                ("Requested", number(config.requested)),
                                ("Allocated", number(config.allocated)),
                                ("Available", number(config.available)),
                                ("Status Reason", config.statusReason ?? "-"),
                                ("Last Modified", config.lastModified ?? "-")
                            ])
                        }
                    }
                } else {
                    emptyDetail("No provisioned concurrency")
                }

                sectionTitle("Versions")
                if let versions = detail?.versions, !versions.isEmpty {
                    ForEach(versions) { version in
                        GroupBox(version.version) {
                            DetailGrid(items: [
                                ("State", version.state ?? "-"),
                                ("Runtime", version.runtime ?? "-"),
                                ("Architectures", joined(version.architectures)),
                                ("Memory", version.memorySize.map { "\($0) MB" } ?? "-"),
                                ("Timeout", version.timeout.map { "\($0)s" } ?? "-"),
                                ("Code Size", bytes(version.codeSize)),
                                ("Last Modified", version.lastModified ?? "-"),
                                ("Description", version.description ?? "-")
                            ])
                        }
                    }
                } else {
                    emptyDetail("No function versions")
                }
            }
            .padding()
        }
    }

    private var codeTab: some View {
        VStack(spacing: 0) {
            HStack {
                if function.packageType == "Image" {
                    Text(detail?.resolvedImageURI ?? detail?.imageURI ?? "Container image")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Deployment package is downloaded only when requested.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(vm.isCodeLoading ? "Loading…" : "Load Code") {
                    vm.loadCodeForSelection()
                }
                .disabled(vm.isCodeLoading)
            }
            .padding()

            if let codeError = vm.codeError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(codeError)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            Divider()
            LambdaCodeView(function: function)
                .overlay {
                    if vm.isCodeLoading {
                        ProgressView()
                    }
                }
        }
    }

    @ViewBuilder
    private var environmentSection: some View {
        sectionTitle("Environment Variables")
        if let environment = detail?.environment, !environment.isEmpty {
            VStack(spacing: 0) {
                ForEach(environment.keys.sorted(), id: \.self) { key in
                    HStack(alignment: .top, spacing: 8) {
                        Text(key)
                            .fontWeight(.medium)
                            .frame(minWidth: 120, alignment: .leading)
                        if revealedEnvironmentKeys.contains(key) {
                            Text(environment[key] ?? "")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        } else {
                            Text("••••••••")
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button {
                            if revealedEnvironmentKeys.contains(key) {
                                revealedEnvironmentKeys.remove(key)
                            } else {
                                revealedEnvironmentKeys.insert(key)
                            }
                        } label: {
                            Image(systemName: revealedEnvironmentKeys.contains(key)
                                ? "eye.slash"
                                : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(revealedEnvironmentKeys.contains(key) ? "Hide value" : "Reveal value")
                        if revealedEnvironmentKeys.contains(key), let value = environment[key] {
                            copyButton(value, label: "Copy environment value")
                        }
                    }
                    .font(.caption)
                    .padding(.vertical, 7)
                    Divider()
                }
            }
        } else {
            emptyDetail(detail?.environmentError ?? "No environment variables")
        }
    }

    @ViewBuilder
    private var layerSection: some View {
        sectionTitle("Layers")
        if let layers = detail?.layers, !layers.isEmpty {
            ForEach(layers) { layer in
                GroupBox {
                    DetailGrid(items: [
                        ("ARN", layer.arn),
                        ("Code Size", bytes(layer.codeSize)),
                        ("Signing Job", layer.signingJobARN ?? "-"),
                        ("Signing Profile", layer.signingProfileVersionARN ?? "-")
                    ])
                }
            }
        } else {
            emptyDetail("No Lambda layers")
        }
    }

    @ViewBuilder
    private var fileSystemSection: some View {
        sectionTitle("File Systems")
        if let fileSystems = detail?.fileSystems, !fileSystems.isEmpty {
            ForEach(fileSystems) { fileSystem in
                DetailGrid(items: [
                    ("EFS Access Point", fileSystem.arn),
                    ("Local Mount Path", fileSystem.localMountPath)
                ])
            }
        } else {
            emptyDetail("No EFS file systems")
        }
    }

    @ViewBuilder
    private var imageConfigurationSection: some View {
        if function.packageType == "Image" {
            sectionTitle("Container Image Configuration")
            DetailGrid(items: [
                ("Image URI", detail?.imageURI ?? "-"),
                ("Resolved Image", detail?.resolvedImageURI ?? "-"),
                ("Repository Type", detail?.repositoryType ?? "-"),
                ("Entry Point", joined(detail?.imageEntryPoint ?? [])),
                ("Command", joined(detail?.imageCommand ?? [])),
                ("Working Directory", detail?.imageWorkingDirectory ?? "-")
            ])
        }
    }

    @ViewBuilder
    private var policySection: some View {
        sectionTitle("Resource Policy")
        if let statements = detail?.policyStatements, !statements.isEmpty {
            ForEach(statements) { statement in
                GroupBox(statement.statementId) {
                    DetailGrid(items: [
                        ("Effect", statement.effect ?? "-"),
                        ("Principals", joined(statement.principals)),
                        ("Actions", joined(statement.actions)),
                        ("Resources", joined(statement.resources)),
                        ("Source ARNs", joined(statement.sourceARNs))
                    ])
                }
            }
        } else {
            emptyDetail("No resource-based policy")
        }
    }

    private func warningBanner(_ warnings: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Some Lambda details could not be loaded", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.orange)
            ForEach(warnings, id: \.self) { warning in
                Text(warning)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
    }

    private func keyValueRows(_ values: [String: String]) -> some View {
        VStack(spacing: 0) {
            ForEach(values.keys.sorted(), id: \.self) { key in
                HStack(alignment: .top) {
                    Text(key)
                        .fontWeight(.medium)
                    Spacer()
                    Text(values[key] ?? "")
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                .font(.caption)
                .padding(.vertical, 6)
                Divider()
            }
        }
    }

    private func emptyDetail(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func copyButton(_ value: String, label: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help(label)
    }

    private var statusColor: Color {
        let state = detail?.state ?? function.state
        let update = detail?.lastUpdateStatus ?? function.lastUpdateStatus
        if state == "Failed" || update == "Failed" {
            return .red
        }
        if state == "Pending" || update == "InProgress" {
            return .orange
        }
        return state == "Active" ? .green : .gray
    }

    private func boolean(_ value: Bool?) -> String {
        value.map { $0 ? "Yes" : "No" } ?? "-"
    }

    private func number(_ value: Int?) -> String {
        value.map(String.init) ?? "-"
    }

    private func seconds(_ value: Int?) -> String {
        value.map { "\($0)s" } ?? "-"
    }

    private func retryValue(_ value: Int?) -> String {
        guard let value else { return "-" }
        return value == -1 ? "Infinite" : String(value)
    }

    private func joined(_ values: [String]) -> String {
        values.isEmpty ? "-" : values.joined(separator: ", ")
    }

    private func bytes(_ value: Int64?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "-"
    }

    private func format(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .standard) ?? "-"
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func qualifier(from arn: String) -> String {
        let suffix = arn.split(separator: ":").last.map(String.init)
        return suffix == function.functionName ? "$LATEST" : suffix ?? "$LATEST"
    }

    private func weights(_ values: [String: Double]) -> String {
        guard !values.isEmpty else { return "-" }
        return values.keys.sorted().map { version in
            let percentage = (values[version] ?? 0) * 100
            return "\(version): \(percentage.formatted(.number.precision(.fractionLength(0...2))))%"
        }
        .joined(separator: ", ")
    }
}
