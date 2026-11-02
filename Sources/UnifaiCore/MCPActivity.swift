import Foundation
import CryptoKit

public struct MCPCall: Codable, Hashable, Identifiable {
    public enum Outcome: String, Codable { case returned, failed, unknown }
    public var id: String
    public var client: String
    public var session: String
    public var server: String
    public var tool: String
    public var date: Date
    public var outcome: Outcome
}

public struct MCPScan: Codable, Equatable {
    public var date: Date
    public var since: Date
    public var filesRead: Int = 0
    public var skippedFiles: Int = 0
    public var skippedLines: Int = 0
    public var wrapperCalls: Int = 0
    public var unavailableSources: [String] = []
    public var sourceFiles: [String: Int]? = [:]
    public var calls: [MCPCall] = []
    public var coverage: String {
        "Observed direct MCP calls in local history, last 90 days. \((sourceFiles ?? [:]).keys.sorted().map { "\($0): \(sourceFiles?[$0] ?? 0) files" }.joined(separator: "; ")). \(skippedFiles) files and \(skippedLines) lines skipped. \(wrapperCalls) execution-wrapper calls were not expanded. Missing logs, other devices, hosted apps and nested calls are not covered. Counts are not provider credits or billable usage."
    }
}

public enum MCPHistory {
    public struct Source { public var client: String; public var root: URL
        public init(client: String, root: URL) { self.client = client; self.root = root }
    }
    public static var localSources: [Source] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [.init(client: "Claude Code", root: home.appendingPathComponent(".claude/projects")),
                .init(client: "Codex", root: home.appendingPathComponent(".codex/sessions"))]
    }
    public static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    public static func serverKey(_ text: String) -> String? {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard name.range(of: "^[a-z0-9][a-z0-9_.-]{0,99}$", options: .regularExpression) != nil else { return nil }
        return name
    }
    static func toolParts(_ name: String) -> (String, String)? {
        let name = name.hasPrefix("functions.mcp__") ? String(name.dropFirst("functions.".count)) : name
        guard name.hasPrefix("mcp__") else { return nil }
        let rest = String(name.dropFirst(5))
        guard let split = rest.range(of: "__"), let server = serverKey(String(rest[..<split.lowerBound])) else { return nil }
        let tool = String(rest[split.upperBound...])
        guard tool.range(of: "^[A-Za-z0-9_.-]{1,160}$", options: .regularExpression) != nil else { return nil }
        return (server, tool)
    }
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    /// Only call metadata escapes this function. Arguments, text, images and tool results are discarded.
    public static func parse(_ data: Data, client: String, fallbackSession: String, since: Date, now: Date) -> MCPScan {
        var scan = MCPScan(date: now, since: since)
        var calls: [String: MCPCall] = [:], outcomes: [String: MCPCall.Outcome] = [:]
        for line in data.split(separator: 10) {
            guard line.count <= 2 * 1024 * 1024,
                  let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { scan.skippedLines += 1; continue }
            guard let stamp = date(row["timestamp"] as? String), stamp >= since, stamp <= now.addingTimeInterval(300) else { continue }
            let session = hash(row["sessionId"] as? String ?? row["session_id"] as? String ?? fallbackSession)
            func add(_ id: String?, _ name: String?) {
                guard let id, id.count <= 512, let name else { return }
                if name == "functions.exec" || name == "exec" { scan.wrapperCalls += 1 }
                guard let (server, tool) = toolParts(name) else { return }
                calls[id] = MCPCall(id: hash(client + ":" + id + ":" + stamp.ISO8601Format()), client: client,
                    session: session, server: server, tool: tool, date: stamp, outcome: .unknown)
            }
            if client == "Claude Code", let message = row["message"] as? [String: Any], let parts = message["content"] as? [[String: Any]] {
                for part in parts {
                    if part["type"] as? String == "tool_use" { add(part["id"] as? String, part["name"] as? String) }
                    if part["type"] as? String == "tool_result", let id = part["tool_use_id"] as? String {
                        outcomes[id] = (part["is_error"] as? Bool) == true ? .failed : .returned
                    }
                }
            } else if client == "Codex", row["type"] as? String == "response_item", let item = row["payload"] as? [String: Any] {
                let type = item["type"] as? String
                if type == "function_call" || type == "custom_tool_call" { add(item["call_id"] as? String, item["name"] as? String) }
                if type == "function_call_output" || type == "custom_tool_call_output", let id = item["call_id"] as? String {
                    outcomes[id] = .returned // Text output is not a reliable success/error signal.
                }
            }
        }
        scan.calls = calls.map { id, call in var call = call; call.outcome = outcomes[id] ?? .unknown; return call }.sorted { $0.date < $1.date }
        return scan
    }
    public static func scan(sources: [Source] = localSources, now: Date = .now) -> MCPScan {
        let since = now.addingTimeInterval(-90 * 86400)
        var result = MCPScan(date: now, since: since), totalBytes = 0
        var merged: [String: MCPCall] = [:]
        for source in sources {
            var sourceBytes = 0
            result.sourceFiles?[source.client] = 0
            guard FileManager.default.fileExists(atPath: source.root.path),
                  (try? source.root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                result.unavailableSources.append(source.client); continue
            }
            guard let enumerator = FileManager.default.enumerator(at: source.root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles], errorHandler: { _, _ in result.skippedFiles += 1; return true }) else {
                result.unavailableSources.append(source.client); continue
            }
            var files: [(URL, Date, Int)] = []
            var inspected = 0
            for case let url as URL in enumerator {
                inspected += 1
                if inspected > 20000 { result.skippedFiles += 1; break }
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]) else { result.skippedFiles += 1; continue }
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard values.isRegularFile == true, url.pathExtension == "jsonl", let modified = values.contentModificationDate, modified >= since else { continue }
                files.append((url, modified, values.fileSize ?? 0))
            }
            files.sort { $0.1 > $1.1 }
            for (index, file) in files.enumerated() {
                guard index < 500, file.2 <= 20 * 1024 * 1024, sourceBytes + file.2 <= 128 * 1024 * 1024, totalBytes + file.2 <= 256 * 1024 * 1024 else { result.skippedFiles += 1; continue }
                guard let handle = try? FileHandle(forReadingFrom: file.0) else { result.skippedFiles += 1; continue }
                let read = try? handle.read(upToCount: 20 * 1024 * 1024 + 1)
                try? handle.close()
                guard let data = read, data.count <= 20 * 1024 * 1024 else { result.skippedFiles += 1; continue }
                totalBytes += data.count; sourceBytes += data.count; result.filesRead += 1
                result.sourceFiles?[source.client, default: 0] += 1
                let parsed = parse(data, client: source.client, fallbackSession: file.0.lastPathComponent, since: since, now: now)
                result.skippedLines += parsed.skippedLines; result.wrapperCalls += parsed.wrapperCalls
                for call in parsed.calls {
                    if merged[call.id]?.outcome == .failed { continue }
                    if merged[call.id] == nil || call.outcome != .unknown { merged[call.id] = call }
                }
            }
        }
        let all = merged.values.sorted { $0.date < $1.date }
        result.calls = Array(all.suffix(20000))
        if all.count > 20000 { result.skippedLines += all.count - 20000 }
        return result
    }
}

