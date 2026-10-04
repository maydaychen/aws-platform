import XCTest
@testable import AWSPlatform

@MainActor
final class RecentResourcesViewModelTests: XCTestCase {
    func testVisitsForEveryServiceSurviveRelaunchWithoutChangingFavorites() throws {
        try withDefaults { defaults in
            let favorite = makeResource(name: "Favorite remains unchanged")
            let favoritesData = try JSONEncoder().encode([favorite])
            defaults.set(favoritesData, forKey: FavoritesViewModel.storageKey)
            let visitedAt = Date(timeIntervalSinceReferenceDate: 100)
            let vm = RecentResourcesViewModel(defaults: defaults, now: { visitedAt })
            let resources = AWSService.allCases.map {
                makeResource(region: $0 == .route53 ? "global" : "us-east-1", service: $0,
                             resourceID: $0 == .route53 ? "ZEXAMPLE" : "i-example")
            }
            XCTAssertTrue(vm.entries.isEmpty)

            resources.forEach { vm.recordVisit($0, scope: scope()) }

            let restored = RecentResourcesViewModel(defaults: defaults)
            XCTAssertNil(restored.storageError)
            XCTAssertEqual(restored.entries(for: scope()).map(\.resource), Array(resources.reversed()))
            XCTAssertTrue(restored.entries.allSatisfy { $0.lastVisitedAt == visitedAt })
            XCTAssertEqual(defaults.data(forKey: FavoritesViewModel.storageKey), favoritesData)
        }
    }

    func testRevisitUpdatesMetadataAndDateWithoutDuplicatingIdentity() throws {
        try withDefaults { defaults in
            var now = Date(timeIntervalSinceReferenceDate: 100)
            let vm = RecentResourcesViewModel(defaults: defaults, now: { now })
            let original = makeResource(name: "Old name")
            let other = makeResource(resourceID: "i-other")
            vm.recordVisit(original, scope: scope())
            now.addTimeInterval(1)
            vm.recordVisit(other, scope: scope())
            XCTAssertEqual(vm.entries.map(\.resource), [other, original])

            let renamed = makeResource(name: "New name")
            now.addTimeInterval(1)
            vm.recordVisit(renamed, scope: scope())

            XCTAssertEqual(vm.entries.map(\.resource), [renamed, other])
            XCTAssertEqual(vm.entries.first?.lastVisitedAt, now)
            XCTAssertEqual(RecentResourcesViewModel(defaults: defaults).entries, vm.entries)
        }
    }

    func testEqualTimeVisitsMoveToFrontAndKeepStableOrderAfterRestore() throws {
        try withDefaults { defaults in
            let vm = RecentResourcesViewModel(defaults: defaults, now: { Date(timeIntervalSinceReferenceDate: 100) })
            let resources = (0..<3).map { makeResource(resourceID: "i-\($0)") }
            resources.forEach { vm.recordVisit($0, scope: scope()) }
            vm.recordVisit(resources[0], scope: scope())

            let expected = [resources[0], resources[2], resources[1]]
            XCTAssertEqual(vm.entries.map(\.resource), expected)
            XCTAssertEqual(RecentResourcesViewModel(defaults: defaults).entries.map(\.resource), expected)
        }
    }

    func testRetentionEvictsOldestWithinEachProfileAndAccountOnly() throws {
        try withDefaults { defaults in
            var now = Date(timeIntervalSinceReferenceDate: 100)
            let vm = RecentResourcesViewModel(defaults: defaults, now: { now })
            let scopes = [scope(), scope(profile: "other"), scope(account: "222222222222")]
            for selectedScope in scopes {
                for index in 0..<55 {
                    now.addTimeInterval(1)
                    vm.recordVisit(makeResource(profile: selectedScope.profileName, account: selectedScope.accountID,
                                                resourceID: "i-\(index)"), scope: selectedScope)
                }
            }

            XCTAssertEqual(vm.entries.count, 150)
            for selectedScope in scopes {
                XCTAssertEqual(vm.entries(for: selectedScope).count, RecentResourcesViewModel.limitPerScope)
                XCTAssertEqual(vm.entries(for: selectedScope).map(\.resource.resourceID), (5..<55).reversed().map { "i-\($0)" })
            }
            XCTAssertEqual(RecentResourcesViewModel(defaults: defaults).entries, vm.entries)
        }
    }

