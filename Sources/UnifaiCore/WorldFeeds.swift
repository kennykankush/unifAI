import Foundation

/// A provider's public status page, read as RSS. Only feeds for providers you have wallets with are read.
public struct StatusFeed: Hashable, Sendable {
    public let id: String
    public let name: String
    public let url: URL
    public let integrations: Set<String>
    /// When set, only incidents mentioning one of these words for a wallet you have are kept.
    /// OpenAI's page covers many products and posts dozens of incidents a month.
    public var keywords: [String: [String]] = [:]

    public static let all: [StatusFeed] = [
        StatusFeed(id: "openai", name: "OpenAI", url: URL(string: "https://status.openai.com/history.rss")!,
                   integrations: ["codex", "openai-api", "chatgpt"],
                   keywords: ["codex": ["codex", "chatgpt", "login", "sign in", "sign-in"],
                              "chatgpt": ["chatgpt", "login", "sign in", "sign-in"],
                              "openai-api": ["api", "responses", "completions", "realtime", "batch", "files", "embeddings", "assistants", "fine-tuning", "platform"]]),
        StatusFeed(id: "anthropic", name: "Anthropic", url: URL(string: "https://status.claude.com/history.rss")!,
                   integrations: ["claude-subscription", "claude-api"]),
        StatusFeed(id: "azure", name: "Azure", url: URL(string: "https://azure.status.microsoft/en-us/status/feed/")!,
                   integrations: ["azure-subscription"]),
        StatusFeed(id: "deepseek", name: "DeepSeek", url: URL(string: "https://status.deepseek.com/history.rss")!,
                   integrations: ["deepseek"]),
    ]

    public static func relevant(to accounts: [ConnectedAccount]) -> [StatusFeed] {
        let owned = Set(accounts.map(\.integrationID))
        return all.filter { !$0.integrations.isDisjoint(with: owned) }
    }
}

public struct StatusFeedClient {
    private let session: URLSession
    public init(session: URLSession = BalanceClient.privateSession()) { self.session = session }

    public func fetch(_ feed: StatusFeed) async throws -> Data {
        var request = URLRequest(url: feed.url, timeoutInterval: 20)
        request.setValue("Unifai", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ConnectorError.invalidResponse }
        guard http.statusCode == 200 else { throw ConnectorError.unavailable(http.statusCode) }
        guard data.count < 2_000_000 else { throw ConnectorError.invalidResponse }
        return data
    }

    /// Incidents from the last `days` days as timeline events, newest first. With `integrations`, a feed's
    /// keywords keep only incidents about products you use.
    public static func events(_ data: Data, feed: StatusFeed, now: Date = .now, days: Double = 14, integrations: Set<String>? = nil) -> [TimelineEvent] {
        let words = integrations.map { owned in feed.keywords.filter { owned.contains($0.key) }.flatMap(\.value) } ?? []
        return RSS.items(data).compactMap { item in
            guard let date = item.date, date > now.addingTimeInterval(-days * 86400), !item.title.isEmpty else { return nil }
            let text = HTMLText.plain(item.description)
            if !words.isEmpty {
                let haystack = (item.title + " " + text).lowercased()
                guard words.contains(where: { haystack.contains($0) }) else { return nil }
            }
            let status = HTMLText.status(in: text)
            let body = HTMLText.trimmed(HTMLText.preferEnglish(HTMLText.latestUpdate(text)), to: 220)
            let key = item.guid ?? item.link?.absoluteString ?? item.title
            let link = item.link.flatMap { $0.scheme == "https" ? $0 : nil }
            return TimelineEvent(id: "status-\(feed.id)-\(key)", date: date, kind: .status,
                                 title: "\(feed.name): \(HTMLText.englishTitle(item.title))", detail: [status, body].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                                 source: link, sourceName: "\(feed.name) status", important: status.map { $0 != "Resolved" && $0 != "Completed" } ?? true)
        }
    }
}

