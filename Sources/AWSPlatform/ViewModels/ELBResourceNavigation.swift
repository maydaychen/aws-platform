import Foundation

/// Opens an explicitly chosen configuration relationship in its verified scope.
@MainActor
final class ELBResourceNavigation: ObservableObject {
    @Published private(set) var target: ELBResourceReference?
    @Published private(set) var error: String?

    private var task: Task<Void, Never>?
    private var generation = 0

    @discardableResult
    func open(
        _ reference: ELBResourceReference, currentScope: MonitoringScope?,
        latestScope: @escaping @MainActor () -> MonitoringScope?,
        elb: ELBViewModel, ec2: EC2ViewModel, lambda: LambdaViewModel
    ) -> Bool {
        cancel()
        guard reference.isValid(in: currentScope), reference.isValid(in: latestScope()) else {
            error = "The selected profile, identity or region has changed. Open the relationship again in its original scope."
            return false
        }
        if Self.requiresELB(reference), elb.scope != reference.scope {
            error = "Load balancing is not configured for this relationship's profile and region."
            return false
        }

        let reloadList: Bool
        switch reference.service {
        case .loadBalancers:
            reloadList = false
            elb.selectedLoadBalancer = nil
        case .targetGroups:
            reloadList = false
            elb.selectedTargetGroup = nil
        case .ec2:
            reloadList = ec2.isLoading
            ec2.cancelLoading()
            ec2.selectedInstance = nil
        case .lambda:
            reloadList = lambda.isLoading
            lambda.cancelLoading()
            lambda.selectedFunction = nil
        default:
            error = "This target type does not support resource navigation."
            return false
        }
        target = reference
        let request = generation
        task = Task {
            guard isCurrent(reference, request: request) else { return }
            guard reference.isValid(in: latestScope()),
                  !Self.requiresELB(reference) || elb.scope == reference.scope else {
                failScopeChange()
                return
            }

            switch reference.service {
            case .loadBalancers:
                if elb.isLoadBalancersLoading {
                    await elb.waitForLoadBalancers()
                } else if elb.loadBalancersError != nil || elb.isLoadBalancersStale
                            || !elb.loadBalancers.contains(where: { $0.arn == reference.resourceID }) {
                    await elb.loadLoadBalancers()
                }
            case .targetGroups:
                if elb.isTargetGroupsLoading {
                    await elb.waitForTargetGroups()
                } else if elb.targetGroupsError != nil || elb.isTargetGroupsStale
                            || !elb.targetGroups.contains(where: { $0.arn == reference.resourceID }) {
                    await elb.loadTargetGroups()
                }
            case .ec2:
                if reloadList || ec2.error != nil || !ec2.instances.contains(where: { $0.instanceId == reference.resourceID }) {
                    await ec2.loadInstances(selectFirstIfNeeded: false)
                }
            case .lambda:
                if reloadList || lambda.error != nil || !lambda.functions.contains(where: { Self.matches($0, reference) }) {
                    await lambda.loadFunctions(selectFirstIfNeeded: false)
                }
            default: return
            }

            guard isCurrent(reference, request: request) else { return }
            guard reference.isValid(in: latestScope()),
                  !Self.requiresELB(reference) || elb.scope == reference.scope else {
                failScopeChange()
                return
            }
            switch reference.service {
            case .loadBalancers:
                guard elb.loadBalancersError == nil, !elb.isLoadBalancersStale, !elb.isLoadBalancersLoading else {
                    fail("Unable to load the related load balancer. Check load balancing access and retry.")
                    return
                }
                guard let row = elb.loadBalancers.first(where: { $0.arn == reference.resourceID }) else {
                    failMissing("load balancer")
                    return
                }
                elb.searchText = ""
                elb.kindFilter = "All"
                elb.selectedLoadBalancer = row
            case .targetGroups:
                guard elb.targetGroupsError == nil, !elb.isTargetGroupsStale, !elb.isTargetGroupsLoading else {
                    fail("Unable to load the related target group. Check load balancing access and retry.")
                    return
                }
                guard let row = elb.targetGroups.first(where: { $0.arn == reference.resourceID }) else {
                    failMissing("target group")
                    return
                }
                elb.groupSearchText = ""
                elb.targetTypeFilter = "All"
                elb.selectedTargetGroup = row
            case .ec2:
                guard ec2.error == nil, !ec2.isLoading else {
                    fail("Unable to load the related instance. Check EC2 access and retry.")
                    return
                }
                guard let row = ec2.instances.first(where: { $0.instanceId == reference.resourceID }) else {
                    failMissing("instance")
                    return
                }
                ec2.searchText = ""
                ec2.stateFilter = "All"
                ec2.healthFilter = .all
                ec2.selectedInstance = row
            case .lambda:
                guard lambda.error == nil, !lambda.isLoading else {
                    fail("Unable to load the related function. Check Lambda access and retry.")
                    return
                }
                guard let row = lambda.functions.first(where: { Self.matches($0, reference) }) else {
                    failMissing("function")
                    return
                }
                lambda.searchText = ""
                lambda.stateFilter = "All"
                lambda.packageFilter = "All"
                lambda.selectedFunction = row
            default: return
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
        target = nil
        error = nil
    }

    private func isCurrent(_ reference: ELBResourceReference, request: Int) -> Bool {
        !Task.isCancelled && generation == request && target == reference
    }

    private func fail(_ message: String) {
        target = nil
        task = nil
        error = message
    }

    private func failScopeChange() {
        fail("The selected profile, identity or region changed before the resource could be opened.")
    }

    private func failMissing(_ resource: String) {
        fail("The related \(resource) was not found in the current profile and region. It may have been removed or be inaccessible.")
    }

    private static func requiresELB(_ reference: ELBResourceReference) -> Bool {
        reference.service == .loadBalancers || reference.service == .targetGroups
    }

    private static func matches(_ function: LambdaFunctionModel, _ reference: ELBResourceReference) -> Bool {
        let baseARN = reference.qualifier == nil
            ? reference.resourceID
            : reference.resourceID.split(separator: ":").dropLast().joined(separator: ":")
        guard let arn = function.arn, arn == baseARN,
              let validated = ELBResourceReference(scope: reference.scope, service: .lambda,
                                                   resourceID: arn, name: function.functionName),
              validated.qualifier == nil else { return false }
        return function.functionName == arn.split(separator: ":").last.map(String.init)
    }
}
