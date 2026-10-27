import SwiftUI
import AppKit
import Charts
import UnifaiCore

// Design language: a dark, solid shell with a vivid violet accent and a lime highlight.
// Colour is the content: a mesh-gradient hero, brand-coloured wallet cards with logo
// watermarks, logo circles in every row, bold tight numerals and charts built on real data.

// MARK: - Palette

enum Palette {
    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    static func hex(_ hex: UInt32) -> Color { Color(nsColor: rgb(hex)) }
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    static let canvasNS = dynamic(rgb(0xF4F4F6), rgb(0x09090A))
    static let canvas = Color(nsColor: canvasNS)
    static let bar = Color(nsColor: dynamic(rgb(0xFFFFFF), rgb(0x050506)))
    static let surface = Color(nsColor: dynamic(rgb(0xFFFFFF), rgb(0x141416)))
    static let raised = Color(nsColor: dynamic(rgb(0xEDEDF1), rgb(0x1F1F23)))
    static let border = Color(nsColor: dynamic(rgb(0x000000, 0.07), rgb(0xFFFFFF, 0.07)))
    static let accent = hex(0x7357FF)
    static let accentDeep = hex(0x5B3CF0)
    static let lime = hex(0xC8F542)
    static let positive = Color(nsColor: dynamic(rgb(0x2E8B1F), rgb(0xC8F542)))
    static let negative = hex(0xFF5C5C)
    static let warning = hex(0xFFA53D)

    static let hero = [hex(0x3D1FD8), hex(0x8A3BFF), hex(0xFF6A88)]

    /// Three-stop brand gradients for wallet and plan cards. Mid-dark stops keep white text legible.
    static func brand(_ integrationID: String?) -> [Color] { brandHex(integrationID).map(hex) }

    static func brandHex(_ integrationID: String?) -> [UInt32] {
        switch integrationID {
        case "openrouter": return [0x4B3BE8, 0x7C4DFF, 0xC064F0]
        case "deepseek": return [0x1E4FE0, 0x3D7BFF, 0x5EA0FF]
        case "openai-api", "chatgpt", "codex": return [0x0A6E55, 0x12A07C, 0x3CCB9F]
        case "claude-api", "claude-subscription": return [0xA8401F, 0xD8693F, 0xEE9466]
        case "gemini-api", "gemini-consumer", "gemini-cli", "vertex": return [0x2F5BD8, 0x7A5CE8, 0xC77ADB]
        case "azure-subscription": return [0x0B4FB3, 0x1C7BE0, 0x3FA2F2]
        case "neon": return [0x0A4D3C, 0x0F9A72, 0x2FD9A0]
        case "aws": return [0x9A5A0C, 0xD18419, 0xEFA53A]
        case "gcp": return [0x1F5BC6, 0x2F8E5A, 0xE0A93A]
        case "cursor", "github-releases", "github-private", "github-stars", "copilot", "x-accounts", "x-for-you", "xai", "vercel", "vercel-ai-gateway":
            return [0x23242B, 0x383A45, 0x5A5D6B]
        case nil: return [0x2C2D36, 0x41434F, 0x6A6D7C]
        default:
            let sets: [[UInt32]] = [
                [0xB8205E, 0xE2457F, 0xF27BA6],
                [0xA9600A, 0xD48820, 0xE9A843],
                [0x0D6F70, 0x1E9B98, 0x45C2B9],
                [0x3F6E12, 0x66A12A, 0x93C94A]
            ]
            let hash = integrationID!.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
            return sets[hash % sets.count]
        }
    }
    static func series(_ integrationID: String?) -> Color { brand(integrationID)[1] }
}

// MARK: - Logos