    func testRestoreSortsDeduplicatesAndCapsEachScopeWithoutWritingStorage() throws {
        try withDefaults { defaults in
            let entries = (0..<55).map {
                RecentResource(resource: makeResource(resourceID: "i-\($0)"),
                               lastVisitedAt: Date(timeIntervalSinceReferenceDate: Double($0)))
            }
            let newest = RecentResource(resource: makeResource(resourceID: "i-0", name: "Renamed newest"),
                                        lastVisitedAt: Date(timeIntervalSinceReferenceDate: 200))
            let other = RecentResource(resource: makeResource(profile: "other"),
                                       lastVisitedAt: Date(timeIntervalSinceReferenceDate: 0))
            let original = try JSONEncoder().encode(entries + [newest, newest, other])
            defaults.set(original, forKey: RecentResourcesViewModel.storageKey)

            let vm = RecentResourcesViewModel(defaults: defaults)

            XCTAssertNil(vm.storageError)
            XCTAssertEqual(vm.entries(for: scope()).count, 50)
            XCTAssertEqual(vm.entries.first, newest)
            XCTAssertEqual(vm.entries(for: scope()).last?.resource.resourceID, "i-6")
            XCTAssertEqual(vm.entries(for: scope(profile: "other")), [other])
            XCTAssertEqual(Set(vm.entries.map(\.id)).count, vm.entries.count)
            XCTAssertEqual(defaults.data(forKey: RecentResourcesViewModel.storageKey), original)
        }
    }

    func testRegionServiceProfileAndAccountAreDistinctResourceIdentities() throws {
        try withDefaults { defaults in
            let vm = RecentResourcesViewModel(defaults: defaults)
            let variants = [makeResource(), makeResource(region: "eu-west-1"), makeResource(service: .lambda),
                            makeResource(profile: "other"), makeResource(account: "222222222222")]
            for resource in variants {
                vm.recordVisit(resource, scope: scope(profile: resource.profileName, account: resource.accountID))
            }

            XCTAssertEqual(Set(vm.entries.map(\.id)).count, 5)
            XCTAssertEqual(vm.entries(for: scope()).count, 3)
            XCTAssertEqual(vm.entries(for: scope(profile: "other")).map(\.resource), [variants[3]])
            XCTAssertEqual(vm.entries(for: scope(account: "222222222222")).map(\.resource), [variants[4]])
        }
    }

    func testSearchMatchesMetadataCaseInsensitivelyOnlyInsideScope() throws {
        try withDefaults { defaults in
            let vm = RecentResourcesViewModel(defaults: defaults)
            let own = makeResource(name: "Production Web")
            vm.recordVisit(own, scope: scope())
            vm.recordVisit(makeResource(profile: "other", name: "Production Web"), scope: scope(profile: "other"))

            for query in ["", "  WEB  ", "i-example", "ec2", "work", "111111111111", "US-EAST-1"] {
                XCTAssertEqual(vm.entries(for: scope(), matching: query).map(\.resource), [own], query)
            }
            XCTAssertTrue(vm.entries(for: scope(), matching: "other").isEmpty)
            XCTAssertTrue(vm.entries(for: scope(), matching: "not-present").isEmpty)
            XCTAssertTrue(vm.entries(for: nil, matching: "Production Web").isEmpty)
        }
    }

    func testRemovalUsesStableIdentityAndClearPreservesOtherScopes() throws {
        try withDefaults { defaults in
            let vm = RecentResourcesViewModel(defaults: defaults)
            let original = makeResource()
            let ownRegion = makeResource(region: "eu-west-1")
            let otherProfile = makeResource(profile: "other")
            let otherAccount = makeResource(account: "222222222222")
            for resource in [original, ownRegion, otherProfile, otherAccount] {
                vm.recordVisit(resource, scope: scope(profile: resource.profileName, account: resource.accountID))
            }
            let renamedEntry = RecentResource(resource: makeResource(name: "New name"), lastVisitedAt: Date())
            vm.remove(renamedEntry, scope: scope())
            XCTAssertEqual(vm.entries(for: scope()).map(\.resource), [ownRegion])

            vm.clear(scope: scope())

            XCTAssertTrue(vm.entries(for: scope()).isEmpty)
            XCTAssertEqual(Set(vm.entries.map(\.id)), Set([otherProfile.id, otherAccount.id]))
            XCTAssertEqual(RecentResourcesViewModel(defaults: defaults).entries, vm.entries)
        }
    }

    func testNilInvalidAndForeignScopesCannotExposeOrMutateHistory() throws {
        try withDefaults { defaults in
            let vm = RecentResourcesViewModel(defaults: defaults)
            vm.recordVisit(makeResource(), scope: scope())
            let entry = try XCTUnwrap(vm.entries.first)
            let original = defaults.data(forKey: RecentResourcesViewModel.storageKey)
            let deniedScopes: [RecentResourceScope?] = [nil, scope(profile: " \n"), scope(account: "invalid"),
                                                       scope(profile: "other"), scope(account: "222222222222")]
            for deniedScope in deniedScopes {
                XCTAssertTrue(vm.entries(for: deniedScope).isEmpty)
                vm.recordVisit(makeResource(name: "Must not replace"), scope: deniedScope)
                vm.remove(entry, scope: deniedScope)
                vm.clear(scope: deniedScope)
                XCTAssertEqual(vm.entries, [entry])
                XCTAssertEqual(defaults.data(forKey: RecentResourcesViewModel.storageKey), original)
            }
        }
    }

