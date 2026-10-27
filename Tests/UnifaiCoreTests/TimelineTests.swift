import XCTest
@testable import UnifaiCore

@MainActor
final class TimelineTests: XCTestCase {
    private let source = URL(string: "https://example.invalid")!
    private let base = Date(timeIntervalSince1970: 1_792_000_000) // 2026-10-15

    private func codexSnapshot(weekly: Int, resetsAt: Date, credits: [ResetCredit]? = nil, at now: Date) -> BalanceSnapshot {
        BalanceSnapshot(balances: [], observedAt: now, source: source, coverage: "Synthetic", plan: "ChatGPT Plus",
                        allowances: [AllowanceWindow(name: "Weekly window", usedPercent: weekly, windowMinutes: 10080, resetsAt: resetsAt),
                                     AllowanceWindow(name: "5-hour window", usedPercent: 10, windowMinutes: 300, resetsAt: now.addingTimeInterval(3600))],
                        resetCredits: credits)
    }

    private func store(balances: @escaping AppStore.BalanceLoader = { _, _, _ in throw ConnectorError.invalidResponse },
                       releases: @escaping AppStore.ReleaseLoader = { _, _ in throw ConnectorError.invalidResponse },
                       status: @escaping AppStore.StatusLoader = { _ in throw ConnectorError.invalidResponse },
                       posts: @escaping AppStore.PostLoader = { _, _, _, _ in throw ConnectorError.invalidResponse },
                       feeds: @escaping AppStore.FeedLoader = { _ in Data("<rss><channel></channel></rss>".utf8) }) -> AppStore {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return AppStore(repository: StateRepository(directory: root.appendingPathComponent(".build/test-data/\(UUID().uuidString)")), vault: MemoryVault(),
                        balances: balances, releases: releases, status: status, posts: posts, feeds: feeds)
    }

    // MARK: Resets and limits

    func testEarlyResetScheduledResetAndLimitReached() {
        let account = ConnectedAccount(integrationID: "codex", label: "Personal", mode: .live)
        let reset = base.addingTimeInterval(3 * 86400)
        let full = codexSnapshot(weekly: 100, resetsAt: reset, at: base)

        let early = AllowanceWatch.events(old: full, new: codexSnapshot(weekly: 0, resetsAt: base.addingTimeInterval(7 * 86400), at: base), account: account, now: base)
        XCTAssertEqual(early.map(\.kind), [.earlyReset])
        XCTAssertTrue(early[0].important)
        XCTAssertTrue(early[0].detail.contains("100% to 0%"))

        let onTime = AllowanceWatch.events(old: full, new: codexSnapshot(weekly: 0, resetsAt: reset.addingTimeInterval(7 * 86400), at: reset), account: account, now: reset.addingTimeInterval(60))
        XCTAssertEqual(onTime.map(\.kind), [.reset])

        let limit = AllowanceWatch.events(old: codexSnapshot(weekly: 90, resetsAt: reset, at: base), new: full, account: account, now: base)
        XCTAssertEqual(limit.map(\.kind), [.limitReached])

        XCTAssertTrue(AllowanceWatch.events(old: full, new: full, account: account, now: base).isEmpty, "No change, no event")
        XCTAssertTrue(AllowanceWatch.events(old: codexSnapshot(weekly: 40, resetsAt: reset, at: base), new: codexSnapshot(weekly: 35, resetsAt: reset, at: base),
                                            account: account, now: base).isEmpty, "Small drops are noise, not resets")
        XCTAssertTrue(AllowanceWatch.events(old: nil, new: full, account: account, now: base).isEmpty, "The first reading has nothing to compare")
    }

    func testNewFreeResetIsReportedOnce() {
        let account = ConnectedAccount(integrationID: "codex", label: "Personal", mode: .live)
        let credit = ResetCredit(id: "c1", title: "Full reset (Weekly + 5 hr)", grantedAt: base, expiresAt: base.addingTimeInterval(30 * 86400))
        let before = codexSnapshot(weekly: 50, resetsAt: base.addingTimeInterval(86400), at: base)
        let after = codexSnapshot(weekly: 50, resetsAt: base.addingTimeInterval(86400), credits: [credit], at: base)
        XCTAssertEqual(AllowanceWatch.events(old: before, new: after, account: account, now: base).map(\.kind), [.resetCredit])
        XCTAssertTrue(AllowanceWatch.events(old: after, new: after, account: account, now: base).isEmpty)
    }

