import XCTest
@testable import AWSPlatform

@MainActor
final class ResourceListLoaderTests: XCTestCase {
    func testOnlyTheSelectedCoreServiceIsQueried() async {
        for service in AWSService.allCases {
            let fixture = Fixture()
            fixture.show(service)
            await fixture.waitForLoads()
            for candidate in Fixture.services {
                XCTAssertEqual(fixture.calls[candidate, default: 0], candidate == service ? 1 : 0,
                               "Showing \(service) must not preload \(candidate)")
            }
        }
    }

    func testOtherDestinationsAndUnreadyProfilesNeverQuery() async {
        let fixture = Fixture()
        for service in Fixture.services {
            for destination in [WorkspaceDestination.favorites, .recents, .costs, .health] {
                fixture.show(service, destination: destination)
            }
            fixture.show(service, isProfileReady: false)
        }
        await fixture.waitForLoads()
        XCTAssertTrue(fixture.calls.isEmpty)
        fixture.show(.lambda)
        await fixture.waitForLoads()
        XCTAssertEqual(fixture.calls, [.lambda: 1])
    }

    func testPendingNavigationSuppressesOrdinaryListQueries() async {
        let fixture = Fixture()
        for service in Fixture.services { fixture.show(service, isNavigating: true) }
        await fixture.waitForLoads()
        XCTAssertTrue(fixture.calls.isEmpty)
        await fixture.lambda.loadFunctions()
        fixture.show(.lambda)
        await fixture.waitForLoads()
        XCTAssertEqual(fixture.calls, [.lambda: 1])
    }

    func testSwitchingServicesReusesCompletedAndInFlightLoads() async {
        let fixture = Fixture()
        for service in Fixture.services { fixture.show(service) }
        for service in Fixture.services.reversed() { fixture.show(service) }
        await fixture.waitForLoads()
        for service in Fixture.services { fixture.show(service) }
        await fixture.waitForLoads()
        XCTAssertEqual(fixture.calls, [.ec2: 1, .lambda: 1, .s3: 1])
    }

    func testReturningToResourcesLoadsTheUnchangedServiceOnce() async {
        let fixture = Fixture()
        fixture.show(.s3, destination: .costs)
        fixture.show(.s3, destination: .resources)
        await fixture.waitForLoads()
        fixture.show(.s3, destination: .favorites)
        fixture.show(.s3, destination: .resources)
        await fixture.waitForLoads()
        XCTAssertEqual(fixture.calls, [.s3: 1])
    }

    func testResettingTheScopeOnlyReloadsTheCurrentlyVisibleService() async {
        let fixture = Fixture()
        for service in Fixture.services { fixture.show(service) }
        await fixture.waitForLoads()
        fixture.ec2.reset()
        fixture.lambda.reset()
        fixture.s3.reset()
        fixture.show(.lambda)
        await fixture.waitForLoads()
        XCTAssertEqual(fixture.calls, [.ec2: 1, .lambda: 2, .s3: 1])
    }

    func testManualRefreshDoesNotLoadOtherServices() async {
        let fixture = Fixture()
        fixture.show(.ec2)
        await fixture.waitForLoads()
        fixture.ec2.refresh()
        await fixture.waitForLoads()
        XCTAssertEqual(fixture.calls, [.ec2: 2])
    }

    @MainActor
    private final class Fixture {
        static let services: [AWSService] = [.ec2, .lambda, .s3]
        private let probe: Probe
        let ec2: EC2ViewModel
        let lambda: LambdaViewModel
        let s3: S3ViewModel
        var calls: [AWSService: Int] { probe.calls }

        init() {
            let probe = Probe()
            self.probe = probe
            ec2 = EC2ViewModel(instanceLoader: {
                probe.calls[.ec2, default: 0] += 1
                return []
            })
            lambda = LambdaViewModel(functionLoader: {
                probe.calls[.lambda, default: 0] += 1
                return []
            })
            s3 = S3ViewModel(bucketLoader: {
                probe.calls[.s3, default: 0] += 1
                return []
            })
        }

        func show(_ service: AWSService, destination: WorkspaceDestination = .resources,
                  isProfileReady: Bool = true, isNavigating: Bool = false) {
            ResourceListLoader.loadIfNeeded(service: service, destination: destination,
                isProfileReady: isProfileReady, isNavigating: isNavigating,
                ec2: ec2, lambda: lambda, s3: s3)
        }

        func waitForLoads() async {
            await ec2.waitForCurrentLoad()
            await lambda.waitForCurrentLoad()
            await s3.waitForCurrentLoad()
        }
    }

    @MainActor
    private final class Probe {
        var calls: [AWSService: Int] = [:]
    }
}