/// Minimal RSS 2.0 reader.
enum RSS {
    struct Item { var title = ""; var link: URL?; var guid: String?; var date: Date?; var description = "" }

    static func items(_ data: Data) -> [Item] {
        let delegate = Reader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    static let dateFormats = ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz"]
    static func date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in dateFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) { return date }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: trimmed)
    }

    final class Reader: NSObject, XMLParserDelegate {
        var items: [Item] = []
        private var current: Item?
        private var text = ""
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "item" || name == "entry" { current = Item() }
            // Atom links carry the URL as an attribute.
            if name == "link", current != nil, let href = attributes["href"], attributes["rel"] == nil || attributes["rel"] == "alternate" {
                current?.link = URL(string: href)
            }
            text = ""
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, foundCDATA block: Data) { text += String(decoding: block, as: UTF8.self) }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard current != nil else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "title": if current?.title.isEmpty == true { current?.title = value }
            case "link": if !value.isEmpty { current?.link = URL(string: value) }
            case "guid", "id": if current?.guid == nil { current?.guid = value }
            case "pubDate", "published", "updated": if current?.date == nil { current?.date = RSS.date(value) }
            case "description", "summary", "content": if current?.description.isEmpty == true { current?.description = value }
            case "item", "entry": if let item = current { items.append(item) }; current = nil
            default: break
            }
            text = ""
        }
    }
}

enum HTMLText {
    /// Strips tags and decodes the common entities.
    static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"<br\s*/?>|</p>|</li>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&nbsp;", " "), ("&#xA;", " ")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    static func status(in text: String) -> String? {
        let pattern = #"(?i)\b(resolved|monitoring|identified|investigating|scheduled|in progress|completed|degraded performance|partial outage|major outage)\b"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return text[range].capitalized.replacingOccurrences(of: " Performance", with: " performance").replacingOccurrences(of: " Outage", with: " outage")
    }

    /// The newest update only, without its timestamp or repeated status word. Statuspage lists every
    /// update as "Oct 13, 18:00 UTC Resolved - text"; incident.io starts with "Status: Identified".
    static func latestUpdate(_ text: String) -> String {
        let stamp = #"[A-Z][a-z]{2} {1,2}\d{1,2}, \d{2}:\d{2} UTC"#
        var body = text.replacingOccurrences(of: #"(?i)^\s*status:\s*(resolved|monitoring|identified|investigating|in progress|scheduled|completed|postmortem)\s*"#, with: "", options: .regularExpression)
        body = body.replacingOccurrences(of: "^\\s*" + stamp + "\\s*", with: "", options: .regularExpression)
        body = body.replacingOccurrences(of: #"^(?i)(resolved|monitoring|identified|investigating|update|scheduled|in progress|completed)\s*-\s*"#, with: "", options: .regularExpression)
        if let next = body.range(of: stamp, options: .regularExpression) { body = String(body[..<next.lowerBound]) }
        return body.trimmingCharacters(in: .whitespaces)
    }

    static func hasCJK(_ text: String) -> Bool { text.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) } }

    /// Bilingual pages (DeepSeek) put English in full-width parentheses in titles.
    static func englishTitle(_ title: String) -> String {
        guard hasCJK(title), let open = title.firstIndex(of: "（"), let close = title.lastIndex(of: "）"), open < close else { return title }
        let inner = String(title[title.index(after: open)..<close])
        return hasCJK(inner) || inner.isEmpty ? title : inner
    }

    /// Drops Chinese or Japanese text when the same notice also has English.
    static func preferEnglish(_ text: String) -> String {
        guard hasCJK(text), text.filter({ $0.isASCII && $0.isLetter }).count >= 20 else { return text }
        let kept = String(String.UnicodeScalarView(text.unicodeScalars.filter { !((0x3000...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value)) }))
        return kept.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.:;)])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func trimmed(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        return (cut.range(of: " ", options: .backwards).map { String(cut[..<$0.lowerBound]) } ?? String(cut)) + "…"
    }
}

// MARK: - X