    func testRefreshRecordsResetEventsOnce() async throws {
        var weekly = 100
        let reset = Date().addingTimeInterval(3 * 86400)
        let store = store(balances: { [self] _, _, now in codexSnapshot(weekly: weekly, resetsAt: reset, at: now) })
        try store.addAccount(integrationID: "codex", label: "Personal", billingScope: "ChatGPT", mode: .live)
        let id = store.state.accounts[0].id
        await store.refreshAccount(id, now: Date())
        weekly = 0
        await store.refreshAccount(id, now: Date().addingTimeInterval(120))
        await store.refreshAccount(id, now: Date().addingTimeInterval(240))
        XCTAssertEqual(store.state.events?.filter { $0.kind == .earlyReset }.count, 1)
    }

    func testRecordDeduplicatesCapsAndUpdatesStatus() {
        var state = PersistentState()
        let first = TimelineEvent(id: "a", date: base, kind: .status, title: "OpenAI: errors", detail: "Investigating", sourceName: "OpenAI status", important: true)
        XCTAssertEqual(state.record([first]).count, 1)
        XCTAssertTrue(state.record([first]).isEmpty)
        var resolved = first; resolved.detail = "Resolved"; resolved.important = false
        XCTAssertTrue(state.record([resolved]).isEmpty, "An update is not a new event")
        XCTAssertEqual(state.events?.first?.detail, "Resolved")
        XCTAssertEqual(state.events?.first?.important, false)
        let many = (0..<700).map { TimelineEvent(id: "e\($0)", date: base.addingTimeInterval(Double($0)), kind: .release, title: "r", detail: "", sourceName: "x") }
        state.record(many)
        XCTAssertEqual(state.events?.count, PersistentState.timelineLimit)
        XCTAssertEqual(state.events?.first?.id, "e699", "Newest first")
    }

    // MARK: Codex

