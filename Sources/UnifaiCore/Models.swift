import Foundation

public extension Decimal {
    /// Rounded half-up to cents.
    var rounded2: Decimal {
        var value = self, result = Decimal()
        NSDecimalRound(&result, &value, 2, .plain)
        return result
    }
}

public struct Money: Codable, Hashable, Identifiable {
    public var amount: Decimal
    public var currency: String
    public var id: String { currency }
    public init(_ amount: Decimal, _ currency: String) {
        self.amount = amount
        self.currency = currency.uppercased()
    }
    public var formatted: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 8
        return "\(currency) \(formatter.string(from: amount as NSDecimalNumber) ?? amount.description)"
    }
    /// Amount without the currency code, for display next to a separate code label.
    public var amountText: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        // Cents for display; more precision only for sub-cent amounts that would otherwise read as zero.
        formatter.maximumFractionDigits = amount != 0 && abs(amount) < Decimal(string: "0.01")! ? 4 : 2
        return formatter.string(from: amount as NSDecimalNumber) ?? amount.description
    }
    public var plainText: String { "\(amountText) \(currency)" }
    public static func parseAmount(_ input: String) -> Decimal? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 24, text.range(of: #"^[0-9]+(\.[0-9]{1,8})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN else { return nil }
        return value
    }
    public static func validCurrency(_ input: String) -> Bool {
        Locale.commonISOCurrencyCodes.contains(input.uppercased())
    }
}

public enum ConnectionMode: String, Codable { case live, manual }

public struct BalanceDetail: Codable, Hashable {
    public var label: String
    public var value: Money
    public init(_ label: String, _ value: Money) { self.label = label; self.value = value }
}

/// A free rate-limit reset granted by a provider (Codex grants these occasionally).
public struct ResetCredit: Codable, Hashable {
    public var id: String?
    public var title: String
    public var grantedAt: Date?
    public var expiresAt: Date?
    public var key: String { id ?? "\(title)-\(Int(grantedAt?.timeIntervalSince1970 ?? 0))" }
    public init(id: String? = nil, title: String, grantedAt: Date?, expiresAt: Date?) {
        self.id = id; self.title = title; self.grantedAt = grantedAt; self.expiresAt = expiresAt
    }
}

/// A service whose latest daily cost jumped well above its recent normal, or started from nothing.
public struct CostAnomaly: Codable, Hashable {
    public var service: String
    /// The day of the spike, yyyy-MM-dd (UTC, as the provider reports it).
    public var day: String
    public var amount: Money
    /// The median daily cost over the week before; zero when the service is new.
    public var typical: Money
    public init(service: String, day: String, amount: Money, typical: Money) {
        self.service = service; self.day = day; self.amount = amount; self.typical = typical
    }
    public var summary: String {
        typical.amount == 0
            ? "\(service) started costing \(amount.plainText) a day on \(day)"
            : "\(service) cost \(amount.plainText) on \(day), against a usual \(typical.plainText) a day"
    }
}

/// One line of a cost breakdown: a service, or a meter within a resource.
public struct CostLine: Codable, Hashable {
    public var name: String
    public var cost: Money
    public init(name: String, cost: Money) { self.name = name; self.cost = cost }
}

/// A model deployed on a Foundry (Azure AI Services / Azure OpenAI) account.
public struct ModelDeployment: Codable, Hashable {
    public var name: String
    public var model: String
    public var version: String?
    public var sku: String?
    public var capacity: Int?
    public init(name: String, model: String, version: String?, sku: String?, capacity: Int?) {
        self.name = name; self.model = model; self.version = version; self.sku = sku; self.capacity = capacity
    }
}

