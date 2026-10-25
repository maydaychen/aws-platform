import Foundation

@MainActor
final class AutoScalingViewModel: ObservableObject {
    typealias GroupLoader = @Sendable (MonitoringScope) async throws -> [ASGGroup]
    typealias PolicyLoader = @Sendable (MonitoringScope, ASGGroup) async throws -> [ASGPolicy]
    typealias ActivityLoader = @Sendable (MonitoringScope, ASGGroup) async throws -> [ASGActivity]

    @Published private(set) var scope: MonitoringScope?
    @Published private(set) var groups: [ASGGroup] = []
    @Published private(set) var policies: [ASGPolicy] = []
    @Published private(set) var activities: [ASGActivity] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isPoliciesLoading = false
    @Published private(set) var isActivitiesLoading = false
    @Published private(set) var error: String?
    @Published private(set) var policiesError: String?
    @Published private(set) var activitiesError: String?
    @Published var searchText = ""
    @Published var selectedGroup: ASGGroup? {
        didSet {
            guard !restoringSelection else { return }
            pendingSelectionARN = nil
            if let selectedGroup, !groups.contains(selectedGroup) {
                restoringSelection = true
                self.selectedGroup = nil
                restoringSelection = false
            }
            guard oldValue != selectedGroup else { return }
            refreshDetails()
        }
    }

    private let groupLoader: GroupLoader
    private let policyLoader: PolicyLoader
    private let activityLoader: ActivityLoader
    private var groupTask: Task<Void, Never>?
    private var policyTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var listGeneration = 0
    private var detailGeneration = 0
    private var hasAttemptedLoad = false
    private var restoringSelection = false
    private var pendingSelectionARN: String?

    convenience init(provider: AWSServiceProvider) {
        let service = AWSAutoScalingService(provider: provider)
        self.init(groupLoader: { try await service.loadGroups(scope: $0) },
                  policyLoader: { try await service.loadPolicies(scope: $0, group: $1) },
                  activityLoader: { try await service.loadActivities(scope: $0, group: $1) })
    }

    init(groupLoader: @escaping GroupLoader, policyLoader: @escaping PolicyLoader,
         activityLoader: @escaping ActivityLoader) {
        self.groupLoader = groupLoader
        self.policyLoader = policyLoader
        self.activityLoader = activityLoader
    }

    var filteredGroups: [ASGGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return groups.filter { group in
            query.isEmpty || group.name.localizedCaseInsensitiveContains(query)
                || group.arn.localizedCaseInsensitiveContains(query)
        }
    }

    func configure(scope: MonitoringScope?) {
        guard self.scope != scope else { return }
        reset()
        self.scope = scope
    }

    func loadIfNeeded() {
        if !hasAttemptedLoad { refresh() }
    }