/// Reads recent posts from followed X accounts with the user's own app-only bearer token.
/// X bills reads per post, so polls ask only for posts newer than the last one seen.
public struct XClient {
    public static let postReadCost = Decimal(string: "0.005")!
    public static let userLookupCost = Decimal(string: "0.010")!
    private let session: URLSession
    public init(session: URLSession = BalanceClient.privateSession()) { self.session = session }

    public struct Post: Hashable {
        public var id: String; public var text: String; public var date: Date?
        public init(id: String, text: String, date: Date?) { self.id = id; self.text = text; self.date = date }
    }
    public struct Result {
        public var userID: String
        public var posts: [Post]
        public var lookups: Int
        public init(userID: String, posts: [Post], lookups: Int) { self.userID = userID; self.posts = posts; self.lookups = lookups }
    }

    public static func validHandle(_ input: String) -> String? {
        var handle = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://x.com/", "https://twitter.com/", "x.com/", "@"] where handle.lowercased().hasPrefix(prefix) { handle.removeFirst(prefix.count) }
        handle = String(handle.split(separator: "/").first ?? "")
        return handle.range(of: #"^[A-Za-z0-9_]{1,15}$"#, options: .regularExpression) != nil ? handle : nil
    }

    public func fetch(token: String, handle: String, userID: String?, sinceID: String?) async throws -> Result {
        var lookups = 0
        var id = userID
        if id == nil {
            let data = try await get("https://api.x.com/2/users/by/username/\(handle)", token: token)
            lookups = 1
            id = try Self.decodeUser(data)
        }
        guard let id else { throw ConnectorError.invalidResponse }
        var components = URLComponents(string: "https://api.x.com/2/users/\(id)/tweets")!
        // On the first read take five posts; later reads only what is new.
        components.queryItems = [URLQueryItem(name: "max_results", value: sinceID == nil ? "5" : "10"),
                                 URLQueryItem(name: "exclude", value: "replies,retweets"),
                                 URLQueryItem(name: "tweet.fields", value: "created_at")]
            + (sinceID.map { [URLQueryItem(name: "since_id", value: $0)] } ?? [])
        let data = try await get(components.url!.absoluteString, token: token)
        return Result(userID: id, posts: try Self.decodePosts(data), lookups: lookups)
    }

    private func get(_ link: String, token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: link)!, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ConnectorError.invalidResponse }
        switch http.statusCode {
        case 200: return data
        case 401, 403: throw ValidationError.message("X refused the bearer token. Check it in Settings and that your X developer account has credit.")
        case 402: throw ValidationError.message("X API credit is used up. Add credit in the X developer console.")
        case 429: throw ConnectorError.rateLimited
        default: throw ConnectorError.unavailable(http.statusCode)
        }
    }

    struct UserResponse: Decodable { struct User: Decodable { let id: String }; let data: User? }
    struct PostsResponse: Decodable {
        struct Item: Decodable { let id: String; let text: String; let created_at: String? }
        let data: [Item]?
    }

    static func decodeUser(_ data: Data) throws -> String {
        guard let user = try? JSONDecoder().decode(UserResponse.self, from: data).data,
              user.id.allSatisfy(\.isNumber) else { throw ValidationError.message("That X account was not found.") }
        return user.id
    }

    static func decodePosts(_ data: Data) throws -> [Post] {
        guard let response = try? JSONDecoder().decode(PostsResponse.self, from: data) else { throw ConnectorError.invalidResponse }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (response.data ?? []).filter { $0.id.allSatisfy(\.isNumber) }
            .map { Post(id: $0.id, text: $0.text, date: $0.created_at.flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }) }
    }

    /// Posts about usage resets or limits, the ones worth a notification.
    public static func mentionsReset(_ text: String) -> Bool {
        text.range(of: #"(?i)\b(reset|resetting|rate limits?|usage limits?|limits? (are|have been) (reset|lifted|raised|increased))\b"#, options: .regularExpression) != nil
    }

    public static func events(_ posts: [Post], handle: String, now: Date = .now) -> [TimelineEvent] {
        posts.map { post in
            let reset = mentionsReset(post.text)
            let category = ProductUpdates.topic(post.text)
            var event = TimelineEvent(id: "post-\(post.id)", date: post.date ?? now, kind: .post,
                                 title: reset ? "@\(handle) on limits and resets" : "@\(handle)",
                                 detail: HTMLText.plain(post.text), source: URL(string: "https://x.com/\(handle)/status/\(post.id)"),
                                 sourceName: "@\(handle)", important: reset || category != "Features & improvements")
            event.notice = ProductNotice(topic: category, observedAt: now, publishedAt: post.date, previousExcerpt: nil,
                excerpt: HTMLText.plain(post.text), relevance: "From an account you follow. Check the announcement's scope and eligibility.", evidence: "Social post · not account-confirmed")
            return event
        }
    }
}