/// A billed cloud resource with this month's cost, for the wallet detail view.
public struct CloudResource: Codable, Hashable, Identifiable {
    /// Azure resource ID, lowercased.
    public var id: String
    public var name: String
    /// Azure resource type, lowercased, such as microsoft.compute/virtualmachines.
    public var type: String
    public var group: String
    public var location: String?
    public var cost: Money?
    /// The meters that make up the cost, largest first.
    public var meters: [CostLine]
    /// Virtual machines: Running, Deallocated or Stopped. "Deleted" when only the bill remembers it.
    public var state: String?
    /// VM size or SKU.
    public var size: String?
    public var models: [ModelDeployment]?
    public var webURL: URL?
    public init(id: String, name: String, type: String, group: String, location: String?, cost: Money?, meters: [CostLine],
                state: String? = nil, size: String? = nil, models: [ModelDeployment]? = nil) {
        self.id = id; self.name = name; self.type = type; self.group = group; self.location = location; self.cost = cost
        self.meters = meters; self.state = state; self.size = size; self.models = models
    }

    /// Plain name for the resource type.
    public var kind: String {
        switch type {
        case "vercel/project", "supabase/project": return "Project"
        case "github/repository": return "Repository"
        case "cloudflare/zone": return "Zone usage"
        case "microsoft.compute/virtualmachines": return "Virtual machine"
        case "microsoft.compute/disks": return "Disk"
        case "microsoft.compute/snapshots": return "Disk snapshot"
        case "microsoft.network/publicipaddresses": return "Public IP"
        case "microsoft.network/networkinterfaces": return "Network interface"
        case "microsoft.network/virtualnetworks": return "Virtual network"
        case "microsoft.network/networksecuritygroups": return "Network security group"
        case "microsoft.network/bastionhosts": return "Bastion"
        case "microsoft.storage/storageaccounts": return "Storage account"
        case "microsoft.cognitiveservices/accounts": return "Foundry account"
        case "microsoft.machinelearningservices/workspaces": return "Foundry project"
        case "microsoft.search/searchservices": return "AI Search"
        case "microsoft.web/sites": return "App Service"
        case "microsoft.web/serverfarms": return "App Service plan"
        case "microsoft.containerinstance/containergroups": return "Container instance"
        case "microsoft.containerregistry/registries": return "Container registry"
        case "microsoft.app/containerapps": return "Container app"
        case "microsoft.keyvault/vaults": return "Key Vault"
        case "microsoft.documentdb/databaseaccounts": return "Cosmos DB"
        case "microsoft.sql/servers/databases": return "SQL database"
        default:
            let last = type.split(separator: "/").last.map(String.init) ?? type
            return last.prefix(1).uppercased() + last.dropFirst()
        }
    }

    /// Which part of the detail view the resource belongs to.
    public var family: String {
        switch type {
        case "microsoft.compute/virtualmachines", "microsoft.compute/disks", "microsoft.compute/snapshots",
             "microsoft.containerinstance/containergroups", "microsoft.app/containerapps", "microsoft.web/sites", "microsoft.web/serverfarms":
            return "Compute"
        case "microsoft.cognitiveservices/accounts", "microsoft.machinelearningservices/workspaces", "microsoft.search/searchservices":
            return "AI"
        case "microsoft.storage/storageaccounts", "microsoft.documentdb/databaseaccounts", "microsoft.sql/servers/databases", "microsoft.containerregistry/registries":
            return "Storage & data"
        default:
            return type.hasPrefix("microsoft.network/") ? "Networking" : "Other"
        }
    }

    public var portalURL: URL? {
        if !type.hasPrefix("microsoft.") { return webURL }
        return URL(string: "https://portal.azure.com/#resource\(id)")
    }
}

/// Total cost of one day, yyyy-MM-dd.
public struct DailyCost: Codable, Hashable {
    public var day: String
    public var amount: Decimal
    public init(day: String, amount: Decimal) { self.day = day; self.amount = amount }
}

/// Tokens used on one day, as reported by the provider.
public struct UsageDay: Codable, Hashable {
    public var date: String
    public var tokens: Int64
    public init(date: String, tokens: Int64) { self.date = date; self.tokens = tokens }
}

