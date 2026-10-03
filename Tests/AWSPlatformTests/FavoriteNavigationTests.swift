import XCTest
@testable import AWSPlatform

@MainActor
final class FavoriteNavigationTests: XCTestCase {
    private var profiles: [AWSProfile] {
        [AWSProfile(name: "work", region: "us-east-1", ssoStartURL: nil,
                    ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil)]
    }

    func testFavoriteCannotChooseAProfileWhenNoneOrAnotherIsSelected() {
        let navigation = FavoriteNavigation()
        for selected in [nil, "other"] as [String?] {
            XCTAssertFalse(navigation.begin(FavoritesViewModelTests.makeFavorite(), profiles: profiles,
                                             selectedProfileName: selected))
            XCTAssertNil(navigation.target)
            XCTAssertTrue(navigation.error?.contains("Select profile work") == true)
        }
    }

    func testMissingProfileFailsWithoutStartingNavigation() {
        let navigation = FavoriteNavigation()
        XCTAssertFalse(navigation.begin(FavoritesViewModelTests.makeFavorite(profile: "missing"), profiles: profiles, selectedProfileName: "work"))
        XCTAssertNil(navigation.target)
        XCTAssertNotNil(navigation.error)
    }

    func testAccountMismatchPreventsOpeningAndNewDestinationClearsFailure() {
        let navigation = FavoriteNavigation()
        let favorite = FavoritesViewModelTests.makeFavorite()
        XCTAssertTrue(navigation.begin(favorite, profiles: profiles, selectedProfileName: "work"))
        XCTAssertFalse(navigation.verifyAccount("222222222222"))
        XCTAssertNil(navigation.target)
        XCTAssertNotNil(navigation.error)
        XCTAssertTrue(navigation.begin(favorite, profiles: profiles, selectedProfileName: "work"))
        XCTAssertTrue(navigation.verifyAccount(favorite.accountID))
        XCTAssertNil(navigation.error)
    }

    func testDestinationIncludesSavedRegionAndCanBeCancelled() {
        let navigation = FavoriteNavigation()
        let favorite = FavoritesViewModelTests.makeFavorite(region: "eu-central-2")
        XCTAssertTrue(navigation.begin(favorite, profiles: profiles, selectedProfileName: "work"))
        XCTAssertTrue(navigation.matches(profileName: "work", region: "eu-central-2"))
        XCTAssertFalse(navigation.matches(profileName: "work", region: "us-east-1"))
        XCTAssertFalse(navigation.matches(profileName: "other", region: "eu-central-2"))
        navigation.cancel()
        XCTAssertNil(navigation.target)
        XCTAssertNil(navigation.error)
    }

    func testEC2FavoriteResolvesByIDAndClearsFilters() {
        let ec2 = EC2ViewModel()
        let lambda = LambdaViewModel()
        let s3 = S3ViewModel()
        let instance = EC2InstanceModel(
            instanceId: "i-example", name: "Renamed instance", instanceType: "t3.micro", state: "running",
            privateIP: nil, publicIP: nil, platformDetails: nil, architecture: nil,
            vpcId: nil, subnetId: nil, availabilityZone: nil, securityGroups: [],
            imageId: nil, imageName: nil, keyName: nil, launchTime: nil, tags: [:]
        )
        ec2.instances = [instance]
        ec2.searchText = "hidden"
        ec2.stateFilter = "stopped"
        ec2.healthFilter = .attention
        let navigation = FavoriteNavigation()
        _ = navigation.begin(FavoritesViewModelTests.makeFavorite(), profiles: profiles, selectedProfileName: "work")
        navigation.resolve(ec2: ec2, lambda: lambda, s3: s3)
        XCTAssertEqual(ec2.selectedInstance?.instanceId, instance.instanceId)
        XCTAssertEqual(ec2.filteredInstances, [instance])
        XCTAssertNil(navigation.target)
        XCTAssertNil(navigation.error)
    }

    func testLambdaFavoriteResolvesAndClearsFilters() {
        let lambda = LambdaViewModel()
        let function = LambdaFunctionModel(
            functionName: "handler", runtime: nil, state: "Active", lastUpdateStatus: nil,
            lastModified: nil, memorySize: nil, arn: nil, handler: nil, role: nil,
            codeSize: nil, timeout: nil, environment: [:], vpcConfig: nil,
            packageType: "Zip", imageUri: nil, tags: [:], codeLocation: nil, codeFiles: []
        )
        lambda.functions = [function]
        lambda.searchText = "hidden"
        lambda.stateFilter = "Failed"
        lambda.packageFilter = "Image"
        let navigation = FavoriteNavigation()
        _ = navigation.begin(FavoritesViewModelTests.makeFavorite(service: .lambda, resourceID: "handler"), profiles: profiles, selectedProfileName: "work")
        navigation.resolve(ec2: EC2ViewModel(), lambda: lambda, s3: S3ViewModel())
        XCTAssertEqual(lambda.selectedFunction, function)
        XCTAssertEqual(lambda.filteredFunctions, [function])
        XCTAssertNil(navigation.error)
    }

    func testS3FavoriteResolvesAndClearsSearch() {
        let s3 = S3ViewModel()
        let bucket = S3BucketModel(name: "example-bucket", region: "eu-west-1", creationDate: nil,
                                   versioningEnabled: nil, encryptionEnabled: nil, publicAccessBlock: nil,
                                   tags: [:], detailError: nil)
        s3.buckets = [bucket]
        s3.bucketSearchText = "hidden"
        s3.objectSearchText = "hidden"
        let navigation = FavoriteNavigation()
        _ = navigation.begin(FavoritesViewModelTests.makeFavorite(service: .s3, resourceID: bucket.name), profiles: profiles, selectedProfileName: "work")
        navigation.resolve(ec2: EC2ViewModel(), lambda: LambdaViewModel(), s3: s3)
        XCTAssertEqual(s3.selectedBucket, bucket)
        XCTAssertEqual(s3.filteredBuckets, [bucket])
        XCTAssertEqual(s3.objectSearchText, "")
    }

    func testUnavailableResourceKeepsSavedFavoriteAndReportsFailure() throws {
        let suite = "FavoriteNavigationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FavoritesViewModel(defaults: defaults)
        let favorite = FavoritesViewModelTests.makeFavorite()
        store.toggle(favorite)
        let navigation = FavoriteNavigation()
        _ = navigation.begin(favorite, profiles: profiles, selectedProfileName: "work")
        navigation.resolve(ec2: EC2ViewModel(), lambda: LambdaViewModel(), s3: S3ViewModel())
        XCTAssertNotNil(navigation.error)
        XCTAssertTrue(store.contains(favorite))
        _ = navigation.begin(favorite, profiles: profiles, selectedProfileName: "work")
        navigation.finish(found: false, loadError: "Permission denied")
        XCTAssertTrue(navigation.error?.contains("Permission denied") == true)
        XCTAssertTrue(store.contains(favorite))
    }
}
