import Foundation

/// One calendar month of spending for download: every payment in the month, plus usage still
/// accruing when the month is the current one. Built on the same breakdown as the dashboard, so
/// the statement and the app always agree.
public struct MonthlyStatement {
    public var month: DateInterval
    public var breakdown: SpendingBreakdown
    /// Signed totals in each original currency. Always exact, whether or not rates are available.
    public var originalTotals: [Money]
    /// False when no display currency is set, so totals stay separate per currency.
    public var converts: Bool

    public init(state: PersistentState, month date: Date, rates: RateTable?, now: Date = .now) {
        let calendar = Calendar.current
        let interval = calendar.dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 0)
        month = interval
        converts = state.displayCurrency != nil
        let currency = state.displayCurrency ?? Self.mainCurrency(state.payments.filter { interval.contains($0.paidAt) }.map(\.money.currency))
        breakdown = state.spendingBreakdown(in: currency, rates: rates, since: interval.start, through: interval.end.addingTimeInterval(-1), now: now)
        var totals: [String: Decimal] = [:]
        for entry in breakdown.entries { totals[entry.original.currency, default: 0] += entry.original.amount }
        originalTotals = totals.keys.sorted().map { Money(totals[$0]!, $0) }
    }

    /// Months that have at least one payment, newest first, always including the current month.
    public static func months(_ state: PersistentState, now: Date = .now) -> [Date] {
        let calendar = Calendar.current
        let starts = Set(state.payments.compactMap { calendar.dateInterval(of: .month, for: $0.paidAt)?.start }
                         + [calendar.dateInterval(of: .month, for: now)?.start].compactMap { $0 })
        return starts.filter { $0 <= now }.sorted(by: >)
    }

    /// The breakdown's notes, without the conversion notes when totals stay in separate currencies.
    public var notes: [String] { converts ? breakdown.notes : breakdown.notes.filter { !$0.localizedCaseInsensitiveContains("rate") } }

    /// One account's signed totals in each original currency.
    public func originalTotals(account id: String) -> [Money] {
        var totals: [String: Decimal] = [:]
        for entry in breakdown.entries where (entry.accountID?.uuidString ?? "unassigned") == id { totals[entry.original.currency, default: 0] += entry.original.amount }
        return totals.keys.sorted().map { Money(totals[$0]!, $0) }
    }

    public var title: String { month.start.formatted(.dateTime.month(.wide).year()) }
    /// Named by the local calendar month, which is how the statement's month is chosen.
    public var fileName: String {
        let components = Calendar.current.dateComponents([.year, .month], from: month.start)
        return String(format: "Unifai statement %04d-%02d", components.year ?? 0, components.month ?? 0)
    }
    public var isCurrentMonth: Bool { month.contains(breakdown.generatedAt) }

    /// One row per entry, oldest first, with the original amount and its conversion.
    public var csv: String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        var lines = ["date,account,description,kind,status,amount,currency,converted_amount,converted_currency,reference"]
        for entry in breakdown.entries.reversed() {
            let fields = [day.string(from: entry.date), entry.account ?? "Unassigned", entry.description, entry.kind, Self.status(entry.status),
                          "\(entry.original.amount)", entry.original.currency,
                          converts ? entry.converted.map { "\($0.amount.rounded2)" } ?? "" : "", converts && entry.converted != nil ? breakdown.currency : "",
                          entry.id.hasPrefix("accruing-") ? "" : entry.id]
            lines.append(fields.map(Self.cell).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func status(_ status: SpendingBreakdown.Status) -> String {
        switch status {
        case .confirmed: return "Confirmed"
        case .estimate: return "Estimate"
        case .automatic: return "Awaiting confirmation"
        case .accruing: return "Accruing"
        }
    }

    /// Quotes a CSV cell, and keeps text that a spreadsheet would run as a formula as plain text.
    static func cell(_ value: String) -> String {
        var text = value
        if let first = text.first, "=+@".contains(first) || (first == "-" && text.range(of: #"^-[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) == nil) { text = "'" + text }
        guard text.contains(where: { ",\"\n\r".contains($0) }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func mainCurrency(_ currencies: [String]) -> String {
        let counts = Dictionary(grouping: currencies, by: { $0 }).mapValues(\.count)
        return counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key ?? "USD"
    }
}
