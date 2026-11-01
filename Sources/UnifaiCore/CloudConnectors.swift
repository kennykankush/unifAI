import Foundation

/// Provider reports remain separate from payments and calendar-month accrual.
public struct ProviderUsage: Codable, Hashable {
    public struct Meter: Codable, Hashable {
        public var name: String
        public var quantity: Decimal
        public var unit: String
        public var resourceID: String?
        public init(name: String, quantity: Decimal, unit: String, resourceID: String? = nil) {
            self.name = name; self.quantity = quantity; self.unit = unit; self.resourceID = resourceID
        }
    }
    public var period: String
    public var costLabel: String
    public var costs: [Money]
    public var meters: [Meter]
    public var details: [BalanceDetail]
    public var note: String
    public init(period: String, costLabel: String, costs: [Money], meters: [Meter] = [], details: [BalanceDetail] = [], note: String) {
        self.period = period; self.costLabel = costLabel; self.costs = costs; self.meters = meters; self.details = details; self.note = note
    }
}

/// Structured credentials stay in the existing per-wallet Keychain item.
public struct ScopedToken: Codable {
    public let scope: String
    public let token: String
    public static let integrations = ["github-billing", "github-org-billing", "cloudflare", "supabase"]
    public static func encode(scope: String, token: String, integration: String) throws -> String {
        let key = ScopedToken(scope: scope.trimmingCharacters(in: .whitespacesAndNewlines), token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        try key.validate(integration)
        return String(decoding: try JSONEncoder().encode(key), as: UTF8.self)
    }
    static func decode(_ value: String, integration: String) throws -> ScopedToken {
        guard let key = try? JSONDecoder().decode(Self.self, from: Data(value.utf8)) else {
            throw ValidationError.message("Edit this wallet and enter its account identifier and access token.")
        }
        try key.validate(integration); return key
    }
    func validate(_ integration: String) throws {
        guard Self.integrations.contains(integration), !scope.isEmpty, scope.count <= 100,
              scope.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              !token.isEmpty, token.utf8.count < 2048,
              token.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }) else {
            throw ValidationError.message("Enter an account identifier and token without spaces or line breaks.")
        }
        if integration == "cloudflare", scope.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) == nil {
            throw ValidationError.message("Cloudflare Account ID must contain 32 hexadecimal characters.")
        }
    }
}

struct CloudReadAPI {
    let session: URLSession
    let host: String
    let provider: String
    func get<T: Decodable>(_ path: String, token: String, query: [URLQueryItem] = []) async throws -> T {
        // Fixed hosts and validated path segments; never follow provider-returned URLs.
        var components = URLComponents(); components.scheme = "https"; components.host = host; components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ConnectorError.invalidResponse }
        var request = URLRequest(url: url); request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if host == "api.github.com" {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Unifai", forHTTPHeaderField: "User-Agent")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ConnectorError.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw ValidationError.message("\(provider) refused access. Check the token permissions and account identifier.")
        case 404: throw ValidationError.message("\(provider) did not expose this report. Check the account identifier, plan eligibility and token permissions.")
        case 429: throw ConnectorError.rateLimited
        default: throw ConnectorError.unavailable(http.statusCode)
        }
        if http.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") == true {
            throw ValidationError.message("\(provider) returned a paginated report this connector cannot complete. The previous reading is preserved.")
        }
        guard let result = try? JSONDecoder().decode(T.self, from: data) else { throw ConnectorError.invalidResponse }
        return result
    }
    static func valid(_ amount: Decimal, nonnegative: Bool = true) throws -> Decimal {
        guard !amount.isNaN, !nonnegative || amount >= 0 else { throw ConnectorError.invalidResponse }
        return amount
    }
    static func decimal(_ string: String, nonnegative: Bool = true) throws -> Decimal {
        guard string.range(of: "^-?[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
              let value = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) else { throw ConnectorError.invalidResponse }
        return try valid(value, nonnegative: nonnegative)
    }
    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func aggregate(_ lines: [CostLine]) -> [CostLine] {
        Dictionary(grouping: lines, by: { "\($0.cost.currency):\($0.name)" }).values.map { rows in
            CostLine(name: rows[0].name, cost: Money(rows.reduce(0) { $0 + $1.cost.amount }, rows[0].cost.currency))
        }.sorted { $0.name == $1.name ? $0.cost.currency < $1.cost.currency : $0.name < $1.name }
    }
    static func totals(_ lines: [CostLine]) -> [Money] {
        Dictionary(grouping: lines, by: { $0.cost.currency }).map { currency, rows in
            Money(rows.reduce(0) { $0 + $1.cost.amount }, currency)
        }.sorted { $0.currency < $1.currency }
    }
    static func meters(_ rows: [ProviderUsage.Meter]) -> [ProviderUsage.Meter] {
        var result: [ProviderUsage.Meter] = []
        for row in rows {
            if let index = result.firstIndex(where: { $0.name == row.name && $0.unit == row.unit && $0.resourceID == row.resourceID }) {
                result[index].quantity += row.quantity
            } else { result.append(row) }
        }
        return result
    }
}

