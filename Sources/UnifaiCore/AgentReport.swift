import Foundation

/// Read-only views of saved state for external agents (the MCP server).
/// Built only from `PersistentState`: no credentials, no network and no writes.
/// Measures stay separate, as in the app: remaining credit, money paid and expected renewals
/// are never added together, and currencies are never combined.
public enum AgentReport {
    public struct Amount: Codable, Equatable {
        public var amount: String
        public var currency: String
        init(_ money: Money) { amount = "\(money.amount)"; currency = money.currency }
    }

    public struct Allowance: Codable, Equatable {
        public var name: String
        public var usedPercent: Int
        public var remainingPercent: Int
        public var windowMinutes: Int?
        public var resetsAt: Date?
    }

    public struct Balance: Codable, Equatable {
        public var accountID: String
        public var provider: String
        public var providerID: String
        public var label: String
        public var billingOwner: String?
        public var mode: String
        public var creditRemaining: [Amount]
        public var details: [String: Amount]
        public var reportedConsumption: [Amount]
        public var observedAt: Date?
        public var stale: Bool
        public var lastError: String?
        public var coverage: String?
        public var source: String?
        public var note: String?
        public var plan: String?
        public var usageWindows: [Allowance]?
        public var limitReached: Bool?
        public var consumptionPeriod: String?
        public var freeResets: Int?
        public var planAdvice: String?
        public var costSpikes: [String]?
    }

    public struct Payment: Codable, Equatable {
        public var id: String
        public var accountID: String?
        public var status: String
        public var description: String
        public var kind: String
        public var amount: Amount
        public var signedAmount: String
        public var paidAt: Date
        public var account: String?
        public var reference: String?
        public var autoRecorded: Bool
    }

    public struct Spending: Codable, Equatable {
        public var paidTotals: [Amount]
        /// All payments in the user's display currency at ECB rates on each payment date. Approximate.
        public var paidTotalConverted: Amount?
        public var conversionNote: String?
        public var since: Date?
        public var coverage: String
        public var historyConfirmedComplete: Bool
        public var payments: [Payment]
        public var note: String
    }

    public struct Renewal: Codable, Equatable {
        public var name: String
        public var expected: Amount
        public var cadence: String
        public var nextRenewal: Date
        public var daysUntil: Int
        public var overdue: Bool
        public var account: String?
    }

    public struct Accrual: Codable, Equatable { public var provider: String; public var label: String; public var amount: Amount }
    public struct Budget: Codable, Equatable { public var monthly: Amount; public var spentIncludingAccruing: Amount; public var percentUsed: Int; public var complete: Bool }

    public struct Overview: Codable, Equatable {
        public var generatedAt: Date
        public var balances: [Balance]
        public var paidTotals: [Amount]
        public var paidTotalConverted: Amount?
        public var conversionNote: String?
        public var paymentCoverage: String
        /// Money paid plus this month's pay-as-you-go usage, per currency: what AI has cost so far.
        public var totalSpentIncludingAccruing: [Amount]
        /// Pay-as-you-go usage building up this month (Azure and similar), not yet invoiced.
        public var accruingThisMonth: [Accrual]
        public var budget: Budget?
        public var upcomingRenewals: [Renewal]
        public var accountsNeedingAttention: [String]
        public var note: String
    }

    static func accountName(_ state: PersistentState, _ id: UUID?) -> String? {
        guard let id, let account = state.accounts.first(where: { $0.id == id }) else { return nil }
        return "\(Catalogue.integration(account.integrationID)?.name ?? account.integrationID) · \(account.label)"
    }

    static func matches(_ account: ConnectedAccount, _ filter: String?) -> Bool {
        guard let filter = filter?.trimmingCharacters(in: .whitespaces), !filter.isEmpty else { return true }
        let name = Catalogue.integration(account.integrationID)?.name ?? ""
        return [account.integrationID, name, account.label, account.billingScope].contains { $0.localizedCaseInsensitiveContains(filter) }
    }

