import XCTest
@testable import AWSPlatform

@MainActor
final class FavoriteNavigationTests: XCTestCase {
    func testRecentResourceCannotSelectProfileAndRejectsChangedAccount() {
        let resource = FavoritesViewModelTests.makeFavorite()
        let navigation = FavoriteNavigation()
        for selected in [nil, "other"] as [String?] {
            XCTAssertFalse(navigation.begin(resource, profiles: profiles, selectedProfileName: selected, source: .recent))
            XCTAssertNil(navigation.target)
            XCTAssertTrue(navigation.error?.contains("recent resource") == true)
            XCTAssertTrue(navigation.error?.contains("No profile was selected automatically") == true)
        }
        XCTAssertFalse(navigation.begin(resource, profiles: [], selectedProfileName: "work", source: .recent))
        XCTAssertTrue(navigation.error?.contains("still saved") == true)
        XCTAssertTrue(navigation.begin(resource, profiles: profiles, selectedProfileName: "work", source: .recent))
        XCTAssertFalse(navigation.verifyAccount("222222222222"))
        XCTAssertNil(navigation.target)
        XCTAssertTrue(navigation.error?.contains("recent resource belongs to") == true)
    }

    func testRecentResourceFailuresKeepRecordAndIdentifyCorrectEntryPoint() {
        let resource = FavoritesViewModelTests.makeFavorite(region: "eu-west-1")
        let navigation = FavoriteNavigation()
        for loadError in [nil, "Access denied"] as [String?] {
            XCTAssertTrue(navigation.begin(resource, profiles: profiles, selectedProfileName: "work", source: .recent))
            XCTAssertTrue(navigation.verifyAccount(resource.accountID))
            XCTAssertTrue(navigation.matches(profileName: "work", region: "eu-west-1"))
            navigation.finish(found: false, loadError: loadError)
            XCTAssertNil(navigation.target)
            XCTAssertTrue(navigation.error?.contains("recent resource is still saved") == true)
            XCTAssertFalse(navigation.error?.contains("favorite") == true)
        }
        _ = navigation.begin(resource, profiles: profiles, selectedProfileName: "work", source: .recent)
        navigation.failConnection()
        XCTAssertTrue(navigation.error?.contains("from Recent") == true)
        _ = navigation.begin(resource, profiles: profiles, selectedProfileName: "work")
        navigation.failConnection()
        XCTAssertTrue(navigation.error?.contains("from Favorites") == true)
    }

    func testRecentResourceNavigationResolvesExactTargetWithoutSavingFavorite() async throws {
        let suite = "RecentNavigationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let favorites = FavoritesViewModel(defaults: defaults)
        let recents = RecentResourcesViewModel(defaults: defaults)
        let topic = SNSTopic(arn: "arn:aws:sns:us-east-1:111111111111:alerts", name: "alerts")
        let resource = FavoritesViewModelTests.makeFavorite(service: .sns, resourceID: topic.arn)
        recents.recordVisit(resource, scope: RecentResourceScope(profileName: "work", accountID: resource.accountID))
        let sns = makeSNSVM(rows: [topic])
        sns.configure(scope: SNSScope(profile: profiles[0], identity: AWSIdentity(
            account: resource.accountID, arn: "arn:aws:iam::111111111111:user/test", userID: "test"
        ), region: resource.region))
        await sns.loadTopics()
        let navigation = FavoriteNavigation()
        XCTAssertTrue(navigation.begin(resource, profiles: profiles, selectedProfileName: "work", source: .recent))
        XCTAssertTrue(navigation.verifyAccount(resource.accountID))
        navigation.resolve(ec2: EC2ViewModel(), lambda: LambdaViewModel(), s3: S3ViewModel(), alarms: makeAlarmVM(), sns: sns)
        XCTAssertEqual(sns.selectedTopic, topic)
        XCTAssertNil(navigation.target)
        XCTAssertNil(navigation.error)
        XCTAssertEqual(recents.entries.count, 1)
        XCTAssertTrue(favorites.favorites.isEmpty)
        XCTAssertNil(defaults.object(forKey: FavoritesViewModel.storageKey))
        await sns.waitForDetails()
    }

    private func makeSNSVM(rows: [SNSTopic] = []) -> SNSViewModel {
        SNSViewModel(listLoader: { _ in rows }, attributeLoader: { _, _ in [:] },
                     tagLoader: { _, _ in [:] }, subscriptionLoader: { _, _ in [] })
    }

    func testSNSFavoriteResolvesByARNAndClearsFilters() async {
        let topic = SNSTopic(arn: "arn:aws:sns:us-east-1:111111111111:alerts", name: "alerts")
        let sns = makeSNSVM(rows: [topic])
        sns.configure(scope: SNSScope(profile: profiles[0], identity: AWSIdentity(
            account: "111111111111", arn: "arn:aws:iam::111111111111:user/test", userID: "test"
        ), region: "us-east-1"))
        await sns.loadTopics()
        sns.searchText = "hidden"
        sns.kindFilter = .fifo
        let favorite = FavoritesViewModelTests.makeFavorite(service: .sns, resourceID: topic.arn)
        let navigation = FavoriteNavigation()
        XCTAssertTrue(navigation.begin(favorite, profiles: profiles, selectedProfileName: "work"))
        XCTAssertTrue(navigation.verifyAccount("111111111111"))
        navigation.resolve(ec2: EC2ViewModel(), lambda: LambdaViewModel(), s3: S3ViewModel(), alarms: makeAlarmVM(), sns: sns)
        XCTAssertEqual(sns.selectedTopic, topic)
        XCTAssertEqual(sns.filteredTopics, [topic])
        XCTAssertNil(navigation.error)
        XCTAssertNil(navigation.target)
        await sns.waitForDetails()
    }

