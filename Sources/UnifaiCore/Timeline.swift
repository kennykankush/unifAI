import Foundation

/// One entry in the timeline: something that happened to your accounts or in the AI world.
public enum TimelineKind: String, Codable, CaseIterable {
    case earlyReset = "Early reset"
    case reset = "Reset"
    case limitReached = "Limit reached"
    case resetCredit = "Free reset"
    case anomaly = "Cost spike"
    case recorded = "Recorded"
    case release = "Release"
    case status = "Status"
    case post = "Post"
    case news = "News"
    case model = "New model"

    public var isAccountEvent: Bool { [.earlyReset, .reset, .limitReached, .resetCredit, .anomaly, .recorded].contains(self) }

    /// Kinds added by a newer version read as News, so an older app or MCP server can still load the file.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TimelineKind(rawValue: raw) ?? .news
    }
}

public struct TimelineEvent: Codable, Identifiable, Hashable {
    /// Stable key so the same event is never recorded twice.
    public var id: String
    public var date: Date
    public var kind: TimelineKind
    public var title: String
    public var detail: String
    public var source: URL?
    public var sourceName: String
    public var accountID: UUID?
    /// Worth a notification and a highlight.
    public var important: Bool
    public init(id: String, date: Date, kind: TimelineKind, title: String, detail: String, source: URL? = nil, sourceName: String, accountID: UUID? = nil, important: Bool = false) {
        self.id = id; self.date = date; self.kind = kind; self.title = title; self.detail = detail
        self.source = source; self.sourceName = sourceName; self.accountID = accountID; self.important = important
    }
}

public extension PersistentState {
    static let timelineLimit = 600

    /// Adds events not already recorded, newest first, keeping the most recent `timelineLimit`.
    /// Returns the events that were new.
    @discardableResult
    mutating func record(_ incoming: [TimelineEvent]) -> [TimelineEvent] {
        var existing = events ?? []
        var known: [String: Int] = [:]
        for (index, event) in existing.enumerated() { known[event.id] = index }
        // A status incident keeps its place but takes the latest update.
        for event in incoming where event.kind == .status {
            if let index = known[event.id], existing[index].detail != event.detail {
                existing[index].detail = event.detail; existing[index].important = event.important
            }
        }
        let fresh = incoming.filter { known[$0.id] == nil }
        guard !fresh.isEmpty else { if existing != (events ?? []) { events = existing }; return [] }
        existing.append(contentsOf: fresh)
        existing.sort { $0.date > $1.date }
        events = Array(existing.prefix(Self.timelineLimit))
        return fresh
    }
}

