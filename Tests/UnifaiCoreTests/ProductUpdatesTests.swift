import XCTest
@testable import UnifaiCore

final class ProductUpdatesTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-11-02T12:00:00Z")!
    let notes = ProductSource.all.first { $0.id == "openai-notes" }!
    let policy = ProductSource.all.first { $0.id == "openai-pro" }!
    var account: ConnectedAccount { ConnectedAccount(integrationID: "codex", label: "Test", mode: .manual) }
    func page(_ body: String) -> Data { Data("<html><nav>Ignore menu</nav><article>\(body)</article><footer>Ignore footer</footer></html>".utf8) }
    func policyPage(_ phrase: String) -> Data {
        page("<h1>Usage limits</h1><p>\(phrase)</p><p>Account eligibility and subscription benefits depend on the selected plan and settings.</p>")
    }
    func testDatedNotesDeduplicateAndPreserveScope() throws {
        let section = "<h1>October 29, 2026</h1><h2>More usage</h2><p>Pro 100 includes twice the previous allowance. Plus usage is unchanged.</p>"
        let snapshot = try ProductUpdates.decode(page(section + section + "<h1>January 1, 2025</h1><h2>Old update</h2><p>Not new today.</p>"), source: notes, now: now)
        XCTAssertEqual(snapshot.entries.count, 1)
        let events = ProductUpdates.events(old: nil, new: snapshot, source: notes, accounts: [account], now: now)
        XCTAssertEqual(events.count, 1); XCTAssertFalse(events[0].important)
        XCTAssertTrue(events[0].notice!.excerpt.contains("Plus usage is unchanged"))
        XCTAssertTrue(events[0].notice!.relevance.contains("not verified"))
        XCTAssertEqual(events[0].date, ISO8601DateFormatter().date(from: "2026-10-29T00:00:00Z"))
        XCTAssertTrue(ProductUpdates.events(old: snapshot, new: snapshot, source: notes, accounts: [account], now: now).isEmpty)
    }
    func testPolicyBaselineSilentAndRealEditsRetainBeforeAfter() throws {
        let old = try ProductUpdates.decode(policyPage("Pro plans include one weekly usage allowance for eligible personal subscribers."), source: policy, now: now)
        XCTAssertTrue(ProductUpdates.events(old: nil, new: old, source: policy, accounts: [account], now: now).isEmpty)
        let new = try ProductUpdates.decode(policyPage("Pro plans now include twice the weekly usage allowance. Other plans remain unchanged."), source: policy, now: now)
        let events = ProductUpdates.events(old: old, new: new, source: policy, accounts: [account], now: now)
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events[0].kind, .policyChange); XCTAssertTrue(events[0].important)
        XCTAssertNotNil(events[0].notice?.previousExcerpt)
        XCTAssertNil(events[0].notice?.publishedAt)
        let markup = try ProductUpdates.decode(policyPage("<strong>Pro plans</strong> now include twice the weekly usage allowance. Other plans remain unchanged."), source: policy, now: now)
        XCTAssertTrue(ProductUpdates.events(old: new, new: markup, source: policy, accounts: [account], now: now).isEmpty)
    }
    func testReorderingRemovalsAndInvalidPages() throws {
        let a = "<p>Usage limits are subject to the subscription plan selected for your account.</p>"
        let b = "<p>Included credits expire according to the promotion terms for eligible subscribers.</p>"
        let old = try ProductUpdates.decode(page(a+b), source: policy, now: now)
        let reordered = try ProductUpdates.decode(page(b+a), source: policy, now: now)
        XCTAssertTrue(ProductUpdates.events(old: old, new: reordered, source: policy, accounts: [], now: now).isEmpty)
        let removed = try ProductUpdates.decode(page(b + "<p>Subscription benefit eligibility depends on current account settings and selected plan.</p>"), source: policy, now: now)
        let events = ProductUpdates.events(old: old, new: removed, source: policy, accounts: [], now: now)
        XCTAssertEqual(events.count, 1); XCTAssertFalse(events[0].important)
        XCTAssertTrue(events[0].notice!.previousExcerpt!.contains("Usage limits"))
        XCTAssertThrowsError(try ProductUpdates.decode(Data("<html>Challenge page</html>".utf8), source: policy, now: now))
        XCTAssertThrowsError(try ProductUpdates.decode(page("<h1>Release notes moved</h1>"), source: notes, now: now))
    }
    func testMarkdownAndClaudeParagraphHeadings() throws {
        let source = ProductSource.all.first { $0.id == "claude-api-notes" }!
        let snapshot = try ProductUpdates.decode(Data("# Release notes\n### October 30, 2026\n- We deprecated a model feature. It will be removed next month.\n### October 29, 2026\n- A new feature is available to eligible users.\n".utf8), source: source, now: now)
        XCTAssertEqual(snapshot.entries.count, 2)
        XCTAssertEqual(ProductUpdates.topic(snapshot.entries[0].text), "Retirements & changes")
        let claude = ProductSource.all.first { $0.id == "claude-notes" }!
        let html = page("<h2>October 2026</h2><h3>October 29, 2026</h3><p><strong>New benefit</strong></p><p>Selected subscriptions now include credits; activation is required.</p>")
        XCTAssertEqual(try ProductUpdates.decode(html, source: claude, now: now).entries.first?.title, "New benefit")
    }
    func testSocialBoostIsNotAccountConfirmation() {
        let event = XClient.events([.init(id: "123", text: "We doubled the included allowance for selected plans today.", date: now)], handle: "example", now: now)[0]
        XCTAssertTrue(event.important); XCTAssertEqual(event.notice?.topic, "Usage & benefits")
        XCTAssertTrue(event.notice!.evidence.contains("Social post"))
        XCTAssertTrue(event.notice!.evidence.contains("not account-confirmed"))
    }
    func testPublicOfficialSourcesOptIn() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UNIFAI_TEST_PRODUCT_UPDATES"] == "1", "Opt in to public official page reads")
        for source in ProductSource.all {
            let data = try await FeedClient().fetch(source.url)
            let snapshot = try ProductUpdates.decode(data, source: source)
            print("Official source: \(source.id), \(snapshot.entries.count) extracted sections")
            if source.id == "openai-notes" {
                let boosts = snapshot.entries.filter { $0.title == "More Work and Codex usage on Pro and Business Premium Plans" }
                if !boosts.isEmpty {
                    XCTAssertEqual(boosts.count, 1)
                    XCTAssertTrue(boosts[0].text.contains("Pro 100"))
                    XCTAssertTrue(boosts[0].text.contains("Pro 200"))
                    print("Verified current Codex allowance announcement: scope retained; duplicate section collapsed")
                }
            }
            if source.format == .policy { XCTAssertEqual(snapshot.entries.count, 1) }
        }
    }
}

