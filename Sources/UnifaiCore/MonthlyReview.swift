import Foundation

public struct TimelinePage {
    public let entries: [TimelineEvent]
    public let index: Int
    public let pageCount: Int
    public let total: Int
    public let lower: Int
    public let upper: Int
    public init(events: [TimelineEvent], index: Int, size: Int = 25) {
        let size = max(1, size)
        let sorted = events.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
        total = sorted.count; pageCount = max(1, (total + size - 1) / size)
        self.index = min(max(0, index), pageCount - 1)
        let start = self.index * size
        entries = Array(sorted.dropFirst(start).prefix(size))
        lower = total == 0 ? 0 : start + 1; upper = min(start + size, total)
    }
}

public struct SubscriptionCostSummary {
    public var original: [Money]
    public var combined: Money?
    public var approximate: Bool
    public var missingRates: Bool
    public var text: String {
        let amount = combined.map { (approximate ? "≈ " : "") + $0.plainText } ?? original.map(\.plainText).joined(separator: " + ")
        return (amount.isEmpty ? "No scheduled charges" : amount + " / month expected")
    }
    public init(schedules: [SubscriptionSchedule], currency: String?, rates: RateTable?, now: Date = .now) {
        var totals: [String: Decimal] = [:]
        for schedule in schedules { totals[schedule.price.currency, default: 0] += schedule.cadence == .yearly ? schedule.price.amount / 12 : schedule.price.amount }
        original = totals.keys.sorted().map { Money(totals[$0]!.rounded2, $0) }
        combined = nil; approximate = false; missingRates = false
        if let currency {
            var amount: Decimal = 0
            for value in original {
                if value.currency == currency { amount += value.amount }
                else if let converted = rates?.convert(value, to: currency, on: now) { amount += converted.amount; approximate = true }
                else { missingRates = true }
            }
            if !missingRates { combined = Money(amount.rounded2, currency) }
        }
    }
}

public struct MonthlyBudgetRecord: Codable, Equatable {
    public var budget: Money?
    public var recordedAt: Date
}

public struct MonthlyReview {
    public var month: DateInterval
    public var key: String
    public var breakdown: SpendingBreakdown
    public var previous: SpendingBreakdown?
    public var originalTotals: [Money]
    public var budgetRecord: MonthlyBudgetRecord?
    public var title: String { "Review " + month.start.formatted(.dateTime.month(.wide)) }
    public var unconfirmedCount: Int { breakdown.entries.filter { $0.status != .confirmed }.count }
    public var hasConversion: Bool { breakdown.entries.contains { $0.original.currency != breakdown.currency } }
    public var totalText: String {
        if breakdown.entries.isEmpty { return "No recorded spending" }
        if !breakdown.complete { return originalTotals.map(\.plainText).joined(separator: " + ") }
        return (hasConversion ? "≈ " : "") + breakdown.total.plainText
    }
    public var budgetText: String {
        guard let budgetRecord else { return "No historical budget saved for this month." }
        guard let budget = budgetRecord.budget else { return "No budget was set for this month." }
        guard breakdown.complete else { return "Budget comparison unavailable: some currency conversions are missing." }
        let difference = breakdown.total.amount - budget.amount
        let lead = hasConversion ? "At reference rates, recorded spending" : "Recorded spending"
        if difference > 0 { return "\(lead) is \(Money(difference, budget.currency).plainText) over the \(budget.plainText) budget." }
        if difference == 0 { return "\(lead) matches the \(budget.plainText) budget." }
        return "\(lead) is \(Money(-difference, budget.currency).plainText) under the \(budget.plainText) budget."
    }
    public var comparisonText: String? {
        guard breakdown.complete, let previous, previous.complete, !previous.entries.isEmpty else { return nil }
        let difference = breakdown.total.amount - previous.total.amount
        if difference == 0 { return "Same recorded total as the previous month." }
        let approximate = hasConversion || previous.entries.contains { $0.original.currency != breakdown.currency }
        return "\(approximate ? "≈ " : "")\(Money(abs(difference), breakdown.currency).plainText) \(difference > 0 ? "more" : "less") than the previous month."
    }
    public init(state: PersistentState, month date: Date, rates: RateTable?, now: Date = .now) {
        let calendar = Calendar.current
        let interval = calendar.dateInterval(of: .month, for: date)!
        month = interval
        key = Self.monthKey(date)
        budgetRecord = state.monthlyBudgetHistory?[key]
        let currency = budgetRecord?.budget?.currency ?? state.displayCurrency ?? MonthlyStatement.mainCurrency(state.payments.filter { $0.paidAt >= interval.start && $0.paidAt < interval.end }.map(\.money.currency))
        breakdown = state.spendingBreakdown(in: currency, rates: rates, since: month.start, through: Date(timeIntervalSinceReferenceDate: month.end.timeIntervalSinceReferenceDate.nextDown), includeAccruing: false, now: now)
        let totals = Dictionary(grouping: breakdown.entries, by: { $0.original.currency })
        originalTotals = totals.keys.sorted().map { Money(totals[$0]!.reduce(0) { $0 + $1.original.amount }, $0) }
        previous = nil
        if let prior = calendar.date(byAdding: .month, value: -1, to: month.start), let interval = calendar.dateInterval(of: .month, for: prior) {
            previous = state.spendingBreakdown(in: currency, rates: rates, since: interval.start, through: Date(timeIntervalSinceReferenceDate: interval.end.timeIntervalSinceReferenceDate.nextDown), includeAccruing: false, now: now)
        }
    }
    public static func monthKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year!, parts.month!)
    }
    public static func date(for key: String) -> Date? {
        guard key.range(of: "^[0-9]{4}-[0-9]{2}$", options: .regularExpression) != nil else { return nil }
        let parts = key.split(separator: "-")
        guard let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month), (1900...9999).contains(year) else { return nil }
        return Calendar.current.date(from: DateComponents(year: year, month: month, day: 1))
    }
    public static func lastClosedMonth(now: Date = .now) -> Date {
        Calendar.current.date(byAdding: .month, value: -1, to: Calendar.current.dateInterval(of: .month, for: now)!.start)!
    }
    public static func availableMonths(_ state: PersistentState, now: Date = .now) -> [Date] {
        let current = Calendar.current.dateInterval(of: .month, for: now)!.start
        return Array(Set(MonthlyStatement.months(state, now: now).filter { $0 < current } + [lastClosedMonth(now: now)])).sorted(by: >)
    }
}

