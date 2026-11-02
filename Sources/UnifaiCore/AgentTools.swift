import Foundation

/// Rich agent queries over saved data only. No AppStore, Keychain, network or writes.
public enum AgentTools {
    private static let accountParameter: [String: Any] = ["type": "string", "description": "Exact account UUID from get_balances."]
    private static let limitParameter: [String: Any] = ["type": "integer", "minimum": 1, "maximum": 200, "description": "Rows to return, default 100. Totals include all matching rows."]
    public static var definitions: [[String: Any]] {
        [
            definition("get_mcp_activity", "Observed MCP activity and purchases",
                       "Returns saved metadata-only MCP usage summaries and explicitly linked purchases. Partial local-history coverage, not provider billing or quotas. Never scans files or refreshes.", [:]),
            definition("get_spending_breakdown", "Explain a spending total",
                       "Explains the dashboard arithmetic with original and converted amounts, exchange-rate notes, confirmed/estimated/automatic payments, accruing usage and per-account subtotals. Defaults to this calendar month in the display currency. Current usage cannot be allocated to a historical or partial-month range.",
                       ["period": ["type": "string", "enum": ["month", "all"], "default": "month"],
                        "since": ["type": "string", "description": "Inclusive YYYY-MM-DD or ISO timestamp; overrides period's start."],
                        "through": ["type": "string", "description": "Inclusive date or timestamp. A date includes the whole local day."],
                        "currency": ["type": "string", "description": "ISO display currency; defaults to the user's preference, then USD."],
                        "account_id": accountParameter, "include_accruing": ["type": "boolean", "default": true],
                        "limit": limitParameter, "offset": ["type": "integer", "minimum": 0, "maximum": 100000]]),
            definition("get_payment", "Inspect a payment",
                       "Returns an exact payment, its confirmation state and retained top-up evidence when available. Older detections may have no before/after evidence. This tool cannot confirm or edit anything.",
                       ["payment_id": ["type": "string", "description": "Exact payment UUID from a spending breakdown or payment report."]], required: ["payment_id"]),
            definition("get_unconfirmed_payments", "Payments needing confirmation",
                       "Lists estimates and automatic renewals with evidence, original currencies and a receipt-search prompt. Nothing is confirmed or imported. Totals cover all matching records.",
                       ["account_id": accountParameter, "limit": limitParameter, "offset": ["type": "integer", "minimum": 0, "maximum": 100000]]),
            definition("get_account_details", "Inspect an AI or cloud wallet",
                       "Returns one account's saved reading, coverage, failure/freshness, payment totals, recent payments, renewals and available cloud services, resource costs and daily usage. No credentials or live refresh.",
                       ["account_id": accountParameter, "limit": limitParameter], required: ["account_id"]),
            definition("get_renewal_outlook", "Expected upcoming charges",
                       "Expands saved recurring schedules across the next 1–366 days. Separates overdue schedules, sums expected charges per currency and optionally converts using current reference rates. This is scheduled cost, not paid spending or a cloud-usage forecast.",
                       ["within_days": ["type": "integer", "minimum": 1, "maximum": 366, "default": 30],
                        "currency": ["type": "string"], "account_id": accountParameter]),
            definition("get_data_health", "Check coverage and freshness",
                       "Shows which wallets are manual, missing a reading, stale or failing; history completeness; unconfirmed payment counts; and the budget including accruing usage. Use before drawing conclusions from incomplete data.", [:])
        ]
    }

