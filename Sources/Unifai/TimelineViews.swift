import SwiftUI
import UnifaiCore

/// How each kind of timeline event looks: a logo where there is one, with a small badge for what happened.
enum EventStyle {
    static func badge(_ event: TimelineEvent) -> (symbol: String, tint: Color)? {
        switch event.kind {
        case .earlyReset: return ("arrow.counterclockwise", Palette.lime)
        case .reset: return ("arrow.clockwise", Palette.positive)
        case .limitReached: return ("gauge.with.dots.needle.100percent", Palette.negative)
        case .resetCredit: return ("gift.fill", Palette.lime)
        case .anomaly: return ("flame.fill", Palette.warning)
        case .recorded: return ("checkmark", Palette.accent)
        case .release: return nil
        case .status: return event.important ? ("exclamationmark", Palette.warning) : ("checkmark", Palette.positive)
        case .post: return event.important ? ("arrow.counterclockwise", Palette.lime) : nil
        case .model: return ("sparkles", event.important ? Palette.lime : Palette.accent)
        case .news: return nil
        case .productUpdate, .policyChange: return ("newspaper.fill", Palette.accent)
        }
    }

    /// Catalogue logo for an OpenRouter model author.
    static func modelLogo(_ author: String?) -> String? {
        switch author {
        case "openai": return "openai-api"
        case "anthropic": return "claude-api"
        case "deepseek": return "deepseek"
        case "google": return "gemini-api"
        case "x-ai": return "xai"
        case "mistralai": return "mistral"
        case "moonshotai": return "kimi"
        case "qwen": return "dashscope"
        case "minimax": return "minimax"
        case "z-ai": return "zai"
        case "perplexity": return "perplexity-api"
        default: return nil
        }
    }

    /// The logo shown for an event: the wallet's provider, the status page's provider or GitHub.
    static func logo(_ event: TimelineEvent, accountIntegration: String?) -> String? {
        if let accountIntegration { return accountIntegration }
        switch event.kind {
        case .release: return "github-releases"
        case .model: return modelLogo(NewModels.author(of: event))
        case .productUpdate, .policyChange:
            return event.sourceName.hasPrefix("Claude") ? "claude-subscription" : "codex"
        case .news:
            switch event.sourceName {
            case "OpenAI News": return "openai-api"
            case "Google DeepMind", "Google AI": return "gemini-api"
            case "Hugging Face": return "huggingface"
            default: return nil
            }
        case .status:
            let name = event.sourceName.lowercased()
            if name.hasPrefix("openai") { return "openai-api" }
            if name.hasPrefix("anthropic") { return "claude-api" }
            if name.hasPrefix("azure") { return "azure-subscription" }
            if name.hasPrefix("deepseek") { return "deepseek" }
            return nil
        default: return nil
        }
    }

    static func tag(_ event: TimelineEvent) -> Chip? {
        if let notice = event.notice { return Chip(text: notice.topic, tint: Palette.accentInk) }
        switch event.kind {
        case .earlyReset: return Chip(text: "Early reset", tint: Palette.lime, filled: true)
        case .resetCredit: return Chip(text: "Free reset", tint: Palette.lime, filled: true)
        case .anomaly: return Chip(text: "Cost spike", tint: Palette.warning)
        case .limitReached: return Chip(text: "Limit", tint: Palette.negative)
        case .release where event.important: return Chip(text: "Yours", tint: Palette.accentInk)
        case .post where event.important: return Chip(text: "Resets", tint: Palette.lime, filled: true)
        case .status where event.important: return Chip(text: "Ongoing", tint: Palette.warning)
        case .model where event.important: return Chip(text: "Your provider", tint: Palette.accentInk)
        default: return nil
        }
    }
}

struct EventIcon: View {
    let event: TimelineEvent
    let integrationID: String?
    var size: CGFloat = 42
    var body: some View {
        let logo = EventStyle.logo(event, accountIntegration: integrationID)
        ZStack(alignment: .bottomTrailing) {
            if event.kind == .post {
                Text("𝕏").font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.white)
                    .frame(width: size, height: size).background(Circle().fill(Palette.hex(0x15161B)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.12)))
            } else {
                LogoCircle(integrationID: logo, size: size, symbol: event.kind == .status ? "waveform.path.ecg" : event.kind == .news ? "newspaper.fill" : "sparkles")
            }
            if let badge = EventStyle.badge(event) {
                Image(systemName: badge.symbol).font(.system(size: size * 0.2, weight: .heavy))
                    .foregroundStyle(Palette.hex(0x15161B))
                    .frame(width: size * 0.42, height: size * 0.42)
                    .background(Circle().fill(badge.tint))
                    .overlay(Circle().strokeBorder(Palette.surface, lineWidth: 2))
                    .offset(x: 3, y: 3)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct EventRow: View {
    let event: TimelineEvent
    let integrationID: String?
    @State private var showingNotice = false
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            EventIcon(event: event, integrationID: integrationID)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(event.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    if let tag = EventStyle.tag(event) { tag }
                }
                if !event.detail.isEmpty {
                    Text(event.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let notice = event.notice {
                    HStack {
                        Text(notice.evidence).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        Button("Read details") { showingNotice = true }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accentInk)
                    }
                }
                Text("\(event.sourceName) · \(event.date.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let source = event.source {
                Link(destination: source) { Image(systemName: "arrow.up.right") }
                    .buttonStyle(IconButtonStyle()).help("Open source").accessibilityLabel("Open \(event.title)")
            }
        }
        .sheet(isPresented: $showingNotice) { ProductNoticeView(event: event) }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .background(RowHighlight())
        .accessibilityElement(children: .combine)
    }
}

/// Compact card for the Overview strip: fixed height, so long titles never stretch the row.
struct EventCard: View {
    let event: TimelineEvent
    let integrationID: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                EventIcon(event: event, integrationID: integrationID, size: 38)
                Spacer()
                if let tag = EventStyle.tag(event) { tag }
            }
            Text(event.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            Text("\(event.sourceName) · \(event.date.formatted(.relative(presentation: .named)))")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
        }
        .surface(padding: 16, radius: 20)
        .frame(height: 142)
    }
}