    func testScopesRequireNonblankProfileAndTwelveASCIIDigits() {
        XCTAssertTrue(scope().isValid)
        XCTAssertTrue(scope(account: "000000000000").isValid)
        XCTAssertFalse(scope(profile: "\n \t").isValid)
        for account in ["", "11111111111", "1111111111111", "111111111111\n", "１１１１１１１１１１１１", "11111111111x"] {
            XCTAssertFalse(scope(account: account).isValid, account)
            XCTAssertFalse(scope(account: account).contains(makeResource(account: account)), account)
        }
        XCTAssertFalse(scope().contains(makeResource(profile: "other")))
        XCTAssertFalse(scope().contains(makeResource(account: "222222222222")))
    }

    func testInvalidResourceMetadataAndNonfiniteTimeAreNotPersisted() throws {
        try withDefaults { defaults in
            let vm = RecentResourcesViewModel(defaults: defaults)
            for resource in [makeResource(region: " "), makeResource(resourceID: ""), makeResource(name: "-")] {
                vm.recordVisit(resource, scope: scope())
            }
            let invalidClock = RecentResourcesViewModel(defaults: defaults, now: { Date(timeIntervalSinceReferenceDate: .infinity) })
            invalidClock.recordVisit(makeResource(), scope: scope())

            XCTAssertTrue(vm.entries.isEmpty)
            XCTAssertTrue(invalidClock.entries.isEmpty)
            XCTAssertNil(vm.storageError)
            XCTAssertNil(invalidClock.storageError)
            XCTAssertNil(defaults.object(forKey: RecentResourcesViewModel.storageKey))
        }
    }

    func testMalformedAndSemanticallyInvalidStorageIsPreservedWithEditingDisabled() throws {
        try withDefaults { defaults in
            let invalidEntry = RecentResource(resource: makeResource(account: "invalid"), lastVisitedAt: Date())
            let invalidName = RecentResource(resource: makeResource(name: " "), lastVisitedAt: Date())
            let validEntry = RecentResource(resource: makeResource(), lastVisitedAt: Date())
            let payloads = [Data("not-json".utf8), try JSONEncoder().encode([validEntry, invalidEntry]),
                            try JSONEncoder().encode([invalidName])]
            for original in payloads {
                defaults.set(original, forKey: RecentResourcesViewModel.storageKey)
                let vm = RecentResourcesViewModel(defaults: defaults)
                XCTAssertNotNil(vm.storageError)
                vm.recordVisit(makeResource(), scope: scope())
                vm.remove(RecentResource(resource: makeResource(), lastVisitedAt: Date()), scope: scope())
                vm.clear(scope: scope())
                XCTAssertTrue(vm.entries(for: scope()).isEmpty)
                XCTAssertEqual(defaults.data(forKey: RecentResourcesViewModel.storageKey), original)
            }
        }
    }

    func testWrongStorageTypeIsPreservedWithEditingDisabled() throws {
        try withDefaults { defaults in
            defaults.set("unexpected string", forKey: RecentResourcesViewModel.storageKey)
            let vm = RecentResourcesViewModel(defaults: defaults)
            XCTAssertNotNil(vm.storageError)
            vm.recordVisit(makeResource(), scope: scope())
            vm.clear(scope: scope())
            XCTAssertEqual(defaults.string(forKey: RecentResourcesViewModel.storageKey), "unexpected string")
            XCTAssertTrue(vm.entries.isEmpty)
        }
    }

    func testSerializationContainsOnlyDestinationMetadataAndTimestamp() throws {
        let entry = RecentResource(resource: makeResource(), lastVisitedAt: Date(timeIntervalSinceReferenceDate: 100))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        XCTAssertEqual(Set(value.keys), ["resource", "lastVisitedAt"])
        let resource = try XCTUnwrap(value["resource"] as? [String: Any])
        XCTAssertEqual(Set(resource.keys), ["profileName", "accountID", "region", "service", "resourceID", "displayName"])
        XCTAssertEqual(value["lastVisitedAt"] as? Double, 100)
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "RecentResourcesViewModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func scope(profile: String = "work", account: String = "111111111111") -> RecentResourceScope {
        RecentResourceScope(profileName: profile, accountID: account)
    }

    private func makeResource(profile: String = "work", account: String = "111111111111", region: String = "us-east-1",
                              service: AWSService = .ec2, resourceID: String = "i-example", name: String = "Example") -> ResourceFavorite {
        ResourceFavorite(profileName: profile, accountID: account, region: region, service: service,
                         resourceID: resourceID, displayName: name)
    }
}
