import XCTest
@testable import UnifaiCore

final class MCPActivityTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1793613600)
    func claude(_ id: String = "tool_1", error: Bool = false) -> Data {
        Data("""
        {"timestamp":"2026-11-02T01:00:00Z","sessionId":"private-session","message":{"content":[{"type":"text","text":"PRIVATE PROMPT"},{"type":"tool_use","id":"\(id)","name":"mcp__refero__refero_search_screens","input":{"query":"PRIVATE ARGUMENT"}}]}}
        {"timestamp":"2026-11-02T01:00:01Z","message":{"content":[{"type":"tool_result","tool_use_id":"\(id)","is_error":\(error),"content":"PRIVATE OUTPUT"}]}}
        """.utf8)
    }
    func testClaudeMetadataOnlyAndExplicitError() throws {
        let report = MCPHistory.parse(claude(error: true), client: "Claude Code", fallbackSession: "private-path", since: .distantPast, now: now)
        XCTAssertEqual(report.calls.count, 1)
        XCTAssertEqual(report.calls[0].server, "refero")
        XCTAssertEqual(report.calls[0].outcome, .failed)
        let persisted = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        for secret in ["PRIVATE PROMPT", "PRIVATE ARGUMENT", "PRIVATE OUTPUT", "private-session", "private-path", "tool_1"] { XCTAssertFalse(persisted.contains(secret)) }
    }
    func testCodexDirectCallsAndWrappersRemainDistinct() {
        let text = """
        {"timestamp":"2026-11-02T01:00:00Z","type":"response_item","payload":{"type":"function_call","call_id":"a","name":"mcp__refero__search","arguments":"PRIVATE"}}
        {"timestamp":"2026-11-02T01:00:01Z","type":"response_item","payload":{"type":"function_call_output","call_id":"a","output":"isError: true is only text"}}
        {"timestamp":"2026-11-02T01:00:02Z","type":"response_item","payload":{"type":"custom_tool_call","call_id":"b","name":"functions.exec","input":"await tools.mcp__refero__search()"}}
        """
        let report = MCPHistory.parse(Data(text.utf8), client: "Codex", fallbackSession: "x", since: .distantPast, now: now)
        XCTAssertEqual(report.calls.count, 1)
        XCTAssertEqual(report.calls[0].outcome, .returned)
        XCTAssertEqual(report.wrapperCalls, 1)
    }
    func testMalformedNamesOldEventsAndMissingResult() {
        var text = String(decoding: claude(), as: UTF8.self).components(separatedBy: "\n").first!
        text += "\nnot-json\n" + text.replacingOccurrences(of: "mcp__refero__refero_search_screens", with: "mcp__https://secret.invalid__tool")
        let report = MCPHistory.parse(Data(text.utf8), client: "Claude Code", fallbackSession: "x", since: .distantPast, now: now)
        XCTAssertEqual(report.calls.count, 1); XCTAssertEqual(report.calls[0].outcome, .unknown)
        XCTAssertEqual(report.skippedLines, 1)
        XCTAssertTrue(MCPHistory.parse(claude(), client: "Claude Code", fallbackSession: "x", since: now, now: now).calls.isEmpty)
    }
    func testScanDeduplicatesForkedTranscriptsAndSkipsSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try claude().write(to: root.appendingPathComponent("one.jsonl"))
        try claude().write(to: root.appendingPathComponent("copy.jsonl"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.jsonl"), withDestinationURL: root.appendingPathComponent("one.jsonl"))
        let scan = MCPHistory.scan(sources: [.init(client: "Claude Code", root: root)], now: now)
        XCTAssertEqual(scan.calls.count, 1)
        XCTAssertEqual(scan.filesRead, 2)
    }
    func testOptionalActualHistoryScan() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UNIFAI_TEST_MCP_HISTORY"] == "1", "Opt in to metadata-only local history scan")
        let scan = MCPHistory.scan()
        print("MCP metadata scan: \(scan.filesRead) files, \(scan.calls.count) calls, \(scan.skippedFiles) skipped files")
        print("Observed services: \(Set(scan.calls.map(\.server)).sorted().joined(separator: ", "))")
        XCTAssertFalse(scan.calls.isEmpty)
        let encoded = try JSONEncoder().encode(scan)
        XCTAssertEqual(try JSONDecoder().decode(MCPScan.self, from: encoded), scan)
    }
}

