import SwiftUI

struct AutoScalingGroupHistoryView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: AutoScalingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DetailSectionTitle(title: "Scaling policy summaries")
            Text(L10n.text("Advanced metric and predictive configurations are not expanded.", locale: locale))
                .font(.caption).foregroundColor(.secondary)
            if vm.isPoliciesLoading { ProgressView(L10n.text("Loading scaling policies…", locale: locale)) }
            if let error = vm.policiesError { NoticeBanner(message: error) }
            if !vm.isPoliciesLoading, vm.policiesError == nil, vm.policies.isEmpty {
                Text(L10n.text("No scaling policies returned.", locale: locale)).foregroundColor(.secondary)
            }
            ForEach(vm.policies) { policy in policyFields(policy) }
            DetailSectionTitle(title: "Scaling activities (last six weeks)")
            if vm.isActivitiesLoading { ProgressView(L10n.text("Loading scaling activities…", locale: locale)) }
            if let error = vm.activitiesError { NoticeBanner(message: error) }
            if !vm.isActivitiesLoading, vm.activitiesError == nil, vm.activities.isEmpty {
                Text(L10n.text("No scaling activities returned in the last six weeks.", locale: locale)).foregroundColor(.secondary)
            }
            ForEach(vm.activities) { activity in
                DetailFieldRows(items: [("Activity ID", activity.activityID), ("Group ARN", value(activity.groupARN)),
                    ("Group state", value(activity.groupState)), ("Started", date(activity.startedAt)), ("Ended", date(activity.endedAt)),
                    ("Status", value(activity.statusCode)), ("Progress (%)", number(activity.progress)),
                    ("Description", value(activity.description)), ("Cause", value(activity.cause)),
                    ("Status message", value(activity.statusMessage)), ("Details", value(activity.details))])
            }
        }
    }

    private func policyFields(_ policy: ASGPolicy) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            DetailFieldRows(items: [("Policy name", policy.name), ("ARN", policy.arn), ("Policy type", value(policy.policyType)),
                ("Enabled", boolean(policy.enabled)), ("Adjustment type", value(policy.adjustmentType)),
                ("Scaling adjustment", number(policy.scalingAdjustment)), ("Minimum adjustment magnitude", number(policy.minAdjustmentMagnitude)),
                ("Cooldown (s)", number(policy.cooldown)), ("Estimated instance warmup (s)", number(policy.estimatedInstanceWarmup)),
                ("Metric aggregation type", value(policy.metricAggregationType)), ("Target value", policy.targetValue.map { String($0) } ?? missing),
                ("Target metric type", value(policy.targetMetricType)), ("Uses customized metric", boolean(policy.usesCustomizedMetric)),
                ("Disable scale in", boolean(policy.disableScaleIn)), ("Predictive mode", value(policy.predictiveMode))])
            ForEach(policy.stepAdjustments.indices, id: \.self) { index in
                let step = policy.stepAdjustments[index]
                DetailFieldRows(items: [("Metric interval lower bound", step.lowerBound.map { String($0) } ?? missing),
                    ("Metric interval upper bound", step.upperBound.map { String($0) } ?? missing),
                    ("Scaling adjustment", number(step.adjustment))])
            }
            ForEach(policy.alarms.indices, id: \.self) { index in
                let alarm = policy.alarms[index]
                DetailFieldRows(items: [("Alarm name", value(alarm.name)), ("Alarm ARN", value(alarm.arn))])
            }
        }
    }

    private var missing: String { L10n.text("Not returned", locale: locale) }
    private func value(_ text: String?) -> String { text.flatMap { $0.isEmpty ? nil : $0 } ?? missing }
    private func number(_ value: Int?) -> String { value.map(String.init) ?? missing }
    private func date(_ value: Date?) -> String {
        value.map { $0.formatted(.dateTime.year().month().day().hour().minute().locale(locale)) } ?? missing
    }
    private func boolean(_ value: Bool?) -> String {
        value.map { L10n.text($0 ? "Yes" : "No", locale: locale) } ?? L10n.text("Unknown", locale: locale)
    }
}
