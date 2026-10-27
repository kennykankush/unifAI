import Foundation

public enum IntegrationCategory: String, CaseIterable, Identifiable {
    case providers = "Model APIs", subscriptions = "Subscriptions & tools", cloud = "Cloud & infrastructure", development = "Development", discovery = "News & discovery"
    public var id: String { rawValue }
}
public enum IntegrationStatus: String { case ready = "Ready to connect", manual = "Manual records", planned = "Planned" }

/// How a service charges, which decides how Unifai counts it.
public enum BillingModel: String, CaseIterable {
    /// Top up first, spend down (OpenRouter, DeepSeek, Claude API).
    case prepaid = "Prepaid credits"
    /// Fixed recurring charge (ChatGPT, Cursor, domains).
    case subscription = "Subscription"
    /// A plan with usage windows or allowances (Codex, Claude subscriptions).
    case allowance = "Plan with usage limits"
    /// Usage accrues and is invoiced after the period (Azure, AWS, Google Cloud).
    case payAsYouGo = "Pay as you go"
}
public enum RouteEvidence: String {
    case documented = "Official route documented", partial = "Partial coverage", reference = "Implementation reference", unverified = "Access unverified"
}
public struct Integration: Identifiable {
    public var id: String
    public var name: String
    public var category: IntegrationCategory
    public var status: IntegrationStatus
    public var evidence: RouteEvidence
    public var method: String
    public var capabilities: String
    public var limitation: String
    public var source: URL?
    /// Codex and Claude Code sign in through their own apps, so Unifai stores no credential for them.
    public var billing: BillingModel {
        switch id {
        case "openrouter", "deepseek", "claude-api", "openai-api", "kimi", "vercel-ai-gateway", "minimax", "zai", "dashscope": return .prepaid
        case "codex", "claude-subscription", "elevenlabs": return .allowance
        case "azure-subscription", "neon", "azure", "bedrock", "vertex", "aws", "gcp", "digitalocean", "hetzner", "railway", "fly", "render", "other-cloud",
             "groq", "mistral", "together", "fireworks", "replicate", "huggingface", "fal", "xai", "perplexity-api", "stability", "gemini-api":
            return .payAsYouGo
        default: return .subscription
        }
    }
    public var needsCredential: Bool { !["codex", "claude-subscription", "azure-subscription"].contains(id) }
    public var symbol: String {
        switch category {
        case .providers: return "cpu"
        case .subscriptions: return "person.crop.rectangle"
        case .cloud: return "cloud"
        case .development: return "chevron.left.forwardslash.chevron.right"
        case .discovery: return "newspaper"
        }
    }
}