@MainActor final class MCPSubscriptionTests: XCTestCase {
    func store() -> AppStore {
        AppStore(repository: StateRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent("mcp-test-\(UUID())")), vault: MemoryVault())
    }
    func testLifetimeCreatesOnePaymentNoRenewalAndRejectsDuplicate() throws {
        let app = store(); defer { try? FileManager.default.removeItem(at: app.repository.directory) }
        let date = Date.now.addingTimeInterval(-86400)
        try app.recordMCPSubscription(server: "Refero", name: "Refero", plan: .lifetime, startedAt: date, amount: Money(99, "USD"))
        XCTAssertEqual(app.state.accounts.count, 1); XCTAssertEqual(app.state.payments.count, 1)
        XCTAssertEqual(app.state.mcpPurchases?.first?.startedAt, date)
        XCTAssertTrue(app.state.subscriptions.isEmpty)
        XCTAssertEqual(app.state.mcpServices().first?.calls, 0)
        XCTAssertThrowsError(try app.recordMCPSubscription(server: "refero", name: "Refero", plan: .lifetime, startedAt: date, amount: Money(99, "USD")))
        XCTAssertEqual(try app.repository.load(), app.state)
    }
    func testExistingPaymentIsLinkedWithoutDuplicateOrConfirmationChange() throws {
        let app = store(); defer { try? FileManager.default.removeItem(at: app.repository.directory) }
        try app.addAccount(integrationID: "custom", label: "Refero", billingScope: "", mode: .manual)
        var payment = PaymentRecord(accountID: app.state.accounts[0].id, description: "Refero", kind: .subscription, money: Money(20, "USD"), paidAt: .now.addingTimeInterval(-100))
        payment.estimated = true
        try app.savePayment(payment)
        try app.recordMCPSubscription(server: "refero", name: "Refero", plan: .monthly, startedAt: payment.paidAt, amount: payment.money, existingPaymentID: payment.id)
        XCTAssertEqual(app.state.payments, [payment]); XCTAssertEqual(app.state.accounts.count, 1)
        try app.removePayment(payment.id)
        XCTAssertTrue(app.state.mcpPurchases!.isEmpty)
    }
    func testRenewalIsExpectedAndFailedTransactionWritesNothing() throws {
        let app = store(); defer { try? FileManager.default.removeItem(at: app.repository.directory) }
        let date = Date.now
        XCTAssertThrowsError(try app.recordMCPSubscription(server: "refero", name: "Refero", plan: .lifetime, startedAt: date, amount: Money(20, "USD"), nextRenewal: date.addingTimeInterval(86400)))
        XCTAssertTrue(app.state.accounts.isEmpty)
        try app.recordMCPSubscription(server: "refero", name: "Refero", plan: .monthly, startedAt: date, amount: Money(20, "USD"), nextRenewal: date.addingTimeInterval(86400))
        XCTAssertEqual(app.state.subscriptions.count, 1)
        XCTAssertFalse(app.state.subscriptions[0].recordsAutomatically)
        XCTAssertEqual(app.state.payments.count, 1)
        let before = app.state
        XCTAssertThrowsError(try app.recordMCPSubscription(server: "other", name: "Other", plan: .monthly, startedAt: date, amount: Money(20, "USD"), existingPaymentID: UUID()))
        XCTAssertEqual(before, app.state)
    }
    func testTrackingDefaultsOffAndReportsExposeNoRawCalls() async throws {
        let app = store(); defer { try? FileManager.default.removeItem(at: app.repository.directory) }
        try await app.refreshMCPActivity(sources: [])
        XCTAssertNil(app.state.mcpScan)
        try app.setMCPTracking(true)
        try await app.refreshMCPActivity(sources: [])
        XCTAssertNotNil(app.state.mcpScan)
        let report = try AgentTools.call("get_mcp_activity", arguments: [:], state: app.state, rates: nil)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: report) as? [String: Any])
    }
}
