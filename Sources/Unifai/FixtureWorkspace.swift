import Foundation
import UnifaiCore

// Explicit opt-in only. This transport never creates URLSession or reads Keychain.
enum FixtureWorkspace {
    static func checkNativeKeychain(directory: URL) {
        let vault = KeychainVault(service: "dev.unifai.synthetic-native-check.\(UUID().uuidString)")
        let a = UUID(), b = UUID()
        var results: [String: String] = ["scope": "Unique synthetic test service; no ambient credentials read", "time": Date.now.ISO8601Format()]
        do {
            guard try vault.read(accountID: a) == nil else { throw ValidationError.message("Expected a new item.") }
            try vault.write("synthetic-a", accountID: a); try vault.write("synthetic-b", accountID: b)
            guard try vault.read(accountID: a) == "synthetic-a", try vault.read(accountID: b) == "synthetic-b" else { throw ValidationError.message("Isolation check failed.") }
            try vault.write("synthetic-replaced", accountID: a)
            guard try vault.read(accountID: a) == "synthetic-replaced", try vault.read(accountID: b) == "synthetic-b" else { throw ValidationError.message("Replacement check failed.") }
            try vault.delete(accountID: a); try vault.delete(accountID: b)
            guard try vault.read(accountID: a) == nil, try vault.read(accountID: b) == nil else { throw ValidationError.message("Deletion check failed.") }
            results["result"] = "PASS: create, read, replace, isolate, delete"
        } catch {
            results["result"] = "FAIL: \(error.localizedDescription)"
            do { try vault.delete(accountID: a); try vault.delete(accountID: b) }
            catch { results["cleanup"] = error.localizedDescription }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(results).write(to: directory.appendingPathComponent("native-keychain-check.json"), options: .atomic)
        } catch { NSLog("Could not save the synthetic Keychain check result.") }
    }
    @MainActor static func prepare(_ store: AppStore, vault: MemoryVault) throws {
        if store.state.accounts.isEmpty && store.state.payments.isEmpty && store.state.repositories.isEmpty {
            try store.addAccount(integrationID: "openrouter", label: "Personal", billingScope: "Personal billing", mode: .live, credential: "fixture-valid")
            try store.addAccount(integrationID: "openrouter", label: "Experiments", billingScope: "Experiment billing", mode: .live, credential: "fixture-valid")
            try store.addAccount(integrationID: "deepseek", label: "Personal", billingScope: "DeepSeek personal", mode: .live, credential: "fixture-valid")
            try store.addAccount(integrationID: "chatgpt", label: "Personal subscription", billingScope: "Shared with Codex", mode: .manual)
            try store.savePayment(.init(accountID: store.state.accounts[0].id, description: "OpenRouter credit purchase", kind: .topUp, money: Money(100, "USD"), paidAt: .now.addingTimeInterval(-86400 * 10), reference: "SYNTHETIC-001"))
            try store.savePayment(.init(accountID: store.state.accounts[3].id, description: "ChatGPT subscription", kind: .subscription, money: Money(20, "USD"), paidAt: .now.addingTimeInterval(-86400 * 5), reference: "SYNTHETIC-002"))
            try store.savePayment(.init(accountID: store.state.accounts[2].id, description: "DeepSeek credit purchase", kind: .topUp, money: Money(100, "CNY"), paidAt: .now.addingTimeInterval(-86400 * 2), reference: "SYNTHETIC-003"))
            try store.saveSubscription(.init(accountID: store.state.accounts[3].id, name: "ChatGPT", price: Money(20, "USD"), cadence: .monthly, nextRenewal: .now.addingTimeInterval(86400 * 25)))
            try store.addRepository("example/ai-hub", includePrereleases: false)
        }
        // Added separately so existing synthetic workspaces gain the OpenAI connectors too.
        if !store.state.accounts.contains(where: { $0.integrationID == "codex" }) {
            try store.addAccount(integrationID: "codex", label: "Personal", billingScope: "ChatGPT Plus", mode: .live)
        }
        if !store.state.accounts.contains(where: { $0.integrationID == "claude-subscription" }) {
            try store.addAccount(integrationID: "claude-subscription", label: "Personal", billingScope: "Claude subscription", mode: .live)
        }
        if !store.state.accounts.contains(where: { $0.integrationID == "azure-subscription" }) {
            try store.addAccount(integrationID: "azure-subscription", label: "Personal", billingScope: "Azure subscription", mode: .live)
        }
        if !store.state.accounts.contains(where: { $0.integrationID == "claude-api" }) {
            try store.addAccount(integrationID: "claude-api", label: "Console", billingScope: "Synthetic Claude organization", mode: .live, credential: "fixture-valid")
        }
        if !store.state.accounts.contains(where: { $0.integrationID == "openai-api" }) {
            try store.addAccount(integrationID: "openai-api", label: "Side projects", billingScope: "Synthetic organization", mode: .live, credential: "fixture-valid")
        }
        if !store.state.accounts.contains(where: { $0.integrationID == "vercel" }) {
            try store.addAccount(integrationID: "vercel", label: "Demo team", billingScope: "Synthetic Vercel team", mode: .live, credential: "fixture-valid")
        }
        for integration in ["github-billing", "cloudflare", "digitalocean", "supabase"] where !store.state.accounts.contains(where: { $0.integrationID == integration }) {
            try store.addAccount(integrationID: integration, label: "Demo", billingScope: "Synthetic \(integration)", mode: .live, credential: "fixture-valid")
        }
        // Synthetic monthly history so the demo shows a detected subscription.
        if let claude = store.state.accounts.first(where: { $0.integrationID == "claude-subscription" }),
           !store.state.payments.contains(where: { $0.reference.hasPrefix("SYNTHETIC-MAX") }) {
            for (index, monthsAgo) in [3, 2, 1].enumerated() {
                let date = Calendar.current.date(byAdding: .month, value: -monthsAgo, to: .now)!.addingTimeInterval(-86400 * 4)
                try store.savePayment(.init(accountID: claude.id, description: "Claude Max 5x", kind: .subscription, money: Money(Decimal(string: "149.99")!, "SGD"),
                                            paidAt: date, reference: "SYNTHETIC-MAX-\(index)"))
            }
        }
        for account in store.state.accounts where account.mode == .live { try vault.write("fixture-valid", accountID: account.id) }
        // Synthetic timeline: what the app records when a reset or limit happens between two readings.
        if store.state.events?.contains(where: { $0.id.hasPrefix("fixture-") }) != true,
           let codex = store.state.accounts.first(where: { $0.integrationID == "codex" }) {
            let hour: TimeInterval = 3600
            try store.recordEvents([
                TimelineEvent(id: "fixture-early", date: .now.addingTimeInterval(-2 * hour), kind: .earlyReset,
                              title: "ChatGPT & Codex: weekly window was reset early",
                              detail: "Usage went from 100% to 0%. The scheduled reset was in 3 days.", sourceName: "ChatGPT & Codex", accountID: codex.id, important: true),
                TimelineEvent(id: "fixture-limit", date: .now.addingTimeInterval(-26 * hour), kind: .limitReached,
                              title: "ChatGPT & Codex: weekly window limit reached", detail: "You have used 100% of this window.",
                              sourceName: "ChatGPT & Codex", accountID: codex.id, important: true),
                TimelineEvent(id: "fixture-limit-2", date: .now.addingTimeInterval(-9 * 24 * hour), kind: .limitReached,
                              title: "ChatGPT & Codex: weekly window limit reached", detail: "You have used 100% of this window.",
                              sourceName: "ChatGPT & Codex", accountID: codex.id, important: true),
            ])
        }
        if !store.hasXToken {
            try store.setXToken("fixture-x-token")
            try store.setXHandles("thsottiaux")
        }
    }