enum Logos {
    /// Provider logos from LobeHub Icons (MIT), bundled in Resources/Logos.
    /// Names ending in "-color" render in brand colour; others are monochrome templates.
    static func name(for integrationID: String) -> String? {
        switch integrationID {
        case "openrouter": return "openrouter-color"
        case "deepseek": return "deepseek-color"
        case "claude-api": return "anthropic"
        case "claude-subscription": return "claude-color"
        case "openai-api", "chatgpt": return "openai"
        case "codex": return "codex-color"
        case "cursor": return "cursor"
        case "gemini-api", "gemini-consumer", "gemini-cli": return "gemini-color"
        case "github-releases", "github-private", "github-stars": return "github"
        case "copilot": return "githubcopilot"
        case "perplexity-api", "perplexity": return "perplexity-color"
        case "xai": return "xai"
        case "groq": return "groq"
        case "mistral": return "mistral-color"
        case "together": return "together-color"
        case "fireworks": return "fireworks-color"
        case "replicate": return "replicate"
        case "huggingface": return "huggingface-color"
        case "fal": return "fal-color"
        case "elevenlabs": return "elevenlabs"
        case "stability": return "stability-color"
        case "dashscope": return "alibabacloud-color"
        case "kimi": return "kimi-color"
        case "minimax": return "minimax-color"
        case "zai": return "zai"
        case "azure": return "azureai-color"
        case "bedrock": return "bedrock-color"
        case "vertex": return "vertexai-color"
        case "windsurf": return "windsurf"
        case "opencode": return "opencode"
        case "cline": return "cline"
        case "roo": return "roocode"
        case "kiro": return "kiro-color"
        case "local": return "ollama"
        case "azure-subscription": return "azure-color"
        case "aws": return "aws-color"
        case "gcp": return "googlecloud-color"
        case "vercel", "vercel-ai-gateway": return "vercel"
        case "cloudflare": return "cloudflare-color"
        case "digitalocean": return "digitalocean"
        case "railway": return "railway"
        default: return nil
        }
    }

    static func fallbackSymbol(for integrationID: String) -> String {
        switch integrationID {
        case "x-accounts", "x-for-you": return "at"
        case "rss": return "dot.radiowaves.up.forward"
        case "status": return "waveform.path.ecg"
        case "papers": return "doc.text"
        case "newsletters": return "envelope"
        case "zed", "continue": return "chevron.left.forwardslash.chevron.right"
        case "custom": return "plus.square.dashed"
        case "hetzner", "other-cloud": return "server.rack"
        case "fly", "render", "netlify": return "cloud"
        case "supabase", "neon": return "cylinder.split.1x2"
        case "domains": return "globe"
        default: return "sparkles"
        }
    }
}

@MainActor enum LogoCache {
    private static var images: [String: NSImage] = [:]
    static func image(_ name: String) -> NSImage? {
        if let cached = images[name] { return cached }
        // Bundled at Contents/Resources/Logos by scripts/assemble-app.sh; missing logos fall back to symbols.
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Logos"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = !name.hasSuffix("-color")
        images[name] = image
        return image
    }
}

