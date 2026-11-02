import SwiftUI
import UnifaiCore

struct MCPActivityView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var embedded = false
    var query = ""
    @State private var scanning = false
    @State private var error: String?
    @State private var purchase: String?
    @State private var showPurchase = false
    private var services: [MCPServiceSummary] { store.state.mcpServices().filter { query.isEmpty || $0.id.localizedCaseInsensitiveContains(query) || $0.purchases.contains { $0.name.localizedCaseInsensitiveContains(query) } } }
    var body: some View {
        Group {
            if embedded { content }
            else { content.padding(24).frame(width: 820, height: 710).background(Palette.canvas) }
        }.sheet(isPresented: $showPurchase) { MCPSubscriptionEditor(server: purchase) }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MCP activity").font(.system(size: 26, weight: .bold))
                    Text("What you use, and what you paid for").foregroundStyle(.secondary)
                }
                Spacer()
                Button("I subscribed") { purchase = nil; showPurchase = true }.buttonStyle(PillButtonStyle(kind: .primary))
                if !embedded { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
            HStack {
                Toggle("Read local client history", isOn: Binding(get: { store.state.mcpTrackingEnabled == true }, set: { value in
                    do { try store.setMCPTracking(value); if value { refresh() } } catch { self.error = error.localizedDescription }
                }))
                Spacer()
                Button(scanning ? "Scanning…" : "Scan now", action: refresh).disabled(scanning || store.state.mcpTrackingEnabled != true)
            }
            Text("Reads Claude Code and Codex session files on this Mac. Saves tool names, dates and outcomes only; no prompts, arguments, results or credentials. Refreshes every 30 minutes while Unifai runs.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { InlineNotice(text: error) }
            if let scan = store.state.mcpScan {
                Text(scan.coverage).font(.caption).foregroundStyle(.secondary)
                Text("Last scan: \(scan.date.formatted())\(scan.unavailableSources.isEmpty ? "" : " · Unavailable: " + scan.unavailableSources.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text("No scan yet. A subscription can be recorded before its first observed call.").font(.callout).foregroundStyle(.secondary) }
            Group {
                if embedded { serviceList }
                else { ScrollView { serviceList } }
            }
        }
    }
    private var serviceList: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
                    if services.isEmpty {
                        Text("No MCP activity recorded").font(.title3.bold()).padding(.top, 24)
                        Text("Enable history reads, or choose “I subscribed” to record Refero or another service.").foregroundStyle(.secondary)
                    }
                    ForEach(services) { service in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(service.purchases.first?.name ?? service.id).font(.system(size: 18, weight: .bold))
                                Spacer()
                                if service.purchases.isEmpty {
                                    Button("I subscribed") { purchase = service.id; showPurchase = true }.buttonStyle(PillButtonStyle(compact: true))
                                } else { Text("Purchase linked").font(.caption).foregroundStyle(Palette.accentInk) }
                            }
                            HStack(spacing: 24) {
                                Text("\(service.calls) observed calls · 30 days").fontWeight(.semibold)
                                Text("\(service.sessions) sessions")
                                Text("\(service.failed) reported errors")
                            }.font(.system(size: 13)).monospacedDigit()
                            if service.unknown > 0 { Text("\(service.unknown) calls have no recorded result").font(.caption).foregroundStyle(.secondary) }
                            Text(service.lastUsed.map { "Last observed \($0.formatted())" } ?? "No calls observed in retained history")
                                .font(.caption).foregroundStyle(.secondary)
                            if !service.clients.isEmpty { Text(service.clients.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                            if let top = service.tools.max(by: { $0.value < $1.value }) {
                                Text("Most used: \(top.key) · \(top.value) calls").font(.caption).textSelection(.enabled)
                            }
                            ForEach(service.purchases) { bought in
                                let payment = store.state.payments.first { $0.id == bought.paymentID }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("\(bought.plan.rawValue) · subscribed \(bought.startedAt.formatted(date: .abbreviated, time: .omitted))")
                                    Text(payment.map { "Linked payment: \($0.money.plainText) · \($0.paidAt.formatted(date: .abbreviated, time: .omitted))" } ?? "Linked payment is no longer available")
                                    if let schedule = store.state.subscriptions.first(where: { $0.id == bought.scheduleID }) {
                                        Text("Expected renewal: \(schedule.nextRenewal.formatted(date: .abbreviated, time: .omitted))")
                                    }
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Provider quota unavailable. No observed calls does not prove this service was unused.").font(.caption).foregroundStyle(.secondary)
                        }.surface(padding: 18, radius: 20)
                    }
                }
    }
    private func refresh() {
        guard !scanning else { return }
        if AppRuntime.fixtureMode { return }
        scanning = true; error = nil
        Task {
            defer { scanning = false }
            do { try await store.refreshMCPActivity() } catch { self.error = error.localizedDescription }
        }
    }
}

