import Foundation

/// Ephemeral SNS relationship navigation, independent of saved favorites.
@MainActor
final class SNSRelatedResourceNavigation: ObservableObject {
    @Published private(set) var target: SNSRelatedResource?
    @Published private(set) var error: String?

    private var task: Task<Void, Never>?
    private var generation = 0
    private var cancelLoad: (() -> Void)?

    @discardableResult
    func open(
        _ resource: SNSRelatedResource, currentScope: SNSScope?,
        latestScope: @escaping @MainActor () -> SNSScope?,
        alarms: AlarmViewModel, lambda: LambdaViewModel
    ) -> Bool {
        cancel()
        guard resource.isValid(in: currentScope), resource.isValid(in: latestScope()) else {
            error = "The selected profile, identity or region has changed. Open the relationship again in its original scope."
            return false
        }
        if resource.service == .alarms, alarms.scope != resource.scope.alarmScope {
            error = "CloudWatch is not configured for this relationship's profile and region."
            return false
        }
        target = resource
        let request = generation
        switch resource.service {
        case .alarms: alarms.selectedAlarm = nil
        case .lambda: lambda.selectedFunction = nil
        default: return false
        }
        task = Task {
            guard !Task.isCancelled, generation == request, target == resource else { return }
            guard resource.isValid(in: latestScope()) else {
                fail("The selected profile, identity or region changed before the resource could be opened.")
                return
            }
            switch resource.service {
            case .alarms:
                if alarms.error != nil || !alarms.alarms.contains(where: { $0.arn == resource.arn }) {
                    cancelLoad = { alarms.cancelLoading() }
                    await alarms.loadAlarms()
                }
            case .lambda:
                if lambda.error != nil || !lambda.functions.contains(where: { Self.matches($0, resource) }) {
                    cancelLoad = { lambda.cancelLoading() }
                    await lambda.loadFunctions(selectFirstIfNeeded: false)
                }
            default: break
            }
            guard !Task.isCancelled, generation == request, target == resource else { return }
            cancelLoad = nil
            guard resource.isValid(in: latestScope()) else {
                fail("The selected profile, identity or region changed before the resource could be opened.")
                return
            }
            switch resource.service {
            case .alarms:
                guard alarms.scope == resource.scope.alarmScope, alarms.error == nil else {
                    fail("Unable to load the related alarm. Check CloudWatch access and retry.")
                    return
                }
                guard let alarm = alarms.alarms.first(where: { $0.arn == resource.arn }) else {
                    fail("The related alarm was not found in the current profile and region. It may have been removed or be inaccessible.")
                    return
                }
                alarms.searchText = ""
                alarms.stateFilter = "All"
                alarms.kindFilter = nil
                alarms.selectedAlarm = alarm
            case .lambda:
                guard lambda.error == nil else {
                    fail("Unable to load the related function. Check Lambda access and retry.")
                    return
                }
                guard let function = lambda.functions.first(where: { Self.matches($0, resource) }) else {
                    fail("The related function was not found in the current profile and region. It may have been removed or be inaccessible.")
                    return
                }
                lambda.searchText = ""
                lambda.stateFilter = "All"
                lambda.packageFilter = "All"
                lambda.selectedFunction = function
            default: break
            }
            target = nil
            task = nil
        }
        return true
    }

    func waitForNavigation() async { await task?.value }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        cancelLoad?()
        cancelLoad = nil
        target = nil
        error = nil
    }

    private func fail(_ message: String) {
        target = nil
        task = nil
        error = message
    }

    private static func matches(_ function: LambdaFunctionModel, _ resource: SNSRelatedResource) -> Bool {
        guard function.functionName == resource.resourceID, let arn = function.arn,
              let destination = SNSRelatedResource(scope: resource.scope, service: .lambda, arn: arn),
              destination.qualifier == nil else { return false }
        return destination.resourceID == resource.resourceID
    }
}