struct ProviderLogo: View {
    let integrationID: String
    var size: CGFloat = 22
    /// Colour for monochrome logos and fallback symbols.
    var ink: Color = .primary
    var body: some View {
        Group {
            if let name = Logos.name(for: integrationID), let image = LogoCache.image(name) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).foregroundStyle(ink)
            } else {
                Image(systemName: Logos.fallbackSymbol(for: integrationID)).resizable().aspectRatio(contentMode: .fit)
                    .fontWeight(.semibold).foregroundStyle(ink).padding(size * 0.08)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Logo inside a circle, as used in transaction rows and on cards.
struct LogoCircle: View {
    let integrationID: String?
    var size: CGFloat = 38
    var symbol: String = "creditcard"
    var onColor = false
    var body: some View {
        ZStack {
            Circle().fill(onColor ? Color.white : Palette.raised)
            if let integrationID {
                ProviderLogo(integrationID: integrationID, size: size * 0.52, ink: onColor ? Palette.hex(0x15161B) : .primary)
            } else {
                Image(systemName: symbol).font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(onColor ? Palette.hex(0x15161B) : .secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Overlapping stack of logo circles.
struct LogoStack: View {
    let ids: [String]
    var size: CGFloat = 28
    var body: some View {
        HStack(spacing: -size * 0.32) {
            ForEach(Array(ids.prefix(5).enumerated()), id: \.offset) { _, id in
                LogoCircle(integrationID: id, size: size, onColor: true)
                    .overlay(Circle().strokeBorder(Palette.surface, lineWidth: 2))
            }
        }
    }
}

// MARK: - Money

struct MoneyText: View {
    let money: Money
    var size: CGFloat = 28
    var weight: Font.Weight = .bold
    var prefix: String = ""
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size > 24 ? 6 : 4) {
            Text(prefix + money.amountText)
                .font(.system(size: size, weight: weight))
                .tracking(size > 24 ? -size * 0.03 : 0)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(money.currency)
                .font(.system(size: max(10, size * 0.42), weight: .semibold))
                .opacity(0.55)
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(prefix.isEmpty ? money.formatted : "\(prefix == "+" ? "plus" : "minus") \(money.formatted)")
    }
}

// MARK: - Surfaces

struct MeshBackdrop: View {
    let colors: [Color]
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            ZStack {
                LinearGradient(colors: [colors[0], colors[1]], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(colors[2]).frame(width: w * 0.85, height: w * 0.85).position(x: w * 0.95, y: h * 0.95).blur(radius: 55).opacity(0.9)
                Circle().fill(colors[1]).frame(width: w * 0.6, height: w * 0.6).position(x: w * 0.55, y: h * 0.1).blur(radius: 50).opacity(0.8)
                Circle().fill(colors[0]).frame(width: w * 0.55, height: w * 0.55).position(x: 0, y: h).blur(radius: 50).opacity(0.85)
                Circle().fill(Color.white).frame(width: w * 0.3, height: w * 0.3).position(x: w * 0.85, y: h * 0.25).blur(radius: 60).opacity(0.18)
            }
            .drawingGroup()
            .overlay(Grain())
        }
        // The blurred blobs extend past the card; clipping hides them but does not stop them
        // from catching clicks meant for neighbouring controls.
        .allowsHitTesting(false)
    }
}

/// Film grain over gradients, the texture that keeps large colour fields from looking flat.
struct Grain: View {
    var opacity: Double = 0.16
    var body: some View {
        if let tile = GrainTile.image {
            Image(nsImage: tile).resizable(resizingMode: .tile)
                .blendMode(.overlay).opacity(opacity)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

@MainActor enum GrainTile {
    static let image: NSImage? = {
        let size = 160
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32),
              let data = rep.bitmapData else { return nil }
        var generator = SystemRandomNumberGenerator()
        for index in 0..<(size * size) {
            let value = UInt8.random(in: 0...255, using: &generator)
            data[index * 4] = value; data[index * 4 + 1] = value; data[index * 4 + 2] = value; data[index * 4 + 3] = 255
        }
        let image = NSImage(size: NSSize(width: size / 2, height: size / 2))
        image.addRepresentation(rep)
        return image
    }()
}

extension View {
    func surface(padding: CGFloat = 20, radius: CGFloat = 20) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
    }
}

struct SectionHeading<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 17, weight: .bold)).tracking(-0.2).lineLimit(1).fixedSize()
            if let subtitle { Text(subtitle).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary) }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension SectionHeading where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) { self.init(title: title, subtitle: subtitle) { EmptyView() } }
}

struct SeeAllButton: View {
    let action: () -> Void
    var title = "See All"
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) { Text(title); Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)) }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(Palette.raised))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Controls

/// Premium material for buttons and selections: vertical gradient, soft top sheen,
/// a hairline edge that is bright at the top and fades out, a dark outer ring and a tight shadow.
struct Gloss<S: InsettableShape>: View {
    let shape: S
    let colors: [Color]
    var highlight: Double = 0.3
    var ring: Double = 0.45
    var glow: Color = .clear
    var body: some View {
        shape.fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .overlay(shape.fill(LinearGradient(stops: [.init(color: .white.opacity(highlight * 0.45), location: 0), .init(color: .white.opacity(0), location: 0.55)], startPoint: .top, endPoint: .bottom)))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(highlight), .white.opacity(highlight * 0.15)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .background(shape.inset(by: -0.5).stroke(Color.black.opacity(ring), lineWidth: 1))
            .shadow(color: .black.opacity(ring * 0.8), radius: 1.5, y: 1)
            .shadow(color: glow, radius: 10, y: 5)
    }
}

extension Palette {
    static let primaryGloss = [hex(0x7766FF), hex(0x5640E8), hex(0x4430CC)]
    static let limeGloss = [hex(0xE2FC86), hex(0xC4EE48), hex(0xA9D62E)]
    static let neutralGloss = [Color(nsColor: dynamic(rgb(0xFFFFFF), rgb(0x2A2B33))), Color(nsColor: dynamic(rgb(0xF4F4F8), rgb(0x1F2026)))]
    static let accentInk = Color(nsColor: dynamic(rgb(0x5640E8), rgb(0xA99BFF)))
}

struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, glass, lime, white }
    var kind: Kind = .secondary
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        PillLabel(configuration: configuration, kind: kind, compact: compact)
    }
    private struct PillLabel: View {
        let configuration: Configuration
        let kind: Kind
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: compact ? 12 : 13, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, compact ? 12 : 16)
                .frame(height: compact ? 28 : 36)
                .foregroundStyle(foreground)
                .shadow(color: kind == .primary ? .black.opacity(0.25) : .clear, radius: 0, y: -0.5)
                .background(background)
                .brightness(hovering && !configuration.isPressed ? 0.04 : 0)
                .scaleEffect(configuration.isPressed ? 0.975 : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.14), value: hovering)
        }
        private var foreground: Color {
            switch kind {
            case .primary, .glass: return .white
            case .lime: return Palette.hex(0x1A2104)
            case .white: return Palette.hex(0x0B0B0C)
            case .secondary: return .primary
            }
        }
        @ViewBuilder private var background: some View {
            switch kind {
            case .primary: Gloss(shape: Capsule(), colors: Palette.primaryGloss, highlight: 0.32, ring: 0.5, glow: Palette.accent.opacity(hovering ? 0.3 : 0.18))
            case .lime: Gloss(shape: Capsule(), colors: Palette.limeGloss, highlight: 0.6, ring: 0.4)
            case .glass: Capsule().fill(Color.white.opacity(hovering ? 0.24 : 0.16)).overlay(Capsule().strokeBorder(Color.white.opacity(0.22)))
            case .secondary: Gloss(shape: Capsule(), colors: Palette.neutralGloss, highlight: 0.09, ring: 0.35).overlay(Capsule().strokeBorder(Palette.border))
            case .white: Gloss(shape: Capsule(), colors: [Palette.hex(0xFFFFFF), Palette.hex(0xE9E9EC)], highlight: 0.9, ring: 0.5)
            }
        }
    }
}

struct Chip: View {
    let text: String
    var tint: Color = .secondary
    var symbol: String?
    var filled = false
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 8).frame(height: 22)
        .foregroundStyle(filled ? Palette.hex(0x15161B) : tint)
        .background(Capsule().fill(filled ? tint : tint.opacity(0.16)))
        .fixedSize()
    }
}

/// White-on-glass chip for use on gradient cards.
struct GlassChip: View {
    let text: String
    var symbol: String?
    var dot: Color?
    var body: some View {
        HStack(spacing: 5) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9).frame(height: 24)
        .background(Capsule().fill(Color.white.opacity(0.2)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18)))
        .fixedSize()
    }
}

struct IconButtonStyle: ButtonStyle {
    var onColor = false
    func makeBody(configuration: Configuration) -> some View {
        IconLabel(configuration: configuration, onColor: onColor)
    }
    private struct IconLabel: View {
        let configuration: Configuration
        let onColor: Bool
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(onColor ? Color.white : (hovering ? Color.primary : Color.secondary))
                .frame(width: 30, height: 30)
                .background(Circle().fill(onColor ? Color.white.opacity(hovering ? 0.3 : 0.18) : (hovering ? Palette.raised : Palette.raised.opacity(0.6))))
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// Capsule segmented control with a sliding selection.
struct SegmentedPills<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    @Namespace private var namespace
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { withAnimation(.snappy(duration: 0.25)) { selection = option } } label: {
                    Text(label(option))
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 14).frame(height: 30)
                        .background {
                            if selected {
                                Capsule().fill(Palette.surface)
                                    .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
                                    .matchedGeometryEffect(id: "segment", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Palette.raised))
        .fixedSize()
    }
}

/// Compact dropdown for currency or range choices.
struct PillMenu<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    var onColor = false
    let label: (Value) -> String
    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in Button(label(option)) { selection = option } }
        } label: {
            HStack(spacing: 5) {
                Text(label(selection)).font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .heavy))
            }
            .foregroundStyle(onColor ? Color.white : Color.primary)
            .padding(.horizontal, 11).frame(height: 28)
            .background(Capsule().fill(onColor ? Color.white.opacity(0.2) : Palette.raised))
            .overlay(Capsule().strokeBorder(onColor ? Color.white.opacity(0.2) : Palette.border))
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

struct InlineNotice: View {
    let text: String
    var symbol: String = "exclamationmark.triangle.fill"
    var tint: Color = Palette.negative
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.12)))
    }
}