    public static func balances(_ state: PersistentState, provider: String? = nil, now: Date = .now) -> [Balance] {
        state.accounts.filter { matches($0, provider) }.map { account in
            let snapshot = account.snapshot
            var note: String?
            if account.mode == .manual { note = "Manual account. No balance API; see payments and renewals." }
            else if snapshot == nil { note = "No reading yet. Refresh this account in the Unifai app." }
            else if snapshot!.isStale(at: now) { note = "Reading is older than one hour. Refresh in the Unifai app for a current value." }
            return Balance(
                accountID: account.id.uuidString,
                provider: Catalogue.integration(account.integrationID)?.name ?? account.integrationID,
                providerID: account.integrationID,
                label: account.label,
                billingOwner: account.billingScope.isEmpty ? nil : account.billingScope,
                mode: account.mode.rawValue,
                creditRemaining: snapshot?.balances.map(Amount.init) ?? [],
                details: Dictionary(snapshot?.details.map { ($0.label, Amount($0.value)) } ?? [], uniquingKeysWith: { first, _ in first }),
                reportedConsumption: snapshot?.reportedConsumption.map(Amount.init) ?? [],
                observedAt: snapshot?.observedAt,
                stale: snapshot?.isStale(at: now) ?? false,
                lastError: account.lastError,
                coverage: snapshot?.coverage,
                source: snapshot?.source.absoluteString,
                note: note,
                plan: snapshot?.plan,
                usageWindows: snapshot?.allowances?.map {
                    Allowance(name: $0.name, usedPercent: $0.usedPercent, remainingPercent: 100 - $0.usedPercent, windowMinutes: $0.windowMinutes, resetsAt: $0.resetsAt)
                },
                limitReached: snapshot?.limitReached,
                consumptionPeriod: snapshot?.consumptionPeriod,
                freeResets: snapshot?.resetCredits?.count,
                planAdvice: PlanAdvisor.advice(for: account, events: state.events ?? [], now: now),
                costSpikes: snapshot?.anomalies.flatMap { $0.isEmpty ? nil : $0.map(\.summary) })
        }
    }

    // MARK: Headroom

    public struct HeadroomItem: Codable, Equatable {
        public var accountID: String
        public var provider: String
        public var providerID: String
        public var label: String
        /// allowance (plan limits), prepaid (credit balance) or payAsYouGo (billed for what you use).
        public var kind: String
        public var usableNow: Bool
        public var summary: String
        public var remainingPercent: Int?
        public var nextReset: Date?
        public var freeResets: Int?
        public var creditRemaining: [Amount]
        public var spentThisMonth: [Amount]
        public var observedAt: Date?
        public var stale: Bool
        public var lastError: String?
    }

    public struct Headroom: Codable, Equatable {
        public var generatedAt: Date
        public var recommendation: String
        /// Best first: plan allowances with room, then prepaid credit, then pay-as-you-go, then anything exhausted.
        public var ranked: [HeadroomItem]
        public var budget: Budget?
        public var unmeasuredAccounts: [String]
        public var note: String
    }

    static func relative(_ date: Date, from now: Date) -> String {
        let hours = date.timeIntervalSince(now) / 3600
        if hours < 1 { return "in under an hour" }
        if hours < 36 { return "in \(Int(hours.rounded())) hours" }
        return "in \(Int((hours / 24).rounded())) days"
    }

