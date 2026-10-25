import Foundation

struct CostScope: Hashable, Sendable {
    let profile: AWSProfile
    let accountID: String
    let principalARN: String
    let configPath: String
    let credentialsPath: String

    var profileName: String { profile.name }

    init(profile: AWSProfile, identity: AWSIdentity, paths: AWSConfigurationPaths = AWSConfigurationPaths()) {
        self.profile = profile
        accountID = identity.account
        principalARN = identity.arn
        configPath = paths.config
        credentialsPath = paths.credentials
    }
}

enum CostDates {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func day(_ date: Date) -> Date { calendar.startOfDay(for: date) }

    static func string(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func date(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), string(date) == value else { return nil }
        return date
    }

    static func monthStart(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
    }

    static func earliestDate(now: Date) -> Date {
        calendar.date(byAdding: .month, value: -12, to: monthStart(now))!
    }

    static func inclusiveEnd(of range: CostDateRange) -> Date {
        calendar.date(byAdding: .day, value: -1, to: range.end)!
    }
}

struct CostDateRange: Hashable, Sendable {
    let start: Date
    let end: Date

    init(start: Date, end: Date) {
        self.start = CostDates.day(start)
        self.end = CostDates.day(end)
    }

    var startString: String { CostDates.string(start) }
    var endString: String { CostDates.string(end) }
    var isEmpty: Bool { start == end }
}

enum CostPeriod: String, CaseIterable, Identifiable {
    case thisMonth, lastMonth, last30Days, custom
    var id: Self { self }
    var title: String {
        switch self {
        case .thisMonth: return "This month"
        case .lastMonth: return "Last month"
        case .last30Days: return "Last 30 days"
        case .custom: return "Custom dates"
        }
    }

    func range(now: Date) -> CostDateRange {
        let today = CostDates.day(now)
        let month = CostDates.monthStart(today)
        switch self {
        case .thisMonth, .custom: return CostDateRange(start: month, end: today)
        case .lastMonth:
            return CostDateRange(start: CostDates.calendar.date(byAdding: .month, value: -1, to: month)!, end: month)
        case .last30Days:
            return CostDateRange(start: CostDates.calendar.date(byAdding: .day, value: -30, to: today)!, end: today)
        }
    }
}

struct CostQuery: Hashable, Sendable {
    let range: CostDateRange
    let region: String?
    let referenceDate: Date

    init(range: CostDateRange, region: String?, referenceDate: Date) {
        self.range = range
        self.region = region
        self.referenceDate = CostDates.day(referenceDate)
    }

    var currentMonthStart: Date { CostDates.monthStart(referenceDate) }
    var summaryRange: CostDateRange {
        CostDateRange(start: CostDates.calendar.date(byAdding: .month, value: -1, to: currentMonthStart)!, end: referenceDate)
    }
    var validationMessage: String? {
        guard range.start <= range.end else { return "The start date must be on or before the end date." }
        guard range.end <= referenceDate else { return "Choose completed UTC days. Today's costs are not included." }
        guard range.start >= CostDates.earliestDate(now: referenceDate) else {
            return "Choose dates within the current month or the previous 12 months."
        }
        return nil
    }
}

struct CostDailyAmount: Hashable, Sendable, Identifiable {
    let date: String
    let amount: Decimal
    var id: String { date }
}

struct CostServiceAmount: Hashable, Sendable, Identifiable {
    let name: String
    let amount: Decimal
    var id: String { name }
}

struct CostReport: Sendable {
    let query: CostQuery
    let currency: String?
    let thisMonth: Decimal?
    let lastMonth: Decimal?
    let daily: [CostDailyAmount]
    let services: [CostServiceAmount]
    let regions: [String]
    let estimated: Bool
    let fetchedAt: Date
    let apiRequestCount: Int
    var selectedTotal: Decimal { daily.reduce(0) { $0 + $1.amount } }
}

enum CostError: LocalizedError {
    case invalidQuery(String), invalidIdentity, unsupportedPartition, invalidResponse, incompletePagination

    var errorDescription: String? {
        switch self {
        case .invalidQuery(let message): return message
        case .invalidIdentity: return "Verify the selected profile's AWS account before loading costs."
        case .unsupportedPartition: return "Cost Explorer is supported here for standard AWS and AWS China accounts. This account's partition is not supported."
        case .invalidResponse: return "AWS returned incomplete or inconsistent cost data. No partial totals are shown. Try refreshing."
        case .incompletePagination: return "The complete cost result could not be retrieved. Narrow the date range and try again."
        }
    }
}
