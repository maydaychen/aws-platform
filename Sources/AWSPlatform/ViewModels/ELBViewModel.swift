import Foundation

@MainActor
final class ELBViewModel: ObservableObject {
    typealias LoadBalancerLoader = @Sendable (MonitoringScope) async throws -> [ELBLoadBalancer]
    typealias TargetGroupLoader = @Sendable (MonitoringScope) async throws -> [ELBTargetGroup]
    typealias ListenerLoader = @Sendable (MonitoringScope, ELBLoadBalancer) async throws -> [ELBListener]
    typealias RuleLoader = @Sendable (MonitoringScope, ELBListener) async throws -> [ELBRule]
    typealias HealthLoader = @Sendable (MonitoringScope, ELBTargetGroup) async throws -> [ELBTargetHealth]

    @Published private(set) var scope: MonitoringScope?
    @Published private(set) var loadBalancers: [ELBLoadBalancer] = []
    @Published private(set) var targetGroups: [ELBTargetGroup] = []
    @Published private(set) var listeners: [ELBListener] = []
    @Published private(set) var rules: [ELBRule] = []
    @Published private(set) var targets: [ELBTargetHealth] = []
    @Published private(set) var isLoadBalancersLoading = false
    @Published private(set) var loadBalancersError: String?
    @Published private(set) var isLoadBalancersStale = false
    @Published private(set) var isTargetGroupsLoading = false
    @Published private(set) var targetGroupsError: String?
    @Published private(set) var isTargetGroupsStale = false
    @Published private(set) var isListenersLoading = false
    @Published private(set) var listenersError: String?
    @Published private(set) var isRulesLoading = false
    @Published private(set) var rulesError: String?
    @Published private(set) var isTargetsLoading = false
    @Published private(set) var targetsError: String?
    @Published var selectedLoadBalancer: ELBLoadBalancer? {
        didSet {
            if let selectedLoadBalancer, !loadBalancers.contains(selectedLoadBalancer) { self.selectedLoadBalancer = nil }
            guard oldValue?.arn != selectedLoadBalancer?.arn else { return }
            refreshListeners()
        }
    }
    @Published var selectedTargetGroup: ELBTargetGroup? {
        didSet {
            if let selectedTargetGroup, !targetGroups.contains(selectedTargetGroup) { self.selectedTargetGroup = nil }
            guard oldValue?.arn != selectedTargetGroup?.arn else { return }
            refreshTargets()
        }
    }
    @Published var selectedListener: ELBListener? {
        didSet {
            if let selectedListener,
               !listeners.contains(selectedListener) || selectedListener.loadBalancerARN != selectedLoadBalancer?.arn {
                self.selectedListener = nil
            }
            guard oldValue?.arn != selectedListener?.arn else { return }
            refreshRules()
        }
    }
    @Published var searchText = ""
    @Published var kindFilter = "All"
    @Published var groupSearchText = ""
    @Published var targetTypeFilter = "All"

    private let loadBalancerLoader: LoadBalancerLoader
    private let targetGroupLoader: TargetGroupLoader
    private let listenerLoader: ListenerLoader
    private let ruleLoader: RuleLoader
    private let healthLoader: HealthLoader
    private var loadBalancerTask: Task<Void, Never>?
    private var targetGroupTask: Task<Void, Never>?
    private var listenerTask: Task<Void, Never>?
    private var ruleTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var loadBalancerGeneration = 0
    private var targetGroupGeneration = 0
    private var listenerGeneration = 0
    private var ruleGeneration = 0
    private var healthGeneration = 0
    private var attemptedLoadBalancers = false
    private var attemptedTargetGroups = false
    private var loadedLoadBalancers = false
    private var loadedTargetGroups = false

    init(loadBalancerLoader: @escaping LoadBalancerLoader, targetGroupLoader: @escaping TargetGroupLoader,
         listenerLoader: @escaping ListenerLoader, ruleLoader: @escaping RuleLoader, healthLoader: @escaping HealthLoader) {
        self.loadBalancerLoader = loadBalancerLoader
        self.targetGroupLoader = targetGroupLoader
        self.listenerLoader = listenerLoader
        self.ruleLoader = ruleLoader
        self.healthLoader = healthLoader
    }