/// Spots resets, limits and new reset credits by comparing a wallet's new reading with the last one.
public enum AllowanceWatch {
    public static func events(old: BalanceSnapshot?, new: BalanceSnapshot, account: ConnectedAccount, now: Date = .now) -> [TimelineEvent] {
        let name = Catalogue.integration(account.integrationID)?.name ?? account.integrationID
        var events: [TimelineEvent] = []
        let previous = Dictionary((old?.allowances ?? []).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for window in new.allowances ?? [] {
            guard let before = previous[window.name] else { continue }
            let stamp = Int((before.resetsAt ?? now).timeIntervalSince1970)
            let dropped = before.usedPercent - window.usedPercent >= 15 || (before.usedPercent >= 100 && window.usedPercent < 100)
            if dropped {
                // Earlier than 15 minutes before the scheduled reset means someone reset it.
                let early = before.resetsAt.map { now < $0.addingTimeInterval(-15 * 60) } ?? false
                let scheduled = before.resetsAt.map { " The scheduled reset was \($0.formatted(date: .abbreviated, time: .shortened))." } ?? ""
                events.append(TimelineEvent(
                    id: "\(early ? "early-" : "")reset-\(account.id)-\(window.name)-\(stamp)", date: now, kind: early ? .earlyReset : .reset,
                    title: early ? "\(name): \(window.name.lowercased()) was reset early" : "\(name): \(window.name.lowercased()) reset",
                    detail: "Usage went from \(before.usedPercent)% to \(window.usedPercent)%.\(early ? scheduled : "")",
                    sourceName: name, accountID: account.id, important: early || before.usedPercent >= 100))
            } else if before.usedPercent < 100 && window.usedPercent >= 100 {
                let reset = window.resetsAt.map { " It resets \($0.formatted(date: .abbreviated, time: .shortened))." } ?? ""
                events.append(TimelineEvent(
                    id: "limit-\(account.id)-\(window.name)-\(Int((window.resetsAt ?? now).timeIntervalSince1970))", date: now, kind: .limitReached,
                    title: "\(name): \(window.name.lowercased()) limit reached", detail: "You have used 100% of this window.\(reset)",
                    sourceName: name, accountID: account.id, important: true))
            }
        }
        let known = Set((old?.resetCredits ?? []).map(\.key))
        for credit in new.resetCredits ?? [] where !known.contains(credit.key) {
            let expiry = credit.expiresAt.map { " Expires \($0.formatted(date: .abbreviated, time: .omitted))." } ?? ""
            events.append(TimelineEvent(
                id: "credit-\(account.id)-\(credit.key)", date: credit.grantedAt ?? now, kind: .resetCredit,
                title: "\(name): free reset available", detail: "\(credit.title).\(expiry) Redeem it in Codex when you hit a limit.",
                sourceName: name, accountID: account.id, important: true))
        }
        return events
    }
}

/// Codex plan guidance from how often limits are hit and how much is used.
public enum PlanAdvisor {
    public static func advice(for account: ConnectedAccount, events: [TimelineEvent], now: Date = .now) -> String? {
        guard let snapshot = account.snapshot, snapshot.allowances?.isEmpty == false else { return nil }
        let recent = events.filter { $0.accountID == account.id && $0.kind == .limitReached && $0.date > now.addingTimeInterval(-28 * 86400) }
        let weekly = recent.filter { $0.title.localizedCaseInsensitiveContains("weekly") }.count
        let credits = snapshot.resetCredits?.count ?? 0
        if weekly >= 2 { return "Weekly limit hit \(weekly) times in 4 weeks; a bigger plan may pay off" }
        if let window = snapshot.allowances?.first(where: { $0.windowMinutes == 10080 }), window.usedPercent >= 100 {
            return credits > 0 ? "Weekly limit reached; you have \(credits) free reset\(credits == 1 ? "" : "s")" : "Weekly limit reached; resets \(window.resetsAt.map { $0.formatted(.relative(presentation: .named)) } ?? "later")"
        }
        if let days = snapshot.usageDays, days.count >= 14 {
            let recentDays = days.suffix(14).filter { $0.tokens > 0 }.count
            if recentDays <= 3 { return "Used on \(recentDays) of the last 14 days; a smaller plan may be enough" }
        }
        return nil
    }
}

/// Spots credit purchases you did not record, from a provider's purchased total rising between two
/// readings, and records them as Estimates until a receipt replaces them. This keeps "spent this
/// month" honest when a top-up was never logged.
public enum TopUpWatch {
    /// OpenRouter adds a 5.5% fee (0.80 minimum) to card purchases of credits.
    static func openRouterCharge(credits: Decimal) -> Decimal { (credits + max(Decimal(string: "0.80")!, credits * Decimal(string: "0.055")!)).rounded2 }

    /// Vercel gives a team $5 of free AI Gateway Credits before its first purchase and none after.
    static let vercelFreeCredit: Decimal = 5

