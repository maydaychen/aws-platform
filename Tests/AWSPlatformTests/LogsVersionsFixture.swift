import Foundation
import SotoCore
import SotoCloudWatchLogs
import SotoS3
@testable import AWSPlatform

struct LogsVersionsFixtureError: AWSErrorType {
    let errorCode: String
    var context: AWSErrorContext? { nil }
    var description: String { errorCode + ": private-test-content" }
    init(_ code: String) { errorCode = code }
    init?(errorCode: String, context: AWSErrorContext) { self.errorCode = errorCode }
}

func logsVersionsScope(profile: String = "work", account: String = "111122223333", region: String = "eu-west-1",
                       configPath: String = "/example/config", role: String = "Test") -> MonitoringScope {
    MonitoringScope(profile: AWSProfile(name: profile, region: region, ssoStartURL: nil, ssoRegion: nil,
                                        ssoAccountID: nil, ssoRoleName: nil),
        identity: .init(account: account, arn: "arn:aws:sts::\(account):assumed-role/\(role)/session", userID: "fixture"),
        region: region, paths: .init(environment: ["AWS_CONFIG_FILE": configPath, "AWS_SHARED_CREDENTIALS_FILE": "/example/credentials"]))
}

func logsBrowserGroup(_ name: String = "/application/main", scope: MonitoringScope = logsVersionsScope()) -> CloudWatchLogGroup {
    .init(arn: "arn:aws:logs:\(scope.region):\(scope.accountID):log-group:\(name)", name: name,
          createdAt: nil, retentionDays: nil, storedBytes: nil, logClass: nil, kmsKeyID: nil)
}

func logsBrowserQuery(scope: MonitoringScope = logsVersionsScope(), group: CloudWatchLogGroup? = nil,
                      stream: String? = nil, pattern: String = "") -> CloudWatchLogsBrowserQuery {
    .init(scope: scope, group: group ?? logsBrowserGroup(scope: scope), streamName: stream,
          startTime: Date(timeIntervalSince1970: 1_700_000_000), endTime: Date(timeIntervalSince1970: 1_700_003_600),
          filterPattern: pattern)
}

func versionsContext(region: String? = "eu-west-1", scope: MonitoringScope = logsVersionsScope()) -> S3TransferContext {
    .init(scope: scope, bucket: "example-bucket", prefix: "reports/", knownRegion: region)
}

func versionsTarget(context: S3TransferContext = versionsContext(), key: String = "reports/summary.csv") -> S3VersionsTarget {
    .init(context: context, key: key, region: "eu-west-1")
}

actor LogsVersionsGate {
    private var entered = false
    private var opened = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        entered = true
        entryWaiters.forEach { $0.resume() }; entryWaiters = []
        if !opened { await withCheckedContinuation { waiting = $0 } }
    }
    func waitForEntry() async { if !entered { await withCheckedContinuation { entryWaiters.append($0) } } }
    func open() { opened = true; waiting?.resume(); waiting = nil }
}

actor LogsBrowserFixture {
    let groups: [CloudWatchLogs.DescribeLogGroupsResponse]
    let streams: [CloudWatchLogs.DescribeLogStreamsResponse]
    let events: [CloudWatchLogs.FilterLogEventsResponse]
    let failAt: Int?
    private(set) var groupInputs: [CloudWatchLogs.DescribeLogGroupsRequest] = []
    private(set) var streamInputs: [CloudWatchLogs.DescribeLogStreamsRequest] = []
    private(set) var eventInputs: [CloudWatchLogs.FilterLogEventsRequest] = []
    init(groups: [CloudWatchLogs.DescribeLogGroupsResponse] = [.init()],
         streams: [CloudWatchLogs.DescribeLogStreamsResponse] = [.init()],
         events: [CloudWatchLogs.FilterLogEventsResponse] = [.init()], failAt: Int? = nil) {
        self.groups = groups; self.streams = streams; self.events = events; self.failAt = failAt
    }
    func loadGroups(_ input: CloudWatchLogs.DescribeLogGroupsRequest) throws -> CloudWatchLogs.DescribeLogGroupsResponse {
        let index = groupInputs.count; groupInputs.append(input)
        if failAt == index { throw LogsVersionsFixtureError("AccessDeniedException") }
        return index < groups.count ? groups[index] : .init()
    }
    func loadStreams(_ input: CloudWatchLogs.DescribeLogStreamsRequest) throws -> CloudWatchLogs.DescribeLogStreamsResponse {
        let index = streamInputs.count; streamInputs.append(input)
        if failAt == index { throw LogsVersionsFixtureError("AccessDeniedException") }
        return index < streams.count ? streams[index] : .init()
    }
    func loadEvents(_ input: CloudWatchLogs.FilterLogEventsRequest) throws -> CloudWatchLogs.FilterLogEventsResponse {
        let index = eventInputs.count; eventInputs.append(input)
        if failAt == index { throw LogsVersionsFixtureError("AccessDeniedException") }
        return index < events.count ? events[index] : .init()
    }
    nonisolated var service: AWSCloudWatchLogsBrowserService {
        .init(groupLoader: { try await self.loadGroups($0) }, streamLoader: { try await self.loadStreams($0) },
              eventLoader: { try await self.loadEvents($0) })
    }
}

actor S3VersionsFixture {
    let pages: [S3.ListObjectVersionsOutput]
    let region: String
    let failAt: Int?
    private(set) var regionContexts: [S3TransferContext] = []
    private(set) var targets: [S3VersionsTarget] = []
    private(set) var inputs: [S3.ListObjectVersionsRequest] = []
    init(pages: [S3.ListObjectVersionsOutput] = [], region: String = "eu-west-1", failAt: Int? = nil) {
        self.pages = pages; self.region = region; self.failAt = failAt
    }
    func loadRegion(_ context: S3TransferContext) -> String { regionContexts.append(context); return region }
    func load(_ target: S3VersionsTarget, _ input: S3.ListObjectVersionsRequest) throws -> S3.ListObjectVersionsOutput {
        let index = inputs.count; inputs.append(input); targets.append(target)
        if failAt == index { throw LogsVersionsFixtureError("AccessDenied") }
        return index < pages.count ? pages[index] : .init(isTruncated: false, name: target.context.bucket, prefix: target.key)
    }
    nonisolated var service: AWSS3VersionsService {
        .init(regionLoader: { await self.loadRegion($0) }, loader: { try await self.load($0, $1) })
    }
}
