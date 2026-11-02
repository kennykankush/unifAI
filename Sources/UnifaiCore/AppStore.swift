import Foundation
import Combine

@MainActor
public final class AppStore: ObservableObject {
    public typealias BalanceLoader = (String, String, Date) async throws -> BalanceSnapshot
    public typealias ReleaseLoader = (WatchedRepository, Date) async throws -> GitHubFetchResult
    @Published public private(set) var state = PersistentState()
    @Published public private(set) var refreshingAccounts: Set<UUID> = []
    @Published public private(set) var refreshingRepositories: Set<UUID> = []
    @Published public private(set) var loadFailure: String?
    @Published public var notice: String?
    @Published public private(set) var rates: RateTable?
    @Published public private(set) var refreshingRates = false
    public typealias RateLoader = ([String], Date, Date) async throws -> RateTable
    public typealias StatusLoader = (StatusFeed) async throws -> Data
    public typealias PostLoader = (_ token: String, _ handle: String, _ userID: String?, _ sinceID: String?) async throws -> XClient.Result
    private let rateLoader: RateLoader
    public typealias FeedLoader = (URL) async throws -> Data
    let statusLoader: StatusLoader
    let postLoader: PostLoader
    let feedLoader: FeedLoader
    @Published public internal(set) var refreshingTimeline = false
    @Published public internal(set) var hasXToken = false
    @Published public internal(set) var timelineErrors: [String: String] = [:]
    public let repository: StateRepository
    let vault: CredentialVault
    private let balances: BalanceLoader
    private let releases: ReleaseLoader