    private static func definition(_ name: String, _ title: String, _ description: String, _ properties: [String: Any],
                                   required: [String] = []) -> [String: Any] {
        ["name": name, "title": title, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
         "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]]
    }

    public struct PaymentDetail: Codable {
        public var id: UUID
        public var accountID: UUID?
        public var account: String?
        public var description: String
        public var kind: String
        public var money: Money
        public var signedAmount: String
        public var status: String
        public var paidAt: Date
        public var createdAt: Date
        public var confirmedAt: Date?
        public var reference: String?
        public var sourceReference: String?
        public var detection: TopUpEvidence?
        public init(_ record: PaymentRecord, state: PersistentState) {
            id = record.id; accountID = record.accountID; account = AgentReport.accountName(state, record.accountID)
            description = record.description; kind = record.kind.rawValue; money = record.money
            signedAmount = "\(record.kind == .refund ? -record.money.amount : record.money.amount)"
            status = record.estimated == true ? "estimate" : record.scheduleID != nil ? "automatic" : "confirmed"
            paidAt = record.paidAt; createdAt = record.createdAt; confirmedAt = record.confirmedAt
            reference = record.reference.isEmpty ? nil : record.reference; detection = record.detection
            sourceReference = record.sourceReference
        }
    }
    public struct BreakdownPage: Codable {
        public var breakdown: SpendingBreakdown
        public var totalEntries: Int
        public var offset: Int
        public var hasMore: Bool
    }
    public struct Review: Codable {
        public var generatedAt: Date
        public var totalEntries: Int
        public var offset: Int
        public var hasMore: Bool
        public var totalsByCurrency: [Money]
        public var payments: [PaymentDetail]
        public var receiptRequest: String
    }
    public struct AccountDetail: Codable {
        public var balance: AgentReport.Balance
        public var snapshot: BalanceSnapshot?
        public var lastAttempt: Date?
        public var paymentsByCurrency: [Money]
        public var paymentCount: Int
        public var recentPayments: [PaymentDetail]
        public var renewals: [AgentReport.Renewal]
    }
    public struct ExpectedCharge: Codable {
        public var scheduleID: UUID
        public var accountID: UUID?
        public var name: String
        public var date: Date
        public var price: Money
    }
    public struct Outlook: Codable {
        public var generatedAt: Date
        public var through: Date
        public var charges: [ExpectedCharge]
        public var overdue: [ExpectedCharge]
        public var totalsByCurrency: [Money]
        public var convertedTotal: Money
        public var conversionComplete: Bool
        public var note: String
    }
    public struct AccountHealth: Codable {
        public var accountID: UUID
        public var name: String
        public var status: String
        public var observedAt: Date?
        public var ageSeconds: Int?
        public var lastError: String?
        public var coverage: String?
    }
    public struct Health: Codable {
        public var generatedAt: Date
        public var accounts: [AccountHealth]
        public var paymentCount: Int
        public var unconfirmedCount: Int
        public var historyConfirmedComplete: Bool
        public var historyCoverage: String
        public var exchangeRatesFetchedAt: Date?
        public var budget: AgentReport.Budget?
    }

    public static func call(_ name: String, arguments: [String: Any], state: PersistentState, rates: RateTable?, now: Date = .now) throws -> Data {
        guard let definition = definitions.first(where: { $0["name"] as? String == name }),
              let schema = definition["inputSchema"] as? [String: Any],
              let properties = schema["properties"] as? [String: Any] else { throw ValidationError.message("Unknown tool: \(name)") }
        guard Set(arguments.keys).isSubset(of: Set(properties.keys)) else { throw ValidationError.message("Unknown argument for \(name).") }
        for key in schema["required"] as? [String] ?? [] where arguments[key] == nil { throw ValidationError.message("\(key) is required.") }
        let encoder = AgentReport.encoder()
        let accountID = try uuid(arguments, "account_id")
        if let accountID, !state.accounts.contains(where: { $0.id == accountID }) { throw ValidationError.message("Account not found. Use an account_id from get_balances.") }
        let limit = try integer(arguments, "limit", default: 100, range: 1...200)
        let offset = try integer(arguments, "offset", default: 0, range: 0...100000)
        let currency = try string(arguments, "currency")?.uppercased() ?? state.displayCurrency ?? "USD"
        guard Money.validCurrency(currency) else { throw ValidationError.message("currency must be a supported ISO currency code.") }
        switch name {
        case "get_mcp_activity":
            struct Report: Codable { let coverage: String; let scannedAt: Date?; let services: [MCPServiceSummary] }
            return try encoder.encode(Report(coverage: state.mcpScan?.coverage ?? "No local history scan recorded.", scannedAt: state.mcpScan?.date, services: state.mcpServices(now: now)))
        case "get_spending_breakdown":
            let period = try string(arguments, "period") ?? "month"
            guard ["month", "all"].contains(period) else { throw ValidationError.message("period must be month or all.") }
            let since = try date(arguments, "since") ?? (period == "month" ? Calendar.current.dateInterval(of: .month, for: now)?.start : nil)
            let through = try date(arguments, "through", endOfDay: true)
            guard since == nil || since! <= min(through ?? now, now) else { throw ValidationError.message("since must not be after through or the present.") }
            var result = state.spendingBreakdown(in: currency, rates: rates, since: since, through: through,
                                                includeAccruing: try boolean(arguments, "include_accruing", default: true), accountID: accountID, now: now)
            let count = result.entries.count
            result.entries = Array(result.entries.dropFirst(offset).prefix(limit))
            return try encoder.encode(BreakdownPage(breakdown: result, totalEntries: count, offset: offset, hasMore: offset + result.entries.count < count))
        case "get_payment":
            guard let id = try uuid(arguments, "payment_id"), let record = state.payments.first(where: { $0.id == id }) else {
                throw ValidationError.message("Payment not found. Use a payment_id from get_spending_breakdown.")
            }
            return try encoder.encode(PaymentDetail(record, state: state))
        case "get_unconfirmed_payments":
            let all = state.payments.filter { $0.autoRecorded && (accountID == nil || $0.accountID == accountID) }.sorted { $0.paidAt < $1.paidAt }
            let page = Array(all.dropFirst(offset).prefix(limit))
            return try encoder.encode(Review(generatedAt: now, totalEntries: all.count, offset: offset, hasMore: offset + page.count < all.count,
                                             totalsByCurrency: Ledger.paidTotals(all, through: now), payments: page.map { PaymentDetail($0, state: state) },
                                             receiptRequest: page.isEmpty ? "No unconfirmed payments in this page." : state.receiptRequest(for: page)))
        case "get_account_details":
            guard let account = state.accounts.first(where: { $0.id == accountID }) else { throw ValidationError.message("account_id is required.") }
            var scoped = state; scoped.accounts = [account]; scoped.subscriptions = state.subscriptions.filter { $0.accountID == account.id }
            let payments = state.payments.filter { $0.accountID == account.id }.sorted { $0.paidAt > $1.paidAt }
            return try encoder.encode(AccountDetail(balance: AgentReport.balances(scoped, now: now)[0], snapshot: account.snapshot, lastAttempt: account.lastAttempt,
                                                     paymentsByCurrency: Ledger.paidTotals(payments, through: now), paymentCount: payments.count,
                                                     recentPayments: payments.prefix(limit).map { PaymentDetail($0, state: state) },
                                                     renewals: AgentReport.renewals(scoped, now: now)))
        case "get_renewal_outlook":
            let days = try integer(arguments, "within_days", default: 30, range: 1...366)
            return try encoder.encode(outlook(state, rates: rates, currency: currency, days: days, accountID: accountID, now: now))
        case "get_data_health":
            return try encoder.encode(health(state, rates: rates, now: now))
        default: throw ValidationError.message("Unknown tool: \(name)")
        }
    }

    public static func health(_ state: PersistentState, rates: RateTable?, now: Date = .now) -> Health {
        Health(generatedAt: now, accounts: state.accounts.map { account in
            let status = account.mode == .manual ? "manual" : account.lastError != nil ? "failed" : account.snapshot == nil ? "missing"
                : account.snapshot!.isStale(at: now) ? "stale" : "fresh"
            return AccountHealth(accountID: account.id, name: AgentReport.accountName(state, account.id) ?? account.label, status: status,
                                 observedAt: account.snapshot?.observedAt, ageSeconds: account.snapshot.map { max(0, Int(now.timeIntervalSince($0.observedAt))) },
                                 lastError: account.lastError, coverage: account.snapshot?.coverage)
        }, paymentCount: state.payments.count, unconfirmedCount: state.payments.filter(\.autoRecorded).count,
               historyConfirmedComplete: state.historyCoverage?.completeForPeriod == true, historyCoverage: state.coverageDescription,
               exchangeRatesFetchedAt: rates?.fetchedAt, budget: AgentReport.overview(state, now: now, rates: rates).budget)
    }

    public static func outlook(_ state: PersistentState, rates: RateTable?, currency: String, days: Int, accountID: UUID? = nil, now: Date = .now) -> Outlook {
        let start = Calendar.current.startOfDay(for: now)
        let end = Calendar.current.date(byAdding: .day, value: days, to: start)!
        var charges: [ExpectedCharge] = [], overdue: [ExpectedCharge] = []
        for plan in state.subscriptions where accountID == nil || plan.accountID == accountID {
            if plan.nextRenewal < start {
                overdue.append(.init(scheduleID: plan.id, accountID: plan.accountID, name: plan.name, date: plan.nextRenewal, price: plan.price))
                continue // An overdue schedule needs review before projecting further charges.
            }
            var date = plan.nextRenewal
            for _ in 0..<13 where date < end {
                charges.append(.init(scheduleID: plan.id, accountID: plan.accountID, name: plan.name, date: date, price: plan.price))
                let next = plan.advanced(from: date)
                guard next > date else { break }
                date = next
            }
        }
        var totals: [String: Decimal] = [:], combined: Decimal = 0
        var complete = true
        for charge in charges {
            totals[charge.price.currency, default: 0] += charge.price.amount
            if let money = charge.price.currency == currency ? charge.price : rates?.convert(charge.price, to: currency, on: now) { combined += money.amount }
            else { complete = false }
        }
        return Outlook(generatedAt: now, through: end, charges: charges.sorted { $0.date < $1.date }, overdue: overdue.sorted { $0.date < $1.date },
                       totalsByCurrency: totals.keys.sorted().map { Money(totals[$0]!, $0) }, convertedTotal: Money(combined, currency), conversionComplete: complete,
                       note: "Expected renewals before through, based on saved schedules. Overdue schedules are excluded from projections. Converted totals use current reference rates, not future card rates. Cloud usage, future top-ups and actual payments are excluded.")
    }

    private static func string(_ args: [String: Any], _ key: String) throws -> String? {
        guard let value = args[key] else { return nil }
        guard let text = value as? String else { throw ValidationError.message("\(key) must be a string.") }
        return text
    }
    private static func uuid(_ args: [String: Any], _ key: String) throws -> UUID? {
        guard let text = try string(args, key) else { return nil }
        guard let id = UUID(uuidString: text) else { throw ValidationError.message("\(key) must be a UUID.") }
        return id
    }
    private static func integer(_ args: [String: Any], _ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = args[key] else { return fallback }
        guard let number = raw as? NSNumber, String(cString: number.objCType) != "c", number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue, number.doubleValue >= Double(range.lowerBound),
              number.doubleValue <= Double(range.upperBound) else { throw ValidationError.message("\(key) must be an integer from \(range.lowerBound) to \(range.upperBound).") }
        return number.intValue
    }
    private static func boolean(_ args: [String: Any], _ key: String, default fallback: Bool) throws -> Bool {
        guard let raw = args[key] else { return fallback }
        guard let number = raw as? NSNumber, String(cString: number.objCType) == "c" else { throw ValidationError.message("\(key) must be true or false.") }
        return number.boolValue
    }
    private static func date(_ args: [String: Any], _ key: String, endOfDay: Bool = false) throws -> Date? {
        guard let text = try string(args, key) else { return nil }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = .current; format.dateFormat = "yyyy-MM-dd"; format.isLenient = false
        if let date = format.date(from: text), format.string(from: date) == text {
            return endOfDay ? Calendar.current.date(byAdding: .day, value: 1, to: date)!.addingTimeInterval(-0.001) : date
        }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: text) { return date }
        throw ValidationError.message("\(key) must be YYYY-MM-DD or an ISO timestamp.")
    }
}