/// A usage allowance that resets on a schedule, such as Codex's 5-hour and weekly windows.
public struct AllowanceWindow: Codable, Hashable, Identifiable {
    public var name: String
    public var usedPercent: Int
    public var windowMinutes: Int?
    public var resetsAt: Date?
    public var id: String { name }
    public init(name: String, usedPercent: Int, windowMinutes: Int? = nil, resetsAt: Date? = nil) {
        self.name = name; self.usedPercent = usedPercent; self.windowMinutes = windowMinutes; self.resetsAt = resetsAt
    }
    public static func name(forMinutes minutes: Int?) -> String {
        switch minutes {
        case 300: return "5-hour window"
        case 10080: return "Weekly window"
        case let value? where value % 1440 == 0: return "\(value / 1440)-day window"
        case let value? where value % 60 == 0: return "\(value / 60)-hour window"
        case let value?: return "\(value)-minute window"
        default: return "Usage window"
        }
    }
}

public struct BalanceSnapshot: Codable, Hashable {
    public var balances: [Money]
    public var details: [BalanceDetail]
    public var reportedConsumption: [Money]
    public var observedAt: Date
    public var source: URL
    public var coverage: String
    // Optional additions keep earlier schema-1 snapshots readable.
    public var plan: String?
    public var allowances: [AllowanceWindow]?
    public var limitReached: Bool?
    public var consumptionPeriod: String?
    public var resetCredits: [ResetCredit]?
    public var usageDays: [UsageDay]?
    public var lifetimeTokens: Int64?
    /// Notable changes spotted in this reading, such as a service's daily cost jumping.
    public var anomalies: [CostAnomaly]?
    /// Cloud wallets: every service this month, every billed resource, and daily totals.
    public var services: [CostLine]?
    public var resources: [CloudResource]?
    public var dailyCosts: [DailyCost]?
    /// Provider usage before credits; excluded from cash and accruing-cost totals.
    public var vercelUsage: VercelUsage?
    public var providerUsage: ProviderUsage?
    /// Stable provider billing scope, used to avoid mistaking an account switch for a plan change.
    public var providerScope: String?
    public init(balances: [Money], details: [BalanceDetail] = [], reportedConsumption: [Money] = [], observedAt: Date = .now, source: URL, coverage: String,
                plan: String? = nil, allowances: [AllowanceWindow]? = nil, limitReached: Bool? = nil, consumptionPeriod: String? = nil,
                resetCredits: [ResetCredit]? = nil, usageDays: [UsageDay]? = nil, lifetimeTokens: Int64? = nil, anomalies: [CostAnomaly]? = nil) {
        self.balances = balances; self.details = details; self.reportedConsumption = reportedConsumption
        self.observedAt = observedAt; self.source = source; self.coverage = coverage
        self.plan = plan; self.allowances = allowances; self.limitReached = limitReached; self.consumptionPeriod = consumptionPeriod
        self.resetCredits = resetCredits; self.usageDays = usageDays; self.lifetimeTokens = lifetimeTokens; self.anomalies = anomalies
    }
    public func isStale(at date: Date = .now) -> Bool { date.timeIntervalSince(observedAt) > 3600 }
}

public struct ConnectedAccount: Codable, Identifiable, Hashable {
    public var id: UUID
    public var integrationID: String
    public var label: String
    public var billingScope: String
    public var mode: ConnectionMode
    public var createdAt: Date
    public var snapshot: BalanceSnapshot?
    public var lastAttempt: Date?
    public var lastError: String?
    /// Notify when remaining credit falls below this amount, in the balance's own currency.
    public var lowBalanceAlert: Decimal?
    public init(id: UUID = UUID(), integrationID: String, label: String, billingScope: String = "", mode: ConnectionMode) {
        self.id = id; self.integrationID = integrationID; self.label = label
        self.billingScope = billingScope; self.mode = mode; self.createdAt = .now
    }
}

public extension ConnectedAccount {
    /// Low-credit thresholds by unit, used until a wallet sets its own.
    static func defaultLowBalance(for currency: String) -> Decimal {
        switch currency {
        case "CREDITS": return 20
        case "CNY": return 35
        case "JPY": return 750
        default: return 5
        }
    }
}

