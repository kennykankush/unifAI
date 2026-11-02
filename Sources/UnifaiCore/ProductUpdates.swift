import Foundation
import CryptoKit

public struct ProductSource: Identifiable, Hashable, Sendable {
    public enum Format: String, Sendable { case htmlNotes, markdownNotes, policy }
    public let id: String
    public let name: String
    public let provider: String
    public let url: URL
    public let format: Format
    public let integrations: Set<String>
    public var pageURL: URL { format == .markdownNotes ? url.deletingPathExtension() : url }
    public static let all: [ProductSource] = [
        .init(id: "openai-notes", name: "ChatGPT release notes", provider: "OpenAI", url: URL(string: "https://help.openai.com/en/articles/6825453-chatgpt-release-notes")!, format: .htmlNotes, integrations: ["codex", "chatgpt"]),
        .init(id: "openai-pro", name: "ChatGPT Pro benefits", provider: "OpenAI", url: URL(string: "https://help.openai.com/en/articles/9793128-about-chatgpt-pro-tiers")!, format: .policy, integrations: ["codex", "chatgpt"]),
        .init(id: "claude-notes", name: "Claude release notes", provider: "Anthropic", url: URL(string: "https://support.claude.com/en/articles/12138966-release-notes")!, format: .htmlNotes, integrations: ["claude-subscription"]),
        .init(id: "claude-plan", name: "Claude Max benefits", provider: "Anthropic", url: URL(string: "https://support.claude.com/en/articles/11049741-what-is-the-max-plan")!, format: .policy, integrations: ["claude-subscription"]),
        .init(id: "claude-api-notes", name: "Claude API release notes", provider: "Anthropic", url: URL(string: "https://platform.claude.com/docs/en/release-notes/overview.md")!, format: .markdownNotes, integrations: ["claude-api"]),
    ]
}

public struct ProductNotice: Codable, Hashable {
    public var topic: String
    public var observedAt: Date
    public var publishedAt: Date?
    public var previousExcerpt: String?
    public var excerpt: String
    public var relevance: String
    public var evidence: String
}

public struct ProductSnapshot: Codable, Equatable {
    public struct Entry: Codable, Equatable {
        public var key: String
        public var title: String
        public var text: String
        public var publishedAt: Date?
        public var digest: String
    }
    public var checkedAt: Date
    public var entries: [Entry]
}