// MARK: - Releases that matter

public enum ReleaseRelevance {
    /// Repositories followed automatically for a wallet, once.
    public static let walletRepositories: [String: String] = [
        "codex": "openai/codex",
        "claude-subscription": "anthropics/claude-code",
    ]

    static let keywords: [String: [String]] = [
        "codex": ["codex", "chatgpt", "gpt-"],
        "openai-api": ["openai", "gpt-"],
        "claude-subscription": ["claude", "anthropic", "opus", "sonnet"],
        "claude-api": ["claude", "anthropic", "opus", "sonnet"],
        "openrouter": ["openrouter"],
        "deepseek": ["deepseek"],
        "azure-subscription": ["azure"],
    ]

    /// Wallet names this release touches: it ships from a repository followed for a wallet, or mentions what you pay for.
    public static func wallets(for release: ReleaseItem, repository: String, accounts: [ConnectedAccount]) -> [String] {
        let text = "\(release.title) \(release.tag) \(release.summary ?? "")".lowercased()
        var names: [String] = []
        for account in accounts {
            let follows = walletRepositories[account.integrationID]?.caseInsensitiveCompare(repository) == .orderedSame
            let mentions = (keywords[account.integrationID] ?? []).contains { text.contains($0) }
            if follows || mentions {
                let name = Catalogue.integration(account.integrationID)?.name ?? account.label
                if !names.contains(name) { names.append(name) }
            }
        }
        return names
    }