    func testCodexDecodesFreeResetsAndUsageHistory() throws {
        let account = Data(#"{"account":{"type":"chatgpt","planType":"plus"}}"#.utf8)
        let limits = Data(#"{"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":1792300000}},"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"r1","status":"available","grantedAt":1791416208,"expiresAt":1794008208,"title":"Full reset (Weekly + 5 hr)"},{"id":"r0","status":"redeemed","grantedAt":1790000000,"title":"Old"}]}}"#.utf8)
        let usage = Data(#"{"dailyUsageBuckets":[{"startDate":"2026-10-02","tokens":5},{"startDate":"2026-10-01","tokens":7}],"summary":{"lifetimeTokens":21896916585}}"#.utf8)
        let snapshot = try CodexClient.decode(account: account, limits: limits, usage: usage)
        XCTAssertEqual(snapshot.resetCredits?.count, 2, "The available count is authoritative even when details are capped")
        XCTAssertEqual(snapshot.resetCredits?.first?.title, "Full reset (Weekly + 5 hr)")
        XCTAssertEqual(snapshot.resetCredits?.first?.key, "r1")
        XCTAssertEqual(snapshot.usageDays?.map(\.date), ["2026-10-01", "2026-10-02"])
        XCTAssertEqual(snapshot.lifetimeTokens, 21896916585)
        let without = try CodexClient.decode(account: account, limits: Data(#"{"rateLimits":{}}"#.utf8))
        XCTAssertNil(without.resetCredits)
        XCTAssertNil(without.usageDays)
    }

    func testPlanAdvice() {
        var account = ConnectedAccount(integrationID: "codex", label: "Personal", mode: .live)
        account.snapshot = codexSnapshot(weekly: 50, resetsAt: base.addingTimeInterval(86400), at: base)
        let hits = (1...2).map { TimelineEvent(id: "l\($0)", date: base.addingTimeInterval(-Double($0) * 86400 * 7), kind: .limitReached,
                                                title: "ChatGPT & Codex: weekly window limit reached", detail: "", sourceName: "Codex", accountID: account.id) }
        XCTAssertEqual(PlanAdvisor.advice(for: account, events: hits, now: base), "Weekly limit hit 2 times in 4 weeks; a bigger plan may pay off")
        account.snapshot?.usageDays = (1...14).map { UsageDay(date: "2026-10-\(String(format: "%02d", $0))", tokens: $0 == 3 ? 100 : 0) }
        XCTAssertEqual(PlanAdvisor.advice(for: account, events: [], now: base), "Used on 1 of the last 14 days; a smaller plan may be enough")
    }

    // MARK: Azure

    private func azureRows(_ rows: [(Double, String, String)]) -> Data {
        let body = rows.map { "[\($0.0),\($0.1),\"\($0.2)\",\"USD\"]" }.joined(separator: ",")
        let head = #"{"properties":{"columns":[{"name":"Cost"},{"name":"UsageDate"},{"name":"ServiceName"},{"name":"Currency"}],"rows":["#
        return Data((head + body + "]}}").utf8)
    }

    func testAzureDailyRowsGiveMonthToDateAndFlagSpikes() throws {
        let now = RateTable.dayFormatter.date(from: "2026-10-19")!.addingTimeInterval(15 * 3600)
        var rows: [(Double, String, String)] = []
        for day in 1...30 { rows.append((1.0, "202609\(String(format: "%02d", day))", "Virtual Machines")) }
        for day in 1...18 { rows.append((day == 18 ? 4.5 : 0.5, "202610\(String(format: "%02d", day))", "Virtual Machines")) }
        rows.append((2.0, "20261019", "Virtual Machines")) // today, partial: counted but not judged
        rows.append((3.0, "20261018", "GPU Compute"))      // new service
        rows.append((0.8, "20261018", "Storage"))          // new but under 1.00
        let snapshot = try AzureCostClient.decode([("Sub", azureRows(rows))], now: now)
        // October only: 17 x 0.5 + 4.5 + 2.0 + 3.0 + 0.8
        XCTAssertEqual(snapshot.reportedConsumption, [Money(Decimal(string: "18.8")!, "USD")])
        let spikes = snapshot.anomalies ?? []
        XCTAssertEqual(spikes.map(\.service), ["Virtual Machines", "GPU Compute"])
        XCTAssertEqual(spikes[0].day, "2026-10-18")
        XCTAssertEqual(spikes[0].typical, Money(Decimal(string: "0.5")!, "USD"))
        XCTAssertEqual(spikes[1].typical.amount, 0, "New spend has no usual cost")
        XCTAssertTrue(spikes[1].summary.contains("started costing"))
    }

    func testAzureWithoutHistoryOrWithSteadyCostHasNoSpikes() throws {
        let now = RateTable.dayFormatter.date(from: "2026-10-19")!.addingTimeInterval(15 * 3600)
        let fresh = try AzureCostClient.decode([("Sub", azureRows([(5.0, "20261018", "Virtual Machines")]))], now: now)
        XCTAssertEqual(fresh.anomalies, [], "A brand-new subscription has nothing to compare against")
        let steady = try AzureCostClient.decode([("Sub", azureRows((1...18).map { (3.0, "202610\(String(format: "%02d", $0))", "Virtual Machines") }))], now: now)
        XCTAssertEqual(steady.anomalies, [])
        let monthOnly = try AzureCostClient.decode([("Sub", Data(#"{"properties":{"columns":[{"name":"Cost"},{"name":"ServiceName"},{"name":"Currency"}],"rows":[[2.5,"Storage","USD"]]}}"#.utf8))])
        XCTAssertNil(monthOnly.anomalies, "Month totals without days cannot be judged")
    }

    func testAnomalyBecomesOneEvent() async throws {
        let spike = CostAnomaly(service: "Virtual Machines", day: "2026-10-18", amount: Money(Decimal(string: "6.42")!, "USD"), typical: Money(Decimal(string: "0.28")!, "USD"))
        let store = store(balances: { [source] _, _, now in
            BalanceSnapshot(balances: [], reportedConsumption: [Money(10, "USD")], observedAt: now, source: source, coverage: "Synthetic",
                            consumptionPeriod: "This month", anomalies: [spike])
        })
        try store.addAccount(integrationID: "azure-subscription", label: "Personal", billingScope: "Azure", mode: .live)
        let id = store.state.accounts[0].id
        await store.refreshAccount(id, now: Date())
        await store.refreshAccount(id, now: Date().addingTimeInterval(120))
        let events = store.state.events?.filter { $0.kind == .anomaly } ?? []
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.title, "Azure subscriptions: Virtual Machines cost jumped")
    }

    // MARK: Status pages

    func testStatusFeedParsesStatuspageAndIncidentIOFormats() {
        let now = RSS.date("Mon, 19 Oct 2026 15:00:00 GMT")!
        let openai = Data("""
        <?xml version="1.0"?><rss version="2.0"><channel><title>OpenAI status</title>
        <item><title><![CDATA[File Download errors]]></title><link>https://status.openai.com//incidents/01M5</link><guid>https://status.openai.com//incidents/01M5</guid>
        <pubDate>Mon, 19 Oct 2026 13:31:52 GMT</pubDate><description><![CDATA[<b>Status: Identified</b><br/><br/>We have identified elevated errors.<ul><li>Files (Degraded performance)</li></ul>]]></description></item>
        <item><title>Old incident</title><link>https://status.openai.com/old</link><pubDate>Mon, 01 Sep 2026 10:00:00 GMT</pubDate><description>Resolved</description></item>
        </channel></rss>
        """.utf8)
        let feed = StatusFeed.all.first { $0.id == "openai" }!
        let events = StatusFeedClient.events(openai, feed: feed, now: now)
        XCTAssertEqual(events.count, 1, "Older than 14 days is dropped")
        XCTAssertEqual(events[0].title, "OpenAI: File Download errors")
        XCTAssertTrue(events[0].detail.hasPrefix("Identified · We have identified elevated errors."))
        XCTAssertTrue(events[0].important)

        let anthropic = Data("""
        <rss version="2.0"><channel><item><title>Elevated errors on platform.claude.com</title>
        <description>&lt;p&gt;&lt;small&gt;Oct 13, 18:00 UTC&lt;/small&gt;&lt;br&gt;&lt;strong&gt;Resolved&lt;/strong&gt; - This issue has been resolved.&lt;/p&gt;</description>
        <pubDate>Mon, 13 Oct 2026 18:00:00 +0000</pubDate><link>https://status.claude.com/incidents/x</link><guid>https://status.claude.com/incidents/x</guid></item></channel></rss>
        """.utf8)
        let resolved = StatusFeedClient.events(anthropic, feed: StatusFeed.all.first { $0.id == "anthropic" }!, now: now)
        XCTAssertEqual(resolved.first?.detail, "Resolved · This issue has been resolved.")
        XCTAssertEqual(resolved.first?.important, false)

        XCTAssertTrue(StatusFeedClient.events(openai, feed: feed, now: now, integrations: ["codex"]).isEmpty, "A file download incident is not about Codex")
        XCTAssertEqual(StatusFeedClient.events(openai, feed: feed, now: now, integrations: ["codex", "openai-api"]).count, 1)

        let deepseek = Data("""
        <rss version="2.0"><channel><item><title>DeepSeek 网页/API 部分中断（DeepSeek Web/API Partially Unavailable）</title><link>https://status.deepseek.com/incidents/7</link>
        <description>&lt;p&gt;&lt;strong&gt;Status:&lt;/strong&gt; resolved&lt;/p&gt;&lt;p&gt;本次问题已解决，服务已恢复。&#xA;&#xA;The incident has been resolved and service has been restored.&lt;/p&gt;</description>
        <guid>urn:flashduty:change:7</guid><pubDate>Thu, 15 Oct 2026 08:11:35 +0800</pubDate></item></channel></rss>
        """.utf8)
        let translated = StatusFeedClient.events(deepseek, feed: StatusFeed.all.first { $0.id == "deepseek" }!, now: now)
        XCTAssertEqual(translated.first?.title, "DeepSeek: DeepSeek Web/API Partially Unavailable")
        XCTAssertEqual(translated.first?.detail, "Resolved · The incident has been resolved and service has been restored.")
    }

    func testOnlyFeedsForYourWalletsAreRead() {
        let accounts = [ConnectedAccount(integrationID: "codex", label: "a", mode: .live), ConnectedAccount(integrationID: "openrouter", label: "b", mode: .live)]
        XCTAssertEqual(StatusFeed.relevant(to: accounts).map(\.id), ["openai"])
    }

    // MARK: X

    func testXHandlesPostsAndResetDetection() throws {
        XCTAssertEqual(XClient.validHandle("@thsottiaux"), "thsottiaux")
        XCTAssertEqual(XClient.validHandle("https://x.com/thsottiaux/status/1"), "thsottiaux")
        XCTAssertNil(XClient.validHandle("not a handle!"))
        XCTAssertTrue(XClient.mentionsReset("We just reset Codex rate limits for everyone"))
        XCTAssertTrue(XClient.mentionsReset("Usage limits have been lifted for the weekend"))
        XCTAssertFalse(XClient.mentionsReset("New Codex app update is out"))
        let posts = try XClient.decodePosts(Data(#"{"data":[{"id":"1900","text":"Resetting rate limits now &amp; enjoy","created_at":"2026-10-19T08:00:00.000Z"}],"meta":{"result_count":1}}"#.utf8))
        XCTAssertEqual(posts.first?.date, ISO8601DateFormatter().date(from: "2026-10-19T08:00:00Z"))
        let event = XClient.events(posts, handle: "thsottiaux")[0]
        XCTAssertTrue(event.important)
        XCTAssertEqual(event.detail, "Resetting rate limits now & enjoy")
        XCTAssertEqual(event.source?.absoluteString, "https://x.com/thsottiaux/status/1900")
        XCTAssertEqual(try XClient.decodePosts(Data(#"{"meta":{"result_count":0}}"#.utf8)), [])
    }

    func testTimelineRefreshPollsOnlyNewPostsAndCountsCost() async throws {
        var calls: [(String?, String?)] = []
        let feedData = Data("<rss><channel></channel></rss>".utf8)
        let store = store(status: { _ in feedData }, posts: { _, _, id, since in
            calls.append((id, since))
            return since == nil
                ? XClient.Result(userID: "42", posts: [.init(id: "998", text: "a", date: Date()), .init(id: "1001", text: "b", date: Date())], lookups: id == nil ? 1 : 0)
                : XClient.Result(userID: "42", posts: [], lookups: 0)
        })
        try store.addAccount(integrationID: "codex", label: "Personal", billingScope: "ChatGPT", mode: .live)
        await store.refreshTimeline(force: true)
        XCTAssertTrue(calls.isEmpty, "No token, no X requests")
        XCTAssertThrowsError(try store.setXHandles("one, two!"))
        try store.setXHandles("@thsottiaux")
        try store.setXToken("token")
        XCTAssertTrue(store.hasXToken)
        let now = Date()
        let fresh = await store.refreshTimeline(force: true, now: now)
        XCTAssertEqual(fresh.filter { $0.kind == .post }.count, 2)
        let spaced = await store.refreshTimeline(now: now.addingTimeInterval(60))
        XCTAssertTrue(spaced.isEmpty, "Spaced 30 minutes apart unless forced")
        await store.refreshTimeline(force: true, now: now.addingTimeInterval(120))
        XCTAssertEqual(calls.count, 2)
        guard calls.count == 2 else { return }
        XCTAssertNil(calls[0].0); XCTAssertNil(calls[0].1)
        XCTAssertEqual(calls[1].0, "42", "The user ID is cached")
        XCTAssertEqual(calls[1].1, "1001", "Asks only for posts newer than the newest seen (numeric order)")
        XCTAssertEqual(store.xCost(month: now), Money(Decimal(string: "0.02")!, "USD"), "2 posts at 0.005 plus one lookup at 0.01")
        try store.setXToken(nil)
        XCTAssertFalse(store.hasXToken)
    }

    // MARK: Releases

    func testReleaseRelevanceAndSummary() {
        let accounts = [ConnectedAccount(integrationID: "codex", label: "Personal", mode: .live),
                        ConnectedAccount(integrationID: "deepseek", label: "Personal", mode: .live)]
        let release = ReleaseItem(id: 1, title: "0.50.0", tag: "rust-v0.50.0", url: URL(string: "https://github.com/openai/codex/releases")!,
                                  publishedAt: base, prerelease: false, summary: "Adds DeepSeek provider presets")
        XCTAssertEqual(ReleaseRelevance.wallets(for: release, repository: "openai/codex", accounts: accounts), ["ChatGPT & Codex", "DeepSeek API"])
        XCTAssertEqual(ReleaseRelevance.wallets(for: release, repository: "someone/else", accounts: [accounts[0]]), [])
        XCTAssertEqual(ReleaseRelevance.summary(fromMarkdown: "## Highlights\n- **Faster** [cloud tasks](https://x.y)\n\n**Full Changelog**: a...b"),
                       "Highlights · Faster cloud tasks")
        XCTAssertNil(ReleaseRelevance.summary(fromMarkdown: ""))
    }

    func testWalletRepositoriesAreFollowedOnceAndReleasesEnterTheTimeline() async throws {
        let now = Date()
        let store = store(releases: { repository, _ in
            GitHubFetchResult(releases: [ReleaseItem(id: 7, title: "Codex 1.2", tag: "v1.2", url: URL(string: "https://github.com/\(repository.slug)/releases/tag/v1.2")!,
                                                     publishedAt: now.addingTimeInterval(-3600), prerelease: false, summary: "Notes")],
                              etag: nil, retryAfter: now.addingTimeInterval(1800))
        })
        try store.addAccount(integrationID: "codex", label: "Personal", billingScope: "ChatGPT", mode: .live)
        XCTAssertEqual(store.state.repositories.map(\.slug), ["openai/codex"])
        try store.removeRepository(store.state.repositories[0].id)
        store.followWalletRepositories()
        XCTAssertTrue(store.state.repositories.isEmpty, "Unfollowing sticks")
        try store.addRepository("openai/codex", includePrereleases: false)
        await store.refreshDueRepositories(now: now)
        let release = store.state.events?.first { $0.kind == .release }
        XCTAssertEqual(release?.title, "openai/codex Codex 1.2")
        XCTAssertEqual(release?.important, true)
        XCTAssertTrue(release?.detail.hasPrefix("Affects ChatGPT & Codex") == true)
    }

    // MARK: Headroom and month close

    func testHeadroomRanksRoomFirstAndExhaustedLast() {
        var state = PersistentState()
        var codex = ConnectedAccount(integrationID: "codex", label: "Personal", mode: .live)
        codex.snapshot = codexSnapshot(weekly: 100, resetsAt: base.addingTimeInterval(2 * 86400), credits: [ResetCredit(title: "Full reset", grantedAt: base, expiresAt: nil)], at: base)
        var router = ConnectedAccount(integrationID: "openrouter", label: "Dev", mode: .live)
        router.snapshot = BalanceSnapshot(balances: [Money(Decimal(string: "9.54")!, "USD")], observedAt: base, source: source, coverage: "Synthetic")
        var azure = ConnectedAccount(integrationID: "azure-subscription", label: "Personal", mode: .live)
        azure.snapshot = BalanceSnapshot(balances: [], reportedConsumption: [Money(17, "USD")], observedAt: base, source: source, coverage: "Synthetic", consumptionPeriod: "This month")
        state.accounts = [codex, azure, router, ConnectedAccount(integrationID: "chatgpt", label: "Manual", mode: .manual)]
        let report = AgentReport.headroom(state, now: base)
        XCTAssertEqual(report.ranked.map(\.providerID), ["openrouter", "azure-subscription", "codex"])
        XCTAssertEqual(report.ranked.last?.freeResets, 1)
        XCTAssertFalse(report.ranked.last?.usableNow ?? true)
        XCTAssertTrue(report.ranked.last?.summary.contains("1 free reset available") == true)
        XCTAssertTrue(report.recommendation.hasPrefix("Use OpenRouter account (Dev) first"))

        // Codex credits keep Codex usable past its limits, ahead of pay-as-you-go.
        codex.snapshot?.balances = [Money(Decimal(string: "187.92")!, "CREDITS")]
        state.accounts[0] = codex
        let withCredits = AgentReport.headroom(state, now: base)
        XCTAssertEqual(withCredits.ranked.map(\.providerID), ["openrouter", "codex", "azure-subscription"])
        XCTAssertEqual(withCredits.ranked[1].summary, "Weekly window used up, resets in 2 days; 187.92 credits cover usage until then; 1 free reset available")
    }

    func testReceiptRequestListsEntriesAndImportColumns() {
        var state = PersistentState()
        let account = ConnectedAccount(integrationID: "claude-subscription", label: "Personal", mode: .live)
        state.accounts = [account]
        var record = PaymentRecord(accountID: account.id, description: "Claude Max 20x", kind: .subscription, money: Money(Decimal(string: "299.99")!, "SGD"),
                                   paidAt: RateTable.dayFormatter.date(from: "2026-10-05")!, scheduleID: UUID())
        record.reference = ""
        let text = state.receiptRequest(for: [record])
        XCTAssertTrue(text.contains("2026-10-05 · Claude subscription · Claude Max 20x · about 299.99 SGD") || text.contains("· Claude Max 20x · about 299.99 SGD"))
        XCTAssertTrue(text.contains("date,description,amount,currency,kind,account,account_label,reference"))
    }
}

/// Opt-in: reads the public status pages. Run with UNIFAI_TEST_STATUS=1.
final class LiveStatusTests: XCTestCase {
    func testLiveStatusFeedsIfRequested() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UNIFAI_TEST_STATUS"] == "1", "Set UNIFAI_TEST_STATUS=1 to read the providers' public status pages.")
        for feed in StatusFeed.all {
            let data = try await StatusFeedClient().fetch(feed)
            let events = StatusFeedClient.events(data, feed: feed, days: 30, integrations: ["codex", "claude-subscription", "azure-subscription", "deepseek"])
            print("Status \(feed.id): \(RSS.items(data).count) items, \(events.count) in 30 days; first: \(events.first.map { "\($0.title) [\($0.detail.prefix(80))]" } ?? "none")")
        }
    }
}

@MainActor
final class TopUpDetectionTests: XCTestCase {
    private let source = URL(string: "https://example.invalid")!

    private func openRouter(purchased: Decimal, remaining: Decimal, at now: Date) -> BalanceSnapshot {
        BalanceSnapshot(balances: [Money(remaining, "USD")], details: [BalanceDetail("Reported credits purchased", Money(purchased, "USD"))],
                        observedAt: now, source: source, coverage: "Synthetic")
    }

    func testOpenRouterPurchaseIsRecordedOnceWithFeeAndAReceiptReplacesIt() async throws {
        var purchased: Decimal = 10
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let store = AppStore(repository: StateRepository(directory: root.appendingPathComponent(".build/test-data/\(UUID().uuidString)")), vault: MemoryVault(),
                             balances: { [self] _, _, now in openRouter(purchased: purchased, remaining: 5, at: now) })
        try store.addAccount(integrationID: "openrouter", label: "Dev", billingScope: "dev", mode: .live, credential: "k")
        let id = store.state.accounts[0].id
        let now = Date()
        await store.refreshAccount(id, now: now)
        XCTAssertTrue(store.state.payments.isEmpty, "The first reading has nothing to compare")
        purchased = 30
        await store.refreshAccount(id, now: now.addingTimeInterval(120))
        await store.refreshAccount(id, now: now.addingTimeInterval(240))
        XCTAssertEqual(store.state.payments.count, 1)
        let detected = store.state.payments[0]
        XCTAssertEqual(detected.money, Money(Decimal(string: "21.10")!, "USD"), "20.00 credits plus OpenRouter's 5.5% fee (0.80 minimum)")
        XCTAssertEqual(detected.kind, .topUp)
        XCTAssertTrue(detected.autoRecorded)
        XCTAssertEqual(store.state.events?.filter { $0.kind == .recorded }.count, 1)

        let day = RateTable.dayFormatter.string(from: now)
        let receipt = "date,description,amount,currency,kind,account,reference\n\(day),OpenRouter credits,21.10,USD,top-up,openrouter,OR-1"
        let summary = try store.importPayments(try PaymentImport.parse(receipt), now: now.addingTimeInterval(300))
        XCTAssertEqual(summary.replaced, 1)
        XCTAssertEqual(store.state.payments.map(\.reference), ["OR-1"])
    }

    func testAManuallyLoggedTopUpIsNotCountedTwice() {
        let account = ConnectedAccount(integrationID: "openrouter", label: "Dev", mode: .live)
        let now = Date()
        let manual = PaymentRecord(accountID: account.id, description: "OpenRouter", kind: .topUp, money: Money(Decimal(string: "10.80")!, "USD"), paidAt: now.addingTimeInterval(-86400))
        XCTAssertTrue(TopUpWatch.payments(old: openRouter(purchased: 0, remaining: 0, at: now.addingTimeInterval(-2 * 86400)), new: openRouter(purchased: 10, remaining: 10, at: now),
                                          account: account, recorded: [manual], now: now).isEmpty)
        XCTAssertEqual(TopUpWatch.payments(old: openRouter(purchased: 0, remaining: 0, at: now), new: openRouter(purchased: 10, remaining: 10, at: now),
                                           account: account, recorded: [], now: now).first?.money, Money(Decimal(string: "10.80")!, "USD"))
    }

    func testDeepSeekBalanceRiseIsALowerBoundEstimate() {
        let account = ConnectedAccount(integrationID: "deepseek", label: "Dev", mode: .live)
        let now = Date()
        func reading(_ purchased: Decimal) -> BalanceSnapshot {
            BalanceSnapshot(balances: [Money(purchased, "USD")], details: [BalanceDetail("Purchased balance", Money(purchased, "USD"))], observedAt: now, source: source, coverage: "Synthetic")
        }
        XCTAssertEqual(TopUpWatch.payments(old: reading(3.43), new: reading(13.2), account: account, recorded: [], now: now).first?.money.amount, Decimal(string: "9.77"))
        XCTAssertTrue(TopUpWatch.payments(old: reading(3.43), new: reading(3.9), account: account, recorded: [], now: now).isEmpty, "Under 1.00 is noise")
        XCTAssertTrue(TopUpWatch.payments(old: reading(13), new: reading(3), account: account, recorded: [], now: now).isEmpty, "Usage lowers it")
    }

    func testVercelAIGatewayCreditsAddedRiseIsDetected() throws {
        let account = ConnectedAccount(integrationID: "vercel-ai-gateway", label: "Personal", mode: .live)
        let now = Date()
        func reading(_ added: Decimal, at date: Date) -> BalanceSnapshot {
            BalanceSnapshot(balances: [Money(added - 1, "USD")], details: [BalanceDetail("Credits added", Money(added, "USD"))],
                            reportedConsumption: [Money(1, "USD")], observedAt: date, source: source, coverage: "Synthetic")
        }
        let found = try XCTUnwrap(TopUpWatch.payments(old: reading(15, at: now.addingTimeInterval(-60)), new: reading(35, at: now),
                                                      account: account, recorded: [], now: now).first)
        XCTAssertEqual(found.money, Money(20, "USD"))
        XCTAssertEqual(found.estimated, true)
        XCTAssertEqual(found.detection?.before, Money(15, "USD"))
        XCTAssertEqual(found.detection?.lowerBound, false)
        let opening = try XCTUnwrap(TopUpWatch.payments(old: nil, new: reading(15, at: now), account: account, recorded: [], now: now).first)
        XCTAssertEqual(opening.money, Money(10, "USD"), "Credits added minus the $5 free credit")
        XCTAssertEqual(opening.estimated, true)
        XCTAssertEqual(opening.kind, .topUp)
        let earlier = BalanceSnapshot(balances: [Money(15, "USD")], observedAt: now.addingTimeInterval(-60), source: source, coverage: "Before Credits added existed")
        XCTAssertEqual(TopUpWatch.payments(old: earlier, new: reading(15, at: now), account: account, recorded: [], now: now).count, 1, "Upgraded wallets get the proposal once")
        XCTAssertTrue(TopUpWatch.payments(old: nil, new: reading(15, at: now), account: account, recorded: [opening], now: now).isEmpty, "Never proposed twice")
        XCTAssertTrue(TopUpWatch.payments(old: nil, new: reading(5, at: now), account: account, recorded: [], now: now).isEmpty, "Free credit alone is not a purchase")
        XCTAssertTrue(TopUpWatch.payments(old: reading(15, at: now.addingTimeInterval(-60)), new: reading(15.5, at: now),
                                          account: account, recorded: [], now: now).isEmpty, "Under 1.00 is noise")
    }
}

final class NewsAndModelsTests: XCTestCase {
    func testAtomAndRSSNewsBecomeRecentEvents() {
        let now = ISO8601DateFormatter().date(from: "2026-10-20T03:00:00Z")!
        let atom = Data("""
        <?xml version="1.0" encoding="utf-8"?><feed xmlns="http://www.w3.org/2005/Atom"><title>Simon Willison</title>
        <entry><title>Claude Code tips</title><link href="https://simonwillison.net/2026/Oct/19/tips/" rel="alternate"/><id>urn:1</id>
        <updated>2026-10-19T22:10:00+00:00</updated><summary type="html">&lt;p&gt;Some &lt;em&gt;tips&lt;/em&gt;.&lt;/p&gt;</summary></entry>
        <entry><title>Old post</title><link href="https://simonwillison.net/2026/Sep/1/old/"/><id>urn:2</id><updated>2026-09-01T10:00:00Z</updated></entry></feed>
        """.utf8)
        let feed = NewsFeed.all.first { $0.id == "simonw" }!
        let events = NewsFeed.events(atom, feed: feed, now: now)
        XCTAssertEqual(events.map(\.title), ["Claude Code tips"], "Older than a week is dropped")
        XCTAssertEqual(events.first?.source?.absoluteString, "https://simonwillison.net/2026/Oct/19/tips/")
        XCTAssertEqual(events.first?.detail, "Some tips.")
        XCTAssertEqual(events.first?.kind, .news)

        let rss = Data("""
        <rss version="2.0"><channel><item><title><![CDATA[Introducing GPT-6]]></title><link>https://openai.com/index/gpt-6</link>
        <guid>gpt-6</guid><pubDate>Mon, 19 Oct 2026 17:00:00 GMT</pubDate><description>A new model.</description></item></channel></rss>
        """.utf8)
        XCTAssertEqual(NewsFeed.events(rss, feed: NewsFeed.all[0], now: now).first?.title, "Introducing GPT-6")
    }

    func testNewModelsAreRecentPricedAndFlaggedForYourProviders() {
        let now = Date(timeIntervalSince1970: 1_792_500_000)
        let fresh = Int(now.timeIntervalSince1970) - 86400, stale = Int(now.timeIntervalSince1970) - 40 * 86400
        let data = Data("""
        {"data":[{"id":"deepseek/deepseek-v4.1-flash","name":"DeepSeek: V4.1 Flash","created":\(fresh),"context_length":1048576,"pricing":{"prompt":"0.00000015","completion":"0.0000006"}},
                 {"id":"minimax/m3:free","name":"MiniMax M3 (free)","created":\(fresh - 60),"context_length":1000000,"pricing":{"prompt":"0","completion":"0"}},
                 {"id":"openai/gpt-old","name":"Old","created":\(stale),"context_length":8000,"pricing":{"prompt":"0.00001","completion":"0.00003"}}]}
        """.utf8)
        let accounts = [ConnectedAccount(integrationID: "deepseek", label: "Dev", mode: .live)]
        let events = NewModels.events(data, accounts: accounts, now: now)
        XCTAssertEqual(events.map(\.title), ["DeepSeek: V4.1 Flash", "MiniMax M3 (free)"])
        XCTAssertEqual(events[0].detail, "1048K context · $0.15 in, $0.60 out per million tokens")
        XCTAssertTrue(events[0].important, "You pay DeepSeek")
        XCTAssertFalse(events[1].important)
        XCTAssertEqual(events[1].detail, "1000K context · free")
        XCTAssertEqual(NewModels.author(of: events[0]), "deepseek")
        XCTAssertTrue(NewModels.events(Data("not json".utf8), accounts: [], now: now).isEmpty)
    }
}

final class ForwardCompatibilityTests: XCTestCase {
    func testUnknownEventKindsFromANewerVersionStillLoad() throws {
        let json = #"{"schemaVersion":1,"accounts":[],"payments":[],"subscriptions":[],"repositories":[],"events":[{"id":"x","date":0,"kind":"Something new","title":"t","detail":"","sourceName":"s","important":false}]}"#
        let state = try JSONDecoder().decode(PersistentState.self, from: Data(json.utf8))
        XCTAssertEqual(state.events?.first?.kind, .news)
    }
}
