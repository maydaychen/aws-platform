import XCTest
@testable import AWSPlatform

@MainActor
final class FavoritesViewModelTests: XCTestCase {
    func testFavoriteSurvivesRelaunchAndRemovalIsPersisted() throws {
        let suite = "FavoritesViewModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let favorite = Self.makeFavorite()
        let first = FavoritesViewModel(defaults: defaults)
        first.toggle(favorite)
        let relaunched = FavoritesViewModel(defaults: defaults)
        XCTAssertEqual(relaunched.favorites, [favorite])
        relaunched.remove(favorite)
        XCTAssertTrue(FavoritesViewModel(defaults: defaults).favorites.isEmpty)
    }

    func testSameResourceInDifferentScopesHasDistinctIdentity() throws {
        let suite = "FavoritesViewModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = FavoritesViewModel(defaults: defaults)
        let variants = [
            Self.makeFavorite(),
            Self.makeFavorite(profile: "other"),
            Self.makeFavorite(account: "222222222222"),
            Self.makeFavorite(region: "eu-west-1"),
            Self.makeFavorite(service: .lambda)
        ]
        variants.forEach(vm.toggle)
        XCTAssertEqual(vm.favorites.count, 5)
        vm.remove(variants[0])
        XCTAssertEqual(vm.favorites.count, 4)
        XCTAssertTrue(variants.dropFirst().allSatisfy(vm.contains))
    }

    func testRenamedResourceCanBeUnstarredByStableIdentity() throws {
        let suite = "FavoritesViewModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = FavoritesViewModel(defaults: defaults)
        vm.toggle(Self.makeFavorite(name: "Old name"))
        let renamed = Self.makeFavorite(name: "New name")
        XCTAssertTrue(vm.contains(renamed))
        vm.toggle(renamed)
        XCTAssertTrue(vm.favorites.isEmpty)
    }

    func testCorruptedStorageIsPreservedAndCannotBeOverwrittenByToggle() throws {
        let suite = "FavoritesViewModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = Data("invalid-json".utf8)
        defaults.set(original, forKey: FavoritesViewModel.storageKey)
        let vm = FavoritesViewModel(defaults: defaults)
        XCTAssertNotNil(vm.storageError)
        vm.toggle(Self.makeFavorite())
        vm.remove(Self.makeFavorite())
        XCTAssertEqual(defaults.data(forKey: FavoritesViewModel.storageKey), original)
        XCTAssertTrue(vm.favorites.isEmpty)
    }

    func testInvalidRecordsFailClosedAndDuplicateRecordsAreDeduplicated() throws {
        let suite = "FavoritesViewModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let favorite = Self.makeFavorite()
        defaults.set(try JSONEncoder().encode([favorite, favorite]), forKey: FavoritesViewModel.storageKey)
        XCTAssertEqual(FavoritesViewModel(defaults: defaults).favorites.count, 1)
        let invalid = try JSONEncoder().encode([Self.makeFavorite(profile: " ")])
        defaults.set(invalid, forKey: FavoritesViewModel.storageKey)
        XCTAssertNotNil(FavoritesViewModel(defaults: defaults).storageError)
        XCTAssertEqual(defaults.data(forKey: FavoritesViewModel.storageKey), invalid)
    }

    func testSearchCoversNameIdentifierServiceAndScopeCaseInsensitively() {
        let favorite = Self.makeFavorite(name: "Production Web")
        for query in ["", "  WEB  ", "i-example", "ec2", "work", "111111111111", "US-EAST-1"] {
            XCTAssertTrue(favorite.matches(query))
        }
        XCTAssertFalse(favorite.matches("not-present"))
    }

    func testSerializedFavoritesContainOnlyResourceMetadata() throws {
        let data = try JSONEncoder().encode(Self.makeFavorite())
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(value.keys), ["profileName", "accountID", "region", "service", "resourceID", "displayName"])
    }

    static func makeFavorite(
        profile: String = "work",
        account: String = "111111111111",
        region: String = "us-east-1",
        service: AWSService = .ec2,
        resourceID: String = "i-example",
        name: String = "Example"
    ) -> ResourceFavorite {
        ResourceFavorite(profileName: profile, accountID: account, region: region,
                         service: service, resourceID: resourceID, displayName: name)
    }
}
