import SwiftUI

struct LambdaDetailView: View {
    @Environment(\.locale) var locale
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case configuration = "Configuration"
        case triggers = "Triggers"
        case versions = "Versions"
        case code = "Code"
        case metrics = "Metrics"
        case logs = "Logs"

        var id: String { rawValue }
    }

    let function: LambdaFunctionModel
    @ObservedObject var vm: LambdaViewModel
    let monitoringScope: MonitoringScope?
    let metricsVM: ResourceMetricsViewModel?
    let logsVM: LambdaLogsViewModel?
    @State private var selectedTab: Tab = .overview
    @State var revealedEnvironmentKeys: Set<String> = []

    init(function: LambdaFunctionModel, vm: LambdaViewModel, tab: Tab = .overview,
         monitoringScope: MonitoringScope? = nil, metricsVM: ResourceMetricsViewModel? = nil,
         logsVM: LambdaLogsViewModel? = nil) {
        self.function = function
        self.vm = vm
        self.monitoringScope = monitoringScope
        self.metricsVM = metricsVM
        self.logsVM = logsVM
        _selectedTab = State(initialValue: tab)
    }

    var detail: LambdaFunctionDetailModel? {
        guard vm.functionDetail?.functionName == function.functionName else { return nil }
        return vm.functionDetail
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            DetailTabPicker(tabs: Tab.allCases.filter {
                ($0 != .metrics || metricsVM != nil) && ($0 != .logs || logsVM != nil)
            }, selection: $selectedTab)
            .padding()

            if let detail, !detail.warnings.isEmpty {
                warningBanner(detail.warnings)
            }

            ZStack {
                tabContent
                if selectedTab != .metrics && vm.isDetailLoading && detail == nil {
                    ProgressView(L10n.text("Loading Lambda details…", locale: locale))
                        .padding()
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { vm.selectDetailSection(selectedDetailSection) }
        .onChange(of: selectedTab) { _ in vm.selectDetailSection(selectedDetailSection) }
        .onChange(of: function.functionName) { _ in
            selectedTab = .overview
            revealedEnvironmentKeys = []
            vm.selectDetailSection(nil)
        }
    }

    private var selectedDetailSection: LambdaDetailSection? {
        switch selectedTab {
        case .configuration: return .configuration
        case .triggers: return .triggers
        case .versions: return .versions
        default: return nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(function.functionName)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .help(function.functionName)
                    if let arn = function.arn {
                        HStack(spacing: 6) {
                            Text(arn)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .help(arn)
                            CopyButton(value: arn, label: "Copy function ARN")
                        }
                    }
                }
                Spacer()
                statusBadge
                    .fixedSize()
            }

            if let detailError = vm.detailError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(L10n.text(detailError, locale: locale))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(L10n.text("Retry", locale: locale)) {
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
            Text(detail?.state ?? function.state ?? L10n.text("Unknown", locale: locale))
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
            detailSection(.triggers) { triggersTab }
        case .versions:
            detailSection(.versions) { versionsTab }
        case .code:
            codeTab
        case .metrics:
            if let metricsVM {
                ResourceMetricsView(vm: metricsVM, scope: monitoringScope, target: .lambda(function.functionName))
            }
        case .logs:
            if let logsVM, let detail {
                LambdaLogsView(vm: logsVM, scope: monitoringScope,
                               context: LambdaLogContext(functionName: detail.functionName, configuredLogGroup: detail.logGroup))
            } else {
                EmptyStateView(text: "Load the function configuration to identify its log group.", icon: "doc.text.magnifyingglass")
            }
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
                    ("Version", detail?.version ?? "$LATEST"),
                    ("Architectures", joined(detail?.architectures ?? [])),
                    ("Package Type", function.packageType ?? "-"),
                    ("Memory", function.memorySize.map { "\($0) MB" } ?? "-"),
                    ("Timeout", function.timeout.map { "\($0)s" } ?? "-"),
                    ("Ephemeral Storage", detail?.ephemeralStorageMB.map { "\($0) MB" } ?? "-"),
                    ("Code Size", bytes(function.codeSize)),
                    ("Last Modified", function.lastModified ?? "-")
                ])

                DetailFieldRows(items: [
                    ("Runtime Version", detail?.runtimeVersionARN ?? "-"),
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
                    ("Reserved Concurrency", number(detail?.reservedConcurrency)),
                    ("Tracing", detail?.tracingMode ?? "-"),
                    ("SnapStart", detail?.snapStartApplyOn ?? "-"),
                    ("SnapStart Status", detail?.snapStartOptimizationStatus ?? "-")
                ])
                DetailFieldRows(items: [
                    ("Execution Role", function.role ?? "-"),
                    ("Dead Letter Target", detail?.deadLetterTargetARN ?? "-"),
                    ("KMS Key", detail?.kmsKeyARN ?? "-"),
                    ("Source KMS Key", detail?.sourceKMSKeyARN ?? "-")
                ])

                sectionTitle("Network")
                DetailGrid(items: [
                    ("VPC", detail?.vpcId ?? function.vpcConfig ?? "-"),
                    ("IPv6 Dual Stack", boolean(detail?.ipv6AllowedForDualStack))
                ])
                DetailFieldRows(items: [
                    ("Subnets", joined(detail?.subnetIds ?? [])),
                    ("Security Groups", joined(detail?.securityGroupIds ?? []))
                ])

                sectionTitle("Logging")
                DetailGrid(items: [
                    ("Log Format", detail?.logFormat ?? "-"),
                    ("Application Level", detail?.applicationLogLevel ?? "-"),
                    ("System Level", detail?.systemLogLevel ?? "-")
                ])
                DetailFieldRows(items: [
                    ("Log Group", detail?.logGroup ?? "-")
                ])

                environmentSection
                layerSection
                fileSystemSection
                imageConfigurationSection
                detailSection(.configuration) { policySection }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func detailSection<Content: View>(
        _ section: LambdaDetailSection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        switch vm.detailSectionState(section) {
        case .loaded:
            VStack(spacing: 0) {
                if !(vm.detailSectionIssues[section] ?? []).isEmpty {
                    HStack {
                        NoticeBanner(message: "Some Lambda details could not be loaded")
                        Button(L10n.text("Retry", locale: locale)) { vm.retryDetailSection(section) }
                    }
                    .padding()
                }
                content()
            }
        case .idle, .loading:
            ProgressView(L10n.text("Loading Lambda section…", locale: locale))
                .padding()
                .frame(maxWidth: .infinity)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                NoticeBanner(message: message)
                Button(L10n.text("Retry", locale: locale)) { vm.retryDetailSection(section) }
            }
            .padding()
        case .cancelled:
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("Lambda section loading was cancelled.", locale: locale))
                    .foregroundColor(.secondary)
                Button(L10n.text("Retry", locale: locale)) { vm.retryDetailSection(section) }
            }
            .padding()
        }
    }

    private func warningBanner(_ warnings: [String]) -> some View {
        ScrollView {
            NoticeBanner(message: (["Some Lambda details could not be loaded"] + warnings).joined(separator: "\n"))
        }
        .frame(maxHeight: 100)
        .padding(.horizontal)
        .padding(.bottom, 8)
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
}
