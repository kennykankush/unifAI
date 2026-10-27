import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UnifaiCore

enum Destination: String, CaseIterable, Identifiable {
    case today = "Today", accounts = "Accounts", payments = "Payments", subscriptions = "Subscriptions", timeline = "Timeline", catalogue = "Catalogue"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "Overview"
        case .accounts: return "Wallets"
        default: return rawValue
        }
    }
    var symbol: String {
        switch self {
        case .today: return "square.grid.2x2.fill"
        case .accounts: return "wallet.pass.fill"
        case .payments: return "arrow.left.arrow.right"
        case .subscriptions: return "calendar"
        case .timeline: return "waveform.path.ecg"
        case .catalogue: return "square.stack.3d.up.fill"
        }
    }
}

enum Editor: Identifiable {
    case account(Integration, ConnectedAccount?), payment(PaymentRecord?), subscription(SubscriptionSchedule?), repository, coverage, settings, wallet(UUID), breakdown(Bool, String), backups
    var id: String {
        switch self {
        case .wallet(let id): return "wallet-\(id)"
        case .breakdown(let month, let currency): return "breakdown-\(month)-\(currency)"
        case .backups: return "backups"
        case .account(let integration, let account): return "account-\(integration.id)-\(account?.id.uuidString ?? "new")"
        case .payment(let record): return "payment-\(record?.id.uuidString ?? "new")"
        case .subscription(let record): return "subscription-\(record?.id.uuidString ?? "new")"
        case .repository: return "repository"
        case .coverage: return "coverage"
        case .settings: return "settings"
        }
    }
}