struct UsageMeter: View {
    let used: Double
    var tint: Color = .white
    var track: Color = Color.white.opacity(0.25)
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(tint).frame(width: max(4, proxy.size.width * min(1, max(0, used))))
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Wallet card

struct WalletCard: View {
    let account: ConnectedAccount
    let paid: [Money]
    var height: CGFloat = 178
    var body: some View {
        let colors = Palette.brand(account.integrationID)
        let name = Catalogue.integration(account.integrationID)?.name ?? account.integrationID
        ZStack(alignment: .topLeading) {
            MeshBackdrop(colors: colors)
            ProviderLogo(integrationID: account.integrationID, size: 150, ink: .white)
                .opacity(0.12)
                .rotationEffect(.degrees(-14))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(x: 34, y: 44)
                .allowsHitTesting(false)
            LinearGradient(colors: [.clear, .black.opacity(0.22)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    LogoCircle(integrationID: account.integrationID, size: 36, onColor: true)
                    Spacer()
                    status
                }
                Spacer(minLength: 8)
                Text(name).font(.system(size: 15, weight: .bold)).lineLimit(1).truncationMode(.tail)
                Text([account.label, account.snapshot?.plan ?? (account.billingScope.isEmpty ? nil : account.billingScope)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12, weight: .medium)).opacity(0.75).lineLimit(1)
                    .padding(.bottom, 10)
                // Fixed slot: a taller amount block (meters, two windows) must not push the name up.
                amount.frame(height: 50, alignment: .bottomLeading)
            }
            .padding(18)
        }
        .foregroundStyle(.white)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: colors[1].opacity(0.28), radius: 16, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 6) {
            if let credits = account.snapshot?.resetCredits, !credits.isEmpty, account.lastError == nil {
                GlassChip(text: credits.count == 1 ? "Free reset" : "\(credits.count) free resets", symbol: "gift.fill")
            }
            if account.lastError == nil, account.snapshot?.anomalies?.isEmpty == false {
                GlassChip(text: "Cost spike", dot: Palette.warning)
            }
            health
        }
    }

    @ViewBuilder private var health: some View {
        if account.lastError != nil { GlassChip(text: "Failed", dot: Palette.negative) }
        else if account.snapshot?.limitReached == true { GlassChip(text: "Limit reached", dot: Palette.negative) }
        else if account.mode == .manual { GlassChip(text: "Manual", symbol: "square.and.pencil") }
        else if account.snapshot == nil { GlassChip(text: "No reading", dot: .white.opacity(0.6)) }
        else if account.snapshot!.isStale() { GlassChip(text: "Stale", dot: Palette.warning) }
        else { GlassChip(text: "Live", dot: Palette.lime) }
    }

    @ViewBuilder private var amount: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let snapshot = account.snapshot, let balance = snapshot.balances.first {
                    Text(balance.currency == "CREDITS" ? "Codex credits" : "Available").font(.system(size: 11, weight: .medium)).opacity(0.7)
                    MoneyText(money: balance, size: 24)
                } else if let snapshot = account.snapshot, let spent = snapshot.reportedConsumption.first {
                    Text(Catalogue.integration(account.integrationID)?.billing == .payAsYouGo ? "Usage \((snapshot.consumptionPeriod ?? "so far").lowercased())" : "Spent, \((snapshot.consumptionPeriod ?? "reported").lowercased())")
                        .font(.system(size: 11, weight: .medium)).opacity(0.7)
                    MoneyText(money: spent, size: 24)
                } else if let plan = account.snapshot?.plan {
                    Text("Plan").font(.system(size: 11, weight: .medium)).opacity(0.7)
                    Text(plan).font(.system(size: 20, weight: .bold)).tracking(-0.4)
                } else if let first = paid.first {
                    Text("Paid").font(.system(size: 11, weight: .medium)).opacity(0.7)
                    MoneyText(money: first, size: 24)
                } else {
                    Text(account.mode == .manual ? "Records" : "Balance").font(.system(size: 11, weight: .medium)).opacity(0.7)
                    Text(account.mode == .manual ? "No payments" : "Refresh to read").font(.system(size: 17, weight: .bold))
                }
            }
            Spacer()
            if let windows = account.snapshot?.allowances, !windows.isEmpty {
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(windows.prefix(2)) { window in
                        HStack(spacing: 6) {
                            Text(Self.shortName(window)).font(.system(size: 10, weight: .semibold)).opacity(0.75)
                            UsageMeter(used: Double(window.usedPercent) / 100, tint: window.usedPercent >= 100 ? Palette.hex(0xFFD1D1) : .white).frame(width: 54)
                            Text("\(window.usedPercent)%").font(.system(size: 11, weight: .bold)).monospacedDigit().frame(width: 34, alignment: .trailing)
                        }
                    }
                }
            } else if let snapshot = account.snapshot, let used = Self.usedFraction(snapshot) {
                VStack(alignment: .trailing, spacing: 5) {
                    Text("\(Int((used * 100).rounded()))% used").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    UsageMeter(used: used).frame(width: 74)
                }
            }
        }
    }

    static func shortName(_ window: AllowanceWindow) -> String {
        switch window.windowMinutes {
        case 300: return "5h"
        case 10080: return "Week"
        default: return window.name.replacingOccurrences(of: " window", with: "")
        }
    }

    /// Consumed share of purchased credit, when the provider reports both in one currency.
    static func usedFraction(_ snapshot: BalanceSnapshot) -> Double? {
        guard let used = snapshot.reportedConsumption.first,
              let purchased = snapshot.details.first(where: { $0.label.localizedCaseInsensitiveContains("purchased") && $0.value.currency == used.currency }),
              purchased.value.amount > 0 else { return nil }
        return NSDecimalNumber(decimal: used.amount / purchased.value.amount).doubleValue
    }
}