public enum Catalogue {
    public static let integrations: [Integration] = {
        var items: [Integration] = [
            .init(id: "openrouter", name: "OpenRouter account", category: .providers, status: .ready, evidence: .documented,
                  method: "Management key · read-only requests", capabilities: "Account balance, reported credit purchases and consumption",
                  limitation: "Requires a management key with broad account authority. Unifai only reads credits. Credit totals do not establish cash payments or daily history.", source: URL(string: "https://openrouter.ai/docs/api/api-reference/credits/get-remaining-credits")),
            .init(id: "deepseek", name: "DeepSeek API", category: .providers, status: .ready, evidence: .documented,
                  method: "API key · read-only requests", capabilities: "Current balance, purchased and promotional components, per currency",
                  limitation: "This endpoint provides current balances. Historical consumption and payment history remain unavailable.", source: URL(string: "https://api-docs.deepseek.com/api/get-user-balance/")),
            .init(id: "claude-api", name: "Claude API / Console", category: .providers, status: .ready, evidence: .documented,
                  method: "Organization Admin key · read-only cost report", capabilities: "API spend for the last 30 days from the Cost API; import credit top-ups from receipts",
                  limitation: "Needs an Admin key (sk-ant-admin01-...), which Anthropic only offers to Console organizations, not individual accounts. Unifai only calls GET /v1/organizations/cost_report. Anthropic offers no remaining-credit endpoint, and Claude subscriptions are billed separately.", source: URL(string: "https://platform.claude.com/docs/en/manage-claude/usage-cost-api")),
            .init(id: "openai-api", name: "OpenAI API Platform", category: .providers, status: .ready, evidence: .documented,
                  method: "Organization Admin key · read-only costs", capabilities: "API spend per currency for the last 30 days, from the Costs API",
                  limitation: "Requires an organization Admin key, which has broad access; Unifai only sends GET /v1/organization/costs. API costs do not include ChatGPT subscription payments, and OpenAI offers no prepaid balance endpoint.", source: URL(string: "https://platform.openai.com/docs/api-reference/usage/costs")),
            .init(id: "claude-subscription", name: "Claude subscription / Code", category: .subscriptions, status: .ready, evidence: .documented,
                  method: "Local Claude Code app · your existing Claude sign-in", capabilities: "Claude plan (Pro, Max, Team) and sign-in status; record payments and renewals",
                  limitation: "Reads claude auth status from Claude Code on this Mac. Anthropic offers no public interface for subscription usage limits, so those stay in Claude Code's /usage; Claude Code's stored token is never read.", source: URL(string: "https://docs.anthropic.com/en/docs/claude-code/overview")),
            .init(id: "codex", name: "ChatGPT & Codex", category: .subscriptions, status: .ready, evidence: .documented,
                  method: "Local Codex app · your existing Codex sign-in", capabilities: "ChatGPT plan, Codex 5-hour and weekly limits with reset times, and Codex credits",
                  limitation: "Reads through the Codex CLI on this Mac (codex app-server), so install Codex and run codex login first. Unifai stores no OpenAI credential. Subscription payments still need manual records.", source: URL(string: "https://developers.openai.com/codex/app-server")),
            .init(id: "chatgpt", name: "ChatGPT subscription", category: .subscriptions, status: .manual, evidence: .unverified,
                  method: "Confirmed payments and renewal schedule", capabilities: "Record payments, refunds and expected renewal",
                  limitation: "OpenAI offers no API for consumer billing, so record payments here. For your live plan and Codex limits, connect ChatGPT & Codex. A plan shared with Codex is a single subscription expense.", source: nil),
            .init(id: "cursor", name: "Cursor", category: .subscriptions, status: .manual, evidence: .partial,
                  method: "Manual personal records; team API planned", capabilities: "Record payments and expected renewal",
                  limitation: "A team Admin API is documented. Personal billing and allowance access have not been established.", source: URL(string: "https://prod.cursor.com/docs/account/teams/admin-api")),
            .init(id: "gemini-api", name: "Gemini API / AI Studio", category: .providers, status: .planned, evidence: .partial,
                  method: "Cloud Billing / AI Studio route under investigation", capabilities: "Planned: project costs and credit tracking",
                  limitation: "AI Studio prepay balance and Cloud Billing are distinct views. Exact access routes remain unverified.", source: URL(string: "https://ai.google.dev/gemini-api/docs/billing")),
            .init(id: "github-releases", name: "GitHub public releases", category: .development, status: .ready, evidence: .documented,
                  method: "Public API · no credential", capabilities: "Recent releases in the Timeline, with release notes and which of your wallets they affect",
                  limitation: "Only public repositories. Checked every 30 minutes while Unifai runs, with caching, at most 10 watched repositories and a shared 20-request hourly budget. GitHub shares its unauthenticated limit across your IP.", source: URL(string: "https://docs.github.com/en/rest/releases/releases")),
            .init(id: "x-accounts", name: "X accounts", category: .discovery, status: .ready, evidence: .documented,
                  method: "Your X API bearer token, set in Settings", capabilities: "Posts from accounts you follow in the Timeline, with reset and limit announcements highlighted",
                  limitation: "X bills your developer account about US$0.005 per post read and US$0.01 per account lookup; Unifai reads only new posts every 30 minutes and shows the estimated cost. Lists and the For You feed are not supported.", source: URL(string: "https://docs.x.com/x-api/posts/timelines/introduction")),
            .init(id: "x-for-you", name: "X For You discovery", category: .discovery, status: .planned, evidence: .unverified,
                  method: "No supported equivalent established", capabilities: "Desired: personalized AI discovery",
                  limitation: "No route to the For You algorithm was established by the research. No browser session is read.", source: nil)
        ]
        let providers = [
            ("perplexity-api", "Perplexity API"), ("xai", "xAI / Grok API"), ("groq", "Groq"),
            ("mistral", "Mistral"), ("together", "Together AI"), ("fireworks", "Fireworks AI"),
            ("replicate", "Replicate"), ("huggingface", "Hugging Face"), ("fal", "fal"),
            ("stability", "Stability AI"), ("dashscope", "Alibaba / DashScope"),
            ("minimax", "MiniMax"), ("zai", "Z.ai"),
            ("azure", "Azure AI / Foundry (manual)"), ("bedrock", "AWS Bedrock"), ("vertex", "Google Vertex AI")
        ]
        items.append(.init(id: "kimi", name: "Kimi API (Moonshot)", category: .providers, status: .ready, evidence: .documented,
                           method: "API key · one read-only balance request", capabilities: "Available, cash and voucher balance in US dollars",
                           limitation: "Uses platform.kimi.ai keys; China platform keys are not accepted. No payment history, so record top-ups from receipts.",
                           source: URL(string: "https://platform.kimi.ai/docs/api/balance")))
        items.append(.init(id: "vercel-ai-gateway", name: "Vercel AI Gateway", category: .providers, status: .ready, evidence: .documented,
                           method: "AI Gateway API key · one read-only credits request", capabilities: "Remaining AI Gateway Credits and total used, in US dollars; detects later top-ups",
                           limitation: "Covers the whole Vercel team the key belongs to. The first reading proposes credits added minus the $5 free credit as an estimated top-up; confirm it against your receipt. There is no daily history. Vercel hosting invoices are separate; track them under Vercel.",
                           source: URL(string: "https://vercel.com/docs/ai-gateway/sdks-and-apis/rest-api#check-credit-balance")))
        items.append(.init(id: "elevenlabs", name: "ElevenLabs", category: .providers, status: .ready, evidence: .documented,
                           method: "API key · one read-only subscription request", capabilities: "Plan, characters used against the allowance, and when it resets",
                           limitation: "Shows usage, not money; record the subscription as a schedule so renewals count toward spend.",
                           source: URL(string: "https://elevenlabs.io/docs/api-reference/user/subscription/get")))
        let tools = [
            ("copilot", "GitHub Copilot"), ("gemini-consumer", "Gemini subscription"), ("gemini-cli", "Gemini CLI"),
            ("windsurf", "Windsurf"), ("opencode", "OpenCode"), ("cline", "Cline"), ("roo", "Roo Code"),
            ("continue", "Continue"), ("zed", "Zed"), ("kiro", "Kiro"), ("perplexity", "Perplexity subscription"),
            ("local", "Local inference"), ("custom", "Custom service")
        ]
        for (id, name) in providers + tools {
            items.append(.init(id: id, name: name, category: providers.contains(where: { $0.0 == id }) ? .providers : .subscriptions,
                               status: .manual, evidence: .unverified, method: "Manual confirmed records",
                               capabilities: "Record payments and expected subscription renewals",
                               limitation: "Automatic billing, balances and allowance access have not been verified or implemented. Local usage paid through another provider must not be counted again.", source: nil))
        }
        items.append(.init(id: "azure-subscription", name: "Azure subscriptions", category: .cloud, status: .ready, evidence: .documented,
                           method: "Local Azure CLI · your existing az login", capabilities: "Month-to-date spend per currency across enabled subscriptions, with the top services (VMs, storage, Foundry models)",
                           limitation: "Reads through the Azure CLI on this Mac (az rest to the Cost Management query API), so install it and run az login first. Unifai stores no Azure credential. Costs can lag by several hours; credits and invoices are not included.",
                           source: URL(string: "https://learn.microsoft.com/en-us/rest/api/cost-management/query/usage")))
        items.append(.init(id: "neon", name: "Neon Postgres", category: .cloud, status: .ready, evidence: .documented,
                           method: "Neon API key · read-only usage requests", capabilities: "Estimated month-to-date cost by line item (compute, storage, restore history, transfer, branches) and per day",
                           limitation: "Needs a usage-based plan (Launch or higher). Neon's API reports usage, not dollars, so Unifai prices it at Neon's published rates; your invoice is the final amount. A personal key must belong to one organization; otherwise use an organization key.",
                           source: URL(string: "https://neon.com/docs/guides/consumption-metrics")))
        let cloud = [("aws", "AWS"), ("gcp", "Google Cloud"), ("vercel", "Vercel"), ("cloudflare", "Cloudflare"), ("digitalocean", "DigitalOcean"),
                     ("hetzner", "Hetzner"), ("railway", "Railway"), ("fly", "Fly.io"), ("render", "Render"), ("supabase", "Supabase"),
                     ("netlify", "Netlify"), ("domains", "Domains & DNS"), ("other-cloud", "Other hosting or servers")]
        for (id, name) in cloud {
            items.append(.init(id: id, name: name, category: .cloud, status: .manual, evidence: .unverified, method: "Manual confirmed records and renewals",
                               capabilities: "Record invoices, top-ups and recurring plans; import from CSV",
                               limitation: "No live connector yet. Record invoices or import them, and add a schedule for fixed monthly plans.", source: nil))
        }
        items.append(.init(id: "status", name: "Provider status pages", category: .discovery, status: .ready, evidence: .documented,
                           method: "Public RSS feeds · no account", capabilities: "Incidents for OpenAI, Anthropic, Azure and DeepSeek in the Timeline, with each provider's current state",
                           limitation: "Automatic for the providers you have wallets with. OpenAI incidents are kept only when they mention products you use.", source: nil))
        items.append(.init(id: "ai-news", name: "AI news & blogs", category: .discovery, status: .ready, evidence: .documented,
                           method: "Public RSS and Atom feeds · no account", capabilities: "OpenAI News, Google DeepMind, Google AI, Hugging Face and Simon Willison's weblog in the Timeline",
                           limitation: "Anthropic publishes no news feed. Turn feeds off in Settings.", source: nil))
        items.append(.init(id: "new-models", name: "New models", category: .discovery, status: .ready, evidence: .documented,
                           method: "OpenRouter's public model list · no key", capabilities: "Models added in the last two weeks, with context length and price per million tokens",
                           limitation: "Covers models listed on OpenRouter; checked every six hours.", source: URL(string: "https://openrouter.ai/docs/api-reference/list-available-models")))
        let sources = [("papers", "Papers"), ("newsletters", "Newsletters, video & podcasts")]
        for (id, name) in sources {
            items.append(.init(id: id, name: name, category: .discovery, status: .planned, evidence: .unverified,
                               method: "Public feed or supported API, per source", capabilities: "Planned: source-linked updates",
                               limitation: "Source URLs, collection permissions and filters need verification. No feed collection is implemented yet.", source: nil))
        }
        items.append(.init(id: "github-private", name: "GitHub private releases", category: .development, status: .planned, evidence: .documented,
                           method: "Planned: repository Contents read permission", capabilities: "Planned: private release watching",
                           limitation: "Private repository credentials are not accepted by this build.", source: URL(string: "https://docs.github.com/en/rest/releases/releases")))
        items.append(.init(id: "github-stars", name: "GitHub stars & activity", category: .development, status: .planned, evidence: .partial,
                           method: "Planned: explicitly selected imports and event routes", capabilities: "Planned: seed a watchlist and select event types",
                           limitation: "Starring, following or watching a project on GitHub is never changed by Unifai.", source: URL(string: "https://docs.github.com/en/rest/activity/starring")))
        return items
    }()
    public static func integration(_ id: String) -> Integration? { integrations.first { $0.id == id } }
}