    /// Where there is capacity to spend right now, for an agent choosing a provider for heavy work.
    public static func headroom(_ state: PersistentState, now: Date = .now, rates: RateTable? = nil) -> Headroom {
        var scored: [(Double, HeadroomItem)] = []
        for account in state.accounts where account.mode == .live {
            guard let snapshot = account.snapshot else { continue }
            let provider = Catalogue.integration(account.integrationID)?.name ?? account.integrationID
            let stale = snapshot.isStale(at: now)
            let credits = snapshot.resetCredits?.count ?? 0
            if let windows = snapshot.allowances, !windows.isEmpty {
                let remaining = windows.map { 100 - $0.usedPercent }.min() ?? 0
                let blocking = windows.filter { $0.usedPercent >= 100 }.compactMap(\.resetsAt).max()
                let next = blocking ?? windows.compactMap(\.resetsAt).min()
                // Codex credits pay for usage past the plan's limits.
                let credit = snapshot.balances.first { $0.currency == "CREDITS" && $0.amount > 0 }
                let exhausted = remaining <= 0 || snapshot.limitReached == true
                var parts: [String] = []
                if exhausted {
                    let used = windows.filter { $0.usedPercent >= 100 }.map(\.name)
                    parts.append("\((used.isEmpty ? ["Limit"] : used).joined(separator: " and ")) used up\(blocking.map { ", resets \(relative($0, from: now))" } ?? "")")
                    if let credit { parts.append("\(credit.amountText) credits cover usage until then") }
                } else {
                    parts.append(windows.map { "\($0.name) \(100 - $0.usedPercent)% left" }.joined(separator: ", "))
                    if let credit { parts.append("\(credit.amountText) credits for usage past the limits") }
                }
                if credits > 0 { parts.append("\(credits) free reset\(credits == 1 ? "" : "s") available") }
                let usable = !exhausted || credit != nil
                let score = !exhausted ? 3 + Double(remaining) / 100 : credit != nil ? 1.8 : credits > 0 ? 0.5 : 0
                scored.append((score, HeadroomItem(
                    accountID: account.id.uuidString,
                    provider: provider, providerID: account.integrationID, label: account.label, kind: "allowance", usableNow: usable, summary: parts.joined(separator: "; "),
                    remainingPercent: remaining, nextReset: next, freeResets: credits > 0 ? credits : nil,
                    creditRemaining: snapshot.balances.map(Amount.init), spentThisMonth: [], observedAt: snapshot.observedAt, stale: stale, lastError: account.lastError)))
            } else if let balance = snapshot.balances.first {
                let floor = account.lowBalanceAlert ?? ConnectedAccount.defaultLowBalance(for: balance.currency)
                let usable = balance.amount > 0
                scored.append((usable ? (balance.amount >= floor ? 2 : 1.2) : 0, HeadroomItem(
                    accountID: account.id.uuidString,
                    provider: provider, providerID: account.integrationID, label: account.label, kind: "prepaid", usableNow: usable,
                    summary: "\(balance.plainText) credit left\(usable && balance.amount < floor ? ", below the low-balance alert" : "")",
                    remainingPercent: nil, nextReset: nil, freeResets: nil, creditRemaining: snapshot.balances.map(Amount.init),
                    spentThisMonth: [], observedAt: snapshot.observedAt, stale: stale, lastError: account.lastError)))
            } else if !snapshot.reportedConsumption.isEmpty, Catalogue.integration(account.integrationID)?.billing == .payAsYouGo {
                let spent = snapshot.reportedConsumption.map(\.plainText).joined(separator: ", ")
                scored.append((1, HeadroomItem(
                    accountID: account.id.uuidString,
                    provider: provider, providerID: account.integrationID, label: account.label, kind: "payAsYouGo", usableNow: true,
                    summary: "Billed per use; \(spent) \(snapshot.consumptionPeriod?.lowercased() ?? "so far")",
                    remainingPercent: nil, nextReset: nil, freeResets: nil, creditRemaining: [],
                    spentThisMonth: snapshot.reportedConsumption.map(Amount.init), observedAt: snapshot.observedAt, stale: stale, lastError: account.lastError)))
            }
        }
        for index in scored.indices where scored[index].1.stale || scored[index].1.lastError != nil {
            scored[index].0 = -1
            scored[index].1.usableNow = false
            scored[index].1.summary = "Refresh needed; last reading: " + scored[index].1.summary
        }
        let ranked = scored.sorted { $0.0 == $1.0 ? $0.1.accountID < $1.1.accountID : $0.0 > $1.0 }.map(\.1)
        let measured = Set(ranked.map(\.accountID))
        let unmeasured = state.accounts.filter { !measured.contains($0.id.uuidString) }.map { accountName(state, $0.id) ?? $0.label }
        let budget = overview(state, now: now, rates: rates).budget
        var recommendation: String
        if let best = ranked.first(where: \.usableNow) {
            recommendation = "Use \(best.provider) (\(best.label)) first: \(best.summary)."
        } else if ranked.contains(where: { $0.stale || $0.lastError != nil }) {
            recommendation = "No fresh reading confirms available capacity. Refresh the affected wallets in Unifai."
        } else if let waiting = ranked.first {
            recommendation = "Nothing has room right now. \(waiting.provider): \(waiting.summary)."
        } else {
            recommendation = "No live wallets with readings. Connect or refresh accounts in the Unifai app."
        }
        if let budget, budget.percentUsed >= 100 { recommendation += " The monthly budget is used up; avoid pay-as-you-go." }
        return Headroom(generatedAt: now, recommendation: recommendation, ranked: ranked, budget: budget, unmeasuredAccounts: unmeasured,
                        note: "Availability from saved readings, not a model-quality or task-compatibility recommendation. Stale or failed readings are not treated as usable now. Accounts without measurable capacity are listed separately. Free resets are redeemed in the provider's own app.")
    }

    // MARK: Timeline

    public struct Event: Codable, Equatable {
        public var date: Date
        public var kind: String
        public var title: String
        public var detail: String
        public var source: String?
        public var from: String
        public var important: Bool
        public var notice: ProductNotice? = nil
    }

    public static func timeline(_ state: PersistentState, kinds: Set<String>? = nil, since: Date? = nil, limit: Int = 30) -> [Event] {
        (state.events ?? []).filter { event in
            (kinds == nil || kinds!.contains(event.kind.rawValue.lowercased())) && (since == nil || event.date >= since!)
        }.prefix(max(0, limit)).map {
            Event(date: $0.date, kind: $0.kind.rawValue, title: $0.title, detail: $0.detail, source: $0.source?.absoluteString,
                  from: $0.sourceName, important: $0.important, notice: $0.notice)
        }
    }