    public static func summary(fromMarkdown body: String?) -> String? {
        guard let body, !body.isEmpty else { return nil }
        let lines = body.components(separatedBy: .newlines).map { line in
            line.replacingOccurrences(of: #"^\s*(#+|[-*+]|\d+\.)\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"[`*_]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty && !$0.lowercased().hasPrefix("full changelog") && !$0.hasPrefix("<!--") }
        let text = HTMLText.plain(lines.prefix(8).joined(separator: " · "))
        return text.isEmpty ? nil : HTMLText.trimmed(text, to: 280)
    }
}

// MARK: - AI news

/// Public feeds about AI products and research, read without an account.
public struct NewsFeed: Hashable, Sendable {
    public let id: String
    public let name: String
    public let url: URL
    public static let all: [NewsFeed] = [
        NewsFeed(id: "openai", name: "OpenAI News", url: URL(string: "https://openai.com/news/rss.xml")!),
        NewsFeed(id: "deepmind", name: "Google DeepMind", url: URL(string: "https://deepmind.google/blog/rss.xml")!),
        NewsFeed(id: "google-ai", name: "Google AI", url: URL(string: "https://blog.google/technology/ai/rss/")!),
        NewsFeed(id: "huggingface", name: "Hugging Face", url: URL(string: "https://huggingface.co/blog/feed.xml")!),
        NewsFeed(id: "simonw", name: "Simon Willison", url: URL(string: "https://simonwillison.net/atom/everything/")!),
    ]

    /// The newest posts from the last `days` days, at most `limit`.
    public static func events(_ data: Data, feed: NewsFeed, now: Date = .now, days: Double = 7, limit: Int = 4) -> [TimelineEvent] {
        RSS.items(data).compactMap { item -> TimelineEvent? in
            guard let date = item.date, date > now.addingTimeInterval(-days * 86400), date <= now.addingTimeInterval(3600), !item.title.isEmpty else { return nil }
            let key = item.guid ?? item.link?.absoluteString ?? item.title
            return TimelineEvent(id: "news-\(feed.id)-\(key)", date: date, kind: .news, title: HTMLText.plain(item.title),
                                 detail: HTMLText.trimmed(HTMLText.plain(item.description), to: 200),
                                 source: item.link.flatMap { $0.scheme == "https" ? $0 : nil }, sourceName: feed.name)
        }
        .sorted { $0.date > $1.date }.prefix(limit).map { $0 }
    }
}

// MARK: - New models

/// Models newly listed on OpenRouter, from its public model list (no key).
public enum NewModels {
    public static let url = URL(string: "https://openrouter.ai/api/v1/models")!

    /// OpenRouter author prefix for each wallet you pay, so models from your providers stand out.
    static let walletAuthors: [String: [String]] = [
        "codex": ["openai"], "openai-api": ["openai"], "claude-subscription": ["anthropic"], "claude-api": ["anthropic"],
        "deepseek": ["deepseek"], "kimi": ["moonshotai"], "openrouter": [],
    ]

    struct Listing: Decodable {
        struct Model: Decodable {
            struct Pricing: Decodable { let prompt: String?; let completion: String? }
            let id: String; let name: String; let created: Int?; let context_length: Int?; let pricing: Pricing?
        }
        let data: [Model]
    }

    public static func events(_ data: Data, accounts: [ConnectedAccount], now: Date = .now, days: Double = 14, limit: Int = 12) -> [TimelineEvent] {
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else { return [] }
        let yours = Set(accounts.flatMap { walletAuthors[$0.integrationID] ?? [] })
        return listing.data.compactMap { model -> TimelineEvent? in
            guard let created = model.created.map({ Date(timeIntervalSince1970: TimeInterval($0)) }), created > now.addingTimeInterval(-days * 86400),
                  model.id.range(of: #"^[a-z0-9._-]+/[A-Za-z0-9._:-]+$"#, options: .regularExpression) != nil else { return nil }
            let author = String(model.id.split(separator: "/").first ?? "")
            var facts: [String] = []
            if let context = model.context_length { facts.append(context >= 1000 ? "\(context / 1000)K context" : "\(context) context") }
            if let prompt = model.pricing?.prompt.flatMap(Double.init), let completion = model.pricing?.completion.flatMap(Double.init) {
                facts.append(prompt == 0 && completion == 0 ? "free" : String(format: "$%.2f in, $%.2f out per million tokens", prompt * 1_000_000, completion * 1_000_000))
            }
            return TimelineEvent(id: "model-\(model.id)", date: created, kind: .model, title: model.name, detail: facts.joined(separator: " · "),
                                 source: URL(string: "https://openrouter.ai/\(model.id)"), sourceName: "OpenRouter", important: yours.contains(author))
        }
        .sorted { $0.date > $1.date }.prefix(limit).map { $0 }
    }

    /// The OpenRouter author of a model event ("deepseek" for model-deepseek/deepseek-v4).
    public static func author(of event: TimelineEvent) -> String? {
        guard event.kind == .model, event.id.hasPrefix("model-") else { return nil }
        return event.id.dropFirst(6).split(separator: "/").first.map(String.init)
    }
}

/// Public feeds and lists fetched without credentials.
public struct FeedClient {
    private let session: URLSession
    public init(session: URLSession = BalanceClient.privateSession()) { self.session = session }
    public func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Unifai", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ConnectorError.invalidResponse }
        guard http.statusCode == 200 else { throw ConnectorError.unavailable(http.statusCode) }
        guard data.count < 4_000_000 else { throw ConnectorError.invalidResponse }
        return data
    }
}