// MARK: - Chart data

enum SpendSeries {
    struct Point: Identifiable { let date: Date; let total: Double; var id: Date { date } }
    struct Slice: Identifiable { let name: String; let integrationID: String?; let amount: Double; var id: String { name } }
    struct Month: Identifiable { let month: Date; let integrationID: String?; let name: String; let amount: Double; var id: String { "\(month.timeIntervalSince1970)-\(name)" } }

    static func currencies(_ payments: [PaymentRecord]) -> [String] {
        let counts = Dictionary(grouping: payments, by: { $0.money.currency }).mapValues(\.count)
        return counts.keys.sorted { (counts[$0]!, $1) > (counts[$1]!, $0) }
    }

    static func signed(_ record: PaymentRecord) -> Double {
        let value = NSDecimalNumber(decimal: record.money.amount).doubleValue
        return record.kind == .refund ? -value : value
    }

    /// Running total of money paid in one currency, starting from zero at the coverage start.
    static func cumulative(_ payments: [PaymentRecord], currency: String, start: Date?) -> [Point] {
        let records = payments.filter { $0.money.currency == currency && $0.paidAt <= .now }.sorted { $0.paidAt < $1.paidAt }
        guard let first = records.first else { return [] }
        // One point per day: several payments at the same moment would otherwise share an x value,
        // and Swift Charts stacks area marks that share one.
        let calendar = Calendar.current
        var total = 0.0
        var points = [Point(date: calendar.startOfDay(for: min(start ?? first.paidAt, first.paidAt)).addingTimeInterval(-86400), total: 0)]
        for record in records {
            total += signed(record)
            let day = calendar.startOfDay(for: record.paidAt)
            if let last = points.last, last.date == day { points[points.count - 1] = Point(date: day, total: total) }
            else { points.append(Point(date: day, total: total)) }
        }
        if let last = points.last, last.date < calendar.startOfDay(for: .now) { points.append(Point(date: calendar.startOfDay(for: .now), total: total)) }
        return points
    }

    static func paidThisMonth(_ payments: [PaymentRecord], currency: String) -> Double {
        guard let start = Calendar.current.dateInterval(of: .month, for: .now)?.start else { return 0 }
        return payments.filter { $0.money.currency == currency && $0.paidAt >= start && $0.paidAt <= .now }.map(signed).reduce(0, +)
    }

    static func byProvider(_ payments: [PaymentRecord], accounts: [ConnectedAccount], currency: String) -> [Slice] {
        var sums: [String: (String?, Double)] = [:]
        for record in payments where record.money.currency == currency {
            let account = accounts.first { $0.id == record.accountID }
            let name = account.map { Catalogue.integration($0.integrationID)?.name ?? $0.integrationID } ?? "Unassigned"
            sums[name, default: (account?.integrationID, 0)].1 += signed(record)
        }
        return sums.filter { $0.value.1 > 0 }.map { Slice(name: $0.key, integrationID: $0.value.0, amount: $0.value.1) }.sorted { $0.amount > $1.amount }
    }

    static func monthly(_ payments: [PaymentRecord], accounts: [ConnectedAccount], currency: String, months: Int = 6) -> [Month] {
        let calendar = Calendar.current
        guard let thisMonth = calendar.dateInterval(of: .month, for: .now)?.start else { return [] }
        let starts = (0..<months).reversed().compactMap { calendar.date(byAdding: .month, value: -$0, to: thisMonth) }
        var result: [Month] = []
        for start in starts {
            guard let end = calendar.date(byAdding: .month, value: 1, to: start) else { continue }
            let inMonth = payments.filter { $0.money.currency == currency && $0.paidAt >= start && $0.paidAt < end }
            let grouped = Dictionary(grouping: inMonth) { record in accounts.first { $0.id == record.accountID }?.integrationID ?? "" }
            if grouped.isEmpty { result.append(Month(month: start, integrationID: nil, name: "None", amount: 0)) }
            for (id, records) in grouped {
                let name = id.isEmpty ? "Unassigned" : (Catalogue.integration(id)?.name ?? id)
                result.append(Month(month: start, integrationID: id.isEmpty ? nil : id, name: name, amount: max(0, records.map(signed).reduce(0, +))))
            }
        }
        return result
    }
}

