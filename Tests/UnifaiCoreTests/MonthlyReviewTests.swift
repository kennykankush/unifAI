import XCTest
@testable import UnifaiCore

final class MonthlyReviewTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-11-02T12:00:00Z")!
    var october: Date { Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))! }
    var rates: RateTable { RateTable(rates: ["2026-09-01":["USD":1.2,"SGD":1.5],"2026-10-01":["USD":1.2,"SGD":1.5],"2026-11-01":["USD":1.2,"SGD":1.5]], fetchedAt: now, currencies: ["USD","SGD"]) }
    func fixture() -> PersistentState {
        var state = PersistentState()
        state.displayCurrency = "SGD"
        let claude = ConnectedAccount(integrationID: "claude-subscription", label: "Fixture", mode: .manual)
        let refero = ConnectedAccount(integrationID: "custom", label: "Refero MCP", mode: .manual)
        state.accounts = [claude, refero]
        state.subscriptions = [.init(accountID: claude.id, name: "Claude", price: Money(330,"SGD"), cadence: .monthly, nextRenewal: now.addingTimeInterval(86400)), .init(accountID: refero.id, name: "Refero", price: Money(17,"USD"), cadence: .monthly, nextRenewal: now.addingTimeInterval(86400), autoRecord: false)]
        let a = PaymentRecord(accountID: claude.id, description: "Claude", kind: .subscription, money: Money(330,"SGD"), paidAt: october)
        let b = PaymentRecord(accountID: refero.id, description: "Refero", kind: .subscription, money: Money(17,"USD"), paidAt: october)
        let refund = PaymentRecord(accountID: refero.id, description: "Refund", kind: .refund, money: Money(10,"USD"), paidAt: october)
        var estimated = PaymentRecord(accountID: refero.id, description: "Usage estimate", kind: .usageCharge, money: Money(5,"USD"), paidAt: october)
        estimated.estimated = true
        let prior = PaymentRecord(accountID: claude.id, description: "September", kind: .subscription, money: Money(100,"SGD"), paidAt: Calendar.current.date(byAdding: .month, value: -1, to: october)!)
        state.payments = [a,b,refund,estimated,prior]
        var purchase = MCPPurchase(server: "refero", name: "Refero", plan: .monthly, startedAt: october, paymentID: b.id, accountID: refero.id)
        purchase.scheduleID = state.subscriptions[1].id
        state.mcpPurchases = [purchase]
        state.monthlyBudgetHistory = ["2026-10": .init(budget: Money(350,"SGD"), recordedAt: october)]
        state.events = (0..<76).map { TimelineEvent(id: "fixture-\($0)", date: now.addingTimeInterval(-Double($0)*60), kind: .news, title: "Fixture update \($0 + 1)", detail: "Synthetic timeline item", sourceName: "Fixture") }
        return state
    }
    func testPaginationIsBoundedStableAndClampsLastPage() {
        let events = fixture().events!
        let a = TimelinePage(events: events.reversed(), index: 0)
        let b = TimelinePage(events: events, index: 1)
        let last = TimelinePage(events: events, index: 99)
        XCTAssertEqual(a.entries.count,25); XCTAssertEqual(a.pageCount,4)
        XCTAssertEqual(a.lower,1); XCTAssertEqual(a.upper,25)
        XCTAssertEqual(b.lower,26); XCTAssertEqual(b.upper,50)
        XCTAssertTrue(Set(a.entries.map(\.id)).isDisjoint(with: b.entries.map(\.id)))
        XCTAssertEqual(last.index,3); XCTAssertEqual(last.entries.count,1)
        XCTAssertEqual(TimelinePage(events: [], index: -3).lower,0)
        XCTAssertEqual(TimelinePage(events: Array(events.prefix(4)), index: 8).index,0)
    }
    func testMonthlyExpectedIncludesEveryCurrencyAndAnnualNormalization() {
        var state = fixture()
        let total = SubscriptionCostSummary(schedules: state.subscriptions, currency: "SGD", rates: rates, now: now)
        XCTAssertEqual(total.combined, Money(351.25,"SGD")); XCTAssertTrue(total.approximate)
        let missing = SubscriptionCostSummary(schedules: state.subscriptions, currency: "SGD", rates: nil, now: now)
        XCTAssertNil(missing.combined); XCTAssertTrue(missing.missingRates)
        XCTAssertTrue(missing.text.contains("17.00 USD")); XCTAssertTrue(missing.text.contains("330.00 SGD"))
        state.subscriptions[1].cadence = .yearly; state.subscriptions[1].price = Money(204,"USD")
        XCTAssertEqual(SubscriptionCostSummary(schedules: state.subscriptions, currency: "SGD", rates: rates, now: now).combined, Money(351.25,"SGD"))
    }
    func testReviewKeepsRefundsEstimatesAndBudgetSeparate() throws {
        let state = fixture(), review = MonthlyReview(state: fixture(), month: october, rates: rates, now: now)
        XCTAssertEqual(review.breakdown.total, Money(345,"SGD"))
        XCTAssertEqual(review.breakdown.confirmedPayments, Money(338.75,"SGD"))
        XCTAssertEqual(review.breakdown.estimatedPayments, Money(6.25,"SGD"))
        XCTAssertEqual(review.unconfirmedCount,1)
        XCTAssertTrue(review.budgetText.contains("5.00 SGD")); XCTAssertTrue(review.budgetText.contains("under"))
        XCTAssertTrue(review.comparisonText!.contains("245.00 SGD"))
        XCTAssertEqual(review.breakdown.byAccount.count,2)
        if let path = ProcessInfo.processInfo.environment["UNIFAI_EXPORT_FINANCE_FIXTURE"] {
            let root = URL(fileURLWithPath: path)
            try StateRepository(directory: root).save(state)
            try RateStore(directory: root).save(rates)
        }
    }
    func testMissingRatesOrHistoricalBudgetNeverClaimsUnderBudget() {
        var state = fixture()
        XCTAssertTrue(MonthlyReview(state: state, month: october, rates: nil, now: now).budgetText.contains("unavailable"))
        state.monthlyBudgetHistory = nil; state.monthlyBudget = Money(1000,"SGD")
        XCTAssertTrue(MonthlyReview(state: state, month: october, rates: rates, now: now).budgetText.contains("No historical budget"))
        state.monthlyBudgetHistory = ["2026-10":.init(budget: Money(300,"SGD"), recordedAt: october)]
        XCTAssertTrue(MonthlyReview(state: state, month: october, rates: rates, now: now).budgetText.contains("over"))
    }
    func testMonthBoundaryIncludesFinalFractionalSecondButNotNextMonth() {
        var state = PersistentState(); state.displayCurrency = "SGD"
        let end = Calendar.current.dateInterval(of: .month, for: october)!.end
        state.payments = [.init(description: "Last instant", kind: .subscription, money: Money(1,"SGD"), paidAt: end.addingTimeInterval(-0.25)),
                          .init(description: "Next month", kind: .subscription, money: Money(99,"SGD"), paidAt: end)]
        XCTAssertEqual(MonthlyReview(state: state, month: october, rates: nil, now: now).breakdown.total, Money(1,"SGD"))
        let statement = MonthlyStatement(state: state, month: october, rates: nil, now: end)
        XCTAssertEqual(statement.breakdown.total,Money(1,"SGD"))
        XCTAssertFalse(statement.isCurrentMonth)
    }
    func testRemindersOnePerMonthAndCalendarBoundary() {
        let state = fixture()
        let reminders = MonthReviewReminder.pending(state: state, rates: rates, handled: [], now: now)
        XCTAssertEqual(reminders.map(\.monthKey),["2026-10","2026-11"])
        XCTAssertNil(reminders[0].fireAt)
        XCTAssertEqual(Calendar.current.component(.month, from: reminders[1].fireAt!),12)
        XCTAssertEqual(Calendar.current.component(.day, from: reminders[1].fireAt!),1)
        XCTAssertEqual(Calendar.current.component(.hour, from: reminders[1].fireAt!),9)
        XCTAssertTrue(MonthReviewReminder.pending(state: state, rates: rates, handled: Set(reminders.map(\.monthKey)), now: now).isEmpty)
        var reviewed = state; reviewed.reviewedMonths = ["2026-10"]
        XCTAssertEqual(MonthReviewReminder.pending(state: reviewed, rates: rates, handled: [], now: now).map(\.monthKey), ["2026-11"])
        XCTAssertTrue(MonthReviewReminder.pending(state: PersistentState(), rates: nil, handled: [], now: now).isEmpty)
        let january = Calendar.current.date(from: DateComponents(year: 2027, month: 1, day: 2))!
        XCTAssertEqual(MonthlyReview.monthKey(MonthlyReview.lastClosedMonth(now: january)),"2026-12")
        XCTAssertNil(MonthlyReview.date(for:"2026-13"))
    }
}

@MainActor final class MonthlyBudgetHistoryTests: XCTestCase {
    func testCaptureDoesNotInventHistoricalBudgetsAndHistoricalEditKeepsCurrentBudget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unifai-month-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(repository: StateRepository(directory: root), vault: MemoryVault())
        let november = Calendar.current.date(from: DateComponents(year:2026,month:11,day:2))!
        let october = Calendar.current.date(byAdding:.month,value:-1,to:november)!
        try store.captureCurrentMonthBudget(now: november)
        XCTAssertNil(store.state.monthlyBudgetHistory?["2026-10"])
        try store.setBudgetForMonth(november, budget: Money(500,"SGD"), now: november)
        try store.setBudgetForMonth(october, budget: Money(350,"SGD"), now: november)
        XCTAssertEqual(store.state.monthlyBudget,Money(500,"SGD"))
        XCTAssertEqual(store.state.monthlyBudgetHistory?["2026-10"]?.budget,Money(350,"SGD"))
        try store.markMonthReviewed(october)
        XCTAssertEqual(try store.repository.load().reviewedMonths,["2026-10"])
        XCTAssertTrue(store.state.payments.isEmpty)
    }
}
