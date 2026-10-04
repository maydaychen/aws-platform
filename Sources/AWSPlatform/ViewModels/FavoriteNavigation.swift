import Combine
import Foundation

/// A window's pending destination is separate from the app-wide saved list.
@MainActor
final class FavoriteNavigation: ObservableObject {
    enum Source {
        case favorite, recent

        var noun: String { self == .favorite ? "favorite" : "recent resource" }
        var listName: String { self == .favorite ? "Favorites" : "Recent" }
    }

    @Published private(set) var target: ResourceFavorite?
    @Published private(set) var error: String?
    private var source: Source = .favorite

    func begin(_ favorite: ResourceFavorite, profiles: [AWSProfile], selectedProfileName: String?, source: Source = .favorite) -> Bool {
        cancel()
        self.source = source
        guard favorite.isValid else {
            error = "This \(source.noun) has an invalid destination."
            return false
        }
        guard profiles.contains(where: { $0.name == favorite.profileName }) else {
            error = "Profile \(favorite.profileName) is unavailable. Restore its AWS configuration and retry. The \(source.noun) is still saved."
            return false
        }
        guard selectedProfileName == favorite.profileName else {
            error = "Select profile \(favorite.profileName) in its session first, then open this \(source.noun). No profile was selected automatically."
            return false
        }
        target = favorite
        return true
    }

    func matches(profileName: String?, region: String) -> Bool {
        guard let target else { return true }
        return target.profileName == profileName && (target.service == .route53 || target.region == region)
    }

    func verifyAccount(_ accountID: String) -> Bool {
        guard let target else { return false }
        guard target.accountID == accountID else {
            fail("Profile \(target.profileName) now resolves to account \(accountID), but this \(source.noun) belongs to \(target.accountID). It was not opened.")
            return false
        }
        return true
    }

    func finish(found: Bool, loadError: String?) {
        guard let target else { return }
        if let loadError {
            fail("Unable to open \(target.displayName): \(loadError) The \(source.noun) is still saved.")
        } else if !found {
            let location = target.service == .route53 ? "profile" : "profile and region"
            fail("\(target.displayName) was not found in the saved \(location). It may have been removed or be inaccessible. The \(source.noun) is still saved.")
        } else {
            cancel()
        }
    }

    func resolve(ec2: EC2ViewModel, lambda: LambdaViewModel, s3: S3ViewModel, alarms: AlarmViewModel, sns: SNSViewModel,
                 route53: Route53ViewModel? = nil) {
        guard let target else { return }
        switch target.service {
        case .ec2:
            ec2.searchText = ""
            ec2.stateFilter = "All"
            ec2.healthFilter = .all
            ec2.selectedInstance = ec2.instances.first { $0.instanceId == target.resourceID }
            finish(found: ec2.selectedInstance != nil, loadError: ec2.error)
        case .lambda:
            lambda.searchText = ""
            lambda.stateFilter = "All"
            lambda.packageFilter = "All"
            lambda.selectedFunction = lambda.functions.first { $0.functionName == target.resourceID }
            finish(found: lambda.selectedFunction != nil, loadError: lambda.error)
        case .s3:
            s3.bucketSearchText = ""
            s3.objectSearchText = ""
            let bucket = s3.buckets.first { $0.name == target.resourceID }
            if let bucket {
                s3.selectBucket(bucket)
            } else {
                s3.selectedBucket = nil
            }
            finish(found: bucket != nil, loadError: s3.error)
        case .alarms:
            alarms.searchText = ""
            alarms.stateFilter = "All"
            alarms.kindFilter = nil
            alarms.selectedAlarm = alarms.alarms.first { $0.arn == target.resourceID }
            finish(found: alarms.selectedAlarm != nil, loadError: alarms.error)
        case .sns:
            sns.searchText = ""
            sns.kindFilter = nil
            sns.selectedTopic = sns.topics.first { $0.arn == target.resourceID }
            finish(found: sns.selectedTopic != nil, loadError: sns.error)
        case .route53:
            route53?.searchText = ""
            route53?.privateFilter = nil
            guard let route53, route53.error == nil else {
                route53?.selectedZone = nil
                finish(found: false, loadError: route53?.error)
                return
            }
            route53.selectedZone = route53.zones.first { $0.id == target.resourceID }
            finish(found: route53.selectedZone != nil, loadError: nil)
        }
    }

    func failConnection() {
        fail("The \(source.noun) could not be opened. Resolve the connection error, then open it again from \(source.listName).")
    }

    func fail(_ message: String) {
        target = nil
        error = message
    }

    func cancel() {
        target = nil
        error = nil
    }
}
