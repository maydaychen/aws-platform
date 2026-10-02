import Combine
import Foundation

/// A window's pending destination is separate from the app-wide saved list.
@MainActor
final class FavoriteNavigation: ObservableObject {
    @Published private(set) var target: ResourceFavorite?
    @Published private(set) var error: String?

    func begin(_ favorite: ResourceFavorite, profiles: [AWSProfile]) -> Bool {
        cancel()
        guard favorite.isValid else {
            error = "This favorite has an invalid destination."
            return false
        }
        guard profiles.contains(where: { $0.name == favorite.profileName }) else {
            error = "Profile \(favorite.profileName) is unavailable. Restore its AWS configuration and retry. The favorite is still saved."
            return false
        }
        target = favorite
        return true
    }

    func matches(profileName: String?, region: String) -> Bool {
        guard let target else { return true }
        return target.profileName == profileName && target.region == region
    }

    func verifyAccount(_ accountID: String) -> Bool {
        guard let target else { return false }
        guard target.accountID == accountID else {
            fail("Profile \(target.profileName) now resolves to account \(accountID), but this favorite belongs to \(target.accountID). It was not opened.")
            return false
        }
        return true
    }

    func finish(found: Bool, loadError: String?) {
        guard let target else { return }
        if let loadError {
            fail("Unable to open \(target.displayName): \(loadError) The favorite is still saved.")
        } else if !found {
            fail("\(target.displayName) was not found in the saved profile and region. It may have been removed or be inaccessible. The favorite is still saved.")
        } else {
            cancel()
        }
    }

    func resolve(ec2: EC2ViewModel, lambda: LambdaViewModel, s3: S3ViewModel) {
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
        }
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