@MainActor final class ProductUpdateStoreTests: XCTestCase {
    func testSnapshotsFailurePreservationSpacingDisableAndReadMarker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unifai-updates-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var fail = false, reads = 0
        let now = ISO8601DateFormatter().date(from: "2026-11-02T12:00:00Z")!
        let store = AppStore(repository: StateRepository(directory: root), vault: MemoryVault(), feeds: { url in
            reads += 1
            if fail { throw URLError(.notConnectedToInternet) }
            if url.path.hasSuffix(".md") { return Data("### November 1, 2026\n- New usage credits are available to selected subscribers.\n".utf8) }
            return Data("<article><h1>November 1, 2026</h1><h2>Usage benefits</h2><p>Selected subscription plans now include additional usage credits and new benefits for eligible accounts.</p></article>".utf8)
        })
        _ = await store.refreshProductUpdates(now: now)
        XCTAssertEqual(reads, ProductSource.all.count)
        XCTAssertEqual(store.state.productSnapshots?.count, ProductSource.all.count)
        let original = store.state.productSnapshots
        _ = await store.refreshProductUpdates(now: now.addingTimeInterval(60))
        XCTAssertEqual(reads, ProductSource.all.count)
        fail = true
        _ = await store.refreshProductUpdates(force: true, now: now.addingTimeInterval(120))
        XCTAssertEqual(store.state.productSnapshots, original)
        XCTAssertEqual(store.state.productErrors?.count, ProductSource.all.count)
        try store.setProductUpdates(false)
        _ = await store.refreshProductUpdates(force: true, now: now.addingTimeInterval(240))
        XCTAssertEqual(reads, 2 * ProductSource.all.count)
        try store.markTimelineRead(now: now)
        XCTAssertEqual(try store.repository.load().timelineReadAt, now)
        XCTAssertEqual(try store.repository.load().productSnapshots, original)
        XCTAssertNotNil(AgentReport.timeline(store.state).first?.notice)
    }
}