// MARK: - Charts

/// Minimal white sparkline for use on gradient cards.
struct Sparkline: View {
    let points: [SpendSeries.Point]
    var body: some View {
        Chart(points) { point in
            AreaMark(x: .value("Date", point.date), y: .value("Total", point.total))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Date", point.date), y: .value("Total", point.total))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.white)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .accessibilityHidden(true)
    }
}

struct SpendAreaChart: View {
    let points: [SpendSeries.Point]
    let currency: String
    var body: some View {
        Chart(points) { point in
            AreaMark(x: .value("Date", point.date), y: .value(currency, point.total), stacking: .unstacked)
                .interpolationMethod(.monotone)
                .foregroundStyle(LinearGradient(stops: [.init(color: Palette.hex(0x8A3BFF).opacity(0.75), location: 0),
                                                        .init(color: Palette.hex(0xFF6A88).opacity(0.35), location: 0.55),
                                                        .init(color: Palette.hex(0xFF6A88).opacity(0), location: 1)],
                                                startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Date", point.date), y: .value(currency, point.total))
                .interpolationMethod(.monotone)
                .foregroundStyle(LinearGradient(colors: [Palette.accent, Palette.hex(0xFF6A88)], startPoint: .leading, endPoint: .trailing))
                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
            if point.id == points.last?.id {
                PointMark(x: .value("Date", point.date), y: .value(currency, point.total))
                    .foregroundStyle(Palette.hex(0xFF6A88)).symbolSize(70)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4])).foregroundStyle(Palette.border)
                AxisValueLabel().font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Cumulative money paid in \(currency)")
    }
}

struct MonthlyBarsChart: View {
    let months: [SpendSeries.Month]
    let currency: String
    var body: some View {
        Chart(months) { item in
            BarMark(x: .value("Month", item.month, unit: .month), y: .value(currency, item.amount), width: .ratio(0.45))
                .foregroundStyle(Palette.series(item.integrationID).gradient)
                .cornerRadius(6)
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4])).foregroundStyle(Palette.border)
                AxisValueLabel().font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated), centered: true).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Money paid per month in \(currency)")
    }
}