public struct GitHubBillingClient {
    let session: URLSession
    public init(session: URLSession = BalanceClient.privateSession()) { self.session = session }
    struct Report: Decodable {
        struct Item: Decodable {
            let date: String; let product: String; let sku: String
            let quantity: Decimal; let unitType: String; let netAmount: Decimal
            let repositoryName: String?
        }
        let usageItems: [Item]
    }
    public func fetch(credential: String, organization: Bool = false, now: Date = .now) async throws -> BalanceSnapshot {
        let integration = organization ? "github-org-billing" : "github-billing"
        let key = try ScopedToken.decode(credential, integration: integration)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let year = calendar.component(.year, from: now), month = calendar.component(.month, from: now)
        let period = String(format: "%04d-%02d", year, month)
        let api = CloudReadAPI(session: session, host: "api.github.com", provider: "GitHub billing")
        let report: Report = try await api.get("/\(organization ? "organizations" : "users")/\(key.scope)/settings/billing/usage", token: key.token,
            query: [.init(name: "year", value: String(year)), .init(name: "month", value: String(month))])
        var lines: [CostLine] = [], meters: [ProviderUsage.Meter] = [], resources: [String: [CostLine]] = [:]
        for row in report.usageItems {
            guard row.date.hasPrefix(period + "-"), !row.product.isEmpty, !row.sku.isEmpty, !row.unitType.isEmpty else { throw ConnectorError.invalidResponse }
            let cost = try CloudReadAPI.valid(row.netAmount), quantity = try CloudReadAPI.valid(row.quantity)
            let name = "\(row.product) · \(row.sku)"
            let line = CostLine(name: name, cost: Money(cost, "USD")); lines.append(line)
            meters.append(.init(name: name, quantity: quantity, unit: row.unitType))
            let repo = row.repositoryName.flatMap { $0.isEmpty ? nil : $0 } ?? "Unattributed"
            resources[repo, default: []].append(line)
            meters.append(.init(name: name, quantity: quantity, unit: row.unitType, resourceID: repo))
        }
        let note = "Net metered usage returned by GitHub's enhanced billing API. Fixed subscriptions, invoices and payments are not included. Organization-paid usage is separate from personal usage. Empty reports mean no returned rows, not proof of a free account."
        var snapshot = BalanceSnapshot(balances: [], observedAt: now, source: URL(string: "https://github.com/settings/billing")!, coverage: note)
        snapshot.providerScope = "github:\(organization ? "org" : "user"):\(key.scope.lowercased())"
        snapshot.providerUsage = ProviderUsage(period: "\(period) · UTC", costLabel: "Net metered usage", costs: CloudReadAPI.totals(lines),
            meters: CloudReadAPI.meters(meters), note: note + " Kept separate from payment totals.")
        snapshot.services = CloudReadAPI.aggregate(lines)
        snapshot.resources = resources.keys.sorted().map { repo in
            let items = resources[repo]!
            var resource = CloudResource(id: repo, name: repo, type: "github/repository", group: key.scope, location: nil,
                cost: CloudReadAPI.totals(items).first, meters: CloudReadAPI.aggregate(items))
            if repo.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil {
                resource.webURL = URL(string: "https://github.com/\(repo)")
            }
            return resource
        }
        return snapshot
    }
}