struct MainView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    let fixtureMode: Bool
    @State private var destination: Destination = AppRuntime.initialDestination ?? .today
    @State private var search = ""
    @State private var editor: Editor?
    @State private var category: IntegrationCategory?
    @State private var removal: Removal?
    @State private var chartCurrency = ""
    @State private var chartMode = "Cumulative"
    @State private var copiedSetup = false
    @State private var signingIn: Set<UUID> = []
    @State private var infoAccount: UUID?
    @State private var timelineFilter = "All"
    @State private var paymentFilter = "All"
    @State private var copiedRequest = false
    @FocusState private var searchFocused: Bool
    @State private var searchActive = false
    @Namespace private var navNamespace
    struct Removal: Identifiable { let id = UUID(); let title: String; let action: () throws -> Void }

    var body: some View {
        // Pages scroll under the floating bar, so the glass has colour to refract.
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = store.loadFailure {
                        InlineNotice(text: error)
                        Button("Review Local Backups") { editor = .backups }.padding(.bottom, 18)
                    }
                    page
                    footer
                }
                .padding(.horizontal, 40).padding(.top, 30).padding(.bottom, 28)
                .frame(maxWidth: 1240, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .contentMargins(.top, FloatingBar.reserved, for: .scrollContent)
            .contentMargins(.top, FloatingBar.reserved - 4, for: .scrollIndicators)
            .defaultScrollAnchor(AppRuntime.initialScroll ?? .top)
            .id(destination)
            .transition(.identity)
            .background(Palette.canvas)
            // Soft edge: content fades as it slides under the bar instead of colliding with it.
            // Solid above the bar so nothing peeks through the gap; a soft fade below it.
            LinearGradient(stops: [.init(color: Palette.canvas, location: 0), .init(color: Palette.canvas, location: 0.16),
                                   .init(color: Palette.canvas.opacity(0.7), location: 0.6), .init(color: Palette.canvas.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: FloatingBar.reserved + 18)
                .allowsHitTesting(false)
            topBar
        }
        .background(Palette.canvas)
        .background(WindowConfigurator(headerHeight: FloatingBar.inset * 2 + FloatingBar.height, trafficLightsX: FloatingBar.sideInset + 20))
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: destination) { _, _ in search = "" }
        .task {
            // Record renewals that fell due while the app was closed, then check every 30 minutes.
            while !Task.isCancelled {
                announce(store.recordDueRenewals())
                announce(store.closePayAsYouGoPeriods())
                await store.refreshRatesIfNeeded()
                await store.refreshStaleAccounts()
                store.followWalletRepositories()
                await store.refreshDueRepositories()
                await store.refreshTimeline()
                Notifier.shared.evaluate(store)
                try? await Task.sleep(for: .seconds(1800))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            announce(store.recordDueRenewals()); announce(store.closePayAsYouGoPeriods())
        }
        .onChange(of: store.state) { _, _ in Notifier.shared.evaluate(store) }
        .onAppear {
            AppRuntime.openMain = { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            AppRuntime.openSettings = { editor = .settings }
            AppRuntime.navigate = { destination = $0 }
            if let wallet = AppRuntime.initialWallet { AppRuntime.initialWallet = nil; editor = .wallet(wallet) }
            if AppRuntime.channel != "release", let index = CommandLine.arguments.firstIndex(of: "--test-breakdown"),
               CommandLine.arguments.indices.contains(index + 1) {
                editor = .breakdown(CommandLine.arguments[index + 1] == "month", activeCurrency)
            }
            AppRuntime.scheduleTestClick()
        }
        .sheet(item: $editor) { item in
            switch item {
            case .account(let integration, let account): AccountEditor(integration: integration, account: account)
            case .payment(let record): PaymentEditor(record: record)
            case .subscription(let schedule): SubscriptionEditor(schedule: schedule)
            case .repository: RepositoryEditor()
            case .coverage: CoverageEditor()
            case .settings: SettingsEditor()
            case .wallet(let id): WalletDetail(accountID: id)
            case .breakdown(let month, let currency): SpendingBreakdownView(monthOnly: month, currency: currency)
            case .backups: BackupsView()
            }
        }
        .alert("Unifai", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("OK", role: .cancel) { store.notice = nil }
        } message: { Text(store.notice ?? "") }
        .alert(item: $removal) { item in
            Alert(title: Text(item.title), message: Text("This removes the local record from Unifai."),
                  primaryButton: .destructive(Text("Remove"), action: { perform(item.action) }), secondaryButton: .cancel())
        }
    }

    @ViewBuilder private var page: some View {
        switch destination {
        case .today: overview
        case .accounts: wallets
        case .payments: payments
        case .subscriptions: subscriptions
        case .catalogue: catalogue
        case .timeline: timeline
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            topBarContent(compact: false)
            topBarContent(compact: true)
        }
        // The window buttons sit inside the bar's left end.
        .padding(.leading, 82).padding(.trailing, 8)
        .frame(height: FloatingBar.height)
        .background(WindowDragArea().clipShape(Capsule()))
        .floatingGlass()
        .padding(.top, FloatingBar.inset).padding(.horizontal, FloatingBar.sideInset)
    }

    private func topBarContent(compact: Bool) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                AppMark(size: 30)
                Text("Unifai.").font(.system(size: 19, weight: .semibold)).tracking(-0.6)
                if fixtureMode { Chip(text: "Demo", tint: Palette.warning, symbol: "testtube.2") }
                else if AppRuntime.channel == "dev" { Chip(text: "Dev", tint: Palette.accentInk, symbol: "hammer.fill") }
            }
            .fixedSize()
            Spacer(minLength: compact ? 12 : 24)
            HStack(spacing: compact ? 0 : 4) {
                ForEach(Destination.allCases) { navItem($0, compact: compact) }
            }
            .fixedSize()
            Spacer(minLength: compact ? 12 : 24)
            HStack(spacing: 10) {
                agentButton(compact: compact)
                primaryAction
            }
            .fixedSize()
        }
    }

    private func navItem(_ item: Destination, compact: Bool) -> some View {
        let selected = destination == item
        let signal = navSignal(item)
        return Button { withAnimation(.snappy(duration: 0.28)) { destination = item } } label: {
            HStack(spacing: 6) {
                Text(item.title)
                    .font(.system(size: 14, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.72))
                if let signal {
                    Circle().fill(signal).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, compact ? 12 : 18).frame(height: 40)
            .background {
                if selected {
                    Capsule().fill(Color.primary.opacity(0.1))
                        .overlay(Capsule().strokeBorder(LinearGradient(colors: [Color.primary.opacity(0.1), .clear], startPoint: .top, endPoint: .bottom)))
                        .matchedGeometryEffect(id: "nav", in: navNamespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title + (signal == nil ? "" : ", needs attention"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A small dot only where something needs action: failed or stale wallets, renewals within a week.
    private func navSignal(_ item: Destination) -> Color? {
        switch item {
        case .accounts: return store.state.accounts.contains(where: needsAttention) ? Palette.warning : nil
        case .subscriptions: return store.state.subscriptions.contains { daysUntil($0.nextRenewal) <= 7 } ? Palette.lime : nil
        case .timeline: return (store.state.events ?? []).contains { $0.important && $0.kind != .release && $0.date > .now.addingTimeInterval(-86400) } ? Palette.lime : nil
        default: return nil
        }
    }

    /// Setup line for the MCP server shipped inside this app bundle (or a local release build of it).
    private var mcpCommand: String? {
        let bundled = Bundle.main.url(forAuxiliaryExecutable: "unifai-mcp")
        let local = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("release/unifai-mcp")
        guard let binary = [bundled, local].compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return nil }
        let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Unifai", isDirectory: true)
        let directory = store.repository.directory.standardizedFileURL
        let extra = directory == defaultDirectory.standardizedFileURL ? "" : " --data-directory \"\(directory.path)\""
        let name = AppRuntime.channel == "release" ? "unifai" : "unifai-\(AppRuntime.channel)"
        return "claude mcp add --scope user \(name) -- \"\(binary.path)\"\(extra)"
    }

    private func agentButton(compact: Bool) -> some View {
        Button {
            guard let command = mcpCommand else {
                store.notice = "Build the MCP server first with scripts/build-mcp.sh, then copy the setup command from here."
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            withAnimation { copiedSetup = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { copiedSetup = false } }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: copiedSetup ? "checkmark" : "sparkles").font(.system(size: 12, weight: .bold))
                if !compact { Text(copiedSetup ? "Command copied" : "Agent access") }
            }
        }
        .buttonStyle(PillButtonStyle(kind: .white))
        .accessibilityLabel(copiedSetup ? "Command copied" : "Agent access")
        .help(mcpCommand.map { "Copy the MCP setup command so coding agents can read balances and spend (read-only):\n\($0)" } ?? "Build the MCP server with scripts/build-mcp.sh")
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: fixtureMode ? "testtube.2" : "lock.fill")
            Text(fixtureMode ? "Synthetic workspace. Network requests are disabled and no real account data is shown." : "Stored on this Mac. Credentials stay in Keychain.")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(fixtureMode ? AnyShapeStyle(Palette.warning.opacity(0.9)) : AnyShapeStyle(.tertiary))
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            // Kept out of the key-view loop until requested, so macOS cannot auto-focus it on window activation.
            TextField(searchPrompt, text: $search).textFieldStyle(.plain).font(.system(size: 13)).focused($searchFocused)
                .disabled(!searchActive && search.isEmpty)
            if search.isEmpty {
                Text("⌘F").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            } else {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14).frame(width: 240, height: 38)
        .background(Capsule().fill(Palette.surface))
        .overlay(Capsule().strokeBorder(searchFocused ? Palette.accent.opacity(0.7) : Palette.border, lineWidth: searchFocused ? 1.5 : 1))
        .overlay {
            if !searchActive && search.isEmpty {
                Color.clear.contentShape(Capsule()).onTapGesture(perform: activateSearch)
            }
        }
        .background { Button("", action: activateSearch).keyboardShortcut("f").hidden() }
        .onChange(of: searchFocused) { _, focused in if !focused && search.isEmpty { searchActive = false } }
    }

    private func activateSearch() {
        searchActive = true
        DispatchQueue.main.async { searchFocused = true }
    }

    // MARK: Helpers

    private var searchPrompt: String {
        switch destination {
        case .catalogue: return "Search services"
        case .timeline: return "Search timeline"
        case .payments: return "Search payments"
        default: return "Search"
        }
    }
    private func matches(_ strings: String...) -> Bool { search.isEmpty || strings.contains { $0.localizedCaseInsensitiveContains(search) } }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { store.notice = error.localizedDescription } }
    private func integrationName(_ account: ConnectedAccount) -> String { Catalogue.integration(account.integrationID)?.name ?? account.integrationID }
    private func accountName(_ id: UUID?) -> String {
        guard let id, let account = store.state.accounts.first(where: { $0.id == id }) else { return "Unassigned" }
        return "\(integrationName(account)) · \(account.label)"
    }
    private func account(_ id: UUID?) -> ConnectedAccount? { id.flatMap { id in store.state.accounts.first { $0.id == id } } }
    private func needsAttention(_ account: ConnectedAccount) -> Bool { account.lastError != nil || account.snapshot?.isStale() == true }
    private func daysUntil(_ date: Date) -> Int {
        Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: Calendar.current.startOfDay(for: date)).day ?? 0
    }
    private func relativeDays(_ days: Int) -> String {
        switch days {
        case ..<0: return "\(-days) day\(days == -1 ? "" : "s") overdue"
        case 0: return "Due today"
        case 1: return "Tomorrow"
        default: return "In \(days) days"
        }
    }
    private func paidTotals(for account: ConnectedAccount) -> [Money] { Ledger.paidTotals(store.state.payments.filter { $0.accountID == account.id }) }
    /// Payments feeding spending views: converted into the display currency when combining.
    private var spendPayments: [PaymentRecord] {
        guard let target = store.state.displayCurrency, let rates = store.rates else { return store.state.payments }
        return store.state.payments(in: target, rates: rates).converted
    }
    private var unconvertedPayments: [PaymentRecord] {
        guard let target = store.state.displayCurrency, let rates = store.rates else { return [] }
        return store.state.payments(in: target, rates: rates).unconverted
    }
    private var combining: Bool { store.state.displayCurrency != nil && store.rates != nil }
    private var defaultDisplayCurrency: String {
        let currencies = SpendSeries.currencies(store.state.payments)
        if let local = Locale.current.currency?.identifier, currencies.contains(local) { return local }
        return currencies.first ?? "USD"
    }
    private var chartCurrencies: [String] { combining ? [store.state.displayCurrency!] : SpendSeries.currencies(store.state.payments) }
    private var activeCurrency: String { chartCurrencies.contains(chartCurrency) ? chartCurrency : (chartCurrencies.first ?? "USD") }
    private var currencyBinding: Binding<String> { Binding(get: { activeCurrency }, set: { chartCurrency = $0 }) }

    /// Currency control for spending views: combine everything into one currency, or show one currency at a time.
    @ViewBuilder private func currencyControl(onColor: Bool, offerCombine: Bool = true) -> some View {
        let currencies = SpendSeries.currencies(store.state.payments)
        if let target = store.state.displayCurrency {
            PillMenu(options: currencies.map { Optional($0) } + [nil],
                     selection: Binding(get: { Optional(target) }, set: { value in Task { await store.setDisplayCurrency(value) } }),
                     onColor: onColor) { $0.map { "All in \($0)" } ?? "Each currency separately" }
                .help("Spending converted at European Central Bank reference rates on each payment date. Recorded amounts are unchanged.")
        } else if currencies.count > 1 && !offerCombine {
            PillMenu(options: currencies, selection: currencyBinding, onColor: onColor) { $0 }
        } else if currencies.count > 1 {
            HStack(spacing: 6) {
                PillMenu(options: currencies, selection: currencyBinding, onColor: onColor) { $0 }
                Button { Task { await store.setDisplayCurrency(defaultDisplayCurrency) } } label: { Label("Combine", systemImage: "arrow.triangle.merge") }
                    .buttonStyle(PillButtonStyle(kind: onColor ? .glass : .secondary, compact: true))
                    .help("Show all spending in \(defaultDisplayCurrency), converted at ECB reference rates on each payment date")
            }
        } else if onColor, let only = currencies.first {
            GlassChip(text: only)
        }
    }

    private var conversionCaption: String? {
        guard let target = store.state.displayCurrency else { return nil }
        if store.rates == nil { return store.refreshingRates ? "Downloading exchange rates..." : nil }
        let others = Set(store.state.payments.map(\.money.currency)).subtracting([target]).sorted()
        var text = others.isEmpty ? "All payments in \(target)" : "\(others.joined(separator: ", ")) converted to \(target) at ECB rates on each payment date, approximate"
        let skipped = unconvertedPayments.count
        if skipped > 0 { text += ". \(skipped) payment\(skipped == 1 ? "" : "s") in other units not included" }
        return text
    }

    private func refreshAll() {
        let ids = store.state.accounts.filter { $0.mode == .live && ($0.lastAttempt.map { Date.now.timeIntervalSince($0) >= 60 } ?? true) }.map(\.id)
        if ids.isEmpty { store.notice = "Balances were refreshed less than a minute ago. Try again shortly."; return }
        Task { for id in ids { await store.refreshAccount(id) } }
    }

    private func pageHeader(_ title: String, _ subtitle: String, chip: Chip? = nil) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text(title).font(.system(size: 30, weight: .bold)).tracking(-0.9)
                    if let chip { chip }
                }
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            searchField
        }
        .padding(.bottom, 26)
    }

    @ViewBuilder private var primaryAction: some View {
        switch destination {
        case .today, .accounts:
            Button { destination = .catalogue } label: { Label("Add Wallet", systemImage: "plus") }
                .buttonStyle(PillButtonStyle(kind: .lime)).keyboardShortcut("n")
        case .payments:
            Button { editor = .payment(nil) } label: { Label("Add Payment", systemImage: "plus") }
                .buttonStyle(PillButtonStyle(kind: .lime)).keyboardShortcut("n")
        case .subscriptions:
            Button { editor = .subscription(nil) } label: { Label("Add Subscription", systemImage: "plus") }
                .buttonStyle(PillButtonStyle(kind: .lime)).keyboardShortcut("n")
        case .timeline:
            Button { editor = .repository } label: { Label("Follow Repository", systemImage: "plus") }
                .buttonStyle(PillButtonStyle(kind: .lime)).keyboardShortcut("n")
        case .catalogue:
            EmptyView()
        }
    }

    /// Unifai's own empty state. Replaces ContentUnavailableView, whose hit area covered
    /// buttons placed below it, so the optional action lives inside the component instead.
    private func emptyState(_ title: String, _ description: String, _ symbol: String,
                            action: String? = nil, perform: @escaping () -> Void = {}) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(Palette.accentInk)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Palette.accent.opacity(0.14)))
                .overlay(Circle().strokeBorder(Palette.accent.opacity(0.2)))
            Text(title).font(.system(size: 17, weight: .bold)).tracking(-0.2)
            Text(description).font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420).fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action, action: perform).buttonStyle(PillButtonStyle(kind: .primary)).padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func moreMenu<Content: View>(_ label: String, onColor: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        Menu(content: content) {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold))
                .foregroundStyle(onColor ? Color.white : Color.secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(onColor ? Color.white.opacity(0.18) : Palette.raised.opacity(0.6)))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(label)
    }

    // MARK: Overview

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 26) {
            pageHeader(greeting, Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()) + ". Here is where your AI money stands.")
                .padding(.bottom, -26)
            if store.state.accounts.isEmpty && store.state.payments.isEmpty && store.state.repositories.isEmpty {
                emptyState("Start with your wallets", "Connect OpenRouter or DeepSeek, record subscription payments, and follow public GitHub releases.", "wallet.pass",
                           action: "Browse Catalogue") { destination = .catalogue }
                    .surface()
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 16) {
                    heroCard
                    quickActions
                }
                VStack(spacing: 18) {
                    walletsTile
                    renewalTile
                }
                .frame(width: 300)
            }
            if !store.state.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeading(title: "My Wallets", subtitle: "\(store.state.accounts.count)") { SeeAllButton { destination = .accounts } }
                    ScrollView(.horizontal) {
                        HStack(spacing: 16) {
                            ForEach(store.state.accounts.filter { matches($0.label, integrationName($0)) }) { account in
                                WalletCard(account: account, paid: paidTotals(for: account))
                                    .frame(width: 290)
                                    .onTapGesture { editor = .wallet(account.id) }
                                    .contextMenu { walletMenuItems(account) }
                            }
                            addWalletCard
                        }
                        .padding(.vertical, 14).padding(.horizontal, 2)
                    }
                    .scrollIndicators(.never)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.9), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
                    .padding(.vertical, -14)
                }
            }
            HStack(alignment: .top, spacing: 18) {
                transactionsPanel
                spendingPanel.frame(width: 300)
            }
            if !(store.state.events ?? []).isEmpty { whatChangedStrip }
        }
    }

    /// Pay-as-you-go usage building up this month (Azure and similar), in one currency where it can be converted.
    private func accruing(in currency: String) -> Decimal {
        store.state.accruingThisMonth().compactMap { item -> Decimal? in
            if item.amount.currency == currency { return item.amount.amount }
            return combining ? store.rates?.convert(item.amount, to: currency, on: .now)?.amount : nil
        }.reduce(0, +)
    }

    private var heroCard: some View {
        Billboard(faces: billboardFaces) { currencyControl(onColor: true) }
    }

    private var billboardFaces: [BoardFace] {
        let currency = activeCurrency
        let calendar = Calendar.current
        let pending = accruing(in: currency)
        let explanation = store.state.spendingBreakdown(in: currency, rates: combining ? store.rates : nil)
        let total: Money? = explanation.total.amount > 0 ? Money(explanation.total.amount.rounded2, currency) : nil
        let month = store.state.monthToDateSpend(in: currency, rates: combining ? store.rates : nil, includeAccruing: true).spent
        let points = SpendSeries.cumulative(spendPayments, currency: currency, start: store.state.coverageStart)

        // Six months of spend for the month face, this month including pay-as-you-go usage so far.
        let thisMonthStart = calendar.dateInterval(of: .month, for: .now)?.start ?? .now
        let starts = (0..<6).reversed().compactMap { calendar.date(byAdding: .month, value: -$0, to: thisMonthStart) }
        let months = starts.map { start -> Double in
            let end = calendar.date(byAdding: .month, value: 1, to: start) ?? .now
            let sum = spendPayments.filter { $0.money.currency == currency && $0.paidAt >= start && $0.paidAt < end }
                .reduce(Decimal(0)) { $0 + ($1.kind == .refund ? -$1.money.amount : $1.money.amount) }
            return max(0, NSDecimalNumber(decimal: start == thisMonthStart ? month.amount : sum).doubleValue)
        }
        let lastMonth = months.count >= 2 ? months[months.count - 2] : 0
        let thisMonth = NSDecimalNumber(decimal: month.amount).doubleValue
        let lastName = starts.count >= 2 ? starts[starts.count - 2].formatted(.dateTime.month(.wide)) : "last month"
        let comparison: String = {
            guard thisMonth > 0 else { return "Nothing recorded in \(Date.now.formatted(.dateTime.month(.wide))) yet" }
            guard lastMonth > 0 else { return "Payments plus pay-as-you-go usage so far" }
            let change = Int(((thisMonth - lastMonth) / lastMonth * 100).rounded())
            return change >= 0 ? "\(change)% more than \(lastName) so far" : "\(-change)% less than \(lastName) so far"
        }()

        // Prepaid credit across live wallets, converted where a reference rate exists.
        let wallets = store.state.accounts.filter { $0.mode == .live }.compactMap { account -> (ConnectedAccount, Money)? in
            guard let balance = account.snapshot?.balances.first(where: { $0.currency != "CREDITS" && $0.currency != "UNLIMITED" }) else { return nil }
            return (account, balance)
        }
        var credit: Decimal = 0, counted: [(ConnectedAccount, Money)] = []
        for (account, balance) in wallets {
            if let money = balance.currency == currency ? balance : store.rates?.convert(balance, to: currency, on: .now) {
                credit += money.amount; counted.append((account, balance))
            }
        }
        let lowest = counted.min { a, b in
            let x = a.1.currency == currency ? a.1.amount : store.rates?.convert(a.1, to: currency, on: .now)?.amount ?? a.1.amount
            let y = b.1.currency == currency ? b.1.amount : store.rates?.convert(b.1, to: currency, on: .now)?.amount ?? b.1.amount
            return x < y
        }
        let creditCaption = counted.isEmpty ? "Connect OpenRouter, DeepSeek or another prepaid wallet"
            : "Across \(counted.count) wallet\(counted.count == 1 ? "" : "s")" + (lowest.map { " · lowest: \(integrationName($0.0)) \($0.1.plainText)" } ?? "")

        return [
            BoardFace(id: "total", title: "Total spent on AI", symbol: "creditcard.fill", value: total, empty: "Nothing yet", colors: Palette.hero,
                      caption: pending > 0 ? "Includes \(Money(pending.rounded2, currency).plainText) of pay-as-you-go usage this month" : (conversionCaption ?? store.state.coverageDescription),
                      chip: month.amount > 0 ? "+\(month.amountText) this month" : nil,
                      visual: points.count > 2 ? AnyView(Sparkline(points: points).frame(width: 200, height: 84)) : nil,
                      footer: AnyView(heroThisMonth),
                      inspect: { editor = .breakdown(false, currency) }, inspectMonth: { editor = .breakdown(true, currency) }),
            BoardFace(id: "month", title: "Spent in \(Date.now.formatted(.dateTime.month(.wide)))", symbol: "calendar", value: month.amount > 0 ? month : nil, empty: "Nothing yet",
                      colors: [Palette.hex(0x0E4A3C), Palette.hex(0x14805F), Palette.hex(0x9DBF2A)], caption: comparison,
                      visual: AnyView(MiniMonthBars(values: months, labels: starts.map { $0.formatted(.dateTime.month(.narrow)) })),
                      footer: AnyView(heroThisMonth), inspect: { editor = .breakdown(true, currency) }),
            BoardFace(id: "credit", title: "Credit remaining", symbol: "wallet.pass.fill", value: credit > 0 ? Money(credit.rounded2, currency) : nil, empty: "No prepaid credit",
                      colors: [Palette.hex(0x1A2F9E), Palette.hex(0x3D5BFF), Palette.hex(0x3FC1FF)], caption: creditCaption,
                      visual: counted.isEmpty ? nil : AnyView(LogoStack(ids: counted.map(\.0.integrationID), size: 40).padding(.bottom, 6))),
        ]
    }

    /// This month at a glance: pay-as-you-go usage still building up, and progress against the budget.
    @ViewBuilder private var heroThisMonth: some View {
        let accruing = store.state.accruingThisMonth()
        let budget = store.state.monthlyBudget
        if !accruing.isEmpty || budget != nil {
            HStack(spacing: 14) {
                if !accruing.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "hourglass").font(.system(size: 10, weight: .bold))
                        Text("Accruing " + accruing.map { "\($0.amount.amountText) \($0.amount.currency)" }.joined(separator: " + ") + " on pay as you go")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .opacity(0.9)
                    .help(accruing.map { "\(Catalogue.integration($0.account.integrationID)?.name ?? "") (\($0.account.label)): \($0.amount.plainText) so far this month, invoiced after month end" }.joined(separator: "\n"))
                }
                if let budget {
                    let spent = store.state.monthToDateSpend(in: budget.currency, rates: store.rates, includeAccruing: true)
                    let ratio = budget.amount > 0 ? NSDecimalNumber(decimal: spent.spent.amount / budget.amount).doubleValue : 0
                    Button { editor = .settings } label: {
                        HStack(spacing: 7) {
                            UsageMeter(used: ratio, tint: ratio >= 1 ? Palette.hex(0xFFD1D1) : ratio >= 0.8 ? Palette.warning : Palette.lime).frame(width: 90)
                            Text("\(spent.spent.amountText) of \(budget.amountText) \(budget.currency) budget").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        }
                    }
                    .buttonStyle(.plain)
                    .help(spent.complete ? "This month's payments plus pay-as-you-go usage. Click to change the budget." : "Some payments could not be converted to \(budget.currency). Combine currencies to include them.")
                } else {
                    Button { editor = .settings } label: { Label("Set budget", systemImage: "target").font(.system(size: 11, weight: .semibold)) }
                        .buttonStyle(.plain).opacity(0.8)
                }
            }
        } else {
            Button { editor = .settings } label: { Label("Set a monthly budget", systemImage: "target").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.plain).opacity(0.8)
        }
    }

    private var quickActions: some View {
        HStack(spacing: 10) {
            Button { editor = .payment(nil) } label: { Label("Add Payment", systemImage: "plus") }.buttonStyle(PillButtonStyle())
            Button(action: refreshAll) { Label("Refresh Balances", systemImage: "arrow.clockwise") }
                .buttonStyle(PillButtonStyle())
                .disabled(store.loadFailure != nil || !store.state.accounts.contains { $0.mode == .live } || !store.refreshingAccounts.isEmpty)
            Button { editor = .subscription(nil) } label: { Label("Add Renewal", systemImage: "calendar.badge.plus") }.buttonStyle(PillButtonStyle())
            Button { editor = .repository } label: { Label("Follow Repo", systemImage: "shippingbox") }.buttonStyle(PillButtonStyle())
            if !store.refreshingAccounts.isEmpty { Spinner(size: .small) }
        }
    }

    private var walletsTile: some View {
        let attention = store.state.accounts.filter(needsAttention).count
        let live = store.state.accounts.filter { $0.mode == .live && $0.snapshot != nil && !needsAttention($0) }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Wallets").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                LogoStack(ids: Array(Set(store.state.accounts.map(\.integrationID))).sorted(), size: 26)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(store.state.accounts.count)").font(.system(size: 34, weight: .heavy)).tracking(-1).contentTransition(.numericText())
                Text("connected").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if attention > 0 { Chip(text: "\(attention) need attention", tint: Palette.warning, symbol: "exclamationmark.triangle.fill") }
                if live > 0 { Chip(text: "\(live) live", tint: Palette.positive, symbol: "bolt.fill") }
                if store.state.accounts.isEmpty { Chip(text: "None yet", tint: .secondary) }
            }
        }
        .surface(padding: 18, radius: 22)
        .frame(height: 140)
    }

    private var renewalTile: some View {
        let next = store.state.subscriptions.min { $0.nextRenewal < $1.nextRenewal }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Next renewal").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if let next { LogoCircle(integrationID: account(next.accountID)?.integrationID, size: 28, symbol: "calendar") }
            }
            if let next {
                let days = daysUntil(next.nextRenewal)
                MoneyText(money: next.price, size: 28, weight: .heavy)
                HStack(spacing: 6) {
                    Text(next.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    Chip(text: relativeDays(days), tint: days < 0 ? Palette.negative : days <= 7 ? Palette.warning : .secondary)
                }
            } else {
                let detected = RenewalDetector.suggestions(store.state).count
                Text(detected > 0 ? "\(detected) detected" : "Nothing scheduled").font(.system(size: 20, weight: .bold)).foregroundStyle(detected > 0 ? Color.primary : Color.secondary)
                Button(detected > 0 ? "Review" : "Add Subscription") { if detected > 0 { destination = .subscriptions } else { editor = .subscription(nil) } }
                    .buttonStyle(PillButtonStyle(kind: detected > 0 ? .primary : .secondary, compact: true))
            }
        }
        .surface(padding: 18, radius: 22)
        .frame(height: 140)
    }

    private var addWalletCard: some View {
        Button { destination = .catalogue } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 18, weight: .bold))
                    .frame(width: 44, height: 44).background(Circle().fill(Palette.raised))
                Text("Add wallet").font(.system(size: 13, weight: .semibold))
                Text("OpenRouter, DeepSeek or manual").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(width: 200, height: 178)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Palette.border, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func signIn(_ account: ConnectedAccount) {
        signingIn.insert(account.id)
        Task {
            do {
                try await SignIn.start(account.integrationID)
                if account.integrationID == "codex" {
                    signingIn.remove(account.id)
                    await store.refreshAccount(account.id)
                } else {
                    store.notice = "Finish signing in in the Terminal window that opened, then click Refresh on this wallet."
                }
            } catch { store.notice = error.localizedDescription }
            signingIn.remove(account.id)
        }
    }

    private func announce(_ recorded: [PaymentRecord]) {
        guard !recorded.isEmpty else { return }
        Notifier.shared.renewalsRecorded(recorded)
        let list = recorded.map { "\($0.description) \($0.money.plainText) on \($0.paidAt.formatted(date: .abbreviated, time: .omitted))" }
        store.notice = "Recorded \(recorded.count) automatic payment\(recorded.count == 1 ? "" : "s"): \(list.joined(separator: "; ")). They are marked Auto until a receipt or invoice confirms them."
    }

    /// Saves a month's statement as a PDF where the user chooses, with a CSV of the same rows beside it.
    private func exportStatement(_ month: Date) {
        let statement = MonthlyStatement(state: store.state, month: month, rates: store.rates)
        let panel = NSSavePanel()
        panel.title = "Save Statement"
        panel.message = "Saves a PDF statement for \(statement.title), with a CSV of the same rows beside it."
        panel.nameFieldStringValue = statement.fileName + ".pdf"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try StatementPDF.render(statement).write(to: url, options: .atomic)
            let csv = url.deletingPathExtension().appendingPathExtension("csv")
            try statement.csv.write(to: csv, atomically: true, encoding: .utf8)
            store.notice = "Saved the \(statement.title) statement: \(url.lastPathComponent) and \(csv.lastPathComponent)."
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            store.notice = "The statement was not saved. \(error.localizedDescription)"
        }
    }

    /// Imports confirmed payments from a CSV the user picks. Nothing is read unless chosen here.
    private func importPayments() {
        let panel = NSOpenPanel()
        panel.title = "Import Payments"
        panel.message = "Choose a CSV with date, description, amount, currency, kind, account, account_label and reference columns."
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let rows = try PaymentImport.parse(try String(contentsOf: url, encoding: .utf8))
            let summary = try store.importPayments(rows)
            var lines = ["Imported \(summary.imported) payment\(summary.imported == 1 ? "" : "s")."]
            if summary.duplicates > 0 { lines.append("Skipped \(summary.duplicates) already recorded.") }
            if summary.replaced > 0 { lines.append("Replaced \(summary.replaced) Auto renewal\(summary.replaced == 1 ? "" : "s") with receipts.") }
            let detected = RenewalDetector.suggestions(store.state).count
            if detected > 0 { lines.append("Found \(detected) recurring subscription\(detected == 1 ? "" : "s") to review in Subscriptions.") }
            if !summary.createdAccounts.isEmpty { lines.append("Added wallets: \(summary.createdAccounts.joined(separator: ", ")).") }
            store.notice = lines.joined(separator: " ")
            Task { await store.refreshRatesIfNeeded() }
        } catch {
            store.notice = "Nothing was imported. \(error.localizedDescription)"
        }
    }

    @ViewBuilder private func walletMenuItems(_ account: ConnectedAccount) -> some View {
        if account.mode == .live { Button("Refresh Balance") { Task { await store.refreshAccount(account.id) } } }
        if SignIn.supports(account.integrationID) { Button(SignIn.title(account.integrationID)) { signIn(account) } }
        Button("Show Details") { editor = .wallet(account.id) }
        Button("Edit Account") { if let integration = Catalogue.integration(account.integrationID) { editor = .account(integration, account) } }
        if account.mode == .live { Button("Switch to Manual Records") { perform { try store.switchToManual(account.id) } } }
        Button("Add Payment") { editor = .payment(.init(accountID: account.id, description: "", kind: .topUp, money: Money(0, "USD"), paidAt: .now)) }
        Divider()
        Button("Remove Account", role: .destructive) { removal = .init(title: "Remove \(account.label)?", action: { try store.removeAccount(account.id) }) }
    }

    private var transactionsPanel: some View {
        let items = Array(store.state.payments.filter { matches($0.description, accountName($0.accountID)) }.sorted { $0.paidAt > $1.paidAt }.prefix(5))
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: "Transactions", subtitle: "Recorded") { SeeAllButton { destination = .payments } }
                .padding(.bottom, 6)
            if items.isEmpty {
                emptyState("No payments yet", "Record a top-up or subscription charge from a receipt, or import a CSV of past payments.", "creditcard",
                           action: "Import CSV", perform: importPayments)
            }
            ForEach(items) { transactionRow($0) }
        }
        .surface(padding: 20, radius: 22)
    }

    private func transactionRow(_ record: PaymentRecord, actions: Bool = false) -> some View {
        let refund = record.kind == .refund
        return HStack(spacing: 14) {
            LogoCircle(integrationID: account(record.accountID)?.integrationID, size: 42, symbol: refund ? "arrow.uturn.backward" : "creditcard")
            VStack(alignment: .leading, spacing: 3) {
                Text(record.description).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(record.paidAt.formatted(date: .abbreviated, time: .omitted) + " · " + accountName(record.accountID))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                MoneyText(money: record.money, size: 15, prefix: refund ? "+" : "−")
                    .foregroundStyle(refund ? Palette.positive : Color.primary)
                HStack(spacing: 6) {
                    if record.autoRecorded { Chip(text: record.estimated == true ? "Estimate" : "Auto", tint: Palette.accentInk, symbol: "arrow.triangle.2.circlepath").help(record.estimated != true ? "Recorded from a subscription schedule. Import the receipt or choose Confirm to mark it as verified."
                                     : record.kind == .topUp ? "Detected from the provider's purchased total rising between two readings. Import the receipt to replace it, or edit the amount and confirm it."
                                     : "Recorded from the last usage reading of the month. Import the invoice or choose Confirm to mark it as verified.") }
                    Text(refund ? "Refunded" : record.kind.rawValue).font(.system(size: 11, weight: .medium)).foregroundStyle(refund ? Palette.positive : .secondary)
                }
            }
            if actions {
                if record.autoRecorded {
                    Button { perform { try store.confirmPayment(record.id) } } label: { Image(systemName: "checkmark") }
                        .buttonStyle(IconButtonStyle()).help("Confirm: the charge matches your receipt").accessibilityLabel("Confirm \(record.description)")
                }
                Button { editor = .payment(record) } label: { Image(systemName: "pencil") }
                    .buttonStyle(IconButtonStyle()).help("Edit").accessibilityLabel("Edit \(record.description)")
                Button { removal = .init(title: "Remove Payment?", action: { try store.removePayment(record.id) }) } label: { Image(systemName: "trash") }
                    .buttonStyle(IconButtonStyle()).help("Remove").accessibilityLabel("Remove \(record.description)")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RowHighlight())
        .contextMenu {
            if record.autoRecorded { Button("Confirm Payment") { perform { try store.confirmPayment(record.id) } } }
            Button("Edit") { editor = .payment(record) }
            Button("Remove", role: .destructive) { removal = .init(title: "Remove Payment?", action: { try store.removePayment(record.id) }) }
        }
    }

    private var spendingPanel: some View {
        let currency = activeCurrency
        let slices = SpendSeries.byProvider(spendPayments, accounts: store.state.accounts, currency: currency)
        return VStack(alignment: .leading, spacing: 16) {
            SectionHeading(title: "Spending") {
                currencyControl(onColor: false, offerCombine: false)
            }
            if slices.isEmpty {
                Text("No payments in \(currency) yet.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ProviderDonut(slices: Array(slices.prefix(5)), currency: currency).frame(maxWidth: .infinity)
            }
        }
        .surface(padding: 20, radius: 22)
    }

    /// Important events from the last week first, then the most recent.
    private var highlightEvents: [TimelineEvent] {
        let events = store.state.events ?? []
        let week = events.filter { $0.important && $0.date > .now.addingTimeInterval(-7 * 86400) }
        return Array((week + events.filter { !week.contains($0) }).prefix(3))
    }

    private var whatChangedStrip: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "What Changed") { SeeAllButton { destination = .timeline } }
            HStack(alignment: .top, spacing: 14) {
                ForEach(highlightEvents) { event in
                    Group {
                        if let source = event.source {
                            Link(destination: source) { EventCard(event: event, integrationID: account(event.accountID)?.integrationID) }.buttonStyle(.plain)
                        } else {
                            EventCard(event: event, integrationID: account(event.accountID)?.integrationID)
                                .onTapGesture { destination = .timeline }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                ForEach(0..<max(0, 3 - highlightEvents.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
            }
        }
    }

    // MARK: Wallets

    private var wallets: some View {
        let items = store.state.accounts.filter { matches($0.label, $0.billingScope, integrationName($0)) }
        let attention = store.state.accounts.filter(needsAttention).count
        return VStack(alignment: .leading, spacing: 0) {
            pageHeader("Wallets", "Each account keeps its own label, billing owner, key and currency.",
                       chip: store.state.accounts.isEmpty ? nil : attention > 0 ? Chip(text: "\(attention) need attention", tint: Palette.warning, symbol: "exclamationmark.triangle.fill") : Chip(text: "All current", tint: Palette.positive, symbol: "checkmark"))
            if items.isEmpty {
                Group {
                    if store.state.accounts.isEmpty {
                        emptyState("No wallets yet", "Connect OpenRouter or DeepSeek for live balances, or add any provider as a manual account.", "wallet.pass",
                                   action: "Browse Catalogue") { destination = .catalogue }
                    } else {
                        emptyState("No matching wallets", "Try a different search.", "magnifyingglass")
                    }
                }
                .surface()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 18, alignment: .top)], spacing: 18) {
                ForEach(items) { walletTile($0) }
            }
        }
    }

    private struct TileRow { let label: String; let value: String; var tint: Color = .primary }

    /// One-line facts for a wallet tile, in a fixed order: usage windows, plan, balance details, spend.
    private func tileRows(_ account: ConnectedAccount) -> [TileRow] {
        guard let snapshot = account.snapshot else {
            return [TileRow(label: "Status", value: account.mode == .manual ? "Manual records only" : "Refresh to read", tint: .secondary)]
        }
        var rows: [TileRow] = []
        for window in snapshot.allowances ?? [] {
            let reset = window.resetsAt.map { " · resets \($0.formatted(.relative(presentation: .named)))" } ?? ""
            rows.append(TileRow(label: window.name, value: "\(window.usedPercent)% used\(reset)",
                                tint: window.usedPercent >= 100 ? Palette.negative : window.usedPercent >= 80 ? Palette.warning : .primary))
        }
        if let credits = snapshot.resetCredits, !credits.isEmpty {
            let expiry = credits.compactMap(\.expiresAt).min().map { " · expires \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? ""
            rows.append(TileRow(label: "Free resets", value: "\(credits.count) available\(expiry)", tint: Palette.positive))
        }
        if let spike = snapshot.anomalies?.first {
            rows.append(TileRow(label: "Cost spike", value: "\(spike.service) \(spike.amount.plainText)/day", tint: Palette.warning))
        }
        // The card already shows the plan; repeat it only when there is nothing else to say.
        if let plan = snapshot.plan, rows.isEmpty { rows.append(TileRow(label: "Plan", value: plan)) }
        rows += snapshot.details.map { TileRow(label: $0.label, value: $0.value.plainText) }
        let period = snapshot.consumptionPeriod.map { " (\($0.lowercased()))" } ?? ""
        rows += snapshot.reportedConsumption.map { TileRow(label: "Reported consumption\(period)", value: $0.plainText) }
        return rows
    }

    private func walletTile(_ account: ConnectedAccount) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            WalletCard(account: account, paid: paidTotals(for: account), height: 190)
                .onTapGesture { editor = .wallet(account.id) }
                .help("Show details")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    if account.mode == .live {
                        Button { Task { await store.refreshAccount(account.id) } } label: {
                            HStack(spacing: 6) {
                                if store.refreshingAccounts.contains(account.id) { Spinner() }
                                else { Image(systemName: "arrow.clockwise") }
                                Text("Refresh")
                            }
                        }
                        .buttonStyle(PillButtonStyle(compact: true))
                        .disabled(store.refreshingAccounts.contains(account.id) || store.loadFailure != nil)
                        .accessibilityLabel("Refresh \(account.label) \(integrationName(account))")
                    }
                    if SignIn.supports(account.integrationID) {
                        Button { signIn(account) } label: {
                            HStack(spacing: 6) {
                                if signingIn.contains(account.id) { Spinner() } else { Image(systemName: "person.crop.circle.badge.checkmark") }
                                Text("Sign In")
                            }
                        }
                        .buttonStyle(PillButtonStyle(compact: true))
                        .disabled(signingIn.contains(account.id))
                        .help(SignIn.title(account.integrationID))
                    }
                    Button { if let integration = Catalogue.integration(account.integrationID) { editor = .account(integration, account) } } label: { Label("Edit", systemImage: "pencil") }
                        .buttonStyle(PillButtonStyle(compact: true))
                    Spacer()
                    // No room for the label beside Sign In; the card already says what the wallet is.
                    if !SignIn.supports(account.integrationID), let billing = Catalogue.integration(account.integrationID)?.billing {
                        Text(billing.rawValue).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    moreMenu("Options for \(account.label)") { walletMenuItems(account) }
                }
                // Every tile uses the same anatomy: up to three one-line rows in a fixed slot, then the
                // footer. Long explanations live behind the info button, so text never stretches a tile.
                VStack(spacing: 9) {
                    ForEach(Array(tileRows(account).enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 8) {
                            Text(row.label).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(row.value).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(row.tint).lineLimit(1)
                        }
                        .font(.system(size: 12))
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(minHeight: 63, alignment: .top)
                HStack(spacing: 10) {
                    Text(account.snapshot.map { "Updated \($0.observedAt.formatted(date: .abbreviated, time: .shortened))" } ?? (account.mode == .manual ? "Manual records" : "Not refreshed yet"))
                        .lineLimit(1)
                    Spacer()
                    if let snapshot = account.snapshot {
                        Button { infoAccount = account.id } label: { Image(systemName: "info.circle") }
                            .buttonStyle(.plain).help(snapshot.coverage).accessibilityLabel("About this reading")
                            .popover(isPresented: Binding(get: { infoAccount == account.id }, set: { if !$0 { infoAccount = nil } }), arrowEdge: .bottom) {
                                Text(snapshot.coverage).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).padding(14).frame(width: 300)
                            }
                        Link(destination: snapshot.source) { Label("Source", systemImage: "arrow.up.right") }
                    }
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                if let error = account.lastError {
                    InlineNotice(text: error + (account.lastAttempt.map { " Last attempt \($0.formatted(date: .abbreviated, time: .shortened))." } ?? ""))
                    // A key this account can never get (Admin keys need an organization): offer manual records instead.
                    if error.localizedCaseInsensitiveContains("Admin key") {
                        Button { perform { try store.switchToManual(account.id) } } label: { Label("Keep as Manual Records", systemImage: "square.and.pencil") }
                            .buttonStyle(PillButtonStyle(compact: true))
                            .help("Stops refreshing this wallet and keeps its recorded payments. You can still import receipts and add top-ups.")
                    }
                }
            }
            .padding(.horizontal, 6)
        }
        .padding(10).padding(.bottom, 6)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Palette.border))
    }

    // MARK: Payments

    private var payments: some View {
        let currency = activeCurrency
        let month = SpendSeries.paidThisMonth(spendPayments, currency: currency)
        let unconfirmed = store.unconfirmedPayments
        let items = store.state.payments.filter { (paymentFilter == "All" || $0.autoRecorded) && matches($0.description, $0.reference, accountName($0.accountID), $0.money.currency) }.sorted { $0.paidAt > $1.paidAt }
        return VStack(alignment: .leading, spacing: 18) {
            pageHeader("Payments", combining ? "Settled charges and refunds from receipts. Shown in \(store.state.displayCurrency!); each payment keeps its recorded currency." : "Settled charges and refunds from receipts. Amounts stay grouped by currency.",
                       chip: month > 0 ? Chip(text: "+\(Money(Decimal(month), currency).amountText) \(currency) this month", tint: Palette.lime, symbol: "arrow.up.right", filled: true) : nil)
                .padding(.bottom, -18)
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Spend over time").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                            if let total = Ledger.paidTotals(spendPayments).first(where: { $0.currency == currency }) { MoneyText(money: total, size: 30, weight: .heavy) }
                        }
                        Spacer()
                        SegmentedPills(options: ["Cumulative", "Monthly"], selection: $chartMode) { $0 }
                        currencyControl(onColor: false)
                    }
                    if spendPayments.contains(where: { $0.money.currency == currency }) {
                        if chartMode == "Monthly" {
                            MonthlyBarsChart(months: SpendSeries.monthly(spendPayments, accounts: store.state.accounts, currency: currency), currency: currency)
                        } else {
                            SpendAreaChart(points: SpendSeries.cumulative(spendPayments, currency: currency, start: store.state.coverageStart), currency: currency)
                        }
                    } else {
                        emptyState("No chart yet", "Payments appear here once recorded.", "chart.xyaxis.line")
                    }
                }
                .surface(padding: 22, radius: 22)
                .frame(height: 300)
                VStack(alignment: .leading, spacing: 14) {
                    Text("Totals").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    let totals = Ledger.paidTotals(store.state.payments)
                    if totals.isEmpty { Text("Nothing recorded").font(.system(size: 20, weight: .bold)).foregroundStyle(.secondary) }
                    if combining, let combined = Ledger.paidTotals(spendPayments).first {
                        MoneyText(money: combined, size: 28, weight: .heavy)
                        Text("Recorded as").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        ForEach(totals) { MoneyText(money: $0, size: 14, weight: .semibold).foregroundStyle(.secondary) }
                    } else {
                        ForEach(totals) { MoneyText(money: $0, size: 26, weight: .heavy) }
                    }
                    let pending = accruing(in: currency)
                    if pending > 0 {
                        Label("+ \(Money(pending.rounded2, currency).plainText) accruing this month", systemImage: "hourglass")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            .help("Pay-as-you-go usage so far this month (Azure and similar), recorded as a payment when the month closes")
                    }
                    Spacer(minLength: 0)
                    Chip(text: store.state.historyCoverage?.completeForPeriod == true ? "Complete for period" : "Partial history",
                         tint: store.state.historyCoverage?.completeForPeriod == true ? Palette.positive : Palette.warning)
                    Text(store.state.coverageDescription).font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Set Coverage") { editor = .coverage }.buttonStyle(PillButtonStyle(compact: true))
                }
                .surface(padding: 22, radius: 22)
                .frame(width: 260, height: 300)
            }
            VStack(alignment: .leading, spacing: 4) {
                SectionHeading(title: "History", subtitle: "\(items.count) record\(items.count == 1 ? "" : "s")") {
                    if !unconfirmed.isEmpty || paymentFilter != "All" {
                        SegmentedPills(options: ["All", "Unconfirmed"], selection: $paymentFilter) { $0 == "All" ? "All" : "Unconfirmed \(unconfirmed.count)" }
                    }
                    Button(action: importPayments) { Label("Import CSV", systemImage: "square.and.arrow.down") }
                        .buttonStyle(PillButtonStyle(compact: true))
                        .help("Import confirmed payments from a CSV file: date, description, amount, currency, kind, account, account_label, reference")
                    Menu {
                        ForEach(MonthlyStatement.months(store.state), id: \.self) { month in
                            Button(month.formatted(.dateTime.month(.wide).year())) { exportStatement(month) }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.text").font(.system(size: 11, weight: .semibold))
                            Text("Statement").font(.system(size: 12, weight: .semibold))
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .heavy))
                        }
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Capsule().fill(Palette.raised))
                        .overlay(Capsule().strokeBorder(Palette.border))
                        .contentShape(Capsule())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("Download a month's statement as a PDF, with a CSV of the same rows beside it")
                }
                .padding(.bottom, 10)
                if !unconfirmed.isEmpty { closeMonthBanner(unconfirmed).padding(.bottom, 10) }
                if items.isEmpty {
                    if paymentFilter == "All" { emptyState("No matching payments", "Add a confirmed payment to begin your recorded history.", "creditcard") }
                    else { emptyState("All confirmed", "Every payment is backed by a receipt or confirmed by you.", "checkmark.seal") }
                }
                let groups = Dictionary(grouping: items) { Calendar.current.dateInterval(of: .month, for: $0.paidAt)?.start ?? $0.paidAt }
                ForEach(groups.keys.sorted(by: >), id: \.self) { month in
                    Text(month.formatted(.dateTime.month(.wide).year()).uppercased())
                        .font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.tertiary)
                        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
                    ForEach(groups[month] ?? []) { record in
                        transactionRow(record, actions: true)
                    }
                }
            }
            .surface(padding: 20, radius: 22)
        }
    }

    /// Auto renewals and usage estimates waiting for receipts, with a prompt an agent can act on.
    private func closeMonthBanner(_ records: [PaymentRecord]) -> some View {
        let total = Ledger.paidTotals(records).map(\.plainText).joined(separator: " + ")
        return HStack(spacing: 14) {
            Image(systemName: "checklist").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.accentInk)
                .frame(width: 40, height: 40).background(Circle().fill(Palette.accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                Text("Close the books").font(.system(size: 14, weight: .bold))
                Text("\(records.count) entr\(records.count == 1 ? "y" : "ies") (\(total)) are Auto or Estimate. Copy a request for an agent with mail access, then import the CSV it returns.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.state.receiptRequest(for: records), forType: .string)
                copiedRequest = true
                Task { try? await Task.sleep(for: .seconds(2)); copiedRequest = false }
            } label: { Label(copiedRequest ? "Copied" : "Copy Receipt Request", systemImage: copiedRequest ? "checkmark" : "doc.on.doc") }
                .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                .help("Copies a prompt listing these entries and the CSV columns Unifai imports")
            if paymentFilter == "All" {
                Button("Review") { paymentFilter = "Unconfirmed" }.buttonStyle(PillButtonStyle(compact: true))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.accent.opacity(0.18)))
    }

    // MARK: Subscriptions

    private var subscriptions: some View {
        let items = store.state.subscriptions.filter { matches($0.name, accountName($0.accountID)) }.sorted { $0.nextRenewal < $1.nextRenewal }
        let monthly = Dictionary(grouping: store.state.subscriptions, by: { $0.price.currency }).map { currency, list in
            Money(list.reduce(Decimal(0)) { $0 + ($1.cadence == .yearly ? $1.price.amount / 12 : $1.price.amount) }, currency)
        }.sorted { $0.currency < $1.currency }
        return VStack(alignment: .leading, spacing: 0) {
            pageHeader("Subscriptions", "Expected charges stay separate from payment history. Record each settled renewal when it happens.",
                       chip: monthly.first.map { Chip(text: "\($0.plainText) / month expected", tint: Palette.accent, symbol: "repeat") })
            let detected = RenewalDetector.suggestions(store.state)
            if !detected.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeading(title: "Detected from your payments", subtitle: "\(detected.count)")
                    ForEach(detected) { suggestionRow($0) }
                }
                .padding(.bottom, 24)
            }
            if items.isEmpty && detected.isEmpty {
                emptyState(store.state.subscriptions.isEmpty ? "No subscriptions yet" : "No matching subscriptions", "Add a schedule for a plan you already pay for.", "calendar",
                           action: store.state.subscriptions.isEmpty ? "Add Subscription" : nil) { editor = .subscription(nil) }.surface()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 18, alignment: .top)], spacing: 18) {
                ForEach(items) { planCard($0) }
            }
        }
    }

    private func suggestionRow(_ suggestion: RenewalSuggestion) -> some View {
        let linked = account(suggestion.accountID)
        return HStack(spacing: 14) {
            LogoCircle(integrationID: linked?.integrationID, size: 42, symbol: "calendar")
            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.name).font(.system(size: 14, weight: .semibold))
                Text("\(suggestion.cadence.rawValue) · next \(suggestion.nextRenewal.formatted(date: .abbreviated, time: .omitted)) · based on \(suggestion.basedOn) payments, last \(suggestion.lastPaid.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                MoneyText(money: suggestion.price, size: 16)
                if suggestion.estimated { Chip(text: "Check price", tint: Palette.warning, symbol: "exclamationmark.triangle.fill").help("The last charge was prorated or prices changed. Confirm the full renewal price.") }
            }
            Button("Add Schedule") {
                editor = .subscription(SubscriptionSchedule(accountID: suggestion.accountID, name: suggestion.name, price: suggestion.price, cadence: suggestion.cadence, nextRenewal: suggestion.nextRenewal))
            }
            .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
            Button { perform { try store.dismissSuggestion(suggestion.id) } } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle()).help("Dismiss").accessibilityLabel("Dismiss \(suggestion.name)")
        }
        .surface(padding: 16, radius: 20)
    }

    private func planCard(_ schedule: SubscriptionSchedule) -> some View {
        let linked = account(schedule.accountID)
        let days = daysUntil(schedule.nextRenewal)
        return ZStack(alignment: .topLeading) {
            MeshBackdrop(colors: Palette.brand(linked?.integrationID))
            if let id = linked?.integrationID {
                ProviderLogo(integrationID: id, size: 140, ink: .white).opacity(0.12).rotationEffect(.degrees(-14))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).offset(x: 30, y: -24)
                    .allowsHitTesting(false)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 8) {
                    LogoCircle(integrationID: linked?.integrationID, size: 38, symbol: "calendar", onColor: true)
                    Spacer()
                    GlassChip(text: relativeDays(days), dot: days < 0 ? Palette.negative : days <= 7 ? Palette.warning : Palette.lime)
                    moreMenu("Options for \(schedule.name)", onColor: true) {
                        Button("Edit Schedule") { editor = .subscription(schedule) }
                        Button("Record Settled Payment") { editor = .payment(.init(accountID: schedule.accountID, description: schedule.name, kind: .subscription, money: schedule.price, paidAt: .now)) }
                        Divider()
                        Button("Remove Schedule", role: .destructive) { removal = .init(title: "Remove Schedule?", action: { try store.removeSubscription(schedule.id) }) }
                    }
                }
                Spacer(minLength: 14)
                Text(schedule.name).font(.system(size: 22, weight: .heavy)).tracking(-0.5).lineLimit(1)
                HStack(spacing: 6) {
                    Text(accountName(schedule.accountID)).font(.system(size: 12, weight: .medium)).opacity(0.75).lineLimit(1)
                    if schedule.recordsAutomatically { GlassChip(text: "Auto-records", symbol: "arrow.triangle.2.circlepath") }
                }
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Next charge").font(.system(size: 11, weight: .medium)).opacity(0.7)
                        Text(schedule.nextRenewal.formatted(.dateTime.month(.abbreviated).day().year())).font(.system(size: 15, weight: .bold))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(schedule.cadence.rawValue).font(.system(size: 11, weight: .medium)).opacity(0.7)
                        MoneyText(money: schedule.price, size: 22)
                    }
                }
                .padding(.top, 14)
                if days < 0 {
                    Text("Date passed. Confirm the payment and update the schedule.").font(.system(size: 11, weight: .semibold))
                        .padding(.top, 10)
                }
            }
            .padding(20)
        }
        .foregroundStyle(.white)
        .frame(height: days < 0 ? 236 : 214)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
        .shadow(color: Palette.brand(linked?.integrationID)[1].opacity(0.28), radius: 16, y: 8)
        .contextMenu {
            Button("Edit Schedule") { editor = .subscription(schedule) }
            Button("Record Settled Payment") { editor = .payment(.init(accountID: schedule.accountID, description: schedule.name, kind: .subscription, money: schedule.price, paidAt: .now)) }
        }
    }

    // MARK: Catalogue

    private var catalogue: some View {
        let items = Catalogue.integrations.filter { (category == nil || $0.category == category) && matches($0.name, $0.capabilities, $0.method, $0.status.rawValue) }
        return VStack(alignment: .leading, spacing: 0) {
            pageHeader("Catalogue", "Connect a supported service, add manual records, or see what is planned.")
            SegmentedPills(options: [nil] + IntegrationCategory.allCases.map(Optional.some), selection: $category) { $0?.rawValue ?? "All" }
                .padding(.bottom, 24)
            if items.isEmpty { emptyState("No matching services", "Try another search or choose All.", "magnifyingglass").surface() }
            VStack(alignment: .leading, spacing: 30) {
                ForEach([IntegrationStatus.ready, .manual, .planned], id: \.self) { status in
                    let group = items.filter { $0.status == status }
                    if !group.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeading(title: status.rawValue, subtitle: "\(group.count)")
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16, alignment: .top)], spacing: 16) {
                                ForEach(group) { catalogueTile($0) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func statusTint(_ status: IntegrationStatus) -> Color {
        switch status {
        case .ready: return Palette.positive
        case .manual: return Palette.accent
        case .planned: return .secondary
        }
    }

    private func catalogueTile(_ integration: Integration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                LogoCircle(integrationID: integration.id, size: 46, onColor: integration.status == .ready)
                    .background(Circle().fill(Palette.series(integration.id).opacity(integration.status == .ready ? 0.5 : 0)).blur(radius: 14))
                Spacer()
                Chip(text: integration.status == .ready ? "Live" : integration.status == .manual ? "Manual" : "Planned",
                     tint: statusTint(integration.status),
                     symbol: integration.status == .ready ? "bolt.fill" : integration.status == .manual ? "square.and.pencil" : "clock")
            }
            .padding(.bottom, 4)
            Text(integration.name).font(.system(size: 15, weight: .bold)).lineLimit(1)
            Text(integration.capabilities).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Text(integration.limitation).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(2).help(integration.limitation)
            Spacer(minLength: 4)
            HStack {
                if let source = integration.source {
                    Link(destination: source) { Label("Docs", systemImage: "arrow.up.right") }
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .help(integration.evidence.rawValue).accessibilityLabel("Source for \(integration.name)")
                }
                Spacer()
                if integration.id == "github-releases" {
                    Button("Follow Repository") { editor = .repository }.buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                } else if integration.id == "x-accounts" {
                    Button("Set Up in Settings") { editor = .settings }.buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                } else if integration.category == .discovery && integration.status == .ready {
                    Button("Open Timeline") { destination = .timeline }.buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                } else if [.providers, .subscriptions, .cloud].contains(integration.category) {
                    if integration.status == .ready {
                        Button("Add Account") { editor = .account(integration, nil) }.buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                    } else {
                        Button("Add Manual Account") { editor = .account(integration, nil) }.buttonStyle(PillButtonStyle(compact: true))
                    }
                }
            }
        }
        .frame(minHeight: 190, alignment: .topLeading)
        .surface(padding: 18, radius: 22)
        .opacity(integration.status == .planned ? 0.72 : 1)
    }

    // MARK: Timeline

    private static let timelineFilters = ["All", "Accounts", "Status", "Models", "News", "Releases", "Posts"]

    private func timelineIncludes(_ event: TimelineEvent) -> Bool {
        switch timelineFilter {
        case "Accounts": return event.kind.isAccountEvent
        case "Status": return event.kind == .status
        case "Releases": return event.kind == .release
        case "Posts": return event.kind == .post
        case "Models": return event.kind == .model
        case "News": return event.kind == .news
        default: return true
        }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private var planAdvice: [(String, String)] {
        store.state.accounts.compactMap { account in
            PlanAdvisor.advice(for: account, events: store.state.events ?? []).map { (integrationName(account), $0) }
        }
    }

    private func checkNow() {
        Task {
            await store.refreshDueRepositories()
            await store.refreshTimeline(force: true)
            for account in store.state.accounts where account.mode == .live && (account.lastAttempt.map { Date.now.timeIntervalSince($0) > 300 } ?? true) {
                await store.refreshAccount(account.id)
            }
        }
    }

    private var timeline: some View {
        let events = (store.state.events ?? []).filter { timelineIncludes($0) && matches($0.title, $0.detail, $0.sourceName) }
        let days = Dictionary(grouping: events) { Calendar.current.startOfDay(for: $0.date) }
        return VStack(alignment: .leading, spacing: 18) {
            pageHeader("Timeline", "Resets, limits, cost spikes, outages, releases and posts about the services you pay for.")
                .padding(.bottom, -18)
            HeadroomCard(report: AgentReport.headroom(store.state, rates: store.rates), advice: planAdvice)
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        SegmentedPills(options: Self.timelineFilters, selection: $timelineFilter) { $0 }
                        Spacer()
                        Button(action: checkNow) {
                            HStack(spacing: 6) {
                                if store.refreshingTimeline { Spinner() } else { Image(systemName: "arrow.clockwise") }
                                Text("Check Now")
                            }
                        }
                        .buttonStyle(PillButtonStyle(compact: true))
                        .disabled(store.refreshingTimeline || store.loadFailure != nil)
                    }
                    .padding(.bottom, 10)
                    if events.isEmpty {
                        emptyState(store.state.events?.isEmpty == false ? "Nothing here" : "Quiet so far",
                                   store.state.events?.isEmpty == false ? "No events match this filter." : "Resets, limits, cost spikes and incidents appear here as Unifai checks your wallets and providers every 30 minutes.",
                                   "waveform.path.ecg", action: store.state.events?.isEmpty == false ? nil : "Check Now", perform: checkNow)
                    }
                    ForEach(days.keys.sorted(by: >), id: \.self) { day in
                        Text(dayTitle(day).uppercased())
                            .font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.tertiary)
                            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 2)
                        ForEach(days[day] ?? []) { event in
                            EventRow(event: event, integrationID: account(event.accountID)?.integrationID)
                        }
                    }
                }
                .surface(padding: 20, radius: 22)
                VStack(spacing: 18) {
                    statusSources
                    newsSources
                    xSources
                    repositorySources
                }
                .frame(width: 300)
            }
        }
    }

    private func sourceRow<Trailing: View>(_ logo: String?, _ title: String, _ subtitle: String, symbol: String = "sparkles", @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            LogoCircle(integrationID: logo, size: 30, symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            trailing()
        }
    }

    /// The latest incident for a provider's status page, if any in the last two weeks.
    private func latestIncident(_ feed: StatusFeed) -> TimelineEvent? {
        (store.state.events ?? []).filter { $0.kind == .status && $0.sourceName == "\(feed.name) status" }.max { $0.date < $1.date }
    }

    private var statusSources: some View {
        let feeds = StatusFeed.relevant(to: store.state.accounts)
        let ongoing = feeds.filter { latestIncident($0)?.important == true }.count
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Status") {
                if !feeds.isEmpty {
                    Chip(text: ongoing == 0 ? "All operational" : "\(ongoing) ongoing", tint: ongoing == 0 ? Palette.positive : Palette.warning,
                         symbol: ongoing == 0 ? "checkmark" : "exclamationmark.triangle.fill")
                }
            }
            if feeds.isEmpty {
                Text("Connect OpenAI, Claude, Azure or DeepSeek wallets to watch their status pages.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(feeds, id: \.id) { feed in
                let logo = feed.id == "openai" ? "openai-api" : feed.id == "anthropic" ? "claude-api" : feed.id == "azure" ? "azure-subscription" : "deepseek"
                let incident = latestIncident(feed)
                let failed = store.timelineErrors[feed.name] != nil
                let ongoingIncident = incident?.important == true
                let subtitle = failed ? "Could not read the status page"
                    : ongoingIncident ? incident!.title.replacingOccurrences(of: "\(feed.name): ", with: "")
                    : incident.map { "Operational · last incident \($0.date.formatted(.relative(presentation: .named)))" } ?? "Operational · no incidents in 14 days"
                Group {
                    if let link = incident?.source, ongoingIncident {
                        Link(destination: link) { sourceRow(logo, feed.name, subtitle) { statusDot(ongoing: true, failed: failed) } }.buttonStyle(.plain)
                    } else {
                        sourceRow(logo, feed.name, subtitle) { statusDot(ongoing: false, failed: failed) }
                    }
                }
                .help(subtitle)
            }
            if let checked = store.state.timelineCheckedAt {
                Text("Checked \(checked.formatted(.relative(presentation: .named)))").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .surface(padding: 18, radius: 22)
    }

    private func statusDot(ongoing: Bool, failed: Bool) -> some View {
        Circle().fill(failed ? Color.secondary : ongoing ? Palette.warning : Palette.positive).frame(width: 8, height: 8)
            .overlay(Circle().stroke((ongoing ? Palette.warning : Palette.positive).opacity(0.35), lineWidth: 4).opacity(failed ? 0 : 1))
    }

    private var newsSources: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "AI News") {
                Text(store.state.newsFeeds == false ? "Off" : "\(NewsFeed.all.count) feeds").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            if store.state.newsFeeds == false {
                Text("News feeds are off. Turn them on in Settings.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                FlowChips(items: NewsFeed.all.map(\.name))
            }
            Text(store.state.newModels == false ? "New models from OpenRouter are off." : "New models from OpenRouter's list, every six hours.")
                .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .surface(padding: 18, radius: 22)
    }

    private var xSources: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Posts on X") {
                if store.hasXToken { Text(store.xCost().plainText + " this month").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
            }
            if !store.hasXToken || (store.state.xHandles ?? []).isEmpty {
                Text(store.hasXToken ? "Add accounts to follow in Settings, such as the people who announce Codex limit resets." : "Follow people who announce limit resets, such as @thsottiaux, with your own X API token. Reads cost about US$0.005 per post.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { editor = .settings } label: { Label(store.hasXToken ? "Add Accounts" : "Set Up", systemImage: "at") }
                    .buttonStyle(PillButtonStyle(compact: true))
            }
            ForEach(store.hasXToken ? store.state.xHandles ?? [] : [], id: \.self) { handle in
                let failed = store.timelineErrors["@\(handle)"]
                HStack(spacing: 10) {
                    Text("𝕏").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 30, height: 30).background(Circle().fill(Palette.hex(0x15161B)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("@\(handle)").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(failed ?? "New posts every 30 minutes").font(.system(size: 11)).foregroundStyle(failed == nil ? Color.secondary : Palette.warning).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Link(destination: URL(string: "https://x.com/\(handle)")!) { Image(systemName: "arrow.up.right") }.buttonStyle(IconButtonStyle())
                }
                .help(failed ?? "")
            }
        }
        .surface(padding: 18, radius: 22)
    }

    private var repositorySources: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Releases", subtitle: store.state.repositories.isEmpty ? nil : "\(store.state.repositories.count)")
            if store.state.repositories.isEmpty {
                Text("Follow public GitHub repositories. Codex and Claude Code are followed for you when you add those wallets.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(store.state.repositories) { repository in
                sourceRow("github-releases", repository.slug,
                          repository.lastError != nil ? "Could not refresh" : repository.lastSuccess.map { "Checked \($0.formatted(.relative(presentation: .named)))" } ?? "Not checked yet") {
                    Link(destination: URL(string: "https://github.com/\(repository.slug)")!) { Image(systemName: "arrow.up.right") }
                        .buttonStyle(IconButtonStyle()).help("Open on GitHub")
                    Button { removal = .init(title: "Unfollow \(repository.slug)?", action: { try store.removeRepository(repository.id) }) } label: { Image(systemName: "trash") }
                        .buttonStyle(IconButtonStyle()).help("Unfollow").accessibilityLabel("Unfollow \(repository.slug)")
                }
                .help(repository.lastError ?? "")
            }
            let followed = Set(store.state.repositories.map { $0.slug.lowercased() })
            let suggestions = Self.suggestedRepositories.filter { !followed.contains($0.lowercased()) }.prefix(5)
            if !suggestions.isEmpty && store.state.repositories.count < 10 {
                Text("SUGGESTED").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.tertiary).padding(.top, 4)
                FlowLayout(spacing: 6) {
                    ForEach(Array(suggestions), id: \.self) { slug in
                        Button { perform { try store.addRepository(slug, includePrereleases: false) }; Task { await store.refreshDueRepositories() } } label: {
                            Label(slug, systemImage: "plus").font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 8).frame(height: 24)
                                .background(Capsule().fill(Palette.raised))
                        }
                        .buttonStyle(.plain)
                        .help("Follow \(slug) releases")
                    }
                }
            }
            Button { editor = .repository } label: { Label("Follow Repository", systemImage: "plus") }
                .buttonStyle(PillButtonStyle(compact: true))
        }
        .surface(padding: 18, radius: 22)
    }

    /// Widely used AI tools whose releases are worth knowing about.
    private static let suggestedRepositories = ["ollama/ollama", "ggml-org/llama.cpp", "vllm-project/vllm", "BerriAI/litellm",
                                                "modelcontextprotocol/servers", "openai/openai-agents-python", "anthropics/claude-agent-sdk-python", "cline/cline"]
}

/// Hover highlight for rows inside surfaces.
struct RowHighlight: View {
    @State private var hovering = false
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Palette.raised.opacity(hovering ? 0.7 : 0))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
