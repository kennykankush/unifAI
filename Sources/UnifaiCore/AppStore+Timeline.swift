import Foundation

public extension AppStore {
    /// Keychain slot for the X bearer token; not tied to a wallet.
    nonisolated static let xTokenID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    /// Follows the release repository for each wallet that has one (Codex, Claude Code), once.
    @discardableResult
    func followWalletRepositories() -> [String] {
        let wanted = Set(state.accounts.compactMap { ReleaseRelevance.walletRepositories[$0.integrationID] })
        let done = Set(state.autoFollowed ?? [])
        let existing = Set(state.repositories.map { $0.slug.lowercased() })
        let added = wanted.subtracting(done).sorted()
        guard !added.isEmpty else { return [] }
        do {
            try change { next in
                for slug in added where !existing.contains(slug.lowercased()) { next.repositories.append(WatchedRepository(slug: slug)) }
                next.autoFollowed = (next.autoFollowed ?? []) + added
            }
        } catch { notice = "Could not follow \(added.joined(separator: ", ")): \(error.localizedDescription)" }
        return added
    }

    nonisolated static func releaseEvents(_ releases: [ReleaseItem], repository: WatchedRepository, accounts: [ConnectedAccount], now: Date) -> [TimelineEvent] {
        releases.filter { (repository.includePrereleases || !$0.prerelease) && ($0.publishedAt ?? .distantPast) > now.addingTimeInterval(-45 * 86400) }
            .prefix(10).map { release in
                let wallets = ReleaseRelevance.wallets(for: release, repository: repository.slug, accounts: accounts)
                return TimelineEvent(id: "release-\(repository.slug.lowercased())-\(release.id)", date: release.publishedAt ?? now, kind: .release,
                                     title: "\(repository.slug) \(release.title)",
                                     detail: [wallets.isEmpty ? nil : "Affects \(wallets.joined(separator: ", "))", release.summary].compactMap { $0 }.joined(separator: " · "),
                                     source: release.url, sourceName: repository.slug, important: !wallets.isEmpty)
            }
    }

    /// Adds events from outside a refresh, such as the synthetic demo workspace.
    func recordEvents(_ events: [TimelineEvent]) throws { try change { $0.record(events) } }

    /// Refreshes followed repositories whose 30-minute spacing has passed, quietly.
    func refreshDueRepositories(now: Date = .now) async {
        guard (state.githubBackoffUntil ?? .distantPast) <= now else { return }
        for repository in state.repositories where (repository.nextAllowedRefresh ?? .distantPast) <= now {
            let recent = (state.githubRequests ?? []).filter { now.timeIntervalSince($0) < 3600 }
            guard recent.count < 18 else { return }
            await refreshRepository(repository.id, now: now)
        }
    }

    func setNewsFeeds(_ on: Bool) throws { try change { $0.newsFeeds = on } }
    func setNewModels(_ on: Bool) throws { try change { $0.newModels = on } }

    // MARK: X

    func setXToken(_ token: String?) throws {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { try vault.delete(accountID: Self.xTokenID); hasXToken = false; return }
        guard trimmed.count <= 512, trimmed.allSatisfy({ !$0.isWhitespace && $0.isASCII }) else {
            throw ValidationError.message("Paste the bearer token from your X developer app exactly as shown.")
        }
        try vault.write(trimmed, accountID: Self.xTokenID)
        hasXToken = true
    }

    func setXHandles(_ input: String) throws {
        let parts = input.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        var handles: [String] = []
        for part in parts {
            guard let handle = XClient.validHandle(part) else { throw ValidationError.message("\(part) is not an X handle.") }
            if !handles.contains(where: { $0.caseInsensitiveCompare(handle) == .orderedSame }) { handles.append(handle) }
        }
        guard handles.count <= 10 else { throw ValidationError.message("Follow at most 10 accounts; each poll is billed by X.") }
        try change { $0.xHandles = handles.isEmpty ? nil : handles }
    }

    /// Estimated X API spend this month from the reads Unifai made.
    func xCost(month: Date = .now) -> Money {
        let key = Self.monthKey(month)
        let reads = Decimal(state.xPostReads?[key] ?? 0), lookups = Decimal(state.xUserLookups?[key] ?? 0)
        return Money(reads * XClient.postReadCost + lookups * XClient.userLookupCost, "USD")
    }

