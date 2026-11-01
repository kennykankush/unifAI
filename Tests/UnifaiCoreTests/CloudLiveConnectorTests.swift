import XCTest
@testable import UnifaiCore

final class CloudLiveConnectorTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1793534400)
    let cfScope = String(repeating: "a", count: 32)
    override func tearDown() { StubProtocol.handler = nil; super.tearDown() }
    func key(_ integration: String, _ scope: String = "fixture") throws -> String {
        try ScopedToken.encode(scope: scope, token: "fixture-token", integration: integration)
    }
    func testGitHubPersonalAndOrganizationScopesQuantitiesAndNetCosts() async throws {
        let session = StubProtocol.session(); defer { session.invalidateAndCancel() }
        var paths: [String] = []
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.host, "api.github.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "month" }?.value, "11")
            XCTAssertEqual(query.first { $0.name == "year" }?.value, "2026")
            paths.append(request.url!.path)
            return (200, [:], Data(#"{"usageItems":[{"date":"2026-11-01","product":"Actions","sku":"Linux","quantity":100,"unitType":"minutes","grossAmount":4,"netAmount":0.8,"repositoryName":"fixture/app"},{"date":"2026-11-01","product":"Actions","sku":"Linux","quantity":50,"unitType":"minutes","netAmount":0.4}]}"#.utf8))
        }
        for (id, org) in [("github-billing", false), ("github-org-billing", true)] {
            let snapshot = try await BalanceClient(session: session).fetch(integrationID: id, credential: key(id), now: now)
            XCTAssertEqual(paths.last, "/\(org ? "organizations" : "users")/fixture/settings/billing/usage")
            XCTAssertEqual(snapshot.providerUsage?.costs, [Money(1.2, "USD")])
            XCTAssertEqual(snapshot.providerUsage?.meters.first?.quantity, 150)
            XCTAssertEqual(snapshot.resources?.count, 2)
            XCTAssertTrue(snapshot.resources!.contains { $0.name == "Unattributed" })
            XCTAssertTrue(snapshot.reportedConsumption.isEmpty)
            XCTAssertTrue(snapshot.balances.isEmpty)
            XCTAssertEqual(snapshot.services?.count, 1)
            XCTAssertEqual(try JSONDecoder().decode(BalanceSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
        }
    }
    func testGitHubRejectsIncompleteAndWrongMonthReports() async throws {
        let session = StubProtocol.session(); defer { session.invalidateAndCancel() }
        for (headers, json) in [(["Link":"<https://other.invalid>; rel=\"next\""], #"{"usageItems":[]}"#),
                                ([:], #"{"usageItems":[{"date":"2026-10-31","product":"Actions","sku":"Linux","quantity":1,"unitType":"minutes","netAmount":1}]}"#),
                                ([:], #"{"usageItems":[{"date":"2026-11-01","product":"Actions","sku":"Linux","quantity":1,"unitType":"minutes"}]}"#)] {
            StubProtocol.handler = { _ in (200, headers, Data(json.utf8)) }
            do { _ = try await GitHubBillingClient(session: session).fetch(credential: key("github-billing"), now: now); XCTFail("Must reject incomplete data") }
            catch { }
        }
    }
    func testCloudflareUsesBillingCycleAndDoesNotSumCumulativeAmounts() async throws {
        let session = StubProtocol.session(); defer { session.invalidateAndCancel() }
        let rows: [[String: Any]] = [
            ["BillingCurrency":"USD", "BillingPeriodStart":"2026-10-18T00:00:00.000Z", "ChargePeriodStart":"2026-10-18T00:00:00Z", "ChargePeriodEnd":"2026-10-19T00:00:00Z", "ServiceName":"Workers", "ContractedCost":1, "CumulatedContractedCost":20, "ConsumedQuantity":100, "ConsumedUnit":"requests", "ZoneId":"zone", "ZoneName":"fixture.invalid"],
            ["BillingCurrency":"USD", "BillingPeriodStart":"2026-10-18T00:00:00Z", "ChargePeriodStart":"2026-10-19T00:00:00Z", "ChargePeriodEnd":"2026-10-20T00:00:00Z", "ServiceName":"Workers", "ContractedCost":2, "CumulatedContractedCost":22, "ConsumedQuantity":200, "ConsumedUnit":"requests", "ZoneId":"zone"],
            ["BillingCurrency":"EUR", "BillingPeriodStart":"2026-10-18T00:00:00Z", "ChargePeriodStart":"2026-10-19T00:00:00Z", "ChargePeriodEnd":"2026-10-20T00:00:00Z", "ServiceName":"R2", "ContractedCost":4, "ConsumedQuantity":2, "ConsumedUnit":"GB-months"]]
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://api.cloudflare.com/client/v4/accounts/\(self.cfScope)/billable-usage")
            return (200, [:], try JSONSerialization.data(withJSONObject: ["success":true,"result":rows]))
        }
        let snapshot = try await BalanceClient(session: session).fetch(integrationID: "cloudflare", credential: key("cloudflare", cfScope), now: now)
        XCTAssertEqual(snapshot.providerUsage?.costs, [Money(4,"EUR"), Money(3,"USD")])
        XCTAssertTrue(snapshot.providerUsage!.period.contains("2026-10-18"))
        XCTAssertEqual(snapshot.providerUsage?.meters.first?.quantity, 300)
        XCTAssertTrue(snapshot.reportedConsumption.isEmpty)
        XCTAssertEqual(snapshot.resources?.count, 2)
        XCTAssertTrue(snapshot.resources!.allSatisfy { $0.portalURL?.host == "dash.cloudflare.com" })
    }
    func testCloudflareFalseSuccessAndMismatchedScopeAreRejected() async throws {
        let session = StubProtocol.session(); defer { session.invalidateAndCancel() }
        for json in [#"{"success":false,"result":[]}"#,
                     #"{"success":true,"result":[{"BillingCurrency":"USD","BillingPeriodStart":"2026-11-01T00:00:00Z","ChargePeriodStart":"2026-11-01T00:00:00Z","ChargePeriodEnd":"2026-11-02T00:00:00Z","ServiceName":"Workers","ContractedCost":1,"ConsumedQuantity":1,"ConsumedUnit":"requests","BillingAccountId":"other"}]}"#] {
            StubProtocol.handler = { _ in (200, [:], Data(json.utf8)) }
            do { _ = try await CloudflareUsageClient(session: session).fetch(credential: key("cloudflare", cfScope), now: now); XCTFail("Must reject") }
            catch { }
        }
    }
    func testDigitalOceanKeepsSignedDebtOutOfCashAndUsesGenerationDate() async throws {
        let session = StubProtocol.session(); defer { session.invalidateAndCancel() }
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.digitalocean.com/v2/customers/my/balance")
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, [:], Data(#"{"month_to_date_usage":"11.21","account_balance":"-12.23","month_to_date_balance":"-1.02","generated_at":"2026-10-31T12:00:00.000Z"}"#.utf8))
        }
        let snapshot = try await BalanceClient(session: session).fetch(integrationID: "digitalocean", credential: "fixture-token", now: now)
        XCTAssertEqual(snapshot.providerUsage?.costs, [Money(11.21,"USD")])
        XCTAssertEqual(snapshot.providerUsage?.details.first?.value, Money(-12.23,"USD"))
        XCTAssertTrue(snapshot.isStale(at: now))
        XCTAssertTrue(snapshot.balances.isEmpty)
        XCTAssertTrue(snapshot.reportedConsumption.isEmpty)
        XCTAssertThrowsError(try CloudReadAPI.decimal("12bad"))
        XCTAssertThrowsError(try CloudReadAPI.decimal("NaN"))
    }
    func testSupabaseFiltersOrganizationAndReadsOnlySelectedAddons() async throws {
        let session = StubProtocol.session(); defer { session.invalidateAndCancel() }
        var paths: [String] = []
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertEqual(request.url?.host,"api.supabase.com")
            paths.append(request.url!.path)
            if request.url!.path == "/v1/projects" {
                return (200, [:], Data(#"[{"id":"abcdefghijklmnopqrst","organization_id":"old","organization_slug":"fixture","name":"Database","region":"ap-southeast-1","status":"ACTIVE_HEALTHY"},{"id":"tsrqponmlkjihgfedcba","organization_id":"other","name":"Other organization","region":"us-east-1","status":"INACTIVE"}]"#.utf8))
            }
            XCTAssertEqual(request.url!.path, "/v1/projects/abcdefghijklmnopqrst/billing/addons")
            return (200, [:], Data(#"{"selected_addons":[{"type":"compute_instance","variant":{"name":"Small","price":{"amount":10}}}],"available_addons":[{"name":"Huge","price":{"amount":1000}}]}"#.utf8))
        }
        let snapshot = try await BalanceClient(session: session).fetch(integrationID: "supabase", credential: key("supabase"), now: now)
        XCTAssertEqual(paths.count, 2)
        XCTAssertEqual(snapshot.resources?.count, 1)
        XCTAssertEqual(snapshot.resources?.first?.size, "Small")
        XCTAssertEqual(snapshot.resources?.first?.portalURL?.host, "supabase.com")
        XCTAssertNil(snapshot.resources?.first?.cost)
        XCTAssertTrue(snapshot.providerUsage!.costs.isEmpty)
        XCTAssertNil(snapshot.plan)
    }
    func testSupabaseDeniedAddonsStillReportsInventoryAndMissingCoverage() async throws {
        let session = StubProtocol.session(); defer { session.invalidateAndCancel() }
        StubProtocol.handler = { request in
            if request.url!.path == "/v1/projects" {
                return (200, [:], Data(#"[{"id":"abcdefghijklmnopqrst","organization_id":"fixture","name":"Database","region":"us-east-1","status":"INACTIVE"}]"#.utf8))
            }
            return (403, [:], Data())
        }
        let snapshot = try await SupabaseInventoryClient(session: session).fetch(credential: key("supabase"), now: now)
        XCTAssertEqual(snapshot.resources?.count, 1)
        XCTAssertNil(snapshot.resources?.first?.size)
        XCTAssertTrue(snapshot.coverage.contains("1 project add-on reads were unavailable"))
    }
    func testAuthenticationFailuresDoNotReturnZeroOrLeakServerBody() async throws {
        let session = StubProtocol.session(); defer { session.invalidateAndCancel() }
        StubProtocol.handler = { _ in (403, [:], Data("private server message".utf8)) }
        for id in ["github-billing", "github-org-billing", "cloudflare", "digitalocean", "supabase"] {
            let credential = id == "digitalocean" ? "fixture-token" : try key(id, id == "cloudflare" ? cfScope : "fixture")
            do { _ = try await BalanceClient(session: session).fetch(integrationID: id, credential: credential, now: now); XCTFail("Should fail") }
            catch { XCTAssertFalse(error.localizedDescription.contains("private server message")) }
        }
    }
    func testOnlyImplementedNewConnectorsAreReady() throws {
        XCTAssertEqual(Set(Catalogue.integrations.map(\.id)).count, Catalogue.integrations.count)
        for id in ["github-billing", "github-org-billing", "cloudflare", "digitalocean", "supabase", "vercel"] {
            XCTAssertEqual(Catalogue.integration(id)?.status, .ready)
        }
        for removed in ["oracle-cloud", "runpod", "resend", "local-hardware", "support-contracts"] { XCTAssertNil(Catalogue.integration(removed)) }
        XCTAssertThrowsError(try key("github-billing", "../other"))
        XCTAssertThrowsError(try key("cloudflare", "not-an-account-id"))
        XCTAssertThrowsError(try ScopedToken.encode(scope: "fixture", token: "bad\ntoken", integration: "supabase"))
    }
}