struct MCPSubscriptionEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var server: String
    @State private var name: String
    @State private var plan = MCPPurchase.Plan.monthly
    @State private var startedAt = Date.now
    @State private var amount = ""
    @State private var currency = "USD"
    @State private var existing = false
    @State private var paymentID: UUID?
    @State private var trackRenewal = false
    @State private var nextRenewal = Calendar.current.date(byAdding: .month, value: 1, to: .now)!
    @State private var error: String?
    init(server: String?) {
        _server = State(initialValue: server ?? "")
        _name = State(initialValue: server == "refero" ? "Refero" : server ?? "")
    }
    private var payments: [PaymentRecord] { store.state.payments.filter { $0.accountID != nil && $0.kind != .refund }.sorted { $0.paidAt > $1.paidAt } }
    var body: some View {
        EditorFrame(title: "Which MCP did you subscribe to?", saveLabel: existing ? "Link Purchase" : "Record Purchase", error: error, save: save) {
            Section {
                TextField("Service", text: $name, prompt: Text("Refero"))
                TextField("Match activity from", text: $server, prompt: Text("refero"))
                    .help("Use the name detected in local history, such as refero.")
                if !store.state.mcpServices().isEmpty {
                    Picker("Detected services", selection: $server) {
                        Text("Choose or type above").tag(server)
                        ForEach(store.state.mcpServices().filter { $0.id != server }) { Text($0.id).tag($0.id) }
                    }
                }
                Picker("Plan", selection: $plan) { ForEach(MCPPurchase.Plan.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                DatePicker("Subscribed on", selection: $startedAt, in: ...Date.now, displayedComponents: .date)
            } footer: { Text("Your declaration records the purchase. MCP activity alone cannot establish whether or when you subscribed.") }
            Section {
                Toggle("Already recorded in Payments", isOn: $existing)
                if existing {
                    Picker("Existing payment", selection: $paymentID) {
                        Text("Choose a payment").tag(nil as UUID?)
                        ForEach(payments) { p in Text("\(p.description) · \(p.money.plainText) · \(p.paidAt.formatted(date: .abbreviated, time: .omitted))").tag(Optional(p.id)) }
                    }.onChange(of: paymentID) { _, value in
                        if let p = payments.first(where: { $0.id == value }) { amount = p.money.amount.description; currency = p.money.currency; startedAt = p.paidAt }
                    }
                }
                TextField(trackRenewal && existing ? "Renewal amount" : "Amount paid", text: $amount, prompt: Text("20.00"))
                    .disabled(existing && !trackRenewal)
                TextField("Currency", text: $currency, prompt: Text("USD"))
                    .disabled(existing && !trackRenewal)
            } footer: { Text(existing ? "Links the payment without adding another charge. Its confirmation status stays unchanged." : "Creates one payment and a wallet for this service. No past renewals are invented.") }
            if plan == .monthly || plan == .annual {
                Section {
                    Toggle("Track the next renewal", isOn: $trackRenewal)
                    if trackRenewal { DatePicker("Next renewal", selection: $nextRenewal, displayedComponents: .date) }
                } footer: { Text("An expected renewal only; automatic payment recording is off.") }
            }
        }
        .onChange(of: name) { old, value in if server.isEmpty || server == old.lowercased().replacingOccurrences(of: " ", with: "-") { server = value.lowercased().replacingOccurrences(of: " ", with: "-") } }
    }
    private func save() {
        do {
            guard let value = Money.parseAmount(amount) else { throw ValidationError.message("Enter an amount such as 20.00.") }
            guard !existing || paymentID != nil else { throw ValidationError.message("Choose the payment you already recorded.") }
            try store.recordMCPSubscription(server: server, name: name, plan: plan, startedAt: startedAt,
                amount: Money(value, currency.uppercased()), existingPaymentID: existing ? paymentID : nil,
                nextRenewal: trackRenewal && (plan == .monthly || plan == .annual) ? nextRenewal : nil)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