    nonisolated static func monthKey(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    // MARK: Refresh

    /// Reads status pages for providers you pay and posts from followed X accounts, at most every 30 minutes
    /// unless forced. Returns the new events.
    @discardableResult
    func refreshTimeline(force: Bool = false, now: Date = .now) async -> [TimelineEvent] {
        guard loadFailure == nil, !refreshingTimeline else { return [] }
        if !force, let checked = state.timelineCheckedAt, now.timeIntervalSince(checked) < 1800 { return [] }
        refreshingTimeline = true
        defer { refreshingTimeline = false }
        try? change { $0.timelineCheckedAt = now }
        let productEvents = await refreshProductUpdates(force: force, now: now)
        var incoming: [TimelineEvent] = []
        var errors: [String: String] = [:]
        for feed in StatusFeed.relevant(to: state.accounts) {
            do { incoming += StatusFeedClient.events(try await statusLoader(feed), feed: feed, now: now, integrations: Set(state.accounts.map(\.integrationID))) }
            catch { errors[feed.name] = "\(feed.name) status could not be read." }
        }
        if state.newsFeeds != false {
            for feed in NewsFeed.all {
                do { incoming += NewsFeed.events(try await feedLoader(feed.url), feed: feed, now: now) }
                catch { errors[feed.name] = "\(feed.name) could not be read." }
            }
        }
        // The model list is large and changes slowly: every six hours.
        if state.newModels != false, force || (state.modelsCheckedAt.map { now.timeIntervalSince($0) >= 6 * 3600 } ?? true) {
            do {
                incoming += NewModels.events(try await feedLoader(NewModels.url), accounts: state.accounts, now: now)
                try? change { $0.modelsCheckedAt = now }
            } catch { errors["OpenRouter models"] = "OpenRouter's model list could not be read." }
        }
        if let token = (try? vault.read(accountID: Self.xTokenID)) ?? nil {
            let key = Self.monthKey(now)
            for handle in state.xHandles ?? [] {
                let id = state.xUserIDs?[handle.lowercased()], since = state.xSinceIDs?[handle.lowercased()]
                do {
                    let result = try await postLoader(token, handle, id, since)
                    incoming += XClient.events(result.posts, handle: handle, now: now)
                    let name = handle.lowercased()
                    // Post IDs are numeric strings; the longest, then highest, is the newest.
                    let newest: String? = result.posts.map(\.id).max(by: Self.olderPostID)
                    try change { next in
                        var ids = next.xUserIDs ?? [:], sinceIDs = next.xSinceIDs ?? [:]
                        var reads = next.xPostReads ?? [:], lookups = next.xUserLookups ?? [:]
                        ids[name] = result.userID
                        if let newest { sinceIDs[name] = newest }
                        reads[key, default: 0] += result.posts.count
                        if result.lookups > 0 { lookups[key, default: 0] += result.lookups }
                        next.xUserIDs = ids; next.xSinceIDs = sinceIDs; next.xPostReads = reads
                        next.xUserLookups = lookups.isEmpty ? nil : lookups
                    }
                } catch {
                    errors["@\(handle)"] = (error as? LocalizedError)?.errorDescription ?? "Posts from @\(handle) could not be read."
                }
            }
        }
        timelineErrors = errors
        var fresh: [TimelineEvent] = []
        do { try change { fresh = $0.record(incoming) } }
        catch { notice = "Could not save the timeline: \(error.localizedDescription)" }
        return productEvents + fresh
    }

    nonisolated static func olderPostID(_ a: String, _ b: String) -> Bool {
        a.count != b.count ? a.count < b.count : a < b
    }

    // MARK: Close the month

    /// Auto renewals and usage estimates still waiting for a receipt, oldest first.
    var unconfirmedPayments: [PaymentRecord] { state.payments.filter(\.autoRecorded).sorted { $0.paidAt < $1.paidAt } }
}

public extension PersistentState {
    /// A prompt for a coding agent with mail access: find the receipts that confirm these entries
    /// and return a CSV Unifai can import.
    func receiptRequest(for records: [PaymentRecord]) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        let lines = records.map { record -> String in
            let account = accounts.first { $0.id == record.accountID }
            let provider = account.flatMap { Catalogue.integration($0.integrationID)?.name } ?? "Unknown provider"
            return "- \(day.string(from: record.paidAt)) · \(provider) · account=\(account?.integrationID ?? "") · account_label=\(account?.label ?? "") · \(record.description) · about \(record.money.plainText)"
        }
        return """
        Find the receipts or invoices for these charges in my email or billing pages:

        \(lines.joined(separator: "\n"))

        Reply with a CSV for Unifai's Import CSV, one row per receipt, with this header:
        date,description,amount,currency,kind,account,account_label,reference

        Use the charged amount and currency from the receipt, kind top-up for credit purchases, subscription for plans, usage for invoices, or refund. \
        Use account as the provider id (for example deepseek, openrouter, codex, claude-subscription, azure-subscription, openai-api), \
        account_label as the wallet label, and reference as the receipt or invoice number. \
        Leave out anything you cannot find rather than guessing.
        """
    }
}