public struct CloudflareUsageClient {
    let session: URLSession
    public init(session: URLSession = BalanceClient.privateSession()) { self.session = session }
    struct Report: Decodable {
        struct Row: Decodable {
            let BillingCurrency: String; let BillingPeriodStart: String
            let ChargePeriodStart: String; let ChargePeriodEnd: String; let ServiceName: String
            let ContractedCost: Decimal; let ConsumedQuantity: Decimal; let ConsumedUnit: String
            let BillingAccountId: String?; let ZoneId: String?; let ZoneName: String?
        }
        let success: Bool; let result: [Row]
    }
    public func fetch(credential: String, now: Date = .now) async throws -> BalanceSnapshot {
        let key = try ScopedToken.decode(credential, integration: "cloudflare")
        let api = CloudReadAPI(session: session, host: "api.cloudflare.com", provider: "Cloudflare billing")
        // V1 defaults to the actual billing cycle, whose anchor may not be day 1.
        let report: Report = try await api.get("/client/v4/accounts/\(key.scope)/billable-usage", token: key.token)
        guard report.success else { throw ValidationError.message("Cloudflare could not return billable usage. Check Billing Read access and Pay-as-you-go eligibility.") }
        var lines: [CostLine] = [], meters: [ProviderUsage.Meter] = [], zones: [String: [CostLine]] = [:], names: [String: String] = [:]
        var periods = Set<String>()
        for row in report.result {
            guard Money.validCurrency(row.BillingCurrency), !row.ServiceName.isEmpty,
                  row.BillingAccountId == nil || row.BillingAccountId?.lowercased() == key.scope.lowercased(),
                  CloudReadAPI.date(row.BillingPeriodStart) != nil,
                  let start = CloudReadAPI.date(row.ChargePeriodStart), let end = CloudReadAPI.date(row.ChargePeriodEnd), start <= end else { throw ConnectorError.invalidResponse }
            periods.insert(String(row.BillingPeriodStart.prefix(10)))
            // Sum period charges only. Summing cumulative fields would double-count days.
            let line = CostLine(name: row.ServiceName, cost: Money(try CloudReadAPI.valid(row.ContractedCost), row.BillingCurrency))
            lines.append(line)
            let quantity = try CloudReadAPI.valid(row.ConsumedQuantity)
            let unit = row.ConsumedUnit.isEmpty ? "provider units" : row.ConsumedUnit
            meters.append(.init(name: row.ServiceName, quantity: quantity, unit: unit))
            let id = row.ZoneId ?? "Account-wide"
            names[id] = row.ZoneName ?? id
            zones[id, default: []].append(line)
            meters.append(.init(name: row.ServiceName, quantity: quantity, unit: unit, resourceID: id))
        }
        let period = periods.isEmpty ? "Current billing cycle · no rows returned" : "Billing period starts: " + periods.sorted().joined(separator: ", ")
        let note = "Pay-as-you-go metered charges from Cloudflare, updated daily. Fixed plan subscriptions and enterprise contracts are outside this report. Zone rows are billing attribution, not a full resource inventory. Amounts remain separate from payment totals."
        var snapshot = BalanceSnapshot(balances: [], observedAt: now, source: URL(string: "https://dash.cloudflare.com/\(key.scope)/billing")!, coverage: note)
        snapshot.providerScope = "cloudflare:\(key.scope.lowercased())"
        snapshot.providerUsage = ProviderUsage(period: period, costLabel: "Metered charges", costs: CloudReadAPI.totals(lines), meters: CloudReadAPI.meters(meters), note: note)
        snapshot.services = CloudReadAPI.aggregate(lines)
        snapshot.resources = zones.keys.sorted().map { id in
            let items = zones[id]!, totals = CloudReadAPI.totals(items)
            var resource = CloudResource(id: id, name: names[id]!, type: "cloudflare/zone", group: "Billing attribution", location: nil,
                cost: totals.count == 1 ? totals[0] : nil, meters: CloudReadAPI.aggregate(items))
            resource.webURL = URL(string: "https://dash.cloudflare.com/\(key.scope)")
            return resource
        }
        return snapshot
    }
}

