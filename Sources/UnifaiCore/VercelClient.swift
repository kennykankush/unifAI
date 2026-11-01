import Foundation

public struct VercelUsage: Codable, Hashable {
    public struct Meter: Codable, Hashable {
        public var name: String
        public var quantity: Decimal
        public var unit: String
        public var projectID: String?
        public init(name: String, quantity: Decimal, unit: String, projectID: String? = nil) {
            self.name = name; self.quantity = quantity; self.unit = unit; self.projectID = projectID
        }
    }
    public var from: Date
    public var to: Date
    public var meters: [Meter]
    public var grossCost: Money?
    public var note: String
    public init(from: Date, to: Date, meters: [Meter], grossCost: Money?, note: String) {
        self.from = from; self.to = to; self.meters = meters; self.grossCost = grossCost; self.note = note
    }
}

/// Team/project APIs are public. The optional billing query follows Vercel CLI's
/// /v2/billing/costs contract, which is not a stable public REST API.
public struct VercelClient {
    enum AccessError: LocalizedError {
        case denied
        var errorDescription: String? { "Vercel refused access. Check the Team ID, token scope and team permissions." }
    }
    let session: URLSession
    public init(session: URLSession = BalanceClient.privateSession()) { self.session = session }

    public struct Credential: Codable {
        public let teamID: String
        public let token: String
        public static func encode(teamID: String, token: String) throws -> String {
            let value = Credential(teamID: teamID.trimmingCharacters(in: .whitespacesAndNewlines),
                                   token: token.trimmingCharacters(in: .whitespacesAndNewlines))
            try value.validate()
            return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        }
        func validate() throws {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
            guard teamID.hasPrefix("team_"), teamID.count > 5, teamID.count < 160,
                  teamID.unicodeScalars.allSatisfy({ allowed.contains($0) }), !token.isEmpty,
                  token.count < 2048, token.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }) else {
                throw ValidationError.message("Enter the Team ID (team_…) from Vercel team settings and an access token for that team.")
            }
        }
    }

    struct Team: Decodable {
        struct Billing: Decodable { let plan: String }
        let id: String; let slug: String; let name: String; let billing: Billing
    }
    struct Projects: Decodable {
        struct Project: Decodable {
            struct Deployment: Decodable { let readyState: String? }
            let id: String; let name: String; let framework: String?; let latestDeployments: [Deployment]?
        }
        struct Pagination: Decodable { let next: Int64? }
        let projects: [Project]; let pagination: Pagination?
    }

    public func fetch(credential: String, now: Date = .now) async throws -> BalanceSnapshot {
        guard let key = try? JSONDecoder().decode(Credential.self, from: Data(credential.utf8)) else {
            throw ValidationError.message("Edit this wallet and enter its Vercel Team ID and access token.")
        }
        try key.validate()
        let team: Team = try await request("/v2/teams/\(key.teamID)", key: key)
        guard team.id == key.teamID, !team.billing.plan.isEmpty else { throw ConnectorError.invalidResponse }
        var projects: [Projects.Project] = [], cursor: Int64?, cursors = Set<Int64>()
        for pageNumber in 0..<50 {
            var query = [URLQueryItem(name: "limit", value: "100")]
            if let cursor { query.append(URLQueryItem(name: "until", value: String(cursor))) }
            let page: Projects = try await request("/v9/projects", key: key, query: query)
            projects += page.projects
            guard let next = page.pagination?.next else { break }
            guard cursors.insert(next).inserted, pageNumber < 49 else {
                throw ValidationError.message("Vercel project pagination did not finish. The previous reading is preserved.")
            }
            cursor = next
        }
        guard Set(projects.map(\.id)).count == projects.count else { throw ConnectorError.invalidResponse }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.dateInterval(of: .month, for: now)!.start
        var snapshot = BalanceSnapshot(balances: [], observedAt: now, source: URL(string: "https://vercel.com/dashboard")!,
            coverage: "\(projects.count) projects visible to this token in \(team.name). Plan read from Vercel. Earlier upgrade dates are unknown; later plan changes are detected between successful readings. Payments and invoices remain separate.",
            plan: "Vercel \(team.billing.plan.capitalized)", consumptionPeriod: "This month (UTC)")
        snapshot.providerScope = team.id
        snapshot.resources = projects.map { project in
            var resource = CloudResource(id: project.id, name: project.name, type: "vercel/project", group: team.name,
                location: nil, cost: nil, meters: [], state: project.latestDeployments?.first?.readyState, size: project.framework)
            var url = URL(string: "https://vercel.com")!
            url.appendPathComponent(team.slug); url.appendPathComponent(project.name)
            resource.webURL = url
            return resource
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        do {
            // Vercel's current join attributes only the first view. Preserve detail-first
            // key order; Swift dictionaries / JSONSerialization do not guarantee it.
            let body = """
            {"from":"\(start.ISO8601Format())","to":"\(now.ISO8601Format())","metrics":["gross_cost","quantity"],"format":"timeseries","views":{"byProductRegionProject":{"groupBy":["product","region","project"]},"byProduct":{"groupBy":["product"]}},"userAgent":"unifai"}
            """
            let costs: Costs = try await request("/v2/billing/costs", key: key, body: Data(body.utf8))
            let decoded = try Self.decodeCosts(costs, from: start, to: now)
            snapshot.vercelUsage = decoded.usage
            snapshot.services = decoded.services
            // Never infer zero for an inventory project absent from the billing response.
            for index in snapshot.resources!.indices {
                let id = snapshot.resources![index].id
                if let lines = decoded.projects[id] {
                    snapshot.resources![index].meters = lines
                    snapshot.resources![index].cost = Money(lines.reduce(0) { $0 + $1.cost.amount }, "USD")
                }
            }
            // Keep charges for deleted/inaccessible projects and unattributed usage visible.
            let known = Set(projects.map(\.id))
            let billedIDs = Set(decoded.projects.keys).union(decoded.usage.meters.compactMap(\.projectID))
            for id in billedIDs.sorted() where !known.contains(id) {
                let lines = decoded.projects[id]
                snapshot.resources!.append(CloudResource(id: id, name: costs.results.dimensionsMeta["project"]?.values?[id]?.title ?? id,
                    type: "vercel/project", group: "Billing only", location: nil,
                    cost: lines.map { Money($0.reduce(0) { $0 + $1.cost.amount }, "USD") }, meters: lines ?? []))
            }
        } catch {
            snapshot.vercelUsage = VercelUsage(from: start, to: now, meters: [], grossCost: nil,
                note: "Usage unavailable. \(Self.safeMessage(error)) Project inventory and plan were refreshed; unavailable usage does not mean zero.")
        }
        return snapshot
    }

    private func request<T: Decodable>(_ path: String, key: Credential, query: [URLQueryItem] = [], body: Data? = nil) async throws -> T {
        var url = URLComponents(string: "https://api.vercel.com\(path)")!
        url.queryItems = [URLQueryItem(name: "teamId", value: key.teamID)] + query
        var request = URLRequest(url: url.url!)
        request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
        request.setValue("Bearer \(key.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ConnectorError.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw AccessError.denied
        case 429: throw ConnectorError.rateLimited
        default: throw ConnectorError.unavailable(http.statusCode)
        }
        guard let result = try? JSONDecoder().decode(T.self, from: data) else { throw ConnectorError.invalidResponse }
        return result
    }

    static func safeMessage(_ error: Error) -> String {
        if error is AccessError { return "The token may lack access to team billing." }
        switch error as? ConnectorError {
        case .authorization: return "The token may lack access to team billing."
        case .rateLimited: return "Vercel rate-limited the request; retry later."
        default: return "The billing route may be unavailable or its response format may have changed."
        }
    }

    // Contract verified against Vercel CLI usage/types.ts and usage/index.ts, 2026-11-01.
    struct Costs: Decodable {
        struct Metric: Decodable {
            struct Unit: Decodable { let kind: String; let name: String?; let singular: String?; let plural: String? }
            let slug: String; let unit: Unit?
        }
        struct Group: Decodable { let dimensionValues: [String: String?]; let metrics: [String]; let totalValue: [Decimal] }
        struct View: Decodable { let groupBy: [String]; let results: [Group] }
        struct Metadata: Decodable {
            struct Value: Decodable { let title: String?; let category: String? }
            let values: [String: Value]?
        }
        struct Results: Decodable { let dimensionsMeta: [String: Metadata]; let views: [String: View] }
        let metrics: [Metric]; let availableCurrencies: [String]?; let results: Results
    }

    static func decodeCosts(_ costs: Costs, from: Date, to: Date) throws -> (usage: VercelUsage, services: [CostLine]?, projects: [String: [CostLine]]) {
        guard let summary = costs.results.views["byProduct"], summary.groupBy == ["product"],
              let costMetric = costs.metrics.first(where: { $0.slug == "gross_cost" }), let costUnit = costMetric.unit else { throw ConnectorError.invalidResponse }
        let isUSD = costUnit.name == "USD" || costUnit.singular == "USD" || costUnit.plural == "USD"
            || (costUnit.kind == "custom" && costUnit.singular == "dollar" && costUnit.plural == "dollars")
        let currencyOK = costs.availableCurrencies?.allSatisfy { $0 == "USD" } ?? true
        let monetary = isUSD && currencyOK
        var meters: [VercelUsage.Meter] = [], services: [CostLine] = [], projects: [String: [CostLine]] = [:]
        var total: Decimal = 0
        func parse(_ group: Costs.Group, projectID: String?) throws -> CostLine? {
            guard let product = group.dimensionValues["product"] ?? nil, !product.isEmpty,
                  group.metrics.count == group.totalValue.count,
                  let costIndex = group.metrics.firstIndex(of: "gross_cost"),
                  group.totalValue.allSatisfy({ !$0.isNaN && $0 >= 0 }) else { throw ConnectorError.invalidResponse }
            let name = costs.results.dimensionsMeta["product"]?.values?[product]?.title ?? product
            if costs.results.dimensionsMeta["product"]?.values?[product]?.category != "Subscription Licenses",
               let quantityIndex = group.metrics.firstIndex(where: { $0 != "gross_cost" }),
               let unit = costs.metrics.first(where: { $0.slug == group.metrics[quantityIndex] })?.unit {
                // Preserve provider units; never treat MIUs as CPU hours or dollars.
                let unitName = unit.plural ?? unit.singular ?? unit.name ?? unit.kind
                if let index = meters.firstIndex(where: { $0.name == name && $0.unit == unitName && $0.projectID == projectID }) {
                    meters[index].quantity += group.totalValue[quantityIndex]
                } else { meters.append(.init(name: name, quantity: group.totalValue[quantityIndex], unit: unitName, projectID: projectID)) }
            }
            return monetary ? CostLine(name: name, cost: Money(group.totalValue[costIndex], "USD")) : nil
        }
        for group in summary.results {
            if let line = try parse(group, projectID: nil) { services.append(line); total += line.cost.amount }
        }
        if let detail = costs.results.views["byProductRegionProject"] {
            guard detail.groupBy.contains("project") else { throw ConnectorError.invalidResponse }
            for group in detail.results {
                let id = (group.dimensionValues["project"] ?? nil) ?? "Unattributed"
                if let line = try parse(group, projectID: id) { projects[id, default: []].append(line) }
            }
        }
        let note = monetary
            ? "Gross charges before credits, discounts and taxes, including any subscription lines Vercel returns. Calendar month to date (UTC), not necessarily your billing cycle. Excluded from spending totals; import invoices to record payments. Billing uses Vercel's CLI route, which may change."
            : "Vercel returned a non-USD or unknown cost unit. Monetary totals are unavailable; usage quantities retain their reported units. Excluded from spending totals."
        func merge(_ lines: [CostLine]) -> [CostLine] {
            Dictionary(grouping: lines, by: \.name).map { name, rows in
                CostLine(name: name, cost: Money(rows.reduce(0) { $0 + $1.cost.amount }, "USD"))
            }.sorted { $0.cost.amount == $1.cost.amount ? $0.name < $1.name : $0.cost.amount > $1.cost.amount }
        }
        return (VercelUsage(from: from, to: to, meters: meters, grossCost: monetary ? Money(total, "USD") : nil, note: note),
                monetary ? merge(services) : nil, projects.mapValues(merge))
    }
}

public enum PlanWatch {
    public static func events(old: BalanceSnapshot?, new: BalanceSnapshot, account: ConnectedAccount, now: Date) -> [TimelineEvent] {
        guard let plan = new.plan, !plan.isEmpty else { return [] }
        let name = Catalogue.integration(account.integrationID)?.name ?? account.integrationID
        guard let old, let previous = old.plan else {
            return [TimelineEvent(id: "plan-first-\(account.id)", date: now, kind: .recorded,
                title: "\(name): \(plan) first observed",
                detail: "This is the first plan reading in Unifai, not the subscription start or upgrade date.",
                source: new.source, sourceName: name, accountID: account.id)]
        }
        guard previous != plan, old.providerScope == new.providerScope else { return [] }
        return [TimelineEvent(id: "plan-change-\(account.id)-\(Int(now.timeIntervalSince1970))", date: now, kind: .recorded,
            title: "\(name): plan changed to \(plan)",
            detail: "Previously \(previous). Observed between \(old.observedAt.ISO8601Format()) and \(now.ISO8601Format()). The exact change time and payment amount are unknown.",
            source: new.source, sourceName: name, accountID: account.id, important: true)]
    }
}