public struct MCPPurchase: Codable, Identifiable, Equatable {
    public enum Plan: String, Codable, CaseIterable { case monthly = "Monthly", annual = "Annual", lifetime = "Lifetime", oneTime = "One-time" }
    public var id: UUID = UUID()
    public var server: String
    public var name: String
    public var plan: Plan
    public var startedAt: Date
    public var paymentID: UUID
    public var accountID: UUID
    public var scheduleID: UUID?
}

public struct MCPServiceSummary: Codable, Identifiable {
    public var id: String
    public var calls: Int
    public var sessions: Int
    public var returned: Int
    public var failed: Int
    public var unknown: Int
    public var lastUsed: Date?
    public var clients: [String]
    public var tools: [String: Int]
    public var purchases: [MCPPurchase]
}

public extension PersistentState {
    func mcpServices(now: Date = .now, days: Int = 30) -> [MCPServiceSummary] {
        let calls = (mcpScan?.calls ?? []).filter { $0.date >= now.addingTimeInterval(-Double(days) * 86400) && $0.date <= now }
        let names = Set(calls.map(\.server)).union((mcpPurchases ?? []).map(\.server))
        return names.sorted().map { name in
            let rows = calls.filter { $0.server == name }
            return MCPServiceSummary(id: name, calls: rows.count, sessions: Set(rows.map(\.session)).count,
                returned: rows.filter { $0.outcome == .returned }.count, failed: rows.filter { $0.outcome == .failed }.count,
                unknown: rows.filter { $0.outcome == .unknown }.count, lastUsed: (mcpScan?.calls ?? []).filter { $0.server == name }.map(\.date).max(),
                clients: Set(rows.map(\.client)).sorted(), tools: Dictionary(grouping: rows, by: \.tool).mapValues(\.count),
                purchases: (mcpPurchases ?? []).filter { $0.server == name })
        }
    }
}