public struct DigitalOceanBillingClient {
    let session: URLSession
    public init(session: URLSession = BalanceClient.privateSession()) { self.session = session }
    struct Balance: Decodable { let month_to_date_balance: String; let account_balance: String; let month_to_date_usage: String; let generated_at: String }
    public func fetch(credential: String, now: Date = .now) async throws -> BalanceSnapshot {
        let api = CloudReadAPI(session: session, host: "api.digitalocean.com", provider: "DigitalOcean")
        let balance: Balance = try await api.get("/v2/customers/my/balance", token: credential)
        let usage = try CloudReadAPI.decimal(balance.month_to_date_usage)
        let account = try CloudReadAPI.decimal(balance.account_balance, nonnegative: false)
        let total = try CloudReadAPI.decimal(balance.month_to_date_balance, nonnegative: false)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: balance.generated_at) ?? ISO8601DateFormatter().date(from: balance.generated_at)
        guard let date, date <= now.addingTimeInterval(300) else { throw ConnectorError.invalidResponse }
        let note = "DigitalOcean's generated account report. Signed balances may represent amounts owed or credit; they are not available cash. Usage excludes prior billing activity. No payments or invoices are inferred."
        // Provider generation time prevents an old response appearing fresh.
        var snapshot = BalanceSnapshot(balances: [], observedAt: date, source: URL(string: "https://cloud.digitalocean.com/account/billing")!, coverage: note)
        snapshot.providerUsage = ProviderUsage(period: "Generated \(balance.generated_at)", costLabel: "Month-to-date usage", costs: [Money(usage, "USD")],
            details: [BalanceDetail("Account balance (signed)", Money(account, "USD")), BalanceDetail("Month-to-date balance (signed)", Money(total, "USD"))], note: note)
        return snapshot
    }
}

public struct SupabaseInventoryClient {
    let session: URLSession
    public init(session: URLSession = BalanceClient.privateSession()) { self.session = session }
    struct Project: Decodable {
        let id: String; let ref: String?; let organization_id: String; let organization_slug: String?
        let name: String; let region: String; let status: String
    }
    struct Addons: Decodable {
        struct Addon: Decodable {
            struct Variant: Decodable { let name: String }
            let type: String; let variant: Variant
        }
        let selected_addons: [Addon]
    }
    public func fetch(credential: String, now: Date = .now) async throws -> BalanceSnapshot {
        let key = try ScopedToken.decode(credential, integration: "supabase")
        let api = CloudReadAPI(session: session, host: "api.supabase.com", provider: "Supabase")
        let all: [Project] = try await api.get("/v1/projects", token: key.token)
        let projects = all.filter { ($0.organization_slug ?? $0.organization_id) == key.scope }
        guard !projects.isEmpty else { throw ValidationError.message("No visible projects match this Supabase organization. Check the organization slug and token access; this is not a zero-usage reading.") }
        guard projects.count <= 100, Set(projects.map { $0.ref ?? $0.id }).count == projects.count else {
            throw ValidationError.message("Supabase returned an unsupported project inventory. This connector reads up to 100 projects per organization.")
        }
        var resources: [CloudResource] = [], missing = 0
        for project in projects {
            let ref = project.ref ?? project.id
            guard ref.range(of: "^[a-z]{20}$", options: .regularExpression) != nil else { throw ConnectorError.invalidResponse }
            var resource = CloudResource(id: ref, name: project.name, type: "supabase/project", group: key.scope,
                location: project.region, cost: nil, meters: [], state: project.status)
            resource.webURL = URL(string: "https://supabase.com/dashboard/project/\(ref)")
            do {
                let addons: Addons = try await api.get("/v1/projects/\(ref)/billing/addons", token: key.token)
                resource.size = addons.selected_addons.map { $0.variant.name }.joined(separator: ", ")
            } catch { missing += 1 }
            resources.append(resource)
        }
        let note = "Live project status, region and selected compute/add-ons for \(key.scope). Prices of available add-ons are not usage or invoices. Billing totals, CPU consumption, plan and upgrade history are unavailable. \(missing) project add-on reads were unavailable."
        var snapshot = BalanceSnapshot(balances: [], observedAt: now, source: URL(string: "https://supabase.com/dashboard/org/\(key.scope)")!, coverage: note)
        snapshot.providerScope = "supabase:\(key.scope)"; snapshot.resources = resources.sorted { $0.name < $1.name }
        snapshot.providerUsage = ProviderUsage(period: "Current inventory · \(resources.count) projects", costLabel: "Billing unavailable", costs: [], note: note)
        return snapshot
    }
}
