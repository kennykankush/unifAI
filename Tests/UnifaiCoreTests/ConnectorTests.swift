import XCTest
@testable import UnifaiCore

final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.notConnectedToInternet) }
            let (code, headers, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        config.urlCredentialStorage = nil; config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }
}

final class ConnectorTests: XCTestCase {
    private let source = URL(string: "https://example.invalid/fixture")!
    override func tearDown() { StubProtocol.handler = nil; super.tearDown() }
    func testOpenRouterSeparatesCreditAndConsumptionFromCash() throws {
        let data = Data(#"{"data":{"total_credits":100.50,"total_usage":30.25}}"#.utf8)
        let snapshot = try BalanceClient.decode(integrationID: "openrouter", data: data, source: source)
        XCTAssertEqual(snapshot.balances, [Money(Decimal(string: "70.25")!, "USD")])
        XCTAssertEqual(snapshot.reportedConsumption, [Money(Decimal(string: "30.25")!, "USD")])
        XCTAssertTrue(snapshot.coverage.contains("unknown"))
        XCTAssertEqual(Ledger.paidTotals([]), [])
    }
    func testOpenRouterZeroNegativeRemainingAndMalformedResponses() throws {
        let zero = try BalanceClient.decode(integrationID: "openrouter", data: Data(#"{"data":{"total_credits":0,"total_usage":0}}"#.utf8), source: source)
        XCTAssertEqual(zero.balances, [Money(0, "USD")])
        let overdrawn = try BalanceClient.decode(integrationID: "openrouter", data: Data(#"{"data":{"total_credits":0,"total_usage":1}}"#.utf8), source: source)
        XCTAssertEqual(overdrawn.balances, [Money(-1, "USD")])
        for json in ["{}", "not-json", #"{"data":{"total_credits":-1,"total_usage":0}}"#, #"{"data":{"total_credits":1}}"#, #"{"data":{"total_credits":"oops","total_usage":0}}"#] {
            XCTAssertThrowsError(try BalanceClient.decode(integrationID: "openrouter", data: Data(json.utf8), source: source))
        }
    }
    func testDeepSeekCurrenciesAndPromotionalBalance() throws {
        let json = #"{"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"},{"currency":"USD","total_balance":"0.00","granted_balance":"0.00","topped_up_balance":"0.00"}]}"#
        let snapshot = try BalanceClient.decode(integrationID: "deepseek", data: Data(json.utf8), source: source)
        XCTAssertEqual(snapshot.balances, [Money(110, "CNY"), Money(0, "USD")])
        XCTAssertEqual(snapshot.details.count, 4)
        XCTAssertTrue(snapshot.reportedConsumption.isEmpty)
        XCTAssertTrue(snapshot.coverage.contains("unavailable"))
    }
    func testDeepSeekRejectsPartialNumericStringsAndDuplicateCurrencies() {
        for amount in ["1garbage", "NaN", "1e6", "1,000", ""] {
            let json = "{\"is_available\":true,\"balance_infos\":[{\"currency\":\"CNY\",\"total_balance\":\"\(amount)\",\"granted_balance\":\"0\",\"topped_up_balance\":\"1\"}]}"
            XCTAssertThrowsError(try BalanceClient.decode(integrationID: "deepseek", data: Data(json.utf8), source: source))
        }
        let row = #"{"currency":"USD","total_balance":"1","granted_balance":"0","topped_up_balance":"1"}"#
        let duplicate = "{\"is_available\":true,\"balance_infos\":[\(row),\(row)]}"
        XCTAssertThrowsError(try BalanceClient.decode(integrationID: "deepseek", data: Data(duplicate.utf8), source: source))
        XCTAssertThrowsError(try BalanceClient.decode(integrationID: "deepseek", data: Data(#"{"is_available":true,"balance_infos":[]}"#.utf8), source: source))
    }
    func testBalanceRequestsUseOnlyExactReadEndpoints() async throws {
        let session = StubProtocol.session(); defer { session.invalidateAndCancel() }
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/credits")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
            XCTAssertNil(request.httpBody)
            return (200, [:], Data(#"{"data":{"total_credits":100,"total_usage":30}}"#.utf8))
        }
        let snapshot = try await BalanceClient(session: session).fetch(integrationID: "openrouter", credential: "fixture-key")
        XCTAssertEqual(snapshot.balances, [Money(70, "USD")])
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/user/balance")
            return (200, [:], Data(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"1","granted_balance":"0","topped_up_balance":"1"}]}"#.utf8))
        }
        _ = try await BalanceClient(session: session).fetch(integrationID: "deepseek", credential: "fixture-key")
    }
    func testKimiAndElevenLabsReadOneEndpointEach() async throws {
        let session = StubProtocol.session(); defer { session.invalidateAndCancel() }
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://api.moonshot.ai/v1/users/me/balance")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
            return (200, [:], Data(#"{"code":0,"data":{"available_balance":49.58894,"voucher_balance":46.58893,"cash_balance":3.00001},"scode":"0x0","status":true}"#.utf8))
        }
        let kimi = try await BalanceClient(session: session).fetch(integrationID: "kimi", credential: "fixture-key")
        XCTAssertEqual(kimi.balances, [Money(Decimal(string: "49.59")!, "USD")])
        XCTAssertEqual(kimi.details.map(\.label), ["Cash balance", "Voucher balance"])

        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.elevenlabs.io/v1/user/subscription")
            XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "fixture-key")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, [:], Data(#"{"tier":"creator","character_count":75000,"character_limit":100000,"next_character_count_reset_unix":1793500000,"status":"active"}"#.utf8))
        }
        let voice = try await BalanceClient(session: session).fetch(integrationID: "elevenlabs", credential: "fixture-key")
        XCTAssertEqual(voice.plan, "ElevenLabs Creator")
        XCTAssertEqual(voice.allowances?.first?.usedPercent, 75)
        XCTAssertEqual(voice.allowances?.first?.resetsAt, Date(timeIntervalSince1970: 1793500000))
        XCTAssertEqual(voice.limitReached, false)
        XCTAssertEqual(Catalogue.integration("elevenlabs")?.billing, .allowance)
        XCTAssertEqual(Catalogue.integration("kimi")?.status, .ready)
    }
    func testVercelAIGatewayReadsCredits() async throws {
        let session = StubProtocol.session(); defer { session.invalidateAndCancel() }
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://ai-gateway.vercel.sh/v1/credits")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
            return (200, [:], Data(#"{"balance":"8.75","total_used":"1.25"}"#.utf8))
        }
        let gateway = try await BalanceClient(session: session).fetch(integrationID: "vercel-ai-gateway", credential: "fixture-key")
        XCTAssertEqual(gateway.balances, [Money(Decimal(string: "8.75")!, "USD")])
        XCTAssertEqual(gateway.reportedConsumption, [Money(Decimal(string: "1.25")!, "USD")])
        XCTAssertEqual(gateway.details, [BalanceDetail("Credits added", Money(10, "USD"))])
        XCTAssertEqual(Catalogue.integration("vercel-ai-gateway")?.billing, .prepaid)
        XCTAssertEqual(Catalogue.integration("vercel-ai-gateway")?.status, .ready)

        for body in [#"{"balance":"-1","total_used":"0"}"#, #"{"balance":"NaN","total_used":"0"}"#, #"{"balance":8.75,"total_used":"0"}"#] {
            StubProtocol.handler = { _ in (200, [:], Data(body.utf8)) }
            do {
                _ = try await BalanceClient(session: session).fetch(integrationID: "vercel-ai-gateway", credential: "fixture-key")
                XCTFail("Accepted \(body)")
            } catch { XCTAssertEqual(error as? ConnectorError, .invalidResponse) }
        }
    }
    func testNeonPricesThisMonthsUsageAtPlanRates() async throws {
        let session = StubProtocol.session(); defer { session.invalidateAndCancel() }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12))!
        var paths: [String] = []
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
            let url = try XCTUnwrap(request.url)
            paths.append(url.path)
            if url.path == "/api/v2/users/me/organizations" {
                return (200, [:], Data(#"{"organizations":[{"id":"org-1","name":"Personal","plan":"launch"}]}"#.utf8))
            }
            XCTAssertEqual(url.path, "/api/v2/consumption_history/v2/projects")
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            XCTAssertEqual(query["org_id"], "org-1")
            XCTAssertEqual(query["from"], "2026-10-01T00:00:00Z")
            XCTAssertEqual(query["to"], "2026-10-03T00:00:00Z")
            XCTAssertEqual(query["granularity"], "daily")
            XCTAssertEqual(query["metrics"]?.split(separator: ",").count, 8)
            return (200, [:], Data(#"""
            {"projects":[{"project_id":"p1","periods":[{"period_plan":"launch","consumption":[
              {"timeframe_start":"2026-10-01T00:00:00Z","metrics":[{"metric_name":"compute_unit_seconds","value":36000},{"metric_name":"root_branch_bytes_month","value":1000000000},
               {"metric_name":"instant_restore_bytes_month","value":500000000},{"metric_name":"public_network_transfer_bytes","value":1000000000},{"metric_name":"extra_branches_month","value":240}]},
              {"timeframe_start":"2026-10-02T00:00:00Z","metrics":[{"metric_name":"compute_unit_seconds","value":18000},{"metric_name":"root_branch_bytes_month","value":1000000000}]}]}]}],
             "pagination":{"cursor":"p1"}}
            """#.utf8))
        }
        let neon = try await BalanceClient(session: session).fetch(integrationID: "neon", credential: "fixture-key", now: now)
        XCTAssertEqual(paths.count, 2)
        // Compute 15 CU-hours x 0.106, storage 2 GB-months x 0.35, restore 0.5 x 0.20,
        // 24 billable branch-hours after 9 included branches, transfer under the 500 GB allowance.
        XCTAssertEqual(neon.reportedConsumption, [Money(Decimal(string: "2.44")!, "USD")])
        XCTAssertEqual(neon.services?.map(\.name), ["Compute", "Storage", "Instant restore", "Extra branches"])
        XCTAssertEqual(neon.services?.first?.cost, Money(Decimal(string: "1.59")!, "USD"))
        XCTAssertEqual(neon.dailyCosts, [DailyCost(day: "2026-10-01", amount: Decimal(string: "1.56")!), DailyCost(day: "2026-10-02", amount: Decimal(string: "0.88")!)])
        XCTAssertEqual(neon.consumptionPeriod, "This month")
        XCTAssertEqual(neon.plan, "Neon Launch")
        XCTAssertEqual(Catalogue.integration("neon")?.billing, .payAsYouGo)
        XCTAssertEqual(Catalogue.integration("neon")?.status, .ready)

        StubProtocol.handler = { request in
            request.url?.path == "/api/v2/users/me/organizations"
                ? (200, [:], Data(#"{"organizations":[{"id":"org-1"}]}"#.utf8)) : (403, [:], Data("{}".utf8))
        }
        do {
            _ = try await BalanceClient(session: session).fetch(integrationID: "neon", credential: "fixture-key", now: now)
            XCTFail("Free plan accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Launch or higher")) }
    }
    func testHTTPFailuresAreTypedAndNeverIncludeBody() async throws {
        let session = StubProtocol.session(); defer { session.invalidateAndCancel() }
        for (status, expected) in [(401, ConnectorError.authorization), (403, .authorization), (429, .rateLimited), (500, .unavailable(500)), (302, .unavailable(302))] {
            StubProtocol.handler = { _ in (status, [:], Data("fixture-secret-response".utf8)) }
            do { _ = try await BalanceClient(session: session).fetch(integrationID: "openrouter", credential: "fixture-key"); XCTFail("Expected rejection") }
            catch { XCTAssertEqual(error as? ConnectorError, expected); XCTAssertFalse(error.localizedDescription.contains("fixture-secret")) }
        }
    }
    func testMissingCredentialAndUnsupportedProviderSendNoRequest() async {
        StubProtocol.handler = { _ in XCTFail("Must not send request"); return (500, [:], Data()) }
        for (integration, credential) in [("openrouter", ""), ("gemini-api", "fixture-key")] {
            do { _ = try await BalanceClient(session: StubProtocol.session()).fetch(integrationID: integration, credential: credential); XCTFail() } catch {}
        }
    }
    func testPrivateSessionDoesNotDiscoverAmbientCredentialsOrCookies() {
        let session = BalanceClient.privateSession(); defer { session.invalidateAndCancel() }
        XCTAssertNil(session.configuration.urlCredentialStorage)
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertNil(session.configuration.urlCache)
    }
    func testReleaseDecodingAndSafeLinks() throws {
        let releases = try GitHubClient.decode(Data(releaseJSON().utf8))
        XCTAssertEqual(releases.count, 1); XCTAssertEqual(releases[0].title, "v1")
        XCTAssertThrowsError(try GitHubClient.decode(Data(releaseJSON(url: "https://evil.invalid/v1").utf8)))
        XCTAssertThrowsError(try GitHubClient.decode(Data(releaseJSON(url: "http://github.com/a/b").utf8)))
        XCTAssertThrowsError(try GitHubClient.decode(Data(releaseJSON(url: "https://github.com:444/example/project/releases/tag/v1").utf8)))
        XCTAssertThrowsError(try GitHubClient.decode(Data(releaseJSON(url: "https://someone@github.com/example/project/releases/tag/v1").utf8)))
        XCTAssertEqual(try GitHubClient.decode(Data(releaseJSON(draft: true).utf8)), [])
    }
    func testGitHubUsesBoundedAnonymousConditionalGETAnd304KeepsCache() async throws {
        let session = StubProtocol.session(); defer { session.invalidateAndCancel() }
        var repo = WatchedRepository(slug: "example/project"); repo.etag = "fixture-etag"
        var requests = 0
        StubProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.url?.query, "per_page=50&page=1")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "fixture-etag")
            return (304, [:], Data())
        }
        let now = Date()
        let result = try await GitHubClient(session: session).fetch(repo, now: now)
        XCTAssertNil(result.releases); XCTAssertEqual(result.etag, "fixture-etag")
        XCTAssertEqual(result.retryAfter, now.addingTimeInterval(1800)); XCTAssertEqual(requests, 1)
    }
    func testGitHubBackoffUsesServerReset() async throws {
        let session = StubProtocol.session(); defer { session.invalidateAndCancel() }
        let now = Date(timeIntervalSince1970: 1_000_000)
        StubProtocol.handler = { _ in (429, ["X-RateLimit-Reset": "1007200", "Retry-After": "60"], Data()) }
        do { _ = try await GitHubClient(session: session).fetch(.init(slug: "example/project"), now: now); XCTFail() }
        catch { XCTAssertEqual(error as? ConnectorError, .retryAt(now.addingTimeInterval(7200))) }
        StubProtocol.handler = { _ in (429, ["Retry-After": "Mon, 12 Jan 1970 17:46:40 GMT"], Data()) }
        do { _ = try await GitHubClient(session: session).fetch(.init(slug: "example/project"), now: now); XCTFail() }
        catch { XCTAssertEqual(error as? ConnectorError, .retryAt(Date(timeIntervalSince1970: 1_014_400))) }
    }
    func testRepositoryValidation() {
        XCTAssertEqual(WatchedRepository.parseSlug("https://github.com/example/project.git/"), "example/project")
        for input in ["a/..", "a/.", "a/b/c", "https://evil.invalid/a/b", "a/b?x=1", "a/b#fragment", "a/b%2Fsecret", "/a/b", "a//b"] { XCTAssertNil(WatchedRepository.parseSlug(input), input) }
    }
    private func releaseJSON(url: String = "https://github.com/example/project/releases/tag/v1", draft: Bool = false) -> String {
        "[{\"id\":1,\"name\":null,\"tag_name\":\"v1\",\"html_url\":\"\(url)\",\"published_at\":\"2026-10-17T00:00:00Z\",\"prerelease\":false,\"draft\":\(draft)}]"
    }
}