public enum PaymentKind: String, Codable, CaseIterable, Identifiable {
    case subscription = "Subscription payment"
    case topUp = "Credit top-up"
    case usageCharge = "Settled usage charge"
    case refund = "Refund"
    public var id: String { rawValue }
}

public struct PaymentRecord: Codable, Identifiable, Hashable {
    public var id: UUID
    public var accountID: UUID?
    public var description: String
    public var kind: PaymentKind
    public var money: Money
    public var paidAt: Date
    public var reference: String
    public var createdAt: Date
    /// Set when a schedule recorded this renewal automatically; cleared once confirmed by a receipt or by hand.
    public var scheduleID: UUID?
    /// Recorded by Unifai from a pay-as-you-go wallet's last usage reading at period end.
    public var estimated: Bool?
    /// Kept after confirmation so the original observation remains inspectable.
    public var detection: TopUpEvidence?
    public var confirmedAt: Date?
    public var sourceReference: String?
    public var autoRecorded: Bool { scheduleID != nil || estimated == true }
    public init(id: UUID = UUID(), accountID: UUID? = nil, description: String, kind: PaymentKind, money: Money, paidAt: Date, reference: String = "", scheduleID: UUID? = nil) {
        self.id = id; self.accountID = accountID; self.description = description; self.kind = kind
        self.money = money; self.paidAt = paidAt; self.reference = reference; self.createdAt = .now; self.scheduleID = scheduleID
    }
}

public struct TopUpEvidence: Codable, Hashable {
    public var before: Money
    public var after: Money
    public var observedFrom: Date
    public var observedThrough: Date
    public var lowerBound: Bool
}

public enum BillingCadence: String, Codable, CaseIterable, Identifiable {
    case monthly = "Monthly", yearly = "Yearly"
    public var id: String { rawValue }
}

public struct SubscriptionSchedule: Codable, Identifiable, Hashable {
    public var id: UUID
    public var accountID: UUID?
    public var name: String
    public var price: Money
    public var cadence: BillingCadence
    public var nextRenewal: Date
    /// Record each renewal as a payment when it falls due. Nil (older schedules) means on.
    public var autoRecord: Bool?
    /// Renewals dated before this are never recorded automatically, so no history is invented.
    public var createdAt: Date?
    public var recordsAutomatically: Bool { autoRecord != false }
    public init(id: UUID = UUID(), accountID: UUID? = nil, name: String, price: Money, cadence: BillingCadence, nextRenewal: Date,
                autoRecord: Bool = true, createdAt: Date = .now) {
        self.id = id; self.accountID = accountID; self.name = name; self.price = price
        self.cadence = cadence; self.nextRenewal = nextRenewal; self.autoRecord = autoRecord; self.createdAt = createdAt
    }
    public func advanced(from date: Date) -> Date {
        Calendar.current.date(byAdding: cadence == .monthly ? .month : .year, value: 1, to: date) ?? date.addingTimeInterval(cadence == .monthly ? 30 * 86400 : 365 * 86400)
    }
}

/// A recurring charge spotted in recorded payments, offered for confirmation before it becomes a schedule.
public struct RenewalSuggestion: Identifiable, Equatable {
    public var id: String
    public var accountID: UUID?
    public var name: String
    public var price: Money
    public var cadence: BillingCadence
    public var nextRenewal: Date
    public var lastPaid: Date
    public var basedOn: Int
    /// The price comes from a prorated or changing charge, so it needs checking.
    public var estimated: Bool
}

