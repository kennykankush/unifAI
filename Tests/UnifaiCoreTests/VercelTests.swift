import XCTest
@testable import UnifaiCore

final class VercelTests: XCTestCase {
    override func tearDown() { StubProtocol.handler = nil; super.tearDown() }
    let now = Date(timeIntervalSince1970: 1793534400)
    let team = #"{"id":"team_fixture","slug":"fixture","name":"Fixture team","billing":{"plan":"pro"}}"#
    // Same multi-metric shape as Vercel's billing-costs-mock.ts. Deliberately reorder
    // metric indexes so decoding cannot confuse CPU quantity with gross dollars.
    static let costs = #"""
    {"metrics":[{"slug":"gross_cost","unit":{"kind":"custom","singular":"dollar","plural":"dollars"}},{"slug":"cpu","unit":{"kind":"custom","singular":"hour","plural":"hours"}}],"availableCurrencies":["USD"],"results":{"dimensionsMeta":{"product":{"values":{"cpu":{"title":"Active CPU"}}}},"views":{"byProduct":{"groupBy":["product"],"results":[{"dimensionValues":{"product":"cpu"},"metrics":["cpu","gross_cost"],"totalValue":[4,0.8]}]},"byProductRegionProject":{"groupBy":["product","region","project"],"results":[{"dimensionValues":{"product":"cpu","project":"prj_one","region":"iad1"},"metrics":["cpu","gross_cost"],"totalValue":[3,0.6]},{"dimensionValues":{"product":"cpu","project":null},"metrics":["cpu","gross_cost"],"totalValue":[1,0.2]}]}}}}
    """#

    func testReadScopePaginationMetersAndNoInventedPayments() async throws {
        let session = StubProtocol.session(); defer { session.invalidateAndCancel() }
        var paths: [String] = []
        StubProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.host, "api.vercel.com")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "teamId" }?.value, "team_fixture")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            paths.append(url.path)
            if url.path == "/v2/teams/team_fixture" { return (200, [:], Data(self.team.utf8)) }
            if url.path == "/v9/projects" {
                XCTAssertEqual(request.httpMethod, "GET")
                if query.contains(where: { $0.name == "until" && $0.value == "123" }) {
                    return (200, [:], Data(#"{"projects":[{"id":"prj_two","name":"unused"}],"pagination":{"next":null}}"#.utf8))
                }
                return (200, [:], Data(#"{"projects":[{"id":"prj_one","name":"app","framework":"nextjs","latestDeployments":[{"readyState":"READY"}]}],"pagination":{"next":123}}"#.utf8))
            }
            XCTAssertEqual(url.path, "/v2/billing/costs")
            XCTAssertEqual(request.httpMethod, "POST")
            // URLSession may move the body into an input stream.
            let body: Data
            if let data = request.httpBody { body = data }
            else {
                let stream = try XCTUnwrap(request.httpBodyStream); stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096), data = Data()
                while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) }
                body = data
            }
            let raw = String(decoding: body, as: UTF8.self)
            XCTAssertLessThan(try XCTUnwrap(raw.range(of: "byProductRegionProject")?.lowerBound), try XCTUnwrap(raw.range(of: "\"byProduct\"")?.lowerBound))
            return (200, [:], Data(Self.costs.utf8))
        }
        let key = try VercelClient.Credential.encode(teamID: "team_fixture", token: "fixture-token")
        let snapshot = try await VercelClient(session: session).fetch(credential: key, now: now)
        XCTAssertEqual(paths.count, 4)
        XCTAssertEqual(snapshot.plan, "Vercel Pro")
        XCTAssertEqual(snapshot.providerScope, "team_fixture")
        XCTAssertEqual(snapshot.vercelUsage?.grossCost, Money(Decimal(string: "0.8")!, "USD"))
        XCTAssertEqual(snapshot.vercelUsage?.meters.first?.quantity, 4)
        XCTAssertEqual(snapshot.vercelUsage?.meters.first?.unit, "hours")
        XCTAssertEqual(snapshot.resources?.count, 3, "Unattributed charges stay visible")
        XCTAssertNil(snapshot.resources?.first(where: { $0.id == "prj_two" })?.cost, "Missing billing rows are not zero")
        XCTAssertEqual(snapshot.resources?.first(where: { $0.id == "prj_one" })?.portalURL?.absoluteString, "https://vercel.com/fixture/app")
        XCTAssertTrue(snapshot.reportedConsumption.isEmpty, "Gross cost must not enter accruing-cost accounting")
        XCTAssertTrue(snapshot.balances.isEmpty, "Usage credit is not a withdrawable balance")
        XCTAssertEqual(try JSONDecoder().decode(BalanceSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }

    func testBillingDenialStillShowsProjectsWithoutFalseZero() async throws {
        let session = StubProtocol.session(); defer { session.invalidateAndCancel() }
        StubProtocol.handler = { request in
            switch request.url!.path {
            case "/v2/teams/team_fixture": return (200, [:], Data(self.team.utf8))
            case "/v9/projects": return (200, [:], Data(#"{"projects":[],"pagination":{"next":null}}"#.utf8))
            default: return (403, [:], Data(#"{"error":{"message":"fixture secret must never appear"}}"#.utf8))
            }
        }
        let snapshot = try await VercelClient(session: session).fetch(credential: VercelClient.Credential.encode(teamID: "team_fixture", token: "fixture-token"), now: now)
        XCTAssertEqual(snapshot.plan, "Vercel Pro")
        XCTAssertNil(snapshot.vercelUsage?.grossCost)
        XCTAssertTrue(snapshot.vercelUsage!.note.contains("Usage unavailable"))
        XCTAssertFalse(snapshot.vercelUsage!.note.contains("fixture secret"))
    }

    func testRepeatedPaginationRejectsIncompleteInventory() async throws {
        let session = StubProtocol.session(); defer { session.invalidateAndCancel() }
        StubProtocol.handler = { request in
            if request.url!.path.hasPrefix("/v2/teams") { return (200, [:], Data(self.team.utf8)) }
            return (200, [:], Data(#"{"projects":[],"pagination":{"next":123}}"#.utf8))
        }
        do {
            _ = try await VercelClient(session: session).fetch(credential: VercelClient.Credential.encode(teamID: "team_fixture", token: "fixture-token"), now: now)
            XCTFail("Incomplete inventory should fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("pagination")) }
    }

    func testMIUsUnknownCurrencyAndMalformedMetricsNeverBecomeDollars() throws {
        let miu = Self.costs.replacingOccurrences(of: "dollar", with: "MIU").replacingOccurrences(of: "[\"USD\"]", with: "[\"managed_infrastructure_units\"]")
        let report = try VercelClient.decodeCosts(JSONDecoder().decode(VercelClient.Costs.self, from: Data(miu.utf8)), from: now, to: now)
        XCTAssertNil(report.usage.grossCost)
        XCTAssertEqual(report.usage.meters.first?.quantity, 4)
        let mixed = Self.costs.replacingOccurrences(of: "[\"USD\"]", with: "[\"USD\",\"EUR\"]")
        XCTAssertNil(try VercelClient.decodeCosts(JSONDecoder().decode(VercelClient.Costs.self, from: Data(mixed.utf8)), from: now, to: now).usage.grossCost)
        for invalid in [Self.costs.replacingOccurrences(of: "[4,0.8]", with: "[4]"), Self.costs.replacingOccurrences(of: "[4,0.8]", with: "[-4,0.8]")] {
            XCTAssertThrowsError(try VercelClient.decodeCosts(JSONDecoder().decode(VercelClient.Costs.self, from: Data(invalid.utf8)), from: now, to: now))
        }
    }

    func testPlanObservationIsNotHistoricalUpgradeAndScopeSwitchIsNotUpgrade() {
        let account = ConnectedAccount(integrationID: "vercel", label: "Test", billingScope: "team_fixture", mode: .live)
        var first = BalanceSnapshot(balances: [], observedAt: now, source: URL(string: "https://vercel.com")!, coverage: "fixture", plan: "Vercel Hobby")
        first.providerScope = "team_fixture"
        let initial = PlanWatch.events(old: nil, new: first, account: account, now: now)
        XCTAssertEqual(initial.count, 1)
        XCTAssertTrue(initial[0].detail.contains("not the subscription start"))
        var pro = first; pro.plan = "Vercel Pro"; pro.observedAt = now.addingTimeInterval(3600)
        XCTAssertEqual(PlanWatch.events(old: first, new: pro, account: account, now: pro.observedAt).count, 1)
        XCTAssertTrue(PlanWatch.events(old: first, new: pro, account: account, now: pro.observedAt)[0].detail.contains("exact change time"))
        XCTAssertTrue(PlanWatch.events(old: pro, new: pro, account: account, now: pro.observedAt).isEmpty)
        pro.providerScope = "team_other"
        XCTAssertTrue(PlanWatch.events(old: first, new: pro, account: account, now: pro.observedAt).isEmpty)
    }

    func testCredentialValidationAndCatalogueHonesty() throws {
        XCTAssertThrowsError(try VercelClient.Credential.encode(teamID: "team_a/../../other", token: "secret"))
        XCTAssertThrowsError(try VercelClient.Credential.encode(teamID: "team_fixture", token: "bad\ntoken"))
        XCTAssertEqual(Set(Catalogue.integrations.map(\.id)).count, Catalogue.integrations.count)
        XCTAssertEqual(Catalogue.integration("vercel")?.status, .ready)
    }

    @MainActor
    func testRefreshPersistsPlanEventsAndFailurePreservesLastReading() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("unifai-vercel-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = StateRepository(directory: directory)
        var plan = "Vercel Hobby", fail = false
        let store = AppStore(repository: repo, vault: MemoryVault(), balances: { _, _, date in
            if fail { throw ConnectorError.authorization }
            var result = BalanceSnapshot(balances: [], observedAt: date, source: URL(string: "https://vercel.com")!, coverage: "fixture", plan: plan)
            result.providerScope = "team_fixture"
            return result
        })
        try store.addAccount(integrationID: "vercel", label: "Fixture", billingScope: "team_fixture", mode: .live,
                             credential: VercelClient.Credential.encode(teamID: "team_fixture", token: "fixture-token"))
        let id = store.state.accounts[0].id
        await store.refreshAccount(id, now: now)
        plan = "Vercel Pro"
        await store.refreshAccount(id, now: now.addingTimeInterval(120))
        await store.refreshAccount(id, now: now.addingTimeInterval(240))
        XCTAssertEqual(store.state.events?.filter { $0.id.hasPrefix("plan-") }.count, 2)
        fail = true
        await store.refreshAccount(id, now: now.addingTimeInterval(360))
        XCTAssertEqual(store.state.accounts[0].snapshot?.plan, "Vercel Pro")
        XCTAssertNotNil(store.state.accounts[0].lastError)
        XCTAssertTrue(store.state.payments.isEmpty)
        XCTAssertEqual(try repo.load(), store.state)
        XCTAssertFalse(try String(contentsOf: repo.file, encoding: .utf8).contains("fixture-token"))
    }
}