struct ProviderDonut: View {
    let slices: [SpendSeries.Slice]
    let currency: String
    var body: some View {
        let total = slices.map(\.amount).reduce(0, +)
        VStack(spacing: 18) {
            Chart(slices) { slice in
                SectorMark(angle: .value(currency, slice.amount), innerRadius: .ratio(0.7), angularInset: 2.5)
                    .cornerRadius(5)
                    .foregroundStyle(Palette.series(slice.integrationID).gradient)
            }
            .chartBackground { _ in
                VStack(spacing: 2) {
                    Text("Total").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Text(Money(Decimal(total), currency).amountText).font(.system(size: 20, weight: .bold)).monospacedDigit().tracking(-0.4)
                    Text(currency).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 156, height: 156)
            VStack(spacing: 10) {
                ForEach(slices) { slice in
                    HStack(spacing: 10) {
                        Circle().fill(Palette.series(slice.integrationID)).frame(width: 9, height: 9)
                        Text(slice.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(total > 0 ? "\(Int((slice.amount / total * 100).rounded()))%" : "").font(.system(size: 12, weight: .bold)).monospacedDigit()
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - App icon

struct AppMark: View {
    var size: CGFloat = 28
    var body: some View {
        Gloss(shape: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous), colors: Palette.primaryGloss, highlight: 0.38, ring: 0.5)
            .overlay {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct AppIconArtwork: View {
    var body: some View {
        ZStack {
            MeshBackdrop(colors: Palette.hero)
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 440, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 24, y: 14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 230, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 230, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 6))
        .padding(100)
        .frame(width: 1024, height: 1024)
    }
    @MainActor static func render() -> NSImage? {
        let renderer = ImageRenderer(content: AppIconArtwork())
        renderer.scale = 1
        return renderer.nsImage
    }
}

// MARK: - Window

/// Makes the main window a single solid surface: transparent title bar over our own header,
/// draggable from empty areas, opaque background, and traffic lights centred in the header.
// MARK: - Floating bar

/// Geometry of the floating top bar: a capsule inset from the window edges.
enum FloatingBar {
    static let height: CGFloat = 56
    static let inset: CGFloat = 10
    static let sideInset: CGFloat = 12
    /// Space the bar takes at the top of each page.
    static let reserved: CGFloat = inset + height + 8
}

extension View {
    /// Liquid Glass on macOS 26 and later; a frosted capsule with a light rim before that.
    @ViewBuilder func floatingGlass() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
                .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        } else {
            self.background(Capsule().fill(.ultraThinMaterial))
                .background(Capsule().fill(Palette.bar.opacity(0.55)))
                .overlay(Capsule().strokeBorder(LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        }
    }
}

struct WindowConfigurator: NSViewRepresentable {
    var headerHeight: CGFloat = 64
    var trafficLightsX: CGFloat = 20
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window, coordinator: context.coordinator) }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { DispatchQueue.main.async { configure(view.window, coordinator: context.coordinator) } }
    func makeCoordinator() -> TrafficLights { TrafficLights(headerHeight: headerHeight, leading: trafficLightsX) }
    private func configure(_ window: NSWindow?, coordinator: TrafficLights) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        // Dragging is limited to the header (WindowDragArea). Whole-window background dragging made
        // macOS treat clicks inside scrolling content as drags, which swallowed button presses.
        window.isMovableByWindowBackground = false
        window.isOpaque = true
        window.backgroundColor = Palette.canvasNS
        window.toolbar = nil
        coordinator.attach(to: window)
    }
}

/// Title-bar behaviour for the custom header: drag to move the window, double-click to zoom
/// (or minimise, following the user's Dock setting).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            // The close, minimise and zoom buttons are moved down into the floating bar, below the
            // strip AppKit hit-tests for them, so their clicks arrive here. Hand them over.
            if let button = Self.windowButton(at: event, in: window) {
                button.mouseDown(with: event)
                return
            }
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                if action == "Minimize" { window?.performMiniaturize(nil) } else if action != "None" { window?.performZoom(nil) }
            } else {
                window?.performDrag(with: event)
            }
        }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
}

extension WindowDragArea.DragView {
    static func windowButton(at event: NSEvent, in window: NSWindow?) -> NSButton? {
        guard let window else { return nil }
        return [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .first { !$0.isHidden && $0.isEnabled && $0.bounds.insetBy(dx: -2, dy: -2).contains($0.convert(event.locationInWindow, from: nil)) }
    }
}

/// Re-centres the close, minimise and zoom buttons in a taller custom header.
/// AppKit lays them out again on resize and full-screen changes, so this re-applies after each.
@MainActor final class TrafficLights: NSObject {
    let headerHeight: CGFloat
    let leading: CGFloat
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    init(headerHeight: CGFloat, leading: CGFloat = 20) { self.headerHeight = headerHeight; self.leading = leading }
    func attach(to window: NSWindow) {
        if self.window !== window {
            self.window = window
            observers.forEach(NotificationCenter.default.removeObserver)
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                                              NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.layout() }
                }
            }
        }
        layout()
    }
    func layout() {
        guard let window, !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let mini = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let titlebar = close.superview else { return }
        let buttonHeight = close.frame.height
        let offset = (headerHeight - titlebar.frame.height) / 2
        let y = (titlebar.frame.height - buttonHeight) / 2 - offset
        for (index, button) in [close, mini, zoom].enumerated() {
            button.setFrameOrigin(NSPoint(x: leading + CGFloat(index) * 20, y: y))
        }
    }
}

/// AppKit's spinner. It animates on its own layer, so a refresh in progress does not make SwiftUI
/// re-lay out the page every frame the way an animated SwiftUI view would.
struct Spinner: NSViewRepresentable {
    var size: NSControl.ControlSize = .mini
    func makeNSView(context: Context) -> NSProgressIndicator {
        let view = NSProgressIndicator()
        view.style = .spinning
        view.controlSize = size
        view.isIndeterminate = true
        view.usesThreadedAnimation = true
        view.startAnimation(nil)
        return view
    }
    func updateNSView(_ view: NSProgressIndicator, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSProgressIndicator, context: Context) -> CGSize? {
        size == .mini ? CGSize(width: 10, height: 10) : CGSize(width: 16, height: 16)
    }
}