public enum ProductUpdates {
    static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined() }
    static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
    static func article(_ html: String) throws -> String {
        let regex = try NSRegularExpression(pattern: "<article\\b[^>]*>(.*?)</article>", options: [.caseInsensitive, .dotMatchesLineSeparators])
        guard let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), let range = Range(match.range(at: 1), in: html) else {
            throw ValidationError.message("The official page no longer has a readable article. The previous snapshot is preserved.")
        }
        var body = String(html[range])
        body = replace(body, "<(script|style|nav|footer)\\b[^>]*>.*?</\\1>", "")
        body = replace(body, "<h[1-6]\\b[^>]*>(.*?)</h[1-6]>", "\n# $1\n")
        body = replace(body, "<p\\b[^>]*>\\s*<(?:b|strong)\\b[^>]*>(.*?)</(?:b|strong)>\\s*</p>", "\n# $1\n")
        body = replace(body, "</(?:p|div|li|tr)>|<br\\s*/?>", "\n")
        return body.components(separatedBy: .newlines).map { HTMLText.plain($0) }.joined(separator: "\n")
    }
    static func lines(_ raw: String, source: ProductSource) throws -> [String] {
        let text = source.format == .markdownNotes ? raw : try article(raw)
        return text.components(separatedBy: .newlines).prefix { line in
            !line.contains("Did this answer your question") && !line.contains("Related articles")
        }.map { line in
            var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            value = replace(value, "\\[([^\\]]+)\\]\\([^)]*\\)", "$1")
            value = value.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            return value
        }.filter { !$0.isEmpty }
    }
    static func publicationDate(_ text: String) -> Date? {
        let plain = text.replacingOccurrences(of: #"^[#\s]+"#, with: "", options: .regularExpression)
        for format in ["MMMM d, yyyy", "MMM d, yyyy", "yyyy-MM-dd"] {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = format; formatter.isLenient = false
            if let date = formatter.date(from: plain), formatter.string(from: date).lowercased() == plain.lowercased() { return date }
        }
        return nil
    }
    public static func topic(_ text: String) -> String {
        let text = text.lowercased()
        if text.range(of: #"\b(retir|deprecat|remov|sunset)"#, options: .regularExpression) != nil { return "Retirements & changes" }
        if text.range(of: #"\b(price|pricing|costs?|billing|discount)\b"#, options: .regularExpression) != nil { return "Pricing & billing" }
        if text.range(of: #"\b(limits?|allowances?|credits?|resets?|usage|plans?|promotion|included|benefits?)\b"#, options: .regularExpression) != nil { return "Usage & benefits" }
        return "Features & improvements"
    }
    public static func decode(_ data: Data, source: ProductSource, now: Date = .now) throws -> ProductSnapshot {
        guard data.count <= 4_000_000, let raw = String(data: data, encoding: .utf8), !raw.isEmpty else { throw ConnectorError.invalidResponse }
        let lines = try lines(raw, source: source)
        if source.format == .policy {
            // Select benefit-related blocks, excluding unrelated navigation, scripts and footer changes.
            let relevant = lines.filter { line in
                !line.hasPrefix("#") && line.count > 25 && line.range(of: #"(?i)\b(usage|allowance|limits?|credits?|benefits?|included|subscription|renewal|promotion|price|\$[0-9])\b"#, options: .regularExpression) != nil
            }
            let text = Array(NSOrderedSet(array: relevant)).compactMap { $0 as? String }.joined(separator: "\n")
            guard text.count >= 80, text.count <= 60000 else { throw ConnectorError.invalidResponse }
            return ProductSnapshot(checkedAt: now, entries: [.init(key: source.id, title: source.name, text: text, publishedAt: nil, digest: hash(text))])
        }
        var entries: [ProductSnapshot.Entry] = [], date: Date?, title: String?, body: [String] = []
        var datedHeadings = 0
        func finish() {
            guard let date, let title, !body.isEmpty, date <= now.addingTimeInterval(86400), date >= now.addingTimeInterval(-45 * 86400) else { return }
            let text = body.joined(separator: "\n")
            guard text.count >= 20 else { return }
            let key = hash(source.id + date.ISO8601Format() + title)
            entries.append(.init(key: key, title: String(title.prefix(180)), text: String(text.prefix(16000)), publishedAt: date, digest: hash(text)))
        }
        for line in lines {
            if line.hasPrefix("#"), let day = publicationDate(line) {
                finish(); date = day; title = nil; body = []; datedHeadings += 1
            } else if line.hasPrefix("#") {
                // Month headings end the previous dated section; they are not announcements.
                let heading = line.replacingOccurrences(of: #"^[#\s]+"#, with: "", options: .regularExpression)
                if heading.range(of: #"^[A-Za-z]+ \d{4}$"#, options: .regularExpression) != nil { finish(); date = nil; title = nil; body = []; continue }
                if date != nil { finish(); title = heading; body = [] }
            } else if date != nil {
                if title == nil {
                    title = String(line.replacingOccurrences(of: #"^[-*]\s*"#, with: "", options: .regularExpression).prefix(140))
                }
                body.append(line)
            }
        }
        finish()
        guard datedHeadings > 0 else { throw ValidationError.message("No dated announcements could be read. The source layout may have changed.") }
        var seen = Set<String>()
        entries = entries.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }.filter { seen.insert($0.key).inserted }
        return ProductSnapshot(checkedAt: now, entries: Array(entries.prefix(60)))
    }
    public static func events(old: ProductSnapshot?, new: ProductSnapshot, source: ProductSource, accounts: [ConnectedAccount], now: Date = .now) -> [TimelineEvent] {
        let owns = !source.integrations.isDisjoint(with: Set(accounts.map(\.integrationID)))
        let relevance = owns ? "You track this provider. Check the source for eligible plans; availability on your account is not verified." : "Official provider update. Account eligibility is not verified."
        let previous = Dictionary((old?.entries ?? []).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        // Policy baselines are silent; initial dated news can be browsed without firing notifications.
        if source.format == .policy && old == nil { return [] }
        return new.entries.compactMap { entry in
            let before = previous[entry.key]
            guard before?.digest != entry.digest else { return nil }
            let revised = before != nil
            if let published = entry.publishedAt, !revised, published < now.addingTimeInterval(-14 * 86400) { return nil }
            var excerpt = entry.text
            var prior: String?
            if let before {
                let oldLines = Set(before.text.components(separatedBy: .newlines))
                let newLines = Set(entry.text.components(separatedBy: .newlines))
                let added = entry.text.components(separatedBy: .newlines).filter { !oldLines.contains($0) }
                let removed = before.text.components(separatedBy: .newlines).filter { !newLines.contains($0) }
                if added.isEmpty && removed.isEmpty { return nil } // Ordering/markup-only edit.
                excerpt = added.isEmpty ? "No replacement wording found in the watched sections. Review the source before drawing a conclusion." : added.joined(separator: "\n")
                prior = removed.isEmpty ? nil : removed.joined(separator: "\n")
            }
            let topic = topic(entry.title + " " + excerpt)
            var event = TimelineEvent(id: "product-\(source.id)-\(entry.key)-\(entry.digest)", date: revised || source.format == .policy ? now : entry.publishedAt ?? now,
                kind: source.format == .policy ? .policyChange : .productUpdate,
                title: source.format == .policy ? "\(source.name): wording changed" : (revised ? "Updated: " : "") + entry.title,
                detail: HTMLText.trimmed(excerpt, to: 260), source: source.pageURL, sourceName: source.name,
                important: old != nil && owns && topic != "Features & improvements")
            event.notice = ProductNotice(topic: topic, observedAt: now, publishedAt: entry.publishedAt,
                previousExcerpt: prior.map { String($0.prefix(4000)) }, excerpt: String(excerpt.prefix(6000)), relevance: relevance, evidence: "Official source · not account-confirmed")
            return event
        }
    }
}

@MainActor public extension AppStore {
    func setProductUpdates(_ enabled: Bool) throws { try change { $0.productUpdatesEnabled = enabled } }
    func markTimelineRead(now: Date = .now) throws { try change { $0.timelineReadAt = now } }
    func refreshProductUpdates(force: Bool = false, now: Date = .now) async -> [TimelineEvent] {
        guard state.productUpdatesEnabled != false, loadFailure == nil else { return [] }
        var events: [TimelineEvent] = []
        for source in ProductSource.all {
            guard state.productUpdatesEnabled != false else { break }
            let checked = state.productChecks?[source.id] ?? .distantPast
            guard force || now.timeIntervalSince(checked) >= 6 * 3600 else { continue }
            do {
                let next = try ProductUpdates.decode(await feedLoader(source.url), source: source, now: now)
                guard state.productUpdatesEnabled != false else { break }
                let incoming = ProductUpdates.events(old: state.productSnapshots?[source.id], new: next, source: source, accounts: state.accounts, now: now)
                try change { state in
                    var snapshots = state.productSnapshots ?? [:]; snapshots[source.id] = next; state.productSnapshots = snapshots
                    var checks = state.productChecks ?? [:]; checks[source.id] = now; state.productChecks = checks
                    var errors = state.productErrors ?? [:]; errors.removeValue(forKey: source.id); state.productErrors = errors
                    state.record(incoming)
                }
                events += incoming
            } catch {
                try? change { state in
                    var checks = state.productChecks ?? [:]; checks[source.id] = now; state.productChecks = checks
                    var errors = state.productErrors ?? [:]; errors[source.id] = "Could not read this source; the last successful snapshot is preserved."; state.productErrors = errors
                }
            }
        }
        return events
    }
}