    /// Synthetic status pages: one ongoing incident and one resolved.
    static func status(_ feed: StatusFeed) async throws -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let recent = formatter.string(from: .now.addingTimeInterval(-3 * 3600)), older = formatter.string(from: .now.addingTimeInterval(-50 * 3600))
        let items: String
        switch feed.id {
        case "openai":
            items = """
            <item><title>Elevated errors for Codex cloud tasks</title><link>https://status.openai.com/</link><guid>fixture-openai-1</guid><pubDate>\(recent)</pubDate>
            <description><![CDATA[<b>Status: Identified</b><br/>We are seeing elevated errors starting Codex cloud tasks and are applying a fix.]]></description></item>
            """
        case "anthropic":
            items = """
            <item><title>Slow responses on Claude Opus</title><link>https://status.claude.com/</link><guid>fixture-anthropic-1</guid><pubDate>\(older)</pubDate>
            <description>&lt;p&gt;&lt;strong&gt;Resolved&lt;/strong&gt; - Response times are back to normal.&lt;/p&gt;</description></item>
            """
        default: items = ""
        }
        return Data("<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>Synthetic</title>\(items)</channel></rss>".utf8)
    }

    /// Synthetic news feeds and model list; the demo never contacts them.
    static func feeds(_ url: URL) async throws -> Data {
        let now = Date.now
        if url == NewModels.url {
            let created = Int(now.addingTimeInterval(-26 * 3600).timeIntervalSince1970), older = Int(now.addingTimeInterval(-4 * 86400).timeIntervalSince1970)
            return Data("""
            {"data":[{"id":"deepseek/deepseek-v4.1-flash","name":"DeepSeek: DeepSeek V4.1 Flash","created":\(created),"context_length":1048576,"pricing":{"prompt":"0.00000015","completion":"0.0000006"}},
                     {"id":"minimax/minimax-m3.1-flash:free","name":"MiniMax: MiniMax M3.1 Flash (free)","created":\(older),"context_length":1000000,"pricing":{"prompt":"0","completion":"0"}}]}
            """.utf8)
        }
        guard let feed = NewsFeed.all.first(where: { $0.url == url }), ["openai", "huggingface"].contains(feed.id) else {
            return Data("<rss version=\"2.0\"><channel></channel></rss>".utf8)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let date = formatter.string(from: now.addingTimeInterval(feed.id == "openai" ? -5 * 3600 : -30 * 3600))
        let (title, detail) = feed.id == "openai"
            ? ("Introducing faster Codex cloud tasks", "Cloud tasks now start in seconds and can run in parallel across repositories.")
            : ("Open models you can run on a laptop", "A tour of small open-weight models and the hardware they need.")
        return Data("""
        <rss version="2.0"><channel><item><title>\(title)</title><link>https://example.com/\(feed.id)</link><guid>fixture-\(feed.id)</guid>
        <pubDate>\(date)</pubDate><description>\(detail)</description></item></channel></rss>
        """.utf8)
    }

    /// Synthetic X posts; the demo never contacts X.
    static func posts(_ token: String, _ handle: String, _ userID: String?, _ sinceID: String?) async throws -> XClient.Result {
        guard sinceID == nil else { return .init(userID: "100", posts: [], lookups: 0) }
        return .init(userID: "100", posts: [
            .init(id: "1900000000000000002", text: "We just reset Codex rate limits for everyone on Plus and Pro. Enjoy, and keep the feedback coming.", date: .now.addingTimeInterval(-2.2 * 3600)),
            .init(id: "1900000000000000001", text: "Codex app update is rolling out today with faster cloud tasks.", date: .now.addingTimeInterval(-30.0 * 3600)),
        ], lookups: 1)
    }
    static func balance(_ integration: String, _ credential: String, _ now: Date) async throws -> BalanceSnapshot {
        if credential == "fixture-unauthorized" { throw ConnectorError.authorization }
        if credential == "fixture-offline" { throw URLError(.notConnectedToInternet) }
        if ["github-billing", "github-org-billing", "cloudflare", "digitalocean", "supabase"].contains(integration) {
            var snapshot = BalanceSnapshot(balances: [], observedAt: now, source: URL(string: "https://example.invalid/fixture")!, coverage: "Synthetic provider report. No live account was accessed.")
            let inventory = integration == "supabase"
            snapshot.providerUsage = ProviderUsage(period: inventory ? "Current inventory" : "Provider billing period",
                costLabel: inventory ? "Billing unavailable" : integration == "digitalocean" ? "Month-to-date usage" : "Metered usage", costs: inventory ? [] : [Money(12.5, "USD")],
                meters: inventory || integration == "digitalocean" ? [] : [.init(name: "Compute", quantity: 250, unit: "minutes")],
                note: inventory ? "Project inventory only. Billing totals and CPU consumption are unavailable." : "Synthetic usage report. Kept separate from payments.")
            if inventory {
                var resource = CloudResource(id: "abcdefghijklmnopqrst", name: "Demo database", type: "supabase/project", group: "Demo organization", location: "ap-southeast-1", cost: nil, meters: [], state: "ACTIVE_HEALTHY", size: "Small")
                resource.webURL = URL(string: "https://supabase.com/dashboard")
                snapshot.resources = [resource]
            }
            if integration == "digitalocean" {
                snapshot.providerUsage?.details = [BalanceDetail("Account balance (signed)", Money(-20, "USD")), BalanceDetail("Month-to-date balance (signed)", Money(-7.5, "USD"))]
            }
            return snapshot
        }
        if integration == "vercel" {
            var snapshot = BalanceSnapshot(balances: [], observedAt: now, source: URL(string: "https://vercel.com/dashboard")!,
                coverage: "Synthetic Vercel team. No live account was accessed.", plan: "Vercel Pro")
            snapshot.providerScope = "team_fixture"
            snapshot.vercelUsage = VercelUsage(from: Calendar.current.dateInterval(of: .month, for: now)!.start, to: now,
                meters: [.init(name: "Active CPU", quantity: 4.25, unit: "CPU-hours"),
                         .init(name: "Provisioned memory", quantity: 92, unit: "GB-hours"),
                         .init(name: "Function invocations", quantity: 125000, unit: "invocations"),
                         .init(name: "Active CPU", quantity: 4.25, unit: "CPU-hours", projectID: "prj_demo")],
                grossCost: Money(8.75, "USD"), note: "Synthetic gross charges before credits and taxes. Excluded from spending totals; import invoices to record payments.")
            snapshot.services = [CostLine(name: "Active CPU", cost: Money(0.85, "USD")), CostLine(name: "Other usage", cost: Money(7.9, "USD"))]
            var project = CloudResource(id: "prj_demo", name: "Demo application", type: "vercel/project", group: "Fixture team", location: nil,
                cost: Money(8.75, "USD"), meters: snapshot.services!, state: "READY", size: "Next.js")
            project.webURL = URL(string: "https://vercel.com/dashboard")
            snapshot.resources = [project]
            return snapshot
        }
        if integration == "codex" {
            let account = Data(#"{"account":{"type":"chatgpt","email":null,"planType":"plus"},"requiresOpenaiAuth":true}"#.utf8)
            let fiveHour = Int(now.addingTimeInterval(3 * 3600 + 1200).timeIntervalSince1970), weekly = Int(now.addingTimeInterval(3 * 86400 + 7200).timeIntervalSince1970)
            let granted = Int(now.addingTimeInterval(-86400).timeIntervalSince1970), expires = Int(now.addingTimeInterval(29 * 86400).timeIntervalSince1970)
            let limits = Data("{\"rateLimits\":{\"limitId\":\"codex\",\"planType\":\"plus\",\"primary\":{\"usedPercent\":42,\"windowDurationMins\":300,\"resetsAt\":\(fiveHour)},\"secondary\":{\"usedPercent\":68,\"windowDurationMins\":10080,\"resetsAt\":\(weekly)},\"credits\":{\"hasCredits\":true,\"unlimited\":false,\"balance\":\"120.50\"}},\"rateLimitResetCredits\":{\"availableCount\":1,\"credits\":[{\"id\":\"fixture-credit\",\"resetType\":\"codexRateLimits\",\"status\":\"available\",\"grantedAt\":\(granted),\"expiresAt\":\(expires),\"title\":\"Full reset (Weekly + 5 hr)\"}]}}".utf8)
            let days = (0..<30).map { offset -> String in
                let date = RateTable.dayFormatter.string(from: now.addingTimeInterval(Double(offset - 29) * 86400))
                return "{\"startDate\":\"\(date)\",\"tokens\":\([0, 1_200_000, 8_400_000, 3_100_000, 0, 12_800_000][offset % 6])}"
            }
            let usage = Data("{\"dailyUsageBuckets\":[\(days.joined(separator: ","))],\"summary\":{\"lifetimeTokens\":412000000}}".utf8)
            return try CodexClient.decode(account: account, limits: limits, usage: usage, now: now)
        }
        if integration == "azure-subscription" {
            // 35 days of daily costs; Virtual Machines jumps yesterday, like a GPU VM left running.
            let utc = DateFormatter()
            utc.locale = Locale(identifier: "en_US_POSIX"); utc.timeZone = TimeZone(identifier: "UTC"); utc.dateFormat = "yyyyMMdd"
            var rows: [String] = []
            for offset in 0...35 {
                let day = utc.string(from: now.addingTimeInterval(Double(offset - 35) * 86400))
                let vm = offset == 34 ? 6.42 : 0.28, foundry = [0.18, 0.31, 0.0, 0.44][offset % 4]
                rows.append("[\(vm),\(day),\"Virtual Machines\",\"USD\"]")
                rows.append("[\(foundry),\(day),\"Foundry Models\",\"USD\"]")
                rows.append("[0.04,\(day),\"Storage\",\"USD\"]")
            }
            let body = #"{"properties":{"columns":[{"name":"Cost"},{"name":"UsageDate"},{"name":"ServiceName"},{"name":"Currency"}],"rows":["# + rows.joined(separator: ",") + "]}}"
            var snapshot = try AzureCostClient.decode([("Synthetic subscription", Data(body.utf8))], now: now)
            let base = "/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups"
            func usd(_ value: String) -> Money { Money(Decimal(string: value)!, "USD") }
            snapshot.resources = [
                CloudResource(id: "\(base)/ml-lab/providers/microsoft.compute/virtualmachines/gpu-train-01", name: "gpu-train-01", type: "microsoft.compute/virtualmachines",
                              group: "ml-lab", location: "eastus", cost: usd("9.64"), meters: [CostLine(name: "NC6s v3 (Linux)", cost: usd("8.44")), CostLine(name: "P30 LRS Disk", cost: usd("1.20"))],
                              state: "Running", size: "Standard_NC6s_v3"),
                CloudResource(id: "\(base)/hadi-ai/providers/microsoft.cognitiveservices/accounts/hadi-foundry", name: "hadi-foundry", type: "microsoft.cognitiveservices/accounts",
                              group: "hadi-ai", location: "eastus2", cost: usd("7.11"),
                              meters: [CostLine(name: "gpt-4.1-mini Inp glbl Tokens", cost: usd("3.20")), CostLine(name: "gpt-4.1-mini Outp glbl Tokens", cost: usd("2.90")), CostLine(name: "o4-mini Inp glbl Tokens", cost: usd("1.01"))],
                              size: "S0", models: [ModelDeployment(name: "gpt-4.1-mini", model: "gpt-4.1-mini", version: "2025-04-14", sku: "GlobalStandard", capacity: 50),
                                                   ModelDeployment(name: "o4-mini", model: "o4-mini", version: "2025-04-16", sku: "GlobalStandard", capacity: 20)]),
                CloudResource(id: "\(base)/hadi-ai/providers/microsoft.storage/storageaccounts/hadilabstore", name: "hadilabstore", type: "microsoft.storage/storageaccounts",
                              group: "hadi-ai", location: "eastus2", cost: usd("1.05"), meters: [CostLine(name: "Hot LRS Data Stored", cost: usd("0.81")), CostLine(name: "Read Operations", cost: usd("0.24"))], size: "Standard_LRS"),
                CloudResource(id: "\(base)/ml-lab/providers/microsoft.network/publicipaddresses/gpu-train-01-ip", name: "gpu-train-01-ip", type: "microsoft.network/publicipaddresses",
                              group: "ml-lab", location: "eastus", cost: usd("0.63"), meters: [CostLine(name: "Standard IPv4 Static Public IP", cost: usd("0.63"))]),
                CloudResource(id: "\(base)/dev/providers/microsoft.compute/virtualmachines/old-sandbox", name: "old-sandbox", type: "microsoft.compute/virtualmachines",
                              group: "dev", location: nil, cost: usd("0.40"), meters: [CostLine(name: "D2s v5", cost: usd("0.40"))], state: "Deleted"),
                CloudResource(id: "\(base)/dev/providers/microsoft.compute/virtualmachines/dev-box", name: "dev-box", type: "microsoft.compute/virtualmachines",
                              group: "dev", location: "southeastasia", cost: usd("0.28"), meters: [CostLine(name: "P10 LRS Disk", cost: usd("0.28"))], state: "Deallocated", size: "Standard_D4s_v5"),
            ]
            return snapshot
        }
        if integration == "claude-subscription" {
            return try ClaudeCodeClient.decode(Data(#"{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}"#.utf8), now: now)
        }
        if integration == "claude-api" {
            let iso = ISO8601DateFormatter(), today = Calendar.current.startOfDay(for: now)
            let buckets = (0..<30).map { day -> String in
                let start = today.addingTimeInterval(TimeInterval((day - 29) * 86400))
                let cents = [412, 0, 1180, 655, 2310, 95][day % 6]
                return "{\"starting_at\":\"\(iso.string(from: start))\",\"ending_at\":\"\(iso.string(from: start.addingTimeInterval(86400)))\",\"results\":[{\"amount\":\"\(cents)\",\"currency\":\"USD\"}]}"
            }
            return try BalanceClient.decode(integrationID: integration, data: Data("{\"data\":[\(buckets.joined(separator: ","))],\"has_more\":false}".utf8), source: URL(string: "https://api.anthropic.com")!, now: now)
        }
        if integration == "openai-api" {
            let today = Int(Calendar.current.startOfDay(for: now).timeIntervalSince1970)
            let buckets = (0..<30).map { day -> String in
                let start = today - (29 - day) * 86400
                let value = day % 3 == 0 ? 0 : [0.42, 1.18, 0.73, 2.05, 0.31][day % 5]
                return "{\"object\":\"bucket\",\"start_time\":\(start),\"end_time\":\(start + 86400),\"results\":[{\"object\":\"organization.costs.result\",\"amount\":{\"value\":\(value),\"currency\":\"usd\"}}]}"
            }
            let body = "{\"object\":\"page\",\"data\":[\(buckets.joined(separator: ","))],\"has_more\":false}"
            return try BalanceClient.decode(integrationID: integration, data: Data(body.utf8), source: URL(string: "https://api.openai.com")!, now: now)
        }
        let body = integration == "openrouter"
            ? #"{"data":{"total_credits":100,"total_usage":30}}"#
            : #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"}]}"#
        return try BalanceClient.decode(integrationID: integration, data: Data(body.utf8), source: URL(string: integration == "openrouter" ? "https://openrouter.ai/api/v1/credits" : "https://api.deepseek.com/user/balance")!, now: now)
    }
    /// Synthetic reference rates; the demo never contacts the ECB.
    static func rates(_ currencies: [String], _ since: Date, _ now: Date) async throws -> RateTable {
        let base: [String: Double] = ["USD": 1.08, "SGD": 1.43, "CNY": 7.6, "GBP": 0.85, "JPY": 160]
        var rates: [String: [String: Double]] = [:]
        var day = Calendar.current.startOfDay(for: since).addingTimeInterval(-14 * 86400)
        while day <= now {
            rates[RateTable.dayFormatter.string(from: day)] = base.filter { currencies.contains($0.key) }
            day = day.addingTimeInterval(86400)
        }
        return RateTable(rates: rates, fetchedAt: now, currencies: currencies)
    }

    static func releases(_ repository: WatchedRepository, _ now: Date) async throws -> GitHubFetchResult {
        let iso = ISO8601DateFormatter()
        let slug = repository.slug, seed = abs(slug.hashValue % 1000) * 10
        let first = iso.string(from: now.addingTimeInterval(-20 * 3600)), second = iso.string(from: now.addingTimeInterval(-4 * 86400))
        let notes = slug.contains("codex") ? "## Highlights\\n- Faster cloud tasks\\n- Shows remaining usage in the status line" : "- Synthetic release notes"
        let data = Data("""
        [{"id":\(seed + 1),"name":"Synthetic release","tag_name":"v1.\(seed % 7).0","html_url":"https://github.com/\(slug)/releases","published_at":"\(first)","prerelease":false,"draft":false,"body":"\(notes)"},
         {"id":\(seed + 2),"name":"Synthetic preview","tag_name":"v1.\(seed % 7).1-beta","html_url":"https://github.com/\(slug)/releases","published_at":"\(second)","prerelease":true,"draft":false}]
        """.utf8)
        return .init(releases: try GitHubClient.decode(data), etag: "fixture-etag", retryAfter: now.addingTimeInterval(1800))
    }
}