public enum RenewalDetector {
    public static func suggestions(_ state: PersistentState, now: Date = .now) -> [RenewalSuggestion] {
        let dismissed = Set(state.dismissedSuggestions ?? [])
        let scheduled = Set(state.subscriptions.compactMap(\.accountID))
        let confirmed = state.payments.filter { $0.kind == .subscription && !$0.autoRecorded }
        let groups = Dictionary(grouping: confirmed) { "\($0.accountID?.uuidString ?? "none")|\($0.money.currency)" }
        var results: [RenewalSuggestion] = []
        for (key, group) in groups {
            guard let accountID = group.first?.accountID, !scheduled.contains(accountID), !dismissed.contains(key), group.count >= 2 else { continue }
            let sorted = group.sorted { $0.paidAt < $1.paidAt }
            // Ignore same-period charges such as an upgrade and a renewal on the same day.
            var gaps: [Double] = []
            for (previous, next) in zip(sorted, sorted.dropFirst()) {
                let days = next.paidAt.timeIntervalSince(previous.paidAt) / 86400
                if days >= 20 { gaps.append(days) }
            }
            let recent = Array(gaps.suffix(4)).sorted()
            guard !recent.isEmpty else { continue }
            let median = recent[recent.count / 2]
            let cadence: BillingCadence
            if (25...45).contains(median) { cadence = .monthly } else if (340...390).contains(median) { cadence = .yearly } else { continue }
            let last = sorted.last!
            let period: Double = cadence == .monthly ? 31 : 366
            // A plan with no charge for more than one and a half periods has probably lapsed.
            guard now.timeIntervalSince(last.paidAt) / 86400 <= period * 1.5 else { continue }
            let template = SubscriptionSchedule(accountID: accountID, name: "", price: last.money, cadence: cadence, nextRenewal: last.paidAt)
            var next = template.advanced(from: last.paidAt)
            while next < Calendar.current.startOfDay(for: now) { next = template.advanced(from: next) }
            let lastThree = sorted.suffix(3).map(\.money.amount)
            let upgrade = last.description.range(of: "upgrade", options: .caseInsensitive) != nil
            let name = last.description.replacingOccurrences(of: " (upgrade)", with: "", options: .caseInsensitive)
            results.append(RenewalSuggestion(id: key, accountID: accountID, name: name, price: last.money, cadence: cadence, nextRenewal: next,
                                             lastPaid: last.paidAt, basedOn: sorted.count, estimated: upgrade || Set(lastThree).count > 1))
        }
        return results.sorted { $0.nextRenewal < $1.nextRenewal }
    }
}

public enum Ledger {
    public static func paidTotals(_ records: [PaymentRecord], since start: Date? = nil, through end: Date = .now) -> [Money] {
        var amounts: [String: Decimal] = [:]
        for record in records where record.paidAt <= end && (start == nil || record.paidAt >= start!) {
            amounts[record.money.currency, default: 0] += record.kind == .refund ? -record.money.amount : record.money.amount
        }
        return amounts.keys.sorted().map { Money(amounts[$0]!, $0) }
    }
    public static func validate(_ record: PaymentRecord, existing: [PaymentRecord], now: Date = .now) throws {
        guard record.money.amount > 0, !record.money.amount.isNaN, Money.validCurrency(record.money.currency) else {
            throw ValidationError.message("Enter a positive amount and a supported currency code.")
        }
        guard record.paidAt <= now else { throw ValidationError.message("A completed payment cannot have a future date. Add a renewal schedule instead.") }
        guard !record.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError.message("Give this payment a name.") }
        let reference = record.reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reference.isEmpty && existing.contains(where: {
            $0.id != record.id && $0.accountID == record.accountID && $0.reference.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(reference) == .orderedSame
        }) { throw ValidationError.message("This payment reference already exists for that account.") }
    }
    public static func validate(_ schedule: SubscriptionSchedule) throws {
        guard schedule.price.amount > 0, !schedule.price.amount.isNaN, Money.validCurrency(schedule.price.currency),
              !schedule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.message("Enter a subscription name, positive amount and supported currency.")
        }
    }
}

