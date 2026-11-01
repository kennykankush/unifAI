import SwiftUI
import Charts
import UnifaiCore

/// What a wallet is made of. For cloud wallets: daily cost, every service, and every billed resource
/// (virtual machines with their power state, Foundry accounts with their deployed models, storage,
/// networking) with the meters behind each cost. For other wallets: the reading and its payments.
struct WalletDetail: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let accountID: UUID
    @State private var expanded: Set<String> = []
    @State private var editingPayment: PaymentRecord?
    @State private var paymentError: String?

    private var account: ConnectedAccount? { store.state.accounts.first { $0.id == accountID } }

    var body: some View {
        VStack(spacing: 0) {
            if let account {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        hero(account)
                        if let usage = account.snapshot?.providerUsage { providerUsagePanel(usage) }
                        if let usage = account.snapshot?.vercelUsage { vercelUsagePanel(usage) }
                        if let days = account.snapshot?.dailyCosts, days.count > 1 { dailyChart(days, anomalies: account.snapshot?.anomalies ?? []) }
                        if let services = account.snapshot?.services, !services.isEmpty { servicesPanel(services) }
                        if let resources = account.snapshot?.resources, !resources.isEmpty { resourcesPanel(resources) }
                        if account.snapshot?.resources == nil, account.integrationID == "azure-subscription" {
                            InlineNotice(text: "Resource details appear after the next refresh. They need the Reader role, which the Cost Management Reader role does not include.")
                        }
                        paymentsPanel(account)
                    }
                    .padding(24)
                }
                .defaultScrollAnchor(AppRuntime.initialScroll ?? .top)
            } else {
                Text("This wallet was removed.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 860, height: 720)
        .ignoresSafeArea()
        .background(Palette.canvas.ignoresSafeArea())
        .background(SheetChrome())
        .sheet(item: $editingPayment) { PaymentEditor(record: $0) }
        .alert("Payment could not be updated", isPresented: Binding(get: { paymentError != nil }, set: { if !$0 { paymentError = nil } })) {
            Button("OK", role: .cancel) { paymentError = nil }
        } message: { Text(paymentError ?? "") }
    }

    // MARK: Hero

    private func hero(_ account: ConnectedAccount) -> some View {
        let name = Catalogue.integration(account.integrationID)?.name ?? account.integrationID
        let spent = account.snapshot?.reportedConsumption.first
        return ZStack(alignment: .topLeading) {
            MeshBackdrop(colors: Palette.brand(account.integrationID))
            ProviderLogo(integrationID: account.integrationID, size: 190, ink: .white)
                .opacity(0.1).rotationEffect(.degrees(-14))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(x: 30, y: 50).allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    LogoCircle(integrationID: account.integrationID, size: 42, onColor: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.system(size: 17, weight: .bold))
                        Text([account.label, account.billingScope].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 12, weight: .medium)).opacity(0.8)
                    }
                    Spacer()
                    if account.mode == .live {
                        Button { Task { await store.refreshAccount(account.id) } } label: {
                            HStack(spacing: 6) {
                                if store.refreshingAccounts.contains(account.id) { Spinner() } else { Image(systemName: "arrow.clockwise") }
                                Text("Refresh")
                            }
                        }
                        .buttonStyle(PillButtonStyle(kind: .glass, compact: true))
                        .disabled(store.refreshingAccounts.contains(account.id))
                    }
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(onColor: true)).keyboardShortcut(.cancelAction).accessibilityLabel("Close")
                }
                Spacer(minLength: 18)
                if let usage = account.snapshot?.providerUsage {
                    Text(usage.costLabel).font(.system(size: 12, weight: .semibold)).opacity(0.8)
                    if let cost = usage.costs.first, usage.costs.count == 1 { MoneyText(money: cost, size: 44, weight: .heavy) }
                    else { Text(account.integrationID == "supabase" ? "\(account.snapshot?.resources?.count ?? 0) project\(account.snapshot?.resources?.count == 1 ? "" : "s")" : usage.costs.isEmpty ? "No usage rows" : "Multiple currencies").font(.system(size: 30, weight: .heavy)) }
                } else if let spent {
                    Text(account.snapshot?.consumptionPeriod.map { "Usage \($0.lowercased())" } ?? "Usage").font(.system(size: 12, weight: .semibold)).opacity(0.8)
                    MoneyText(money: spent, size: 44, weight: .heavy)
                    if let pace = Self.pace(spent) {
                        Text("On pace for about \(pace.plainText) by the end of the month").font(.system(size: 12, weight: .medium)).opacity(0.85).padding(.top, 4)
                    }
                } else if let balance = account.snapshot?.balances.first {
                    Text("Available").font(.system(size: 12, weight: .semibold)).opacity(0.8)
                    MoneyText(money: balance, size: 44, weight: .heavy)
                } else if let plan = account.snapshot?.plan {
                    Text("Plan").font(.system(size: 12, weight: .semibold)).opacity(0.8)
                    Text(plan).font(.system(size: 34, weight: .heavy)).tracking(-0.8)
                } else {
                    Text(account.mode == .manual ? "Manual records" : "No reading yet").font(.system(size: 28, weight: .heavy))
                }
                HStack(spacing: 8) {
                    if let observed = account.snapshot?.observedAt { GlassChip(text: "Updated \(observed.formatted(.relative(presentation: .named)))", dot: Palette.lime) }
                    if let spikes = account.snapshot?.anomalies, !spikes.isEmpty { GlassChip(text: spikes.count == 1 ? "1 cost spike" : "\(spikes.count) cost spikes", dot: Palette.warning) }
                    if let error = account.lastError { GlassChip(text: "Failed", dot: Palette.negative).help(error) }
                }
                .padding(.top, 12)
            }
            .padding(24)
        }
        .foregroundStyle(.white)
        .frame(height: 250)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
    }

    /// Straight-line projection of month-to-date usage over the whole month.
    static func pace(_ spent: Money, now: Date = .now) -> Money? {
        let calendar = Calendar.current
        guard let days = calendar.range(of: .day, in: .month, for: now)?.count else { return nil }
        let elapsed = calendar.component(.day, from: now)
        guard elapsed >= 3, elapsed < days, spent.amount > 0 else { return nil }
        return Money((spent.amount / Decimal(elapsed) * Decimal(days)).rounded2, spent.currency)
    }

    // MARK: Daily

    private struct Day: Identifiable { let id: String; let date: Date; let amount: Double; let spike: Bool; let partial: Bool }

    private func dailyChart(_ days: [DailyCost], anomalies: [CostAnomaly]) -> some View {
        let spikes = Set(anomalies.map(\.day))
        let today = RateTable.dayFormatter.string(from: .now)
        let points = days.suffix(35).compactMap { day -> Day? in
            guard let date = RateTable.dayFormatter.date(from: day.day) else { return nil }
            return Day(id: day.day, date: date, amount: NSDecimalNumber(decimal: day.amount).doubleValue, spike: spikes.contains(day.day), partial: day.day >= today)
        }
        let currency = account?.snapshot?.reportedConsumption.first?.currency ?? "USD"
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "Daily cost", subtitle: "Last \(points.count) days · \(currency)") {
                HStack(spacing: 12) {
                    legend(Palette.accent, "Day")
                    if !spikes.isEmpty { legend(Palette.warning, "Spike") }
                }
            }
            Chart(points) { point in
                BarMark(x: .value("Day", point.date, unit: .day), y: .value("Cost", point.amount))
                    .foregroundStyle(point.spike ? Palette.warning : Palette.accent.opacity(point.partial ? 0.45 : 1))
                    .cornerRadius(3)
            }
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
            .chartYAxis { AxisMarks(position: .leading) { AxisGridLine().foregroundStyle(Palette.border); AxisValueLabel() } }
            .frame(height: 170)
            if !anomalies.isEmpty {
                ForEach(anomalies, id: \.self) { spike in
                    Label(spike.summary, systemImage: "flame.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.warning)
                }
            }
        }
        .surface(padding: 20, radius: 22)
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
    }

    // MARK: Services

    private func servicesPanel(_ services: [CostLine]) -> some View {
        let top = services.map { NSDecimalNumber(decimal: $0.cost.amount).doubleValue }.max() ?? 1
        let sameCurrency = Set(services.map { $0.cost.currency }).count == 1
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Services", subtitle: account?.snapshot?.providerUsage?.period ?? "This month")
            ForEach(services, id: \.self) { line in
                HStack(spacing: 12) {
                    Text(line.name).font(.system(size: 13, weight: .medium)).lineLimit(1).frame(width: 220, alignment: .leading)
                    if sameCurrency { GeometryReader { proxy in
                        Capsule().fill(Palette.accent.opacity(0.85))
                            .frame(width: max(4, proxy.size.width * NSDecimalNumber(decimal: line.cost.amount).doubleValue / max(top, 0.01)))
                    }
                    .frame(height: 8) } else { Spacer(minLength: 12) }
                    MoneyText(money: line.cost, size: 13, weight: .semibold).frame(width: 110, alignment: .trailing)
                }
            }
        }
        .surface(padding: 20, radius: 22)
    }

    // MARK: Resources

    private static let families = ["Compute", "AI", "Storage & data", "Networking", "Other"]

    private func resourcesPanel(_ resources: [CloudResource]) -> some View {
        let groups = Dictionary(grouping: resources, by: \.family)
        return VStack(alignment: .leading, spacing: 6) {
            SectionHeading(title: account?.integrationID == "vercel" ? "Projects" : "Resources",
                           subtitle: account?.snapshot?.providerUsage != nil ? "\(resources.count) · provider report" : account?.integrationID == "vercel" ? "\(resources.count) · gross charges this month" : "\(resources.count) · cost this month")
                .padding(.bottom, 6)
            ForEach(Self.families.filter { groups[$0] != nil }, id: \.self) { family in
                Text(family.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.tertiary)
                    .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 2)
                ForEach(groups[family] ?? []) { resourceRow($0) }
            }
        }
        .surface(padding: 20, radius: 22)
    }

    private func symbol(_ resource: CloudResource) -> String {
        switch resource.type {
        case "microsoft.compute/virtualmachines": return "desktopcomputer"
        case "microsoft.compute/disks", "microsoft.compute/snapshots": return "internaldrive.fill"
        case "microsoft.cognitiveservices/accounts", "microsoft.machinelearningservices/workspaces": return "sparkles"
        case "microsoft.search/searchservices": return "magnifyingglass"
        case "microsoft.storage/storageaccounts": return "externaldrive.fill"
        case "microsoft.containerinstance/containergroups", "microsoft.app/containerapps", "microsoft.containerregistry/registries": return "shippingbox.fill"
        default: return resource.family == "Networking" ? "network" : "cube.fill"
        }
    }

    private func stateChip(_ state: String) -> Chip {
        switch state {
        case "READY": return Chip(text: "Ready", tint: Palette.positive, symbol: "play.fill")
        case "ACTIVE_HEALTHY": return Chip(text: "Healthy", tint: Palette.positive, symbol: "play.fill")
        case "INACTIVE": return Chip(text: "Inactive", tint: .secondary, symbol: "pause.fill")
        case "ERROR": return Chip(text: "Deployment failed", tint: Palette.negative, symbol: "exclamationmark.triangle.fill")
        case "BUILDING": return Chip(text: "Building", tint: .secondary, symbol: "arrow.triangle.2.circlepath")
        case "Running": return Chip(text: "Running", tint: Palette.positive, symbol: "play.fill")
        case "Stopped": return Chip(text: "Stopped, still billed", tint: Palette.warning, symbol: "exclamationmark.triangle.fill")
        case "Deleted": return Chip(text: "Deleted", tint: .secondary, symbol: "trash")
        default: return Chip(text: state, tint: .secondary, symbol: "pause.fill")
        }
    }

    private func resourceRow(_ resource: CloudResource) -> some View {
        let open = expanded.contains(resource.id)
        let quantities = account?.snapshot?.vercelUsage?.meters.filter { $0.projectID == resource.id } ?? []
        let providerMeters = account?.snapshot?.providerUsage?.meters.filter { $0.resourceID == resource.id } ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol(resource)).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.accentInk)
                    .frame(width: 38, height: 38).background(Circle().fill(Palette.accent.opacity(0.14)))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(resource.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        if let state = resource.state { stateChip(state) }
                    }
                    Text([resource.kind, resource.size, resource.group.isEmpty ? nil : resource.group, resource.location].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    if let models = resource.models, !models.isEmpty {
                        FlowChips(items: models.map { model in
                            [model.model, model.version, model.sku, model.capacity.map { "\($0)K TPM" }].compactMap { $0 }.joined(separator: " · ")
                        })
                        .padding(.top, 2)
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    if let cost = resource.cost { MoneyText(money: cost, size: 15, weight: .bold) }
                    else { Text(Set(resource.meters.map { $0.cost.currency }).count > 1 ? "Multiple currencies" : resource.type.hasPrefix("microsoft.") ? "No cost yet" : "Cost unavailable").font(.system(size: 12)).foregroundStyle(.tertiary) }
                    if !resource.meters.isEmpty || !quantities.isEmpty || !providerMeters.isEmpty {
                        Button { withAnimation(.snappy(duration: 0.2)) { if open { expanded.remove(resource.id) } else { expanded.insert(resource.id) } } } label: {
                            Label(open ? "Hide meters" : "Show meters", systemImage: open ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                if let url = resource.portalURL, resource.state != "Deleted" {
                    Link(destination: url) { Image(systemName: "arrow.up.right") }.buttonStyle(IconButtonStyle()).help("Open in provider dashboard").accessibilityLabel("Open \(resource.name) in provider dashboard")
                }
            }
            if open {
                VStack(spacing: 6) {
                    ForEach(Array(providerMeters.enumerated()), id: \.offset) { _, meter in
                        HStack(alignment: .firstTextBaseline) {
                            Text(meter.name).font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(meter.quantity.formatted()) \(meter.unit)").font(.system(size: 12)).monospacedDigit()
                        }
                    }
                    ForEach(Array(quantities.enumerated()), id: \.offset) { _, meter in
                        HStack(alignment: .firstTextBaseline) {
                            Text(meter.name).font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(meter.quantity.formatted()) \(meter.unit)").font(.system(size: 12)).monospacedDigit()
                        }
                    }
                    ForEach(resource.meters, id: \.self) { meter in
                        HStack {
                            Text(meter.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            MoneyText(money: meter.cost, size: 12, weight: .medium)
                        }
                    }
                }
                .padding(.leading, 50).padding(.trailing, 44)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(RowHighlight())
    }

    // MARK: Payments

    private func providerUsagePanel(_ usage: ProviderUsage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Provider report", subtitle: usage.period)
            ForEach(usage.costs, id: \.currency) { cost in
                HStack { Text(usage.costLabel); Spacer(); MoneyText(money: cost, size: 20, weight: .bold) }
            }
            if usage.costs.isEmpty { Text("No monetary total returned").font(.callout).foregroundStyle(.secondary) }
            ForEach(Array(usage.meters.filter { $0.resourceID == nil }.enumerated()), id: \.offset) { _, meter in
                HStack(alignment: .firstTextBaseline) {
                    Text(meter.name).font(.system(size: 13, weight: .medium)); Spacer(minLength: 16)
                    Text("\(meter.quantity.formatted()) \(meter.unit)").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                }
            }
            ForEach(usage.details, id: \.self) { detail in
                HStack { Text(detail.label); Spacer(); MoneyText(money: detail.value, size: 14, weight: .medium) }
            }
            Text(usage.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.surface(padding: 20, radius: 22)
    }

    private func vercelUsagePanel(_ usage: VercelUsage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Vercel usage", subtitle: "Calendar month to date · UTC")
            if let gross = usage.grossCost {
                HStack { Text("Gross charges before credits"); Spacer(); MoneyText(money: gross, size: 20, weight: .bold) }
            }
            ForEach(Array(usage.meters.filter { $0.projectID == nil }.enumerated()), id: \.offset) { _, meter in
                HStack(alignment: .firstTextBaseline) {
                    Text(meter.name).font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 16)
                    Text("\(meter.quantity.formatted()) \(meter.unit)").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                }
            }
            Text(usage.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Plan changes appear in Timeline after refresh. The first reading does not establish your upgrade date.")
                .font(.caption).foregroundStyle(.secondary)
        }.surface(padding: 20, radius: 22)
    }

    private func paymentsPanel(_ account: ConnectedAccount) -> some View {
        let records = store.state.payments.filter { $0.accountID == account.id }.sorted { $0.paidAt > $1.paidAt }
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: "Payments", subtitle: records.isEmpty ? "None recorded" : "\(records.count)")
            if records.isEmpty {
                Text(account.integrationID == "azure-subscription" ? "Azure bills after each month. Unifai records the month's usage as an Estimate at month end; import the invoice to replace it."
                     : "Record top-ups and charges for this wallet in Payments.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(records.prefix(12)) { record in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.description).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(record.paidAt.formatted(date: .abbreviated, time: .omitted) + (record.autoRecorded ? " · \(record.estimated == true ? "Estimate" : "Auto")" : ""))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        if let evidence = record.detection {
                            Text("Observed \(evidence.before.plainText) → \(evidence.after.plainText)")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    MoneyText(money: record.money, size: 14, prefix: record.kind == .refund ? "+" : "−")
                    if record.autoRecorded {
                        Button("Confirm") {
                            do { try store.confirmPayment(record.id) }
                            catch { paymentError = error.localizedDescription }
                        }.buttonStyle(PillButtonStyle(compact: true)).help("Confirm that this amount matches your receipt")
                    }
                    Button { editingPayment = record } label: { Image(systemName: "pencil") }
                        .buttonStyle(IconButtonStyle()).help("Correct payment details").accessibilityLabel("Edit \(record.description)")
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .surface(padding: 20, radius: 22)
    }
}

/// Small chips that wrap onto further lines.
struct FlowChips: View {
    let items: [String]
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accentInk)
                    .padding(.horizontal, 8).frame(height: 22).background(Capsule().fill(Palette.accent.opacity(0.14)))
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing; row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; row = max(row, size.height)
        }
    }
}

/// macOS 26 gives sheets a title bar strip; make it transparent so the content runs to the top edge.
struct SheetChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = Palette.canvasNS
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