    public static func payments(old: BalanceSnapshot?, new: BalanceSnapshot, account: ConnectedAccount, recorded: [PaymentRecord], now: Date = .now) -> [PaymentRecord] {
        func detail(_ snapshot: BalanceSnapshot, _ label: String) -> Money? { snapshot.details.first { $0.label == label }?.value }
        let name = Catalogue.integration(account.integrationID)?.name ?? account.label
        if account.integrationID == "vercel-ai-gateway", old.flatMap({ detail($0, "Credits added") }) == nil {
            // First reading with credits added: anything above the free credit was bought before connecting.
            // Proposed once as an Estimate, unless a top-up for this wallet is already recorded.
            guard let added = detail(new, "Credits added"), added.amount - vercelFreeCredit >= 1,
                  !recorded.contains(where: { $0.accountID == account.id && $0.kind == .topUp }) else { return [] }
            let credits = Money((added.amount - vercelFreeCredit).rounded2, added.currency)
            var record = PaymentRecord(accountID: account.id, description: "\(name) credits \(credits.amountText) (detected)", kind: .topUp, money: credits,
                                       paidAt: now, reference: "DETECTED-\(account.integrationID.uppercased())-\(Int(now.timeIntervalSince1970))")
            record.estimated = true
            return [record]
        }
        guard let old else { return [] }
        var found: (credits: Money, charge: Money, description: String)?
        var evidenceLabel = "Reported credits purchased"
        switch account.integrationID {
        case "openrouter":
            // Total credits ever purchased: any rise is a purchase.
            if let before = detail(old, "Reported credits purchased"), let after = detail(new, "Reported credits purchased"),
               before.currency == after.currency, after.amount - before.amount >= Decimal(string: "0.5")! {
                let credits = after.amount - before.amount
                let charge = openRouterCharge(credits: credits)
                found = (Money(credits, after.currency), Money(charge, after.currency),
                         "OpenRouter credits \(Money(credits, after.currency).amountText) + fee (detected)")
            }
        case "vercel-ai-gateway":
            // Remaining plus used only rises when credits are added. Paid teams no longer receive free credits.
            evidenceLabel = "Credits added"
            if let before = detail(old, evidenceLabel), let after = detail(new, evidenceLabel),
               before.currency == after.currency, after.amount - before.amount >= 1 {
                let credits = after.amount - before.amount
                found = (Money(credits, after.currency), Money(credits.rounded2, after.currency), "\(name) credits \(Money(credits, after.currency).amountText) (detected)")
            }
        case "deepseek":
            // The purchased balance only rises when you top up; usage in between makes this a lower bound.
            evidenceLabel = "Purchased balance"
            if let before = detail(old, "Purchased balance"), let after = detail(new, "Purchased balance"),
               before.currency == after.currency, after.amount - before.amount >= 1 {
                let credits = after.amount - before.amount
                found = (Money(credits, after.currency), Money(credits.rounded2, after.currency), "\(name) top-up of at least \(Money(credits, after.currency).amountText) (detected)")
            }
        default: break
        }
        guard let found else { return [] }
        // Only a receipt recorded within this observation interval can explain this increase.
        // An earlier detected purchase (even after confirmation) must never swallow a new one.
        let logged = recorded.filter {
            $0.accountID == account.id && $0.kind == .topUp && $0.money.currency == found.charge.currency
                && !$0.autoRecorded && $0.detection == nil && !$0.reference.hasPrefix("DETECTED-")
                && $0.sourceReference?.hasPrefix("DETECTED-") != true
                && $0.paidAt > old.observedAt && $0.paidAt <= new.observedAt
                && $0.money.amount >= found.credits.amount
        }
        if logged.count == 1 { return [] }
        var record = PaymentRecord(accountID: account.id, description: found.description, kind: .topUp, money: found.charge, paidAt: now,
                                   reference: "DETECTED-\(account.integrationID.uppercased())-\(Int(now.timeIntervalSince1970))")
        record.estimated = true
        if let before = detail(old, evidenceLabel), let after = detail(new, evidenceLabel) {
            record.detection = TopUpEvidence(before: before, after: after, observedFrom: old.observedAt,
                                             observedThrough: new.observedAt, lowerBound: account.integrationID == "deepseek")
        }
        return [record]
    }
}