public enum ValidationError: LocalizedError, Equatable {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public struct ReleaseItem: Codable, Identifiable, Hashable {
    public var id: Int
    public var title: String
    public var tag: String
    public var url: URL
    public var publishedAt: Date?
    public var prerelease: Bool
    /// The start of the release notes, as plain text.
    public var summary: String?
    public init(id: Int, title: String, tag: String, url: URL, publishedAt: Date?, prerelease: Bool, summary: String? = nil) {
        self.id = id; self.title = title; self.tag = tag; self.url = url; self.publishedAt = publishedAt; self.prerelease = prerelease
        self.summary = summary
    }
}

public struct WatchedRepository: Codable, Identifiable, Hashable {
    public var id: UUID
    public var slug: String
    public var releases: [ReleaseItem]
    public var includePrereleases: Bool
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var lastError: String?
    public var etag: String?
    public var nextAllowedRefresh: Date?
    public init(id: UUID = UUID(), slug: String, includePrereleases: Bool = false) {
        self.id = id; self.slug = slug; self.releases = []; self.includePrereleases = includePrereleases
    }
    public static func parseSlug(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("https://github.com/") { text.removeFirst("https://github.com/".count) }
        if text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text.removeLast(4) }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}$"#, options: .regularExpression) != nil,
              parts[1].range(of: #"^[A-Za-z0-9_.-]{1,100}$"#, options: .regularExpression) != nil,
              parts[1] != ".", parts[1] != ".." else { return nil }
        return text
    }
}

public struct PersistentState: Codable, Equatable {
    public var schemaVersion: Int = 1
    public var mcpTrackingEnabled: Bool?
    public var mcpScan: MCPScan?
    public var mcpPurchases: [MCPPurchase]?
    public var accounts: [ConnectedAccount] = []
    public var payments: [PaymentRecord] = []
    public var subscriptions: [SubscriptionSchedule] = []
    public var repositories: [WatchedRepository] = []
    // Optional additions preserve the original schema-1 scaffold files.
    public var historyCoverage: HistoryCoverage?
    public var githubRequests: [Date]?
    public var githubBackoffUntil: Date?
    public var dismissedSuggestions: [String]?
    /// Currency used to combine spending views. Nil shows each currency separately.
    public var displayCurrency: String?
    /// Monthly spending budget, compared against this month's payments in its currency.
    public var monthlyBudget: Money?
    /// Refresh live wallets in the background while the app runs. Nil means on.
    public var autoRefresh: Bool?
    public var events: [TimelineEvent]?
    public var productUpdatesEnabled: Bool?
    public var productSnapshots: [String: ProductSnapshot]?
    public var productChecks: [String: Date]?
    public var productErrors: [String: String]?
    public var timelineReadAt: Date?
    public var timelineCheckedAt: Date?
    /// X accounts to follow in the timeline, without the @.
    public var xHandles: [String]?
    public var xUserIDs: [String: String]?
    public var xSinceIDs: [String: String]?
    /// X API reads per month ("yyyy-MM"), for the cost estimate.
    public var xPostReads: [String: Int]?
    public var xUserLookups: [String: Int]?
    /// Repositories already followed once for a wallet, so removing one sticks.
    public var autoFollowed: [String]?
    /// AI news feeds and new-model listings in the Timeline. Nil means on.
    public var newsFeeds: Bool?
    public var newModels: Bool?
    public var modelsCheckedAt: Date?
    public init() {}
}

public struct HistoryCoverage: Codable, Equatable {
    public var start: Date
    public var completeForPeriod: Bool
    public init(start: Date, completeForPeriod: Bool) { self.start = start; self.completeForPeriod = completeForPeriod }
}

public extension PersistentState {
    var coverageStart: Date? { historyCoverage?.start ?? payments.map(\.paidAt).min() }
    var coverageDescription: String {
        guard let start = coverageStart else { return "No payment history recorded" }
        let status = historyCoverage?.completeForPeriod == true ? "Confirmed complete for this period" : "Partial history"
        return "Recorded since \(start.formatted(date: .abbreviated, time: .omitted)) · \(status)"
    }
    func visibleReleases(for repository: WatchedRepository) -> [ReleaseItem] {
        repository.releases.filter { repository.includePrereleases || !$0.prerelease }
    }
}