    public init(repository: StateRepository, vault: CredentialVault = KeychainVault(),
                balances: @escaping BalanceLoader = { try await BalanceClient().fetch(integrationID: $0, credential: $1, now: $2) },
                releases: @escaping ReleaseLoader = { try await GitHubClient().fetch($0, now: $1) },
                rates rateLoader: @escaping RateLoader = { try await ExchangeRates.fetch(currencies: $0, since: $1, now: $2) },
                status: @escaping StatusLoader = { try await StatusFeedClient().fetch($0) },
                posts: @escaping PostLoader = { try await XClient().fetch(token: $0, handle: $1, userID: $2, sinceID: $3) },
                feeds: @escaping FeedLoader = { try await FeedClient().fetch($0) }) {
        self.repository = repository; self.vault = vault; self.balances = balances; self.releases = releases; self.rateLoader = rateLoader
        self.statusLoader = status; self.postLoader = posts; self.feedLoader = feeds
        self.hasXToken = ((try? vault.read(accountID: Self.xTokenID)) ?? nil) != nil
        self.rates = RateStore(directory: repository.directory).load()
        do { state = try repository.load() }
        catch { loadFailure = "Could not load saved data: \(error.localizedDescription) Review Local Backups to recover a saved copy. The original file has been preserved; saving is disabled." }
    }
    func change(_ update: (inout PersistentState) throws -> Void) throws {
        guard loadFailure == nil else { throw ValidationError.message("Saving is disabled because the saved data could not be loaded.") }
        var next = state
        try update(&next)
        guard next != state else { return }
        try repository.save(next)
        state = next
    }
    private func validateCredential(_ credential: String) throws -> String {
        let value = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4096, value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw ValidationError.message("Enter a credential without line breaks.")
        }
        return value
    }
    public func addAccount(integrationID: String, label: String, billingScope: String, mode: ConnectionMode, credential: String = "") throws {
        guard loadFailure == nil else { throw ValidationError.message("Repair the saved data before adding an account.") }
        guard let integration = Catalogue.integration(integrationID), integration.category != .discovery, integration.category != .development else {
            throw ValidationError.message("Choose a financial service from the catalogue.")
        }
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = billingScope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ValidationError.message("Give this account a label.") }
        guard !state.accounts.contains(where: { $0.integrationID == integrationID && $0.label.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw ValidationError.message("An account with this label already exists for this service.")
        }
        if mode == .live {
            guard integration.status == .ready else { throw ValidationError.message("This connector is planned. Use manual records instead.") }
            guard !owner.isEmpty else { throw ValidationError.message("Name the billing owner so keys for the same account are not counted twice.") }
            guard !state.accounts.contains(where: { $0.mode == .live && $0.integrationID == integrationID && $0.billingScope.caseInsensitiveCompare(owner) == .orderedSame }) else {
                throw ValidationError.message("That billing owner is already connected. Replace its key instead of adding the balance again.")
            }
        }
        if mode == .live && !integration.needsCredential && state.accounts.contains(where: { $0.mode == .live && $0.integrationID == integrationID }) {
            throw ValidationError.message("This connection reads the single account signed in on this Mac, and it is already connected.")
        }
        let storesCredential = mode == .live && integration.needsCredential
        let account = ConnectedAccount(integrationID: integrationID, label: name, billingScope: owner, mode: mode)
        if storesCredential { try vault.write(try validateCredential(credential), accountID: account.id) }
        do { try change { $0.accounts.append(account) } }
        catch {
            if storesCredential { try? vault.delete(accountID: account.id) }
            throw error
        }
        followWalletRepositories()
    }
    public func updateAccount(_ id: UUID, label: String, credential: String) throws {
        guard let account = state.accounts.first(where: { $0.id == id }), !refreshingAccounts.contains(id), loadFailure == nil else {
            throw ValidationError.message("Wait for the account refresh to finish, then try again.")
        }
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !state.accounts.contains(where: { $0.id != id && $0.integrationID == account.integrationID && $0.label.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw ValidationError.message("Enter a unique account label for this service.")
        }
        let replacing = account.mode == .live && !credential.isEmpty && Catalogue.integration(account.integrationID)?.needsCredential != false
        let previous = replacing ? try vault.read(accountID: id) : nil
        if replacing { try vault.write(try validateCredential(credential), accountID: id) }
        do {
            try change { next in
                let index = next.accounts.firstIndex { $0.id == id }!
                next.accounts[index].label = name
                if replacing { next.accounts[index].lastError = nil; next.accounts[index].lastAttempt = nil }
            }
        } catch {
            if replacing {
                if let previous { try? vault.write(previous, accountID: id) }
                else { try? vault.delete(accountID: id) }
            }
            throw error
        }
    }
    /// Turns a live wallet into manual records, keeping its payments and schedules. For providers whose
    /// connector cannot work for this account, such as Anthropic's Cost API on an individual account.
    public func switchToManual(_ id: UUID) throws {
        guard !refreshingAccounts.contains(id), loadFailure == nil else { throw ValidationError.message("Wait for the refresh to finish.") }
        guard state.accounts.contains(where: { $0.id == id && $0.mode == .live }) else { return }
        try change { next in
            guard let index = next.accounts.firstIndex(where: { $0.id == id }) else { return }
            next.accounts[index].mode = .manual
            next.accounts[index].snapshot = nil
            next.accounts[index].lastError = nil
            next.accounts[index].lastAttempt = nil
        }
        try? vault.delete(accountID: id)
    }

    public func removeAccount(_ id: UUID) throws {
        guard !refreshingAccounts.contains(id), loadFailure == nil else { throw ValidationError.message("Wait for the refresh to finish.") }
        guard !state.payments.contains(where: { $0.accountID == id }), !state.subscriptions.contains(where: { $0.accountID == id }) else {
            throw ValidationError.message("This account has financial records. Remove or reassign those records first.")
        }
        let previous = try vault.read(accountID: id)
        try vault.delete(accountID: id)
        do { try change { $0.accounts.removeAll { $0.id == id } } }
        catch { if let previous { try? vault.write(previous, accountID: id) }; throw error }
    }
    /// Adds imported payments in one save. Rows already recorded (same wallet and receipt
    /// reference, or same wallet, day, amount and description) are skipped. Missing wallets for
    /// a named service are created as manual accounts. Any invalid row rejects the whole file.
    @discardableResult
    public func importPayments(_ rows: [PaymentImport.Row], now: Date = .now) throws -> PaymentImport.Summary {
        guard loadFailure == nil else { throw ValidationError.message("Repair the saved data before importing.") }
        var summary = PaymentImport.Summary()
        try change { next in
            for row in rows {
                var accountID: UUID?
                if let integration = row.integrationID {
                    let sameProvider = next.accounts.filter { $0.integrationID == integration }
                    let named = sameProvider.first { $0.label.caseInsensitiveCompare(row.accountLabel) == .orderedSame }
                    if !row.accountLabelSpecified, sameProvider.count > 1 {
                        throw ValidationError.message("Line \(row.line): more than one \(integration) wallet exists. Add account_label to choose the billing account. Nothing was imported.")
                    }
                    if let existing = row.accountLabelSpecified ? named : sameProvider.first {
                        accountID = existing.id
                    } else {
                        let created = ConnectedAccount(integrationID: integration, label: row.accountLabel, billingScope: "", mode: .manual)
                        next.accounts.append(created)
                        accountID = created.id
                        summary.createdAccounts.append("\(Catalogue.integration(integration)?.name ?? integration) · \(row.accountLabel)")
                    }
                }
                let record = PaymentRecord(accountID: accountID, description: row.description, kind: row.kind, money: row.money, paidAt: row.paidAt, reference: row.reference)
                let day = Calendar.current.startOfDay(for: row.paidAt)
                let duplicate = next.payments.contains { existing in
                    guard existing.accountID == accountID else { return false }
                    if !row.reference.isEmpty { return existing.reference.caseInsensitiveCompare(row.reference) == .orderedSame }
                    return !existing.autoRecorded && Calendar.current.startOfDay(for: existing.paidAt) == day
                        && existing.money == row.money && existing.description == row.description
                }
                if duplicate { summary.duplicates += 1; continue }
                // Resolve at most one estimate. Check duplicates first so importing a receipt
                // again cannot remove a subsequently detected purchase.
                var confirmed = record
                if let match = try PaymentReconciliation.match(record, in: next.payments) {
                    confirmed.id = match.id
                    confirmed.createdAt = match.createdAt
                    confirmed.detection = match.detection
                    confirmed.sourceReference = match.sourceReference ?? match.reference
                    confirmed.confirmedAt = now
                    next.payments.removeAll { $0.id == match.id }
                    summary.replaced += 1
                }
                do { try Ledger.validate(record, existing: next.payments, now: now) }
                catch { throw ValidationError.message("Line \(row.line): \(error.localizedDescription)") }
                next.payments.append(confirmed)
                summary.imported += 1
            }
        }
        return summary
    }
    public func savePayment(_ record: PaymentRecord, now: Date = .now) throws {
        try Ledger.validate(record, existing: state.payments, now: now)
        try validateAccount(record.accountID)
        try change { next in
            if let index = next.payments.firstIndex(where: { $0.id == record.id }) {
                var edited = record
                edited.createdAt = next.payments[index].createdAt
                edited.detection = next.payments[index].detection
                edited.sourceReference = next.payments[index].sourceReference
                edited.confirmedAt = now
                next.payments[index] = edited
            }
            else { next.payments.append(record) }
            if let coverage = next.historyCoverage, record.paidAt < coverage.start {
                next.historyCoverage = .init(start: record.paidAt, completeForPeriod: false)
            }
        }
    }
    public func removePayment(_ id: UUID) throws {
        try change { next in
            next.payments.removeAll { $0.id == id }
            next.mcpPurchases?.removeAll { $0.paymentID == id }
            if next.historyCoverage != nil { next.historyCoverage?.completeForPeriod = false }
        }
    }
    public func saveSubscription(_ schedule: SubscriptionSchedule) throws {
        try Ledger.validate(schedule); try validateAccount(schedule.accountID)
        try change { next in
            if let index = next.subscriptions.firstIndex(where: { $0.id == schedule.id }) { next.subscriptions[index] = schedule }
            else { next.subscriptions.append(schedule) }
        }
    }
    public func removeSubscription(_ id: UUID) throws { try change { $0.subscriptions.removeAll { $0.id == id } } }

    /// Records every renewal that has fallen due for schedules set to record automatically, then
    /// moves each schedule to its next date. Renewals dated before the schedule existed are left
    /// for the user to confirm, so no past payments are invented. Safe to call repeatedly.
    @discardableResult
    public func recordDueRenewals(now: Date = .now) -> [PaymentRecord] {
        guard loadFailure == nil else { return [] }
        var recorded: [PaymentRecord] = []
        do {
            try change { next in
                for index in next.subscriptions.indices where next.subscriptions[index].recordsAutomatically {
                    var schedule = next.subscriptions[index]
                    if schedule.createdAt == nil { schedule.createdAt = now }
                    let earliest = Calendar.current.startOfDay(for: schedule.createdAt!)
                    var guardCount = 0
                    while schedule.nextRenewal <= now, schedule.nextRenewal >= earliest, guardCount < 60 {
                        guardCount += 1
                        let day = schedule.nextRenewal.formatted(.iso8601.year().month().day())
                        let payment = PaymentRecord(accountID: schedule.accountID, description: schedule.name, kind: .subscription, money: schedule.price,
                                                    paidAt: schedule.nextRenewal, reference: "auto-\(schedule.id.uuidString.prefix(8))-\(day)", scheduleID: schedule.id)
                        if !next.payments.contains(where: { $0.reference == payment.reference && $0.accountID == payment.accountID }) {
                            next.payments.append(payment); recorded.append(payment)
                        }
                        schedule.nextRenewal = schedule.advanced(from: schedule.nextRenewal)
                    }
                    next.subscriptions[index] = schedule
                }
            }
        } catch { notice = "Could not record due renewals: \(error.localizedDescription)"; return [] }
        return recorded
    }

    /// Marks an automatically recorded payment as confirmed by the user.
    public func confirmPayment(_ id: UUID) throws {
        try change { next in
            if let index = next.payments.firstIndex(where: { $0.id == id }), next.payments[index].autoRecorded {
                next.payments[index].scheduleID = nil; next.payments[index].estimated = nil
                next.payments[index].confirmedAt = .now
            }
        }
    }

    public func restoreBackup(_ name: String) throws {
        guard refreshingAccounts.isEmpty, refreshingRepositories.isEmpty, !refreshingTimeline, !refreshingRates else {
            throw ValidationError.message("Wait for the current refresh to finish before restoring.")
        }
        let restored = try repository.restore(backup: name)
        state = restored
        loadFailure = nil
        timelineErrors = [:]
        notice = "Backup restored. The previous data file was preserved in Backups. Credentials stay in Keychain; reconnect any accounts that need a key."
    }

    /// For pay-as-you-go wallets whose last month-to-date reading belongs to an earlier month,
    /// records that reading as the period's usage charge, marked Auto as an estimate. An
    /// imported invoice replaces it. Each wallet and month is recorded once.
    @discardableResult
    public func closePayAsYouGoPeriods(now: Date = .now) -> [PaymentRecord] {
        guard loadFailure == nil else { return [] }
        let calendar = Calendar.current
        guard let thisMonth = calendar.dateInterval(of: .month, for: now)?.start else { return [] }
        var recorded: [PaymentRecord] = []
        do {
            try change { next in
                for account in next.accounts where account.mode == .live && Catalogue.integration(account.integrationID)?.billing == .payAsYouGo {
                    guard let snapshot = account.snapshot, snapshot.consumptionPeriod == "This month", snapshot.observedAt < thisMonth,
                          let period = calendar.dateInterval(of: .month, for: snapshot.observedAt) else { continue }
                    let monthName = period.start.formatted(.dateTime.month(.wide).year())
                    for spent in snapshot.reportedConsumption where spent.amount > 0 {
                        let reference = "auto-usage-\(account.id.uuidString.prefix(8))-\(period.start.formatted(.iso8601.year().month()))-\(spent.currency)"
                        guard !next.payments.contains(where: { $0.reference == reference || $0.sourceReference == reference }) else { continue }
                        let name = Catalogue.integration(account.integrationID)?.name ?? account.integrationID
                        var payment = PaymentRecord(accountID: account.id, description: "\(name) usage, \(monthName)", kind: .usageCharge, money: spent,
                                                    paidAt: min(period.end.addingTimeInterval(-60), now), reference: reference)
                        payment.estimated = true
                        next.payments.append(payment); recorded.append(payment)
                    }
                }
            }
        } catch { notice = "Could not record last month's usage: \(error.localizedDescription)"; return [] }
        return recorded
    }

    /// Chooses the currency for combined spending views, or nil for separate currencies.
    public func setDisplayCurrency(_ currency: String?) async {
        do { try change { $0.displayCurrency = currency } } catch { notice = error.localizedDescription; return }
        await refreshRatesIfNeeded()
    }

    /// Downloads ECB reference rates when combining currencies and the cached table is missing
    /// a currency, does not reach back to the oldest payment, or is more than a day old.
    public func refreshRatesIfNeeded(now: Date = .now) async {
        guard let target = state.displayCurrency, !refreshingRates else { return }
        let needed = Set(state.payments.map(\.money.currency) + [target]).filter { $0 != "EUR" && Money.validCurrency($0) }
        guard !needed.isEmpty, let oldest = state.payments.map(\.paidAt).min() else { return }
        if let table = rates, needed.isSubset(of: Set(table.currencies)), now.timeIntervalSince(table.fetchedAt) < 86400,
           let first = table.rates.keys.min(), first <= RateTable.dayFormatter.string(from: oldest.addingTimeInterval(-7 * 86400)) { return }
        refreshingRates = true
        defer { refreshingRates = false }
        do {
            let table = try await rateLoader(needed.sorted(), oldest, now)
            try? RateStore(directory: repository.directory).save(table)
            rates = table
        } catch {
            if rates == nil { notice = "Could not download exchange rates, so currencies stay separate for now. \(Self.safeError(error))" }
        }
    }

    /// Refreshes live wallets whose last attempt is older than `interval`, one at a time.
    /// Used by the background timer; manual Refresh keeps its one-minute cooldown.
    public func refreshStaleAccounts(olderThan interval: TimeInterval = 3600, now: Date = .now) async {
        guard state.autoRefresh != false, loadFailure == nil else { return }
        let due = state.accounts.filter { $0.mode == .live && ($0.lastAttempt.map { now.timeIntervalSince($0) >= interval } ?? true) }.map(\.id)
        for id in due where !refreshingAccounts.contains(id) { await refreshAccount(id, now: .now) }
    }

    public func setAutoRefresh(_ enabled: Bool) throws { try change { $0.autoRefresh = enabled } }

    public func setMonthlyBudget(_ budget: Money?) throws {
        if let budget { guard budget.amount > 0, Money.validCurrency(budget.currency) else { throw ValidationError.message("Enter a positive budget and a currency code.") } }
        try setBudgetForMonth(.now, budget: budget)
    }

    public func setLowBalanceAlert(_ id: UUID, below amount: Decimal?) throws {
        if let amount { guard amount >= 0 else { throw ValidationError.message("Enter zero or more.") } }
        try change { next in if let index = next.accounts.firstIndex(where: { $0.id == id }) { next.accounts[index].lowBalanceAlert = amount } }
    }

    public func dismissSuggestion(_ id: String) throws {
        try change { next in next.dismissedSuggestions = Array(Set((next.dismissedSuggestions ?? []) + [id])).sorted() }
    }
    private func validateAccount(_ id: UUID?) throws {
        if let id, !state.accounts.contains(where: { $0.id == id }) { throw ValidationError.message("Choose an existing account.") }
    }
    public func setCoverage(start: Date, complete: Bool, now: Date = .now) throws {
        guard start <= now, state.payments.allSatisfy({ $0.paidAt >= start }) else {
            throw ValidationError.message("Coverage must start on or before the earliest payment, and cannot start in the future.")
        }
        try change { $0.historyCoverage = .init(start: start, completeForPeriod: complete) }
    }
    public func refreshAccount(_ id: UUID, now: Date = .now) async {
        guard let index = state.accounts.firstIndex(where: { $0.id == id }), state.accounts[index].mode == .live,
              !refreshingAccounts.contains(id), loadFailure == nil else { return }
        // A reading from the last minute is already current: skip quietly rather than interrupt.
        // After a failure, allow a retry after ten seconds.
        if let attempt = state.accounts[index].lastAttempt,
           now.timeIntervalSince(attempt) < (state.accounts[index].lastError == nil ? 60 : 10) { return }
        closePayAsYouGoPeriods(now: now)
        refreshingAccounts.insert(id)
        defer { refreshingAccounts.remove(id) }
        do {
            try change { $0.accounts[index].lastAttempt = now }
            let account = state.accounts[index]
            let credential: String
            if Catalogue.integration(account.integrationID)?.needsCredential == false { credential = "" }
            else {
                guard let saved = try vault.read(accountID: id) else { throw ConnectorError.missingCredential }
                credential = saved
            }
            let snapshot = try await balances(account.integrationID, credential, now)
            try change { next in
                guard let current = next.accounts.firstIndex(where: { $0.id == id }) else { return }
                let previous = next.accounts[current].snapshot
                next.accounts[current].snapshot = snapshot; next.accounts[current].lastError = nil
                let topUps = TopUpWatch.payments(old: previous, new: snapshot, account: next.accounts[current], recorded: next.payments, now: now)
                next.payments += topUps
                next.record(AllowanceWatch.events(old: previous, new: snapshot, account: next.accounts[current], now: now)
                    + PlanWatch.events(old: previous, new: snapshot, account: next.accounts[current], now: now)
                    + Self.anomalyEvents(snapshot, account: next.accounts[current], now: now)
                    + topUps.map { payment in
                        TimelineEvent(id: "topup-\(payment.id)", date: now, kind: .recorded, title: "\(Catalogue.integration(next.accounts[current].integrationID)?.name ?? "Wallet"): top-up detected",
                                      detail: "Recorded \(payment.money.plainText) as an Estimate. Import the receipt to replace it, or confirm it in Payments.",
                                      sourceName: "Unifai", accountID: payment.accountID, important: true)
                    })
            }
        } catch {
            // Never persist a response body, request headers or credential in errors.
            let message = Self.safeError(error)
            do { try change { next in if let current = next.accounts.firstIndex(where: { $0.id == id }) { next.accounts[current].lastError = message } } }
            catch { notice = "Could not save refresh status: \(error.localizedDescription)" }
        }
    }
    public func addRepository(_ input: String, includePrereleases: Bool) throws {
        guard let slug = WatchedRepository.parseSlug(input) else { throw ValidationError.message("Enter a public GitHub repository as owner/name or its HTTPS URL.") }
        guard state.repositories.count < 10 else { throw ValidationError.message("This build supports at most 10 watched repositories.") }
        guard !state.repositories.contains(where: { $0.slug.caseInsensitiveCompare(slug) == .orderedSame }) else { throw ValidationError.message("You already follow this repository.") }
        try change { $0.repositories.append(.init(slug: slug, includePrereleases: includePrereleases)) }
    }
    public func setPrereleases(_ id: UUID, include: Bool) throws {
        try change { next in if let index = next.repositories.firstIndex(where: { $0.id == id }) { next.repositories[index].includePrereleases = include } }
    }
    public func removeRepository(_ id: UUID) throws {
        guard !refreshingRepositories.contains(id) else { throw ValidationError.message("Wait for the repository refresh to finish.") }
        try change { $0.repositories.removeAll { $0.id == id } }
    }
    public func refreshRepository(_ id: UUID, now: Date = .now) async {
        guard let index = state.repositories.firstIndex(where: { $0.id == id }), !refreshingRepositories.contains(id), loadFailure == nil else { return }
        let until = max(state.repositories[index].nextAllowedRefresh ?? .distantPast, state.githubBackoffUntil ?? .distantPast)
        if until > now {
            notice = "GitHub refresh available after \(until.formatted(date: .omitted, time: .shortened))."; return
        }
        let recent = (state.githubRequests ?? []).filter { now.timeIntervalSince($0) < 3600 }
        guard recent.count < 20 else { notice = "The local budget of 20 GitHub requests per hour is used. Try again later."; return }
        refreshingRepositories.insert(id)
        defer { refreshingRepositories.remove(id) }
        do {
            try change { next in
                next.githubRequests = recent + [now]
                next.repositories[index].lastAttempt = now
                next.repositories[index].nextAllowedRefresh = now.addingTimeInterval(1800)
            }
            let result = try await releases(state.repositories[index], now)
            try change { next in
                guard let current = next.repositories.firstIndex(where: { $0.id == id }) else { return }
                if let items = result.releases {
                    next.repositories[current].releases = items
                    next.record(Self.releaseEvents(items, repository: next.repositories[current], accounts: next.accounts, now: now))
                }
                next.repositories[current].etag = result.etag
                next.repositories[current].lastSuccess = now
                next.repositories[current].lastError = nil
                next.repositories[current].nextAllowedRefresh = max(result.retryAfter, now.addingTimeInterval(1800))
            }
        } catch {
            let message = Self.safeError(error)
            do {
                try change { next in
                    if case ConnectorError.retryAt(let date) = error { next.githubBackoffUntil = max(date, next.githubBackoffUntil ?? .distantPast) }
                    if let current = next.repositories.firstIndex(where: { $0.id == id }) { next.repositories[current].lastError = message }
                }
            } catch { notice = "Could not save release status: \(error.localizedDescription)" }
        }
    }
    static func anomalyEvents(_ snapshot: BalanceSnapshot, account: ConnectedAccount, now: Date) -> [TimelineEvent] {
        let name = Catalogue.integration(account.integrationID)?.name ?? account.label
        return (snapshot.anomalies ?? []).map { spike in
            TimelineEvent(id: "anomaly-\(account.id)-\(spike.service)-\(spike.day)", date: now, kind: .anomaly,
                          title: spike.typical.amount == 0 ? "\(name): new spend on \(spike.service)" : "\(name): \(spike.service) cost jumped",
                          detail: spike.summary + ". Check for a resource left running.", source: snapshot.source,
                          sourceName: name, accountID: account.id, important: true)
        }
    }

    private static func safeError(_ error: Error) -> String {
        if let known = error as? ConnectorError { return known.localizedDescription }
        if error is URLError { return "The network request failed. Check your connection and try again. The last successful reading is preserved." }
        if error is ValidationError { return error.localizedDescription }
        return "Refresh failed. The last successful reading is preserved. Check your connection and saved data."
    }
}