@MainActor public extension AppStore {
    func captureCurrentMonthBudget(now: Date = .now) throws {
        let key = MonthlyReview.monthKey(now)
        guard state.monthlyBudgetHistory?[key] == nil else { return }
        try change { next in
            var history = next.monthlyBudgetHistory ?? [:]
            history[key] = .init(budget: next.monthlyBudget, recordedAt: now); next.monthlyBudgetHistory = history
        }
    }
    func setBudgetForMonth(_ month: Date, budget: Money?, now: Date = .now) throws {
        if let budget { guard budget.amount > 0, !budget.amount.isNaN, Money.validCurrency(budget.currency) else { throw ValidationError.message("Enter a positive budget and valid currency.") } }
        let key = MonthlyReview.monthKey(month)
        try change { next in
            var history = next.monthlyBudgetHistory ?? [:]; history[key] = .init(budget: budget, recordedAt: now); next.monthlyBudgetHistory = history
            if key == MonthlyReview.monthKey(now) { next.monthlyBudget = budget }
        }
    }
    func markMonthReviewed(_ month: Date) throws {
        try change { next in next.reviewedMonths = Array(Set((next.reviewedMonths ?? []) + [MonthlyReview.monthKey(month)])).sorted() }
    }
}

public struct MonthReviewReminder: Sendable {
    public var monthKey: String
    public var title: String
    public var body: String
    public var fireAt: Date?
    public var id: String { "month-review-" + monthKey }
    public static func pending(state: PersistentState, rates: RateTable?, handled: Set<String>, now: Date = .now) -> [MonthReviewReminder] {
        guard !state.accounts.isEmpty || !state.payments.isEmpty else { return [] }
        var reminders: [MonthReviewReminder] = []
        let last = MonthlyReview.lastClosedMonth(now: now), lastKey = MonthlyReview.monthKey(last)
        if !handled.contains(lastKey), !(state.reviewedMonths ?? []).contains(lastKey) {
            let review = MonthlyReview(state: state, month: last, rates: rates, now: now)
            reminders.append(.init(monthKey: lastKey, title: review.title,
                body: "Recorded: \(review.totalText). \(review.budgetText) Open your monthly review for the breakdown and \(review.unconfirmedCount) records needing confirmation.", fireAt: nil))
        }
        let current = Calendar.current.dateInterval(of: .month, for: now)!
        let key = MonthlyReview.monthKey(now)
        if !handled.contains(key), let date = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: current.end) {
            reminders.append(.init(monthKey: key, title: "Review " + current.start.formatted(.dateTime.month(.wide)),
                body: "The month has wrapped up. Open Unifai to review recorded spending, budget and receipts.", fireAt: date))
        }
        return reminders
    }
}