    func testMissingSNSFavoriteDoesNotSelectAnotherTopicAndRemainsSaved() async {
        let topic = SNSTopic(arn: "arn:aws:sns:us-east-1:111111111111:other", name: "other")
        let sns = makeSNSVM(rows: [topic])
        sns.configure(scope: SNSScope(profile: profiles[0], identity: AWSIdentity(
            account: "111111111111", arn: "arn:aws:iam::111111111111:user/test", userID: "test"
        ), region: "us-east-1"))
        await sns.loadTopics()
        let navigation = FavoriteNavigation()
        let favorite = FavoritesViewModelTests.makeFavorite(service: .sns,
            resourceID: "arn:aws:sns:us-east-1:111111111111:deleted")
        _ = navigation.begin(favorite, profiles: profiles, selectedProfileName: "work")
        navigation.resolve(ec2: EC2ViewModel(), lambda: LambdaViewModel(), s3: S3ViewModel(), alarms: makeAlarmVM(), sns: sns)
        XCTAssertNil(sns.selectedTopic)
        XCTAssertTrue(navigation.error?.contains("not found") == true)
        XCTAssertTrue(navigation.error?.contains("still saved") == true)
    }

    private func makeAlarmVM(rows: [CloudWatchAlarm] = []) -> AlarmViewModel {
        AlarmViewModel(listLoader: { _ in rows }, tagLoader: { _, _ in [:] }, historyLoader: { _, _ in [] })
    }

    func testAlarmFavoriteResolvesByARNAndClearsFilters() async {
        let alarm = CloudWatchAlarm(arn: "arn:aws:cloudwatch:us-east-1:111111111111:alarm:HighCPU",
                                    name: "HighCPU", kind: .metric, state: "ALARM")
        let alarms = makeAlarmVM(rows: [alarm])
        alarms.configure(scope: AlarmScope(profile: profiles[0], identity: AWSIdentity(
            account: "111111111111", arn: "arn:aws:iam::111111111111:user/test", userID: "test"
        ), region: "us-east-1"))
        await alarms.loadAlarms()
        alarms.searchText = "hidden"
        alarms.stateFilter = "OK"
        alarms.kindFilter = .composite
        let favorite = FavoritesViewModelTests.makeFavorite(service: .alarms, resourceID: alarm.arn)
        let navigation = FavoriteNavigation()
        XCTAssertTrue(navigation.begin(favorite, profiles: profiles, selectedProfileName: "work"))
        XCTAssertTrue(navigation.verifyAccount("111111111111"))
        navigation.resolve(ec2: EC2ViewModel(), lambda: LambdaViewModel(), s3: S3ViewModel(), alarms: alarms, sns: makeSNSVM())
        XCTAssertEqual(alarms.selectedAlarm, alarm)
        XCTAssertEqual(alarms.filteredAlarms, [alarm])
        XCTAssertNil(navigation.error)
        XCTAssertNil(navigation.target)
        await alarms.waitForDetails()
    }

    func testMissingAlarmFavoriteReportsFailureWithoutSelectingAnotherAlarm() async {
        let existing = CloudWatchAlarm(arn: "arn:aws:cloudwatch:us-east-1:111111111111:alarm:other",
                                       name: "other", kind: .composite, state: "OK")
        let alarms = makeAlarmVM(rows: [existing])
        alarms.configure(scope: AlarmScope(profile: profiles[0], identity: AWSIdentity(
            account: "111111111111", arn: "arn:aws:iam::111111111111:user/test", userID: "test"
        ), region: "us-east-1"))
        await alarms.loadAlarms()
        let navigation = FavoriteNavigation()
        let favorite = FavoritesViewModelTests.makeFavorite(service: .alarms,
            resourceID: "arn:aws:cloudwatch:us-east-1:111111111111:alarm:deleted")
        _ = navigation.begin(favorite, profiles: profiles, selectedProfileName: "work")
        navigation.resolve(ec2: EC2ViewModel(), lambda: LambdaViewModel(), s3: S3ViewModel(), alarms: alarms, sns: makeSNSVM())
        XCTAssertNil(alarms.selectedAlarm)
        XCTAssertTrue(navigation.error?.contains("not found") == true)
        XCTAssertTrue(navigation.error?.contains("still saved") == true)
    }

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
        navigation.resolve(ec2: ec2, lambda: lambda, s3: s3, alarms: makeAlarmVM(), sns: makeSNSVM())
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
        navigation.resolve(ec2: EC2ViewModel(), lambda: lambda, s3: S3ViewModel(), alarms: makeAlarmVM(), sns: makeSNSVM())
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
        navigation.resolve(ec2: EC2ViewModel(), lambda: LambdaViewModel(), s3: s3, alarms: makeAlarmVM(), sns: makeSNSVM())
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
        navigation.resolve(ec2: EC2ViewModel(), lambda: LambdaViewModel(), s3: S3ViewModel(), alarms: makeAlarmVM(), sns: makeSNSVM())
        XCTAssertNotNil(navigation.error)
        XCTAssertTrue(store.contains(favorite))
        _ = navigation.begin(favorite, profiles: profiles, selectedProfileName: "work")
        navigation.finish(found: false, loadError: "Permission denied")
        XCTAssertTrue(navigation.error?.contains("Permission denied") == true)
        XCTAssertTrue(store.contains(favorite))
    }
}
