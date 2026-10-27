import XCTest
@testable import UnifaiCore

final class MonthlyStatementTests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    func testStatementCoversOneLocalMonthWithSignedOriginalTotals() {
        var state = PersistentState()
        let account = ConnectedAccount(integrationID: "openrouter", label: "Dev", mode: .manual)
        state.accounts = [account]
        state.payments = [
            PaymentRecord(accountID: account.id, description: "September top-up", kind: .topUp, money: Money(5, "USD"), paidAt: date(2026, 9, 30)),
            PaymentRecord(accountID: account.id, description: "Credits, \"bulk\"", kind: .topUp, money: Money(20, "USD"), paidAt: date(2026, 10, 1)),
            PaymentRecord(accountID: account.id, description: "=SUM(A1)", kind: .refund, money: Money(3, "USD"), paidAt: date(2026, 10, 31)),
            PaymentRecord(accountID: account.id, description: "Plan", kind: .subscription, money: Money(30, "SGD"), paidAt: date(2026, 10, 15)),
            PaymentRecord(accountID: account.id, description: "November", kind: .topUp, money: Money(7, "USD"), paidAt: date(2026, 11, 1))
        ]
        let statement = MonthlyStatement(state: state, month: date(2026, 10, 20), rates: nil, now: date(2026, 12, 5))
        XCTAssertEqual(statement.fileName, "Unifai statement 2026-10")
        XCTAssertFalse(statement.isCurrentMonth)
        XCTAssertFalse(statement.converts)
        XCTAssertEqual(statement.breakdown.entries.count, 3)
        XCTAssertEqual(statement.originalTotals, [Money(30, "SGD"), Money(17, "USD")], "Refunds are subtracted")
        XCTAssertEqual(statement.originalTotals(account: account.id.uuidString), [Money(30, "SGD"), Money(17, "USD")])
        XCTAssertFalse(statement.notes.contains { $0.localizedCaseInsensitiveContains("rate") })

        let lines = statement.csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "date,account,description,kind,status,amount,currency,converted_amount,converted_currency,reference")
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[1].hasPrefix("2026-10-01,OpenRouter account · Dev,\"Credits, \"\"bulk\"\"\",Credit top-up,Confirmed,20,USD,,,"))
        XCTAssertTrue(lines[3].contains(",'=SUM(A1),Refund,Confirmed,-3,USD,"), "Formulas stay text; refunds are negative")
    }

    func testMonthsListPaymentMonthsNewestFirstWithTheCurrentMonth() {
        var state = PersistentState()
        state.payments = [PaymentRecord(description: "a", kind: .topUp, money: Money(1, "USD"), paidAt: date(2026, 8, 3)),
                          PaymentRecord(description: "b", kind: .topUp, money: Money(1, "USD"), paidAt: date(2026, 8, 20))]
        let months = MonthlyStatement.months(state, now: date(2026, 10, 28))
        XCTAssertEqual(months.map { Calendar.current.component(.month, from: $0) }, [10, 8])
    }

    func testCellQuotingAndFormulaGuard() {
        XCTAssertEqual(MonthlyStatement.cell("plain"), "plain")
        XCTAssertEqual(MonthlyStatement.cell("-12.5"), "-12.5")
        XCTAssertEqual(MonthlyStatement.cell("-cmd"), "'-cmd")
        XCTAssertEqual(MonthlyStatement.cell("+1,2"), "\"'+1,2\"")
        XCTAssertEqual(MonthlyStatement.cell("@x"), "'@x")
    }
}
