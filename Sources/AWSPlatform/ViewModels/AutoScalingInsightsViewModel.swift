import Foundation

@MainActor
final class AutoScalingInsightsViewModel: ObservableObject {
    typealias TemplateLoader = @Sendable (MonitoringScope, ASGGroup, ASGLaunchTemplate) async throws -> [ASGTemplateVersion]
    typealias RefreshLoader = @Sendable (MonitoringScope, ASGGroup) async throws -> [ASGInstanceRefresh]

    @Published private(set) var scope: MonitoringScope?
    @Published private(set) var group: ASGGroup?
    @Published private(set) var templateVersions: [ASGTemplateVersion] = []
    @Published private(set) var instanceRefreshes: [ASGInstanceRefresh] = []
    @Published private(set) var isTemplatesLoading = false
    @Published private(set) var isRefreshesLoading = false
    @Published private(set) var templatesError: String?
    @Published private(set) var refreshesError: String?
    @Published private(set) var didLoadTemplates = false
    @Published private(set) var didLoadRefreshes = false

    private let templateLoader: TemplateLoader
    private let refreshLoader: RefreshLoader
    private var templateTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var templateGeneration = 0
    private var refreshGeneration = 0

    convenience init(provider: AWSServiceProvider) {
        let service = AWSAutoScalingInsightsService(provider: provider)
        self.init(templateLoader: { try await service.loadTemplateVersions(scope: $0, group: $1, template: $2) },
                  refreshLoader: { try await service.loadInstanceRefreshes(scope: $0, group: $1) })
    }

    init(templateLoader: @escaping TemplateLoader, refreshLoader: @escaping RefreshLoader) {
        self.templateLoader = templateLoader
        self.refreshLoader = refreshLoader
    }

    var templates: [ASGLaunchTemplate] { group.map(ASGInsightsContext.templates(in:)) ?? [] }

    func configure(scope: MonitoringScope?, group: ASGGroup?) {
        guard self.scope != scope || self.group != group else { return }
        reset()
        guard let scope, let group, (try? ASGInsightsContext.validate(scope: scope, group: group)) != nil else { return }
        self.scope = scope
        self.group = group
    }

    func loadTemplateVersions() {
        guard let scope, let group else { return }
        invalidateTemplates()
        templateVersions = []
        templatesError = nil
        didLoadTemplates = true
        let references = templates
        guard !references.isEmpty else { return }
        isTemplatesLoading = true
        let generation = templateGeneration
        let loader = templateLoader
        templateTask = Task { [weak self] in
            do {
                var rows: [ASGTemplateVersion] = []
                for reference in references {
                    try Task.checkCancellation()
                    let versions = try await loader(scope, group, reference)
                    try Task.checkCancellation()
                    guard versions.allSatisfy({ $0.reference == reference && $0.version > 0 && !$0.templateID.isEmpty }),
                          Set(versions.map(\.id)).count == versions.count else { throw AutoScalingInsightsError.invalidResponse }
                    rows += versions
                }
                guard let self, self.isCurrent(scope: scope, group: group), self.templateGeneration == generation else { return }
                self.templateVersions = rows
                self.isTemplatesLoading = false
                self.templateTask = nil
            } catch {
                guard let self, self.isCurrent(scope: scope, group: group), self.templateGeneration == generation else { return }
                self.isTemplatesLoading = false
                self.templateTask = nil
                self.templatesError = Self.message(error)
            }
        }
    }

    func loadInstanceRefreshes() {
        guard let scope, let group else { return }
        invalidateRefreshes()
        instanceRefreshes = []
        refreshesError = nil
        didLoadRefreshes = true
        isRefreshesLoading = true
        let generation = refreshGeneration
        let loader = refreshLoader
        refreshTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let rows = try await loader(scope, group)
                try Task.checkCancellation()
                guard rows.allSatisfy({ !$0.id.isEmpty && $0.groupName == group.name }),
                      Set(rows.map(\.id)).count == rows.count else { throw AutoScalingInsightsError.invalidResponse }
                guard let self, self.isCurrent(scope: scope, group: group), self.refreshGeneration == generation else { return }
                self.instanceRefreshes = rows
                self.isRefreshesLoading = false
                self.refreshTask = nil
            } catch {
                guard let self, self.isCurrent(scope: scope, group: group), self.refreshGeneration == generation else { return }
                self.isRefreshesLoading = false
                self.refreshTask = nil
                self.refreshesError = Self.message(error)
            }
        }
    }

    func cancelLoading() {
        if isTemplatesLoading { invalidateTemplates(); templatesError = "Loading cancelled. Use Load to try again." }
        if isRefreshesLoading { invalidateRefreshes(); refreshesError = "Loading cancelled. Use Load to try again." }
    }

    func reset() {
        invalidateTemplates()
        invalidateRefreshes()
        scope = nil
        group = nil
        templateVersions = []
        instanceRefreshes = []
        templatesError = nil
        refreshesError = nil
        didLoadTemplates = false
        didLoadRefreshes = false
    }

    func waitForLoading() async {
        let templates = templateTask
        let refreshes = refreshTask
        await templates?.value
        await refreshes?.value
    }

    private func isCurrent(scope: MonitoringScope, group: ASGGroup) -> Bool { self.scope == scope && self.group == group }

    private func invalidateTemplates() {
        templateGeneration += 1
        templateTask?.cancel()
        templateTask = nil
        isTemplatesLoading = false
    }

    private func invalidateRefreshes() {
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshesLoading = false
    }

    private static func message(_ error: Error) -> String {
        if error is CancellationError { return "Loading cancelled. Use Load to try again." }
        return (error as? AutoScalingInsightsError)?.localizedDescription ?? AutoScalingInsightsError.failed.localizedDescription
    }
}