@MainActor public extension AppStore {
    func setMCPTracking(_ enabled: Bool) throws { try change { $0.mcpTrackingEnabled = enabled } }
    func refreshMCPActivity(now: Date = .now, sources: [MCPHistory.Source]? = nil) async throws {
        guard state.mcpTrackingEnabled == true else { return }
        let result = await Task.detached(priority: .utility) { MCPHistory.scan(sources: sources ?? MCPHistory.localSources, now: now) }.value
        // Disabling while a scan runs must not republish its data.
        guard state.mcpTrackingEnabled == true else { return }
        guard (state.mcpScan?.date ?? .distantPast) <= now else { return }
        try change { next in
            var result = result
            var merged = Dictionary((next.mcpScan?.calls ?? []).filter { $0.date >= result.since }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for call in result.calls {
                if merged[call.id]?.outcome == .failed { continue }
                if merged[call.id] == nil || call.outcome != .unknown { merged[call.id] = call }
            }
            result.calls = Array(merged.values.sorted { $0.date < $1.date }.suffix(20000))
            next.mcpScan = result
        }
    }
    func recordMCPSubscription(server: String, name: String, plan: MCPPurchase.Plan, startedAt: Date,
                               amount: Money, existingPaymentID: UUID? = nil, nextRenewal: Date? = nil, now: Date = .now) throws {
        guard let server = MCPHistory.serverKey(server), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 100, startedAt <= now, amount.amount > 0, !amount.amount.isNaN, Money.validCurrency(amount.currency) else {
            throw ValidationError.message("Enter a service identifier, name, purchase date, positive amount and currency.")
        }
        guard !(state.mcpPurchases ?? []).contains(where: { $0.server == server }) else {
            throw ValidationError.message("This MCP already has a purchase linked. Manage its payments and renewal in Wallets and Subscriptions.")
        }
        if let nextRenewal, (plan != .monthly && plan != .annual) || nextRenewal <= now {
            throw ValidationError.message("Use a future renewal date for monthly or annual plans. Lifetime purchases do not renew.")
        }
        try change { next in
            let accountID: UUID, paymentID: UUID
            if let existingPaymentID {
                guard let payment = next.payments.first(where: { $0.id == existingPaymentID }), let owner = payment.accountID,
                      next.accounts.contains(where: { $0.id == owner }), payment.kind != .refund else {
                    throw ValidationError.message("Choose an existing non-refund payment assigned to a wallet.")
                }
                guard !(next.mcpPurchases ?? []).contains(where: { $0.paymentID == existingPaymentID }) else {
                    throw ValidationError.message("That payment is already linked to an MCP service.")
                }
                accountID = owner; paymentID = existingPaymentID
            } else {
                guard !next.accounts.contains(where: { $0.label.caseInsensitiveCompare(name + " MCP") == .orderedSame }) else {
                    throw ValidationError.message("A wallet for this service already exists. Link its existing payment instead.")
                }
                let account = ConnectedAccount(integrationID: "custom", label: name + " MCP", billingScope: "Declared purchase", mode: .manual)
                next.accounts.append(account); accountID = account.id
                let payment = PaymentRecord(accountID: accountID, description: name + " " + plan.rawValue, kind: .subscription, money: amount, paidAt: startedAt)
                try Ledger.validate(payment, existing: next.payments, now: now)
                next.payments.append(payment); paymentID = payment.id
                if let coverage = next.historyCoverage, startedAt < coverage.start {
                    next.historyCoverage = .init(start: startedAt, completeForPeriod: false)
                }
            }
            var purchase = MCPPurchase(server: server, name: name, plan: plan, startedAt: startedAt, paymentID: paymentID, accountID: accountID)
            if let nextRenewal {
                guard !next.subscriptions.contains(where: { $0.accountID == accountID }) else {
                    throw ValidationError.message("This wallet already has a renewal schedule. Link without adding another renewal.")
                }
                let schedule = SubscriptionSchedule(accountID: accountID, name: name + " MCP", price: amount,
                    cadence: plan == .monthly ? .monthly : .yearly, nextRenewal: nextRenewal, autoRecord: false, createdAt: now)
                try Ledger.validate(schedule)
                next.subscriptions.append(schedule); purchase.scheduleID = schedule.id
            }
            next.mcpPurchases = (next.mcpPurchases ?? []) + [purchase]
        }
    }
}
