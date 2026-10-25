import XCTest
@testable import AWSPlatform

@MainActor
final class SNSViewModelTests: XCTestCase {
    func testNoScopeOrConfigureNeverRequestsData() async {
        let probe = SNSProbe()
        let vm = makeViewModel(probe)
        vm.loadIfNeeded()
        vm.refresh()
        vm.refreshDetails()
        await vm.loadTopics()
        vm.configure(scope: snsScope())
        let counts = await probe.counts()
        XCTAssertEqual(counts, [0, 0, 0, 0])
        XCTAssertTrue(vm.topics.isEmpty)
        XCTAssertNil(vm.selectedTopic)
    }

    func testFirstVisitDeduplicatesAndNeverAutoSelectsOrEnriches() async {
        let gate = TestGate()
        let probe = SNSProbe(listGate: gate)
        let vm = makeViewModel(probe)
        vm.configure(scope: snsScope())
        vm.loadIfNeeded()
        await gate.waitForEntry()
        vm.loadIfNeeded()
        let joined = Task { await vm.loadTopics() }
        await Task.yield()
        await gate.open()
        await joined.value
        await vm.waitForCurrentLoad()
        vm.loadIfNeeded()
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 0, 0, 0])
        XCTAssertEqual(vm.topics.count, 2)
        XCTAssertNil(vm.selectedTopic)
    }

    func testEmptySuccessfulListDoesNotReloadOnReentry() async {
        let probe = SNSProbe(results: [[]])
        let vm = makeViewModel(probe)
        vm.configure(scope: snsScope())
        vm.loadIfNeeded()
        await vm.waitForCurrentLoad()
        vm.loadIfNeeded()
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 0, 0, 0])
        XCTAssertNil(vm.error)
        XCTAssertTrue(vm.topics.isEmpty)
    }

    func testSelectionStartsThreeDetailRequestsOnceAndUnlistedTopicIsRejected() async {
        let probe = SNSProbe()
        let vm = makeViewModel(probe)
        vm.configure(scope: snsScope())
        await vm.loadTopics()
        vm.selectedTopic = vm.topics.first
        await vm.waitForDetails()
        vm.selectedTopic = vm.topics.first
        await vm.waitForDetails()
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1, 1, 1])
        XCTAssertEqual(vm.attributes["DisplayName"], "notifications")
        XCTAssertEqual(vm.tags["Name"], "notifications")
        XCTAssertEqual(vm.subscriptions.first?.topicARN, vm.selectedTopic?.arn)
        vm.selectedTopic = snsTopic("unlisted")
        await vm.waitForDetails()
        XCTAssertNil(vm.selectedTopic)
        XCTAssertTrue(vm.attributes.isEmpty)
        XCTAssertTrue(vm.tags.isEmpty)
        XCTAssertTrue(vm.subscriptions.isEmpty)
        let finalCounts = await probe.counts()
        XCTAssertEqual(finalCounts, counts)
    }

    func testFailedFirstLoadDoesNotAutoRetryButExplicitLoadDoes() async {
        let probe = SNSProbe(listFailures: [1])
        let vm = makeViewModel(probe)
        vm.configure(scope: snsScope())
        vm.loadIfNeeded()
        await vm.waitForCurrentLoad()
        XCTAssertNotNil(vm.error)
        vm.loadIfNeeded()
        let firstCounts = await probe.counts()
        XCTAssertEqual(firstCounts, [1, 0, 0, 0])
        await vm.loadTopics()
        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.topics.count, 2)
        let finalCounts = await probe.counts()
        XCTAssertEqual(finalCounts, [2, 0, 0, 0])
    }

    func testCancelRejectsLateListAndDoesNotAutoRetry() async {
        let gate = TestGate()
        let probe = SNSProbe(listGate: gate)
        let vm = makeViewModel(probe)
        vm.configure(scope: snsScope())
        vm.loadIfNeeded()
        await gate.waitForEntry()
        let waiting = Task { await vm.waitForCurrentLoad() }
        await Task.yield()
        vm.cancelLoading()
        await gate.open()
        await waiting.value
        XCTAssertFalse(vm.isLoading)
        XCTAssertTrue(vm.topics.isEmpty)
        XCTAssertNotNil(vm.error)
        vm.loadIfNeeded()
        let firstCounts = await probe.counts()
        XCTAssertEqual(firstCounts, [1, 0, 0, 0])
        vm.refresh()
        await vm.waitForCurrentLoad()
        XCTAssertEqual(vm.topics.count, 2)
        XCTAssertNil(vm.error)
    }

    func testProfileRegionIdentityAndConfigurationChangesClearContextAndFilters() async {
        let probe = SNSProbe()
        let vm = makeViewModel(probe)
        let scopes = [
            snsScope(), snsScope(region: "eu-west-1"), snsScope(profile: "other"),
            snsScope(account: "444455556666"), snsScope(role: "OtherRole"),
            snsScope(paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/tmp/other-config"]))
        ]
        for scope in scopes {
            vm.configure(scope: scope)
            XCTAssertTrue(vm.topics.isEmpty)
            XCTAssertNil(vm.selectedTopic)
            XCTAssertTrue(vm.attributes.isEmpty)
            XCTAssertTrue(vm.tags.isEmpty)
            XCTAssertTrue(vm.subscriptions.isEmpty)
            XCTAssertEqual(vm.searchText, "")
            XCTAssertNil(vm.kindFilter)
            vm.loadIfNeeded()
            await vm.waitForCurrentLoad()
            vm.selectedTopic = vm.topics.first
            await vm.waitForDetails()
            vm.searchText = "notifications"
            vm.kindFilter = .standard
        }
        let counts = await probe.counts()
        XCTAssertEqual(counts, Array(repeating: scopes.count, count: 4))
        vm.configure(scope: scopes.last)
        vm.loadIfNeeded()
        let finalCounts = await probe.counts()
        XCTAssertEqual(finalCounts, counts)
        XCTAssertNotNil(vm.selectedTopic)
    }

    func testLateOldScopeListSuccessAndFailureCannotOverwriteNewContext() async {
        for shouldFail in [false, true] {
            let gate = TestGate()
            let probe = SNSProbe(results: [[snsTopic("old")], [snsTopic("new")]], listGate: gate,
                                 listFailures: shouldFail ? [1] : [])
            let vm = makeViewModel(probe)
            vm.configure(scope: snsScope())
            vm.loadIfNeeded()
            await gate.waitForEntry()
            let waiting = Task { await vm.waitForCurrentLoad() }
            await Task.yield()
            vm.configure(scope: snsScope(region: "eu-west-1"))
            vm.loadIfNeeded()
            await vm.waitForCurrentLoad()
            await gate.open()
            await waiting.value
            XCTAssertEqual(vm.topics.map(\.name), ["new"])
            XCTAssertNil(vm.error)
            XCTAssertFalse(vm.isLoading)
        }
    }

    func testLateSelectedTopicDetailsSuccessAndFailureCannotPublish() async {
        for shouldFail in [false, true] {
            let attributes = TestGate()
            let tags = TestGate()
            let subscriptions = TestGate()
            let failures: Set<Int> = shouldFail ? [1] : []
            let probe = SNSProbe(attributeGate: attributes, tagGate: tags, subscriptionGate: subscriptions,
                                 attributeFailures: failures, tagFailures: failures, subscriptionFailures: failures)
            let vm = makeViewModel(probe)
            vm.configure(scope: snsScope())
            await vm.loadTopics()
            vm.selectedTopic = vm.topics[0]
            await attributes.waitForEntry()
            await tags.waitForEntry()
            await subscriptions.waitForEntry()
            let waiting = Task { await vm.waitForDetails() }
            await Task.yield()
            vm.selectedTopic = vm.topics[1]
            await vm.waitForDetails()
            await attributes.open()
            await tags.open()
            await subscriptions.open()
            await waiting.value

            XCTAssertEqual(vm.selectedTopic?.name, "orders.fifo")
            XCTAssertEqual(vm.attributes["DisplayName"], "orders.fifo")
            XCTAssertEqual(vm.tags["Name"], "orders.fifo")
            XCTAssertEqual(vm.subscriptions.first?.topicARN, vm.selectedTopic?.arn)
            XCTAssertNil(vm.attributesError)
            XCTAssertNil(vm.tagsError)
            XCTAssertNil(vm.subscriptionsError)
            XCTAssertFalse(vm.isAttributesLoading)
            XCTAssertFalse(vm.isTagsLoading)
            XCTAssertFalse(vm.isSubscriptionsLoading)
        }
    }

    func testResetInvalidatesAllPendingDetails() async {
        let attributes = TestGate()
        let tags = TestGate()
        let subscriptions = TestGate()
        let probe = SNSProbe(attributeGate: attributes, tagGate: tags, subscriptionGate: subscriptions)
        let vm = makeViewModel(probe)
        vm.configure(scope: snsScope())
        await vm.loadTopics()
        vm.selectedTopic = vm.topics[0]
        await attributes.waitForEntry()
        await tags.waitForEntry()
        await subscriptions.waitForEntry()
        let waiting = Task { await vm.waitForDetails() }
        await Task.yield()
        vm.reset()
        await attributes.open()
        await tags.open()
        await subscriptions.open()
        await waiting.value
        XCTAssertNil(vm.scope)
        XCTAssertNil(vm.selectedTopic)
        XCTAssertTrue(vm.topics.isEmpty)
        XCTAssertTrue(vm.attributes.isEmpty)
        XCTAssertTrue(vm.tags.isEmpty)
        XCTAssertTrue(vm.subscriptions.isEmpty)
        XCTAssertNil(vm.attributesError)
        XCTAssertNil(vm.tagsError)
        XCTAssertNil(vm.subscriptionsError)
        XCTAssertFalse(vm.isAttributesLoading)
        XCTAssertFalse(vm.isTagsLoading)
        XCTAssertFalse(vm.isSubscriptionsLoading)
    }

    func testDetailFailuresAreIndependentAndRefreshRetriesEachSection() async {
        let probe = SNSProbe(attributeFailures: [1], tagFailures: [2], subscriptionFailures: [3])
        let vm = makeViewModel(probe)
        vm.configure(scope: snsScope())
        await vm.loadTopics()
        vm.selectedTopic = vm.topics[0]
        await vm.waitForDetails()
        XCTAssertNotNil(vm.attributesError)
        XCTAssertFalse(vm.tags.isEmpty)
        XCTAssertFalse(vm.subscriptions.isEmpty)

        vm.refreshDetails()
        await vm.waitForDetails()
        XCTAssertNil(vm.attributesError)
        XCTAssertFalse(vm.attributes.isEmpty)
        XCTAssertNotNil(vm.tagsError)
        XCTAssertFalse(vm.subscriptions.isEmpty)

        vm.refreshDetails()
        await vm.waitForDetails()
        XCTAssertFalse(vm.attributes.isEmpty)
        XCTAssertNil(vm.tagsError)
        XCTAssertFalse(vm.tags.isEmpty)
        XCTAssertNotNil(vm.subscriptionsError)
        XCTAssertTrue(vm.subscriptions.isEmpty)
        XCTAssertNotNil(vm.selectedTopic)
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 3, 3, 3])
    }

    func testListRefreshPreservesSelectedARNReloadsDetailsAndClearsDeletedTopic() async {
        let topic = snsTopic("notifications")
        let probe = SNSProbe(results: [[topic], [topic], []])
        let vm = makeViewModel(probe)
        vm.configure(scope: snsScope())
        await vm.loadTopics()
        vm.selectedTopic = vm.topics.first
        await vm.waitForDetails()
        vm.refresh()
        await vm.waitForCurrentLoad()
        await vm.waitForDetails()
        XCTAssertEqual(vm.selectedTopic, topic)
        let selectedCounts = await probe.counts()
        XCTAssertEqual(selectedCounts, [2, 2, 2, 2])

        vm.refresh()
        await vm.waitForCurrentLoad()
        XCTAssertNil(vm.selectedTopic)
        XCTAssertTrue(vm.attributes.isEmpty)
        XCTAssertTrue(vm.tags.isEmpty)
        XCTAssertTrue(vm.subscriptions.isEmpty)
        let deletedCounts = await probe.counts()
        XCTAssertEqual(deletedCounts, [3, 2, 2, 2])
    }

    func testFailedRefreshRetainsCompletePriorListAndError() async {
        let probe = SNSProbe(listFailures: [2])
        let vm = makeViewModel(probe)
        vm.configure(scope: snsScope())
        await vm.loadTopics()
        let previous = vm.topics
        vm.refresh()
        await vm.waitForCurrentLoad()
        XCTAssertEqual(vm.topics, previous)
        XCTAssertNotNil(vm.error)
        XCTAssertNil(vm.selectedTopic)
    }

    func testClearingSelectionClearsDetailsAndDoesNotMakeNewRequests() async {
        let probe = SNSProbe()
        let vm = makeViewModel(probe)
        vm.configure(scope: snsScope())
        await vm.loadTopics()
        vm.selectedTopic = vm.topics[0]
        await vm.waitForDetails()
        vm.selectedTopic = nil
        vm.refreshDetails()
        XCTAssertTrue(vm.attributes.isEmpty)
        XCTAssertTrue(vm.tags.isEmpty)
        XCTAssertTrue(vm.subscriptions.isEmpty)
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1, 1, 1])
    }

    func testSearchAndTopicKindFilteringRemainLocal() async {
        let probe = SNSProbe()
        let vm = makeViewModel(probe)
        vm.configure(scope: snsScope())
        await vm.loadTopics()
        vm.searchText = " NOTIFICATIONS "
        XCTAssertEqual(vm.filteredTopics.map(\.name), ["notifications"])
        vm.searchText = ":orders.fifo"
        XCTAssertEqual(vm.filteredTopics.map(\.name), ["orders.fifo"])
        vm.searchText = ""
        vm.kindFilter = .fifo
        XCTAssertEqual(vm.filteredTopics.map(\.name), ["orders.fifo"])
        vm.kindFilter = .standard
        XCTAssertEqual(vm.filteredTopics.map(\.name), ["notifications"])
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 0, 0, 0])
    }

    func testEndpointRevealRequiresExplicitActionAndMatchingProfileTopicAndValue() {
        let topic = snsTopic("notifications")
        let scope = snsScope()
        let subscription = SNSSubscription(id: "same-id", endpoint: "first@example.invalid", topicARN: topic.arn, status: "Pending confirmation")
        var visibility = SNSEndpointRevealState()
        XCTAssertFalse(visibility.isRevealed(subscription, scope: scope, topicARN: topic.arn))
        visibility.toggle(subscription, scope: scope, topicARN: topic.arn)
        XCTAssertTrue(visibility.isRevealed(subscription, scope: scope, topicARN: topic.arn))
        XCTAssertFalse(visibility.isRevealed(subscription, scope: nil, topicARN: topic.arn))
        XCTAssertFalse(visibility.isRevealed(subscription, scope: snsScope(role: "OtherRole"), topicARN: topic.arn))
        XCTAssertFalse(visibility.isRevealed(subscription, scope: scope, topicARN: snsTopic("other").arn))
        let changed = SNSSubscription(id: "same-id", endpoint: "second@example.invalid", topicARN: topic.arn, status: "Pending confirmation")
        XCTAssertFalse(visibility.isRevealed(changed, scope: scope, topicARN: topic.arn))
        visibility.clear()
        XCTAssertFalse(visibility.isRevealed(subscription, scope: scope, topicARN: topic.arn))
    }

    func testEndpointHideToggleAndTopicChangeDiscardPreviousReveal() {
        let first = snsTopic("first")
        let second = snsTopic("second")
        let scope = snsScope()
        let firstSubscription = SNSSubscription(id: "1", endpoint: "first@example.invalid", topicARN: first.arn, status: "Pending confirmation")
        let secondSubscription = SNSSubscription(id: "1", endpoint: "second@example.invalid", topicARN: second.arn, status: "Pending confirmation")
        var visibility = SNSEndpointRevealState()
        visibility.toggle(firstSubscription, scope: scope, topicARN: first.arn)
        visibility.toggle(firstSubscription, scope: scope, topicARN: first.arn)
        XCTAssertFalse(visibility.isRevealed(firstSubscription, scope: scope, topicARN: first.arn))
        visibility.toggle(firstSubscription, scope: scope, topicARN: first.arn)
        visibility.toggle(secondSubscription, scope: scope, topicARN: second.arn)
        XCTAssertTrue(visibility.isRevealed(secondSubscription, scope: scope, topicARN: second.arn))
        XCTAssertFalse(visibility.isRevealed(firstSubscription, scope: scope, topicARN: first.arn))
    }

    private func makeViewModel(_ probe: SNSProbe) -> SNSViewModel {
        SNSViewModel(listLoader: { try await probe.list($0) }, attributeLoader: { try await probe.attributes($0, $1) },
                     tagLoader: { try await probe.tags($0, $1) }, subscriptionLoader: { try await probe.subscriptions($0, $1) })
    }
}

