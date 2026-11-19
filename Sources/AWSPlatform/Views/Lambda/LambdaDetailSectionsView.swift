import SwiftUI

extension LambdaDetailView {
    var triggersTab: some View {
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
                                CopyButton(value: source.uuid, label: "Copy mapping UUID")
                            }
                        }
                    }
                } else {
                    componentEmptyState(.eventSources, empty: "No event source mappings")
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
                    componentEmptyState(.asyncInvokeConfigs, empty: "No asynchronous invocation configuration")
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
                                    Label(L10n.text("Public", locale: locale), systemImage: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                }
                                Spacer()
                                CopyButton(value: url.url, label: "Copy function URL")
                            }
                        }
                    }
                } else {
                    componentEmptyState(.functionURLs, empty: "No function URLs")
                }
            }
            .padding()
        }
    }

    var versionsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailGrid(items: [
                    ("Reserved Concurrency", number(detail?.reservedConcurrency)),
                    ("Published Versions", componentCount(.versions, count: detail?.versions.filter { $0.version != "$LATEST" }.count ?? 0)),
                    ("Aliases", componentCount(.aliases, count: detail?.aliases.count ?? 0)),
                    ("Provisioned Configs", componentCount(.provisionedConcurrency, count: detail?.provisionedConcurrency.count ?? 0))
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
                    componentEmptyState(.aliases, empty: "No aliases")
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
                    componentEmptyState(.provisionedConcurrency, empty: "No provisioned concurrency")
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
                    componentEmptyState(.versions, empty: "No function versions")
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func componentEmptyState(_ component: LambdaDetailComponent, empty text: String) -> some View {
        if let issue = vm.detailSectionIssue(component) {
            NoticeBanner(message: "\(L10n.text(component.rawValue, locale: locale)): \(L10n.text(issue.message, locale: locale))")
        } else {
            EmptyDetailNote(text: text)
        }
    }

    private func componentCount(_ component: LambdaDetailComponent, count: Int) -> String {
        vm.detailSectionIssue(component) == nil ? String(count) : "-"
    }

    var codeTab: some View {
        VStack(spacing: 0) {
            HStack {
                if function.packageType == "Image" {
                    Text(detail?.resolvedImageURI ?? detail?.imageURI ?? L10n.text("Container image", locale: locale))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text(L10n.text("Deployment package is downloaded only when requested.", locale: locale))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if vm.isCodeLoading {
                    Button(L10n.text("Cancel", locale: locale)) {
                        vm.cancelCodeLoading()
                    }
                }
                Button(L10n.text(vm.isCodeLoading ? "Loading…" : "Load Code", locale: locale)) {
                    vm.loadCodeForSelection()
                }
                .disabled(vm.isCodeLoading)
            }
            .padding()

            if let codeError = vm.codeError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(L10n.text(codeError, locale: locale))
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
    var environmentSection: some View {
        sectionTitle("Environment Variables")
        if let environment = detail?.environment, !environment.isEmpty {
            VStack(spacing: 8) {
                ForEach(environment.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 8) {
                            Text(key)
                                .font(.caption.weight(.medium))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button {
                                if revealedEnvironmentKeys.contains(key) {
                                    revealedEnvironmentKeys.remove(key)
                                } else {
                                    revealedEnvironmentKeys.insert(key)
                                }
                            } label: {
                                Image(systemName: revealedEnvironmentKeys.contains(key) ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .help(L10n.text(revealedEnvironmentKeys.contains(key) ? "Hide value" : "Reveal value", locale: locale))
                            .accessibilityLabel(L10n.format(revealedEnvironmentKeys.contains(key) ? "Hide %@" : "Reveal %@", key, locale: locale))
                            if revealedEnvironmentKeys.contains(key), let value = environment[key] {
                                CopyButton(value: value, label: "Copy environment value")
                            }
                        }
                        if revealedEnvironmentKeys.contains(key) {
                            Text(environment[key] ?? "")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("••••••••")
                                .foregroundColor(.secondary)
                        }
                    }
                    .font(.caption)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        } else {
            EmptyDetailNote(text: detail?.environmentError ?? "No environment variables")
        }
    }

    @ViewBuilder
    var layerSection: some View {
        sectionTitle("Layers")
        if let layers = detail?.layers, !layers.isEmpty {
            ForEach(layers) { layer in
                GroupBox {
                    DetailFieldRows(items: [
                        ("ARN", layer.arn),
                        ("Code Size", bytes(layer.codeSize)),
                        ("Signing Job", layer.signingJobARN ?? "-"),
                        ("Signing Profile", layer.signingProfileVersionARN ?? "-")
                    ])
                }
            }
        } else {
            EmptyDetailNote(text: "No Lambda layers")
        }
    }

    @ViewBuilder
    var fileSystemSection: some View {
        sectionTitle("File Systems")
        if let fileSystems = detail?.fileSystems, !fileSystems.isEmpty {
            ForEach(fileSystems) { fileSystem in
                DetailFieldRows(items: [
                    ("EFS Access Point", fileSystem.arn),
                    ("Local Mount Path", fileSystem.localMountPath)
                ])
            }
        } else {
            EmptyDetailNote(text: "No EFS file systems")
        }
    }

    @ViewBuilder
    var imageConfigurationSection: some View {
        if function.packageType == "Image" {
            sectionTitle("Container Image Configuration")
            DetailFieldRows(items: [
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
    var policySection: some View {
        sectionTitle("Resource Policy")
        if let statements = detail?.policyStatements, !statements.isEmpty {
            ForEach(statements) { statement in
                GroupBox(statement.statementId) {
                    DetailFieldRows(items: [
                        ("Effect", statement.effect ?? "-"),
                        ("Principals", joined(statement.principals)),
                        ("Actions", joined(statement.actions)),
                        ("Resources", joined(statement.resources)),
                        ("Source ARNs", joined(statement.sourceARNs))
                    ])
                }
            }
        } else {
            EmptyDetailNote(text: "No resource-based policy")
        }
    }

    func sectionTitle(_ title: String) -> some View {
        DetailSectionTitle(title: title)
    }

    func keyValueRows(_ values: [String: String]) -> some View {
        DetailKeyValueRows(values: values)
    }

    func boolean(_ value: Bool?) -> String {
        value.map { L10n.text($0 ? "Yes" : "No", locale: locale) } ?? "-"
    }

    func number(_ value: Int?) -> String {
        value.map(String.init) ?? "-"
    }

    private func seconds(_ value: Int?) -> String {
        value.map { "\($0)s" } ?? "-"
    }

    private func retryValue(_ value: Int?) -> String {
        guard let value else { return "-" }
        return value == -1 ? L10n.text("Infinite", locale: locale) : String(value)
    }

    func joined(_ values: [String]) -> String {
        values.isEmpty ? "-" : values.joined(separator: ", ")
    }

    func bytes(_ value: Int64?) -> String {
        value.map { $0.formatted(.byteCount(style: .file).locale(locale)) } ?? "-"
    }

    private func format(_ date: Date?) -> String {
        date?.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(locale)) ?? "-"
    }

    func nonEmpty(_ value: String?) -> String? {
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
            return "\(version): \(percentage.formatted(.number.precision(.fractionLength(0...2)).locale(locale)))%"
        }
        .joined(separator: ", ")
    }
}