    static func converted(_ state: PersistentState, rates: RateTable?, since: Date? = nil) -> (Amount?, String?) {
        guard let target = state.displayCurrency, let rates else { return (nil, nil) }
        var scoped = state
        if let since { scoped.payments = state.payments.filter { $0.paidAt >= since } }
        let result = scoped.payments(in: target, rates: rates)
        guard let total = Ledger.paidTotals(result.converted).first else { return (nil, nil) }
        var note = "Every payment converted to \(target) at the European Central Bank reference rate for its date. Approximate: card issuers use their own rates. Recorded amounts are unchanged."
        if !result.unconverted.isEmpty { note += " \(result.unconverted.count) payment(s) in currencies without a reference rate are excluded." }
        return (Amount(total), note)
    }

    public static func spending(_ state: PersistentState, since: Date? = nil, limit: Int = 20, rates: RateTable? = nil) -> Spending {
        let converted = converted(state, rates: rates, since: since)
        let records = state.payments.filter { since == nil || $0.paidAt >= since! }.sorted { $0.paidAt > $1.paidAt }
        return Spending(
            paidTotals: Ledger.paidTotals(state.payments, since: since).map(Amount.init),
            paidTotalConverted: converted.0,
            conversionNote: converted.1,
            since: since ?? state.coverageStart,
            coverage: state.coverageDescription,
            historyConfirmedComplete: state.historyCoverage?.completeForPeriod == true,
            payments: records.prefix(max(0, limit)).map { record in
                Payment(id: record.id.uuidString, accountID: record.accountID?.uuidString,
                        status: record.estimated == true ? "estimate" : record.scheduleID != nil ? "automatic" : "confirmed",
                        description: record.description, kind: record.kind.rawValue, amount: Amount(record.money),
                        signedAmount: record.kind == .refund ? "-\(record.money.amount)" : "\(record.money.amount)",
                        paidAt: record.paidAt, account: accountName(state, record.accountID),
                        reference: record.reference.isEmpty ? nil : record.reference, autoRecorded: record.autoRecorded)
            },
            note: "Recorded payments include confirmed entries, detected estimates and automatic renewals. Check status before calling a charge confirmed. Refunds are subtracted. Not a lifetime total unless history is confirmed complete.")
    }

    public static func renewals(_ state: PersistentState, withinDays: Int? = nil, now: Date = .now) -> [Renewal] {
        let today = Calendar.current.startOfDay(for: now)
        return state.subscriptions.sorted { $0.nextRenewal < $1.nextRenewal }.compactMap { schedule in
            let days = Calendar.current.dateComponents([.day], from: today, to: Calendar.current.startOfDay(for: schedule.nextRenewal)).day ?? 0
            if let withinDays, days > withinDays { return nil }
            return Renewal(name: schedule.name, expected: Amount(schedule.price), cadence: schedule.cadence.rawValue,
                           nextRenewal: schedule.nextRenewal, daysUntil: days, overdue: days < 0, account: accountName(state, schedule.accountID))
        }
    }

    public static func overview(_ state: PersistentState, now: Date = .now, rates: RateTable? = nil) -> Overview {
        let balances = balances(state, now: now)
        let converted = converted(state, rates: rates)
        return Overview(
            generatedAt: now,
            balances: balances,
            paidTotals: Ledger.paidTotals(state.payments).map(Amount.init),
            paidTotalConverted: converted.0,
            conversionNote: converted.1,
            paymentCoverage: state.coverageDescription,
            totalSpentIncludingAccruing: {
                var totals = Dictionary(Ledger.paidTotals(state.payments).map { ($0.currency, $0.amount) }, uniquingKeysWith: +)
                for item in state.accruingThisMonth(now: now) { totals[item.amount.currency, default: 0] += item.amount.amount }
                return totals.keys.sorted().map { Amount(Money(totals[$0]!.rounded2, $0)) }
            }(),
            accruingThisMonth: state.accruingThisMonth(now: now).map {
                Accrual(provider: Catalogue.integration($0.account.integrationID)?.name ?? $0.account.integrationID, label: $0.account.label, amount: Amount($0.amount))
            },
            budget: state.monthlyBudget.map { budget in
                let spent = state.monthToDateSpend(in: budget.currency, rates: rates, now: now, includeAccruing: true)
                let percent = budget.amount > 0 ? Int((NSDecimalNumber(decimal: spent.spent.amount / budget.amount).doubleValue * 100).rounded()) : 0
                return Budget(monthly: Amount(budget), spentIncludingAccruing: Amount(spent.spent), percentUsed: percent, complete: spent.complete)
            },
            upcomingRenewals: renewals(state, withinDays: 30, now: now),
            accountsNeedingAttention: balances.filter { $0.lastError != nil || $0.stale }.map { "\($0.provider) · \($0.label)" },
            note: "Values are the last readings saved by the Unifai app. Credit remaining, money paid and expected renewals are separate measures; do not add them together or across currencies.")
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