/// "Right now": where there is capacity to spend, the same ranking agents get from get_headroom.
struct HeadroomCard: View {
    let report: AgentReport.Headroom
    let advice: [(String, String)]
    var body: some View {
        ZStack(alignment: .topLeading) {
            MeshBackdrop(colors: [Palette.hex(0x0E3B33), Palette.hex(0x12715B), Palette.hex(0x6E8F1E)])
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        Circle().fill(Palette.lime).frame(width: 7, height: 7)
                        Text("RIGHT NOW").font(.system(size: 11, weight: .bold)).tracking(1.2).opacity(0.85)
                    }
                    Text(headline).font(.system(size: 28, weight: .heavy)).tracking(-0.8).lineLimit(1).minimumScaleFactor(0.7)
                    Text(detail).font(.system(size: 13, weight: .medium)).opacity(0.85)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    ForEach(Array(advice.prefix(2).enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 6) {
                            Image(systemName: "lightbulb.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.lime)
                            Text("\(item.0): \(item.1)").font(.system(size: 12, weight: .medium)).lineLimit(1)
                        }
                        .opacity(0.92)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(report.ranked.prefix(3).enumerated()), id: \.offset) { index, item in
                        row(item, rank: index + 1)
                    }
                    if report.ranked.isEmpty {
                        Text("Connect a live wallet to see where you have room.").font(.system(size: 12, weight: .medium)).opacity(0.8)
                    }
                }
                .frame(width: 330)
            }
            .padding(24)
        }
        .foregroundStyle(.white)
        .frame(height: 196)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
    }

    private var best: AgentReport.HeadroomItem? { report.ranked.first(where: \.usableNow) }

    private var headline: String {
        if let best { return "Start with \(best.provider)" }
        return report.ranked.isEmpty ? "No live readings yet" : "Everything is used up"
    }

    private var detail: String {
        if let best { return "\(best.label) · \(best.summary.prefix(1).uppercased() + best.summary.dropFirst())" }
        if let next = report.ranked.first { return "\(next.provider): \(next.summary)" }
        return "Connect or refresh a live wallet to see where you have room."
    }

    private func row(_ item: AgentReport.HeadroomItem, rank: Int) -> some View {
        HStack(spacing: 12) {
            LogoCircle(integrationID: item.providerID, size: 34, onColor: true)
                .overlay(alignment: .topLeading) {
                    Text("\(rank)").font(.system(size: 9, weight: .heavy)).foregroundStyle(Palette.hex(0x15161B))
                        .frame(width: 15, height: 15).background(Circle().fill(item.usableNow ? Palette.lime : Color.white.opacity(0.6)))
                        .offset(x: -3, y: -3)
                }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.provider).font(.system(size: 13, weight: .bold)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(headline(item)).font(.system(size: 12, weight: .bold)).monospacedDigit().lineLimit(1)
                }
                if let remaining = item.remainingPercent {
                    UsageMeter(used: Double(remaining) / 100, tint: remaining > 0 ? Palette.lime : Palette.hex(0xFFD1D1))
                } else {
                    Text("\(item.label) · \(item.kind == "payAsYouGo" ? "billed per use" : "prepaid credit")").font(.system(size: 11, weight: .medium)).opacity(0.7).lineLimit(1)
                }
            }
        }
        .help(item.summary)
    }

    private func headline(_ item: AgentReport.HeadroomItem) -> String {
        if let remaining = item.remainingPercent {
            if remaining <= 0, let reset = item.nextReset { return "Resets \(reset.formatted(.relative(presentation: .named)))" }
            return "\(remaining)% left"
        }
        if let credit = item.creditRemaining.first { return Money(Decimal(string: credit.amount) ?? 0, credit.currency).plainText }
        if let spent = item.spentThisMonth.first { return Money(Decimal(string: spent.amount) ?? 0, spent.currency).plainText }
        return ""
    }
}