    func refresh() {
        guard let scope, scope.isValid else { return }
        let selectionARN = selectedGroup?.arn ?? pendingSelectionARN
        invalidateList()
        clearDetails()
        restoringSelection = true
        selectedGroup = nil
        restoringSelection = false
        groups = []
        pendingSelectionARN = selectionARN
        hasAttemptedLoad = true
        isLoading = true
        error = nil
        let generation = listGeneration
        let loader = groupLoader
        groupTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let rows = try await loader(scope)
                try Task.checkCancellation()
                guard let self, self.isCurrentList(generation, scope: scope) else { return }
                guard rows.allSatisfy({ !$0.arn.isEmpty && !$0.name.isEmpty }),
                      Set(rows.map(\.arn)).count == rows.count,
                      Set(rows.map(\.name)).count == rows.count else { throw AutoScalingError.invalidResponse }
                self.groups = rows
                self.isLoading = false
                self.groupTask = nil
                let selection = self.pendingSelectionARN.flatMap { arn in rows.first { $0.arn == arn } }
                self.pendingSelectionARN = nil
                if let selection {
                    self.restoringSelection = true
                    self.selectedGroup = selection
                    self.restoringSelection = false
                    self.refreshDetails()
                }
            } catch {
                guard let self, self.isCurrentList(generation, scope: scope) else { return }
                self.isLoading = false
                self.groupTask = nil
                self.error = self.safeMessage(error, operation: .groups)
            }
        }
    }

    func refreshDetails() {
        clearDetails()
        guard let scope, scope.isValid, let group = selectedGroup, groups.contains(group) else { return }
        let generation = detailGeneration
        let loadPolicies = policyLoader
        let loadActivities = activityLoader
        isPoliciesLoading = true
        isActivitiesLoading = true
        policyTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let rows = try await loadPolicies(scope, group)
                try Task.checkCancellation()
                guard let self, self.isCurrentDetail(generation, scope: scope, group: group) else { return }
                guard rows.allSatisfy({ !$0.arn.isEmpty && !$0.name.isEmpty && $0.groupName == group.name }),
                      Set(rows.map(\.arn)).count == rows.count,
                      Set(rows.map(\.name)).count == rows.count else { throw AutoScalingError.invalidResponse }
                self.policies = rows
                self.isPoliciesLoading = false
                self.policyTask = nil
            } catch {
                guard let self, self.isCurrentDetail(generation, scope: scope, group: group) else { return }
                self.isPoliciesLoading = false
                self.policyTask = nil
                self.policiesError = self.safeMessage(error, operation: .policies)
            }
        }
        activityTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let rows = try await loadActivities(scope, group)
                try Task.checkCancellation()
                guard let self, self.isCurrentDetail(generation, scope: scope, group: group) else { return }
                guard rows.allSatisfy({ !$0.activityID.isEmpty && $0.groupName == group.name && $0.groupARN == group.arn }),
                      Set(rows.map(\.activityID)).count == rows.count else { throw AutoScalingError.invalidResponse }
                self.activities = rows
                self.isActivitiesLoading = false
                self.activityTask = nil
            } catch {
                guard let self, self.isCurrentDetail(generation, scope: scope, group: group) else { return }
                self.isActivitiesLoading = false
                self.activityTask = nil
                self.activitiesError = self.safeMessage(error, operation: .activities)
            }
        }
    }

    func cancelLoading() {
        let loadingGroups = isLoading
        let loadingPolicies = isPoliciesLoading
        let loadingActivities = isActivitiesLoading
        invalidateList()
        invalidateDetails()
        let message = "Loading cancelled. Use Refresh to try again."
        if loadingGroups { error = message }
        if loadingPolicies { policiesError = message }
        if loadingActivities { activitiesError = message }
    }

    func reset() {
        invalidateList()
        clearDetails()
        scope = nil
        groups = []
        restoringSelection = true
        selectedGroup = nil
        restoringSelection = false
        pendingSelectionARN = nil
        hasAttemptedLoad = false
        error = nil
        searchText = ""
    }

    func waitForLoading() async { await groupTask?.value }

    func waitForDetails() async {
        let policies = policyTask
        let activities = activityTask
        await policies?.value
        await activities?.value
    }

    private func isCurrentList(_ generation: Int, scope: MonitoringScope) -> Bool {
        listGeneration == generation && self.scope == scope
    }

    private func isCurrentDetail(_ generation: Int, scope: MonitoringScope, group: ASGGroup) -> Bool {
        detailGeneration == generation && self.scope == scope && selectedGroup == group && groups.contains(group)
    }

    private func invalidateList() {
        listGeneration += 1
        groupTask?.cancel()
        groupTask = nil
        isLoading = false
    }

    private func invalidateDetails() {
        detailGeneration += 1
        policyTask?.cancel()
        activityTask?.cancel()
        policyTask = nil
        activityTask = nil
        isPoliciesLoading = false
        isActivitiesLoading = false
    }

    private func clearDetails() {
        invalidateDetails()
        policies = []
        activities = []
        policiesError = nil
        activitiesError = nil
    }

    private enum Operation { case groups, policies, activities }

    private func safeMessage(_ error: Error, operation: Operation) -> String {
        if error is CancellationError { return "Loading cancelled. Use Refresh to try again." }
        if let error = error as? AutoScalingError { return error.localizedDescription }
        if let error = error as? AWSAutoScalingService.RequestError { return error.localizedDescription }
        switch operation {
        case .groups: return "Unable to load Auto Scaling groups. Refresh to try again."
        case .policies: return "Unable to load Auto Scaling policies. Refresh to try again."
        case .activities: return "Unable to load Auto Scaling activities. Refresh to try again."
        }
    }
}