    var availableKinds: [String] { ["All"] + Set(loadBalancers.map(\.kind)).sorted() }
    var availableTargetTypes: [String] { ["All"] + Set(targetGroups.map(\.targetType)).sorted() }
    var filteredLoadBalancers: [ELBLoadBalancer] {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return loadBalancers.filter { item in
            guard kindFilter == "All" || item.kind.caseInsensitiveCompare(kindFilter) == .orderedSame else { return false }
            let text = [item.arn, item.name, item.kind] + [item.dnsName, item.scheme, item.state].compactMap { $0 }
                + item.fields.flatMap { [$0.name, $0.value] }
            return search.isEmpty || text.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }
    var filteredTargetGroups: [ELBTargetGroup] {
        let search = groupSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return targetGroups.filter { item in
            guard targetTypeFilter == "All" || item.targetType.caseInsensitiveCompare(targetTypeFilter) == .orderedSame else { return false }
            let text = [item.arn, item.name, item.targetType] + [item.protocolName, item.port.map(String.init)].compactMap { $0 }
                + item.loadBalancerARNs + item.fields.flatMap { [$0.name, $0.value] }
            return search.isEmpty || text.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    func configure(scope: MonitoringScope?) {
        guard self.scope != scope else { return }
        reset()
        self.scope = scope
    }

    func loadLoadBalancersIfNeeded() { if !attemptedLoadBalancers { refreshLoadBalancers() } }
    func loadTargetGroupsIfNeeded() { if !attemptedTargetGroups { refreshTargetGroups() } }
    func loadLoadBalancers() async {
        guard !Task.isCancelled else { return }
        if isLoadBalancersLoading {
            await loadBalancerTask?.value
            return
        }
        refreshLoadBalancers()
        let generation = loadBalancerGeneration
        let task = loadBalancerTask
        await withTaskCancellationHandler {
            await task?.value
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.loadBalancerGeneration == generation else { return }
                self.cancelLoadBalancers()
            }
        }
    }
    func loadTargetGroups() async {
        guard !Task.isCancelled else { return }
        if isTargetGroupsLoading {
            await targetGroupTask?.value
            return
        }
        refreshTargetGroups()
        let generation = targetGroupGeneration
        let task = targetGroupTask
        await withTaskCancellationHandler {
            await task?.value
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.targetGroupGeneration == generation else { return }
                self.cancelTargetGroups()
            }
        }
    }
    func waitForLoadBalancers() async { await loadBalancerTask?.value }
    func waitForTargetGroups() async { await targetGroupTask?.value }
    func waitForDetails() async {
        let listener = listenerTask
        let health = healthTask
        await listener?.value
        let rule = ruleTask
        await rule?.value
        await health?.value
    }

    func refreshLoadBalancers() {
        guard let scope else { return }
        loadBalancerGeneration += 1
        let generation = loadBalancerGeneration
        loadBalancerTask?.cancel()
        loadBalancerTask = nil
        attemptedLoadBalancers = true
        guard scope.isValid else {
            isLoadBalancersLoading = false
            loadBalancersError = ELBError.invalidScope.localizedDescription
            return
        }
        isLoadBalancersLoading = true
        loadBalancersError = nil
        let loader = loadBalancerLoader
        loadBalancerTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let rows = try await loader(scope)
                try Task.checkCancellation()
                guard let self, self.scope == scope, self.loadBalancerGeneration == generation else { return }
                guard rows.allSatisfy({ ELBARN.isLoadBalancer($0.arn, scope: scope) }), Set(rows.map(\.arn)).count == rows.count else {
                    throw ELBError.invalidResponse
                }
                let selectedARN = self.selectedLoadBalancer?.arn
                self.loadBalancers = rows
                self.selectedLoadBalancer = selectedARN.flatMap { arn in rows.first { $0.arn == arn } }
                if self.selectedLoadBalancer != nil { self.refreshListeners() }
                self.isLoadBalancersLoading = false
                self.isLoadBalancersStale = false
                self.loadedLoadBalancers = true
                self.loadBalancerTask = nil
                if !self.availableKinds.contains(self.kindFilter) { self.kindFilter = "All" }
            } catch {
                guard let self, self.scope == scope, self.loadBalancerGeneration == generation else { return }
                self.isLoadBalancersLoading = false
                self.isLoadBalancersStale = self.loadedLoadBalancers
                self.loadBalancerTask = nil
                self.loadBalancersError = self.listMessage(error, stale: self.isLoadBalancersStale)
            }
        }
    }

    func refreshTargetGroups() {
        guard let scope else { return }
        targetGroupGeneration += 1
        let generation = targetGroupGeneration
        targetGroupTask?.cancel()
        targetGroupTask = nil
        attemptedTargetGroups = true
        guard scope.isValid else {
            isTargetGroupsLoading = false
            targetGroupsError = ELBError.invalidScope.localizedDescription
            return
        }
        isTargetGroupsLoading = true
        targetGroupsError = nil
        let loader = targetGroupLoader
        targetGroupTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let rows = try await loader(scope)
                try Task.checkCancellation()
                guard let self, self.scope == scope, self.targetGroupGeneration == generation else { return }
                guard rows.allSatisfy({ ELBARN.isTargetGroup($0.arn, scope: scope) }), Set(rows.map(\.arn)).count == rows.count else {
                    throw ELBError.invalidResponse
                }
                let selectedARN = self.selectedTargetGroup?.arn
                self.targetGroups = rows
                self.selectedTargetGroup = selectedARN.flatMap { arn in rows.first { $0.arn == arn } }
                if self.selectedTargetGroup != nil { self.refreshTargets() }
                self.isTargetGroupsLoading = false
                self.isTargetGroupsStale = false
                self.loadedTargetGroups = true
                self.targetGroupTask = nil
                if !self.availableTargetTypes.contains(self.targetTypeFilter) { self.targetTypeFilter = "All" }
            } catch {
                guard let self, self.scope == scope, self.targetGroupGeneration == generation else { return }
                self.isTargetGroupsLoading = false
                self.isTargetGroupsStale = self.loadedTargetGroups
                self.targetGroupTask = nil
                self.targetGroupsError = self.listMessage(error, stale: self.isTargetGroupsStale)
            }
        }
    }

    func refreshListeners() {
        let selectedARN = selectedListener?.arn
        clearListeners()
        guard let scope, scope.isValid, let parent = selectedLoadBalancer, loadBalancers.contains(parent),
              ELBARN.isLoadBalancer(parent.arn, scope: scope) else { return }
        let generation = listenerGeneration
        let loader = listenerLoader
        isListenersLoading = true
        listenerTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let rows = try await loader(scope, parent)
                try Task.checkCancellation()
                guard let self, self.scope == scope, self.listenerGeneration == generation,
                      self.selectedLoadBalancer?.arn == parent.arn else { return }
                guard rows.allSatisfy({ self.validListener($0, parent: parent, scope: scope) }), Set(rows.map(\.arn)).count == rows.count else {
                    throw ELBError.invalidResponse
                }
                self.listeners = rows
                self.selectedListener = selectedARN.flatMap { arn in rows.first { $0.arn == arn } }
                self.isListenersLoading = false
                self.listenerTask = nil
            } catch {
                guard let self, self.scope == scope, self.listenerGeneration == generation,
                      self.selectedLoadBalancer?.arn == parent.arn else { return }
                self.isListenersLoading = false
                self.listenerTask = nil
                self.listenersError = self.safeMessage(error)
            }
        }
    }

    func refreshRules() {
        clearRules()
        guard let scope, scope.isValid, let parent = selectedLoadBalancer, let listener = selectedListener,
              listeners.contains(listener), validListener(listener, parent: parent, scope: scope), listener.supportsRules else { return }
        let generation = ruleGeneration
        let loader = ruleLoader
        isRulesLoading = true
        ruleTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let rows = try await loader(scope, listener)
                try Task.checkCancellation()
                guard let self, self.scope == scope, self.ruleGeneration == generation,
                      self.selectedListener?.arn == listener.arn, self.selectedLoadBalancer?.arn == parent.arn else { return }
                guard rows.allSatisfy({ self.validRule($0, listener: listener, scope: scope) }), Set(rows.map(\.arn)).count == rows.count else {
                    throw ELBError.invalidResponse
                }
                self.rules = rows
                self.isRulesLoading = false
                self.ruleTask = nil
            } catch {
                guard let self, self.scope == scope, self.ruleGeneration == generation,
                      self.selectedListener?.arn == listener.arn, self.selectedLoadBalancer?.arn == parent.arn else { return }
                self.isRulesLoading = false
                self.ruleTask = nil
                self.rulesError = self.safeMessage(error)
            }
        }
    }

    func refreshTargets() {
        clearTargets()
        guard let scope, scope.isValid, let group = selectedTargetGroup, targetGroups.contains(group),
              ELBARN.isTargetGroup(group.arn, scope: scope) else { return }
        let generation = healthGeneration
        let loader = healthLoader
        isTargetsLoading = true
        healthTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let rows = try await loader(scope, group)
                try Task.checkCancellation()
                guard let self, self.scope == scope, self.healthGeneration == generation,
                      self.selectedTargetGroup?.arn == group.arn else { return }
                self.targets = rows
                self.isTargetsLoading = false
                self.healthTask = nil
            } catch {
                guard let self, self.scope == scope, self.healthGeneration == generation,
                      self.selectedTargetGroup?.arn == group.arn else { return }
                self.isTargetsLoading = false
                self.healthTask = nil
                self.targetsError = self.safeMessage(error)
            }
        }
    }

    func cancelLoadBalancers() {
        guard isLoadBalancersLoading else { return }
        loadBalancerGeneration += 1
        loadBalancerTask?.cancel()
        loadBalancerTask = nil
        isLoadBalancersLoading = false
        isLoadBalancersStale = loadedLoadBalancers
        loadBalancersError = listMessage(CancellationError(), stale: isLoadBalancersStale)
    }

    func cancelTargetGroups() {
        guard isTargetGroupsLoading else { return }
        targetGroupGeneration += 1
        targetGroupTask?.cancel()
        targetGroupTask = nil
        isTargetGroupsLoading = false
        isTargetGroupsStale = loadedTargetGroups
        targetGroupsError = listMessage(CancellationError(), stale: isTargetGroupsStale)
    }

    func cancelDetails() {
        listenerGeneration += 1
        ruleGeneration += 1
        healthGeneration += 1
        listenerTask?.cancel()
        ruleTask?.cancel()
        healthTask?.cancel()
        listenerTask = nil
        ruleTask = nil
        healthTask = nil
        if isListenersLoading { listenersError = safeMessage(CancellationError()) }
        if isRulesLoading { rulesError = safeMessage(CancellationError()) }
        if isTargetsLoading { targetsError = safeMessage(CancellationError()) }
        isListenersLoading = false
        isRulesLoading = false
        isTargetsLoading = false
    }

    func reset() {
        loadBalancerGeneration += 1
        targetGroupGeneration += 1
        loadBalancerTask?.cancel()
        targetGroupTask?.cancel()
        loadBalancerTask = nil
        targetGroupTask = nil
        scope = nil
        loadBalancers = []
        targetGroups = []
        selectedLoadBalancer = nil
        selectedTargetGroup = nil
        clearListeners()
        clearTargets()
        isLoadBalancersLoading = false
        isTargetGroupsLoading = false
        loadBalancersError = nil
        targetGroupsError = nil
        isLoadBalancersStale = false
        isTargetGroupsStale = false
        attemptedLoadBalancers = false
        attemptedTargetGroups = false
        loadedLoadBalancers = false
        loadedTargetGroups = false
        searchText = ""
        groupSearchText = ""
        kindFilter = "All"
        targetTypeFilter = "All"
    }

    private func clearListeners() {
        listenerGeneration += 1
        listenerTask?.cancel()
        listenerTask = nil
        listeners = []
        selectedListener = nil
        clearRules()
        isListenersLoading = false
        listenersError = nil
    }
    private func clearRules() {
        ruleGeneration += 1
        ruleTask?.cancel()
        ruleTask = nil
        rules = []
        isRulesLoading = false
        rulesError = nil
    }
    private func clearTargets() {
        healthGeneration += 1
        healthTask?.cancel()
        healthTask = nil
        targets = []
        isTargetsLoading = false
        targetsError = nil
    }
    private func validListener(_ listener: ELBListener, parent: ELBLoadBalancer, scope: MonitoringScope) -> Bool {
        guard listener.loadBalancerARN == parent.arn,
              let resource = ELBARN.resource(listener.arn, scope: scope),
              let parentResource = ELBARN.resource(parent.arn, scope: scope) else { return false }
        let parts = resource.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 5 && parts.allSatisfy { !$0.isEmpty }
            && resource.hasPrefix("listener/" + parentResource.dropFirst("loadbalancer/".count) + "/")
    }
    private func validRule(_ rule: ELBRule, listener: ELBListener, scope: MonitoringScope) -> Bool {
        guard let resource = ELBARN.resource(rule.arn, scope: scope),
              let listenerResource = ELBARN.resource(listener.arn, scope: scope) else { return false }
        let parts = resource.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 6 && parts.allSatisfy { !$0.isEmpty }
            && resource.hasPrefix("listener-rule/" + listenerResource.dropFirst("listener/".count) + "/")
    }
    private func listMessage(_ error: Error, stale: Bool) -> String {
        let message = safeMessage(error)
        return stale ? "\(message) Showing the previous list; it may be out of date." : message
    }
    private func safeMessage(_ error: Error) -> String {
        if error is CancellationError { return "Loading cancelled. Refresh to try again." }
        if let error = error as? ELBError { return error.localizedDescription }
        if let error = error as? AWSELBService.RequestError { return error.localizedDescription }
        return "Unable to load load balancing data. Refresh to try again."
    }
}