private func snsScope(
    profile: String = "work", account: String = "111122223333", role: String = "ReadOnly", region: String = "us-east-1",
    paths: AWSConfigurationPaths = AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/tmp/sns-config"])
) -> SNSScope {
    SNSScope(
        profile: AWSProfile(name: profile, region: region, ssoStartURL: nil, ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil),
        identity: AWSIdentity(account: account, arn: "arn:aws:sts::\(account):assumed-role/\(role)/test", userID: "test"),
        region: region, paths: paths
    )
}

private func snsTopic(_ name: String) -> SNSTopic {
    SNSTopic(arn: "arn:aws:sns:us-east-1:111122223333:\(name)", name: name)
}

private actor SNSProbe {
    private var listCalls = 0
    private var attributeCalls = 0
    private var tagCalls = 0
    private var subscriptionCalls = 0
    private let results: [[SNSTopic]]
    private let listGate: TestGate?
    private let attributeGate: TestGate?
    private let tagGate: TestGate?
    private let subscriptionGate: TestGate?
    private let listFailures: Set<Int>
    private let attributeFailures: Set<Int>
    private let tagFailures: Set<Int>
    private let subscriptionFailures: Set<Int>

    init(results: [[SNSTopic]] = [[snsTopic("notifications"), snsTopic("orders.fifo")]], listGate: TestGate? = nil,
         attributeGate: TestGate? = nil, tagGate: TestGate? = nil, subscriptionGate: TestGate? = nil,
         listFailures: Set<Int> = [], attributeFailures: Set<Int> = [], tagFailures: Set<Int> = [], subscriptionFailures: Set<Int> = []) {
        self.results = results
        self.listGate = listGate
        self.attributeGate = attributeGate
        self.tagGate = tagGate
        self.subscriptionGate = subscriptionGate
        self.listFailures = listFailures
        self.attributeFailures = attributeFailures
        self.tagFailures = tagFailures
        self.subscriptionFailures = subscriptionFailures
    }

    func counts() -> [Int] { [listCalls, attributeCalls, tagCalls, subscriptionCalls] }

    func list(_ scope: SNSScope) async throws -> [SNSTopic] {
        listCalls += 1
        let call = listCalls
        if call == 1 { await listGate?.wait() }
        if listFailures.contains(call) { throw SNSError.invalidResponse }
        return results[min(call - 1, results.count - 1)]
    }

    func attributes(_ scope: SNSScope, _ topic: SNSTopic) async throws -> [String: String] {
        attributeCalls += 1
        let call = attributeCalls
        if call == 1 { await attributeGate?.wait() }
        if attributeFailures.contains(call) { throw SNSError.invalidResponse }
        return ["DisplayName": topic.name]
    }

    func tags(_ scope: SNSScope, _ topic: SNSTopic) async throws -> [String: String] {
        tagCalls += 1
        let call = tagCalls
        if call == 1 { await tagGate?.wait() }
        if tagFailures.contains(call) { throw SNSError.invalidResponse }
        return ["Name": topic.name]
    }

    func subscriptions(_ scope: SNSScope, _ topic: SNSTopic) async throws -> [SNSSubscription] {
        subscriptionCalls += 1
        let call = subscriptionCalls
        if call == 1 { await subscriptionGate?.wait() }
        if subscriptionFailures.contains(call) { throw SNSError.invalidResponse }
        return [SNSSubscription(id: "\(topic.arn)-subscription", protocolName: "email", endpoint: "example@example.invalid",
                                owner: "444455556666", topicARN: topic.arn, status: "Pending confirmation")]
    }
}
