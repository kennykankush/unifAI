import SwiftUI
import UnifaiCore

struct EditorFrame<Fields: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let saveLabel: String
    let error: String?
    let save: () -> Void
    @ViewBuilder let fields: () -> Fields
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 22, weight: .bold)).padding(.horizontal, 24).padding(.top, 24)
            Form { fields() }.formStyle(.grouped)
            if let error { InlineNotice(text: error).padding(.horizontal, 24).accessibilityElement(children: .ignore).accessibilityLabel("Validation error: \(error)") }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button(saveLabel, action: save).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }
                .padding(.horizontal, 24).padding(.bottom, 24)
        }.frame(width: 540).frame(minHeight: 440, maxHeight: 650)
    }
}

struct AccountEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let integration: Integration
    let account: ConnectedAccount?
    @State private var label: String
    @State private var owner: String
    @State private var mode: ConnectionMode
    @State private var credential = ""
    @State private var error: String?
    @State private var signingIn = false
    @State private var signInStatus: String?
    @State private var alertBelow = ""
    init(integration: Integration, account: ConnectedAccount?) {
        self.integration = integration; self.account = account
        _label = State(initialValue: account?.label ?? "")
        _owner = State(initialValue: account?.billingScope ?? "")
        _mode = State(initialValue: account?.mode ?? (integration.status == .ready ? .live : .manual))
        _alertBelow = State(initialValue: account?.lowBalanceAlert.map { "\($0)" } ?? "")
    }
    var body: some View {
        EditorFrame(title: account == nil ? "Add \(integration.name)" : "Edit \(integration.name)", saveLabel: account == nil ? "Add Account" : "Save Account", error: error, save: save) {
            Section {
                TextField("Account Label", text: $label, prompt: Text("Personal or Work"))
                if account == nil {
                    TextField("Billing Owner", text: $owner, prompt: Text(integration.id == "codex" ? "ChatGPT Plus, personal" : "Organization or billing account"))
                    if integration.status == .ready {
                        Picker("Connection", selection: $mode) { Text("Live Connection").tag(ConnectionMode.live); Text("Manual Records").tag(ConnectionMode.manual) }
                    }
                } else { LabeledContent("Billing Owner", value: owner.isEmpty ? "Unspecified" : owner) }
            } footer: { Text("Connect each billing owner once. Two keys for the same owner share one balance.") }
            if mode == .live && !integration.needsCredential {
                Section {
                    Label(localToolTitle, systemImage: "terminal")
                    Text(localToolText).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(SignIn.title(integration.id)) { startSignIn() }.disabled(signingIn)
                        if signingIn { Spinner(size: .small) }
                        if let signInStatus { Text(signInStatus).font(.caption).foregroundStyle(.secondary) }
                    }
                } footer: { Text("Already signed in to \(integration.id == "codex" ? "Codex" : integration.id == "azure-subscription" ? "the Azure CLI" : "Claude Code")? Skip this and add the account.") }
            } else if mode == .live {
                Section {
                    SecureField(account == nil ? "Credential" : "Replace Credential", text: $credential, prompt: Text(account == nil ? (integration.id == "openai-api" ? "sk-admin-..." : integration.id == "claude-api" ? "sk-ant-admin01-..." : "Paste a key") : "Leave blank to keep the saved key"))
                        .textContentType(.password)
                    Text(credentialHint).font(.caption).foregroundStyle(.secondary)
                } footer: { Text("Saved per account in macOS Keychain. No refresh occurs until you click Refresh. In a synthetic workspace, keys stay in memory and requests use fixtures.") }
            }
            if let account, account.mode == .live, let balance = account.snapshot?.balances.first {
                Section {
                    TextField("Alert when credit falls below", text: $alertBelow, prompt: Text(Notifier.defaultThreshold(for: balance.currency).description))
                } footer: { Text("In \(balance.currency). Leave blank for the default of \(Notifier.defaultThreshold(for: balance.currency)) \(balance.currency).") }
            }
            Section { Text(integration.limitation).font(.callout).foregroundStyle(.secondary) }
        }
    }
    private var localToolTitle: String {
        switch integration.id {
        case "codex": return "Uses the Codex app on this Mac"
        case "azure-subscription": return "Uses the Azure CLI on this Mac"
        default: return "Uses Claude Code on this Mac"
        }
    }
    private var localToolText: String {
        switch integration.id {
        case "codex": return "Unifai asks Codex for your ChatGPT plan, Codex usage windows and credits. Codex keeps the sign-in; Unifai stores no OpenAI password or token."
        case "azure-subscription": return "Unifai runs read-only cost queries with az for every enabled subscription. The Azure CLI keeps the sign-in; Unifai stores no Azure credential. The signed-in account needs Cost Management Reader or Reader."
        default: return "Unifai asks Claude Code which plan you are signed in to. Claude Code keeps the sign-in; Unifai never reads its token. Anthropic does not share subscription usage limits with other apps."
        }
    }
    private func startSignIn() {
        signingIn = true; signInStatus = integration.id == "codex" ? "Finish in your browser" : nil; error = nil
        Task {
            do {
                try await SignIn.start(integration.id)
                signInStatus = integration.id == "codex" ? "Signed in" : "Finish in Terminal, then add the account"
            } catch { self.error = error.localizedDescription; signInStatus = nil }
            signingIn = false
        }
    }
    private var credentialHint: String {
        switch integration.id {
        case "openrouter": return "OpenRouter requires a management key. It has broad account authority; Unifai only sends GET /api/v1/credits."
        case "openai-api": return "Create an organization Admin key at platform.openai.com > Settings > Organization > Admin keys. It has broad access; Unifai only sends GET /v1/organization/costs."
        case "claude-api": return "Create an Admin key in Claude Console > Settings > Admin keys (organizations only). It has broad access; Unifai only sends GET /v1/organizations/cost_report. Import top-ups from receipts on the Payments page."
        case "kimi": return "Create an API key at platform.kimi.ai > API Keys. Unifai only sends GET /v1/users/me/balance."
        case "vercel-ai-gateway": return "Create an API key in the Vercel dashboard > AI Gateway > API Keys. Unifai only sends GET /v1/credits."
        case "elevenlabs": return "Create an API key at elevenlabs.io > Developers > API Keys; it needs User read access. Unifai only sends GET /v1/user/subscription."
        default: return "Unifai only sends GET /user/balance with the key you enter."
        }
    }
    private func save() {
        do {
            if let account {
                try store.updateAccount(account.id, label: label, credential: credential)
                let threshold = alertBelow.trimmingCharacters(in: .whitespaces)
                if threshold.isEmpty { try store.setLowBalanceAlert(account.id, below: nil) }
                else {
                    guard let value = Money.parseAmount(threshold) else { throw ValidationError.message("Enter an alert amount like 5.00, or leave it blank.") }
                    try store.setLowBalanceAlert(account.id, below: value)
                }
            }
            else { try store.addAccount(integrationID: integration.id, label: label, billingScope: owner, mode: mode, credential: credential) }
            credential = ""; dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct AccountPicker: View {
    @EnvironmentObject private var store: AppStore
    @Binding var selection: UUID?
    var body: some View {
        Picker("Account", selection: $selection) {
            Text("Unassigned").tag(nil as UUID?)
            ForEach(store.state.accounts) { Text("\(Catalogue.integration($0.integrationID)?.name ?? $0.integrationID) · \($0.label)").tag(Optional($0.id)) }
        }
    }
}

struct PaymentEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let record: PaymentRecord?
    @State private var account: UUID?
    @State private var name: String
    @State private var kind: PaymentKind
    @State private var amount: String
    @State private var currency: String
    @State private var paidAt: Date
    @State private var reference: String
    @State private var error: String?
    init(record: PaymentRecord?) {
        self.record = record
        _account = State(initialValue: record?.accountID)
        _name = State(initialValue: record?.description ?? "")
        _kind = State(initialValue: record?.kind ?? .topUp)
        _amount = State(initialValue: record.map { $0.money.amount > 0 ? $0.money.amount.description : "" } ?? "")
        _currency = State(initialValue: record?.money.currency ?? "USD")
        _paidAt = State(initialValue: record?.paidAt ?? .now)
        _reference = State(initialValue: record?.reference ?? "")
    }
    var body: some View {
        EditorFrame(title: "Confirmed Payment", saveLabel: "Save Payment", error: error, save: save) {
            Section {
                TextField("Description", text: $name, prompt: Text("Credit purchase or subscription"))
                AccountPicker(selection: $account)
                Picker("Payment Type", selection: $kind) { ForEach(PaymentKind.allCases) { Text($0.rawValue).tag($0) } }
                TextField("Amount", text: $amount, prompt: Text("100.00"))
                TextField("Currency", text: $currency, prompt: Text("USD or CNY"))
                DatePicker("Paid On", selection: $paidAt, in: ...Date.now, displayedComponents: .date)
                TextField("Receipt Reference", text: $reference, prompt: Text("Optional, used to detect duplicates"))
            } footer: { Text("Use a positive amount, including for refunds. Refunds reduce money paid. Enter a decimal point without thousands separators. Scheduled renewals belong in Subscriptions.") }
        }
    }
    private func save() {
        do {
            guard let value = Money.parseAmount(amount) else { throw ValidationError.message("Enter an amount such as 100.00, using a decimal point.") }
            let item = PaymentRecord(id: record?.id ?? UUID(), accountID: account, description: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind,
                                     money: Money(value, currency.trimmingCharacters(in: .whitespacesAndNewlines)), paidAt: paidAt, reference: reference.trimmingCharacters(in: .whitespacesAndNewlines))
            try store.savePayment(item); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct SubscriptionEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let schedule: SubscriptionSchedule?
    @State private var account: UUID?
    @State private var name: String
    @State private var amount: String
    @State private var currency: String
    @State private var cadence: BillingCadence
    @State private var renewal: Date
    @State private var autoRecord: Bool
    @State private var error: String?
    init(schedule: SubscriptionSchedule?) {
        self.schedule = schedule
        _account = State(initialValue: schedule?.accountID)
        _name = State(initialValue: schedule?.name ?? "")
        _amount = State(initialValue: schedule?.price.amount.description ?? "")
        _currency = State(initialValue: schedule?.price.currency ?? "USD")
        _cadence = State(initialValue: schedule?.cadence ?? .monthly)
        _renewal = State(initialValue: schedule?.nextRenewal ?? .now)
        _autoRecord = State(initialValue: schedule?.recordsAutomatically ?? true)
    }
    var body: some View {
        EditorFrame(title: "Subscription Schedule", saveLabel: "Save Schedule", error: error, save: save) {
            Section {
                TextField("Subscription Name", text: $name, prompt: Text("Plan name"))
                AccountPicker(selection: $account)
                TextField("Expected Amount", text: $amount, prompt: Text("20.00"))
                TextField("Currency", text: $currency, prompt: Text("USD"))
                Picker("Cadence", selection: $cadence) { ForEach(BillingCadence.allCases) { Text($0.rawValue).tag($0) } }
                DatePicker("Next Expected Renewal", selection: $renewal, displayedComponents: .date)
                Toggle("Record each renewal automatically when it's due", isOn: $autoRecord)
            } footer: { Text(autoRecord
                ? "On the renewal date Unifai adds the charge to Payments, marked Auto, and moves this schedule forward. Importing the real receipt replaces the Auto entry. Dates before today are never back-filled."
                : "This only tracks the expected charge. Record each completed renewal yourself and update its next date.") }
        }
    }
    private func save() {
        do {
            guard let value = Money.parseAmount(amount) else { throw ValidationError.message("Enter an expected amount such as 20.00.") }
            let existing = schedule.flatMap { schedule in store.state.subscriptions.first { $0.id == schedule.id } }
            try store.saveSubscription(.init(id: schedule?.id ?? UUID(), accountID: account, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                             price: Money(value, currency.trimmingCharacters(in: .whitespacesAndNewlines)), cadence: cadence, nextRenewal: renewal,
                                             autoRecord: autoRecord, createdAt: existing?.createdAt ?? .now))
            _ = store.recordDueRenewals()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct RepositoryEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var slug = ""
    @State private var prereleases = false
    @State private var error: String?
    var body: some View {
        EditorFrame(title: "Follow Public Repository", saveLabel: "Follow Repository", error: error, save: save) {
            Section {
                TextField("Repository", text: $slug, prompt: Text("owner/repository"))
                Toggle("Include Prereleases", isOn: $prereleases)
            } footer: { Text("A local follow in Unifai. Your GitHub stars and watches are unchanged. Refresh after adding to retrieve the latest 50 releases. Private repositories and GitHub credentials are not supported.") }
        }
    }
    private func save() {
        do { try store.addRepository(slug, includePrereleases: prereleases); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

struct CoverageEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date = .now
    @State private var complete = false
    @State private var error: String?
    var body: some View {
        EditorFrame(title: "Payment History Coverage", saveLabel: "Save Coverage", error: error, save: save) {
            Section {
                DatePicker("Recorded Since", selection: $start, in: ...Date.now, displayedComponents: .date)
                Toggle("All Payments Since This Date Are Recorded", isOn: $complete)
            } footer: { Text("Only confirm completeness after checking your receipts for every account. The total covers this period. A current balance cannot establish lifetime spending.") }
        }.onAppear { start = store.state.coverageStart ?? .now; complete = store.state.historyCoverage?.completeForPeriod ?? false }
    }
    private func save() {
        do { try store.setCoverage(start: Calendar.current.startOfDay(for: start), complete: complete); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

/// App settings: display currency, monthly budget, background refresh and notifications.
struct SettingsEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var displayCurrency = ""
    @State private var budgetAmount = ""
    @State private var budgetCurrency = ""
    @State private var autoRefresh = true
    @State private var notifications = true
    @State private var xToken = ""
    @State private var removeXToken = false
    @State private var xHandles = ""
    @State private var newsFeeds = true
    @State private var newModels = true
    @State private var showBackups = false
    @State private var error: String?
    private var currencies: [String] {
        let recorded = Set(store.state.payments.map(\.money.currency))
        return Array(recorded.union(["SGD", "USD", "EUR", "GBP", "CNY", "JPY"]).union([Locale.current.currency?.identifier ?? "USD"])).filter { Money.validCurrency($0) }.sorted()
    }
    var body: some View {
        EditorFrame(title: "Settings", saveLabel: "Save Settings", error: error, save: save) {
            Section {
                Picker("Show spending in", selection: $displayCurrency) {
                    Text("Each currency separately").tag("")
                    ForEach(currencies, id: \.self) { Text("All in \($0)").tag($0) }
                }
            } header: { Text("Currency") } footer: { Text("Combined figures convert each payment at the European Central Bank rate for its date. Recorded amounts never change.") }
            Section {
                TextField("Monthly AI and cloud budget", text: $budgetAmount, prompt: Text("Leave blank for no budget"))
                Picker("Budget currency", selection: $budgetCurrency) { ForEach(currencies, id: \.self) { Text($0).tag($0) } }
            } header: { Text("Budget") } footer: { Text("Your budget includes this month's recorded payments and accruing cloud usage. Notifications use the same total at 80% and 100%.") }
            Section {
                Button("Review Local Backups") { showBackups = true }
            } header: { Text("Saved data") } footer: {
                Text("Automatic copies keep recent records recoverable on this Mac. API keys stay in Keychain.")
            }
            Section {
                Toggle("Refresh wallets in the background every hour", isOn: $autoRefresh)
                Toggle("Notifications", isOn: $notifications)
            } header: { Text("Automation") } footer: { Text("Notifications cover low credit, failed refreshes, renewals due tomorrow, recorded renewals, usage limits resetting, early resets, free resets, cost spikes and your budget. Everything is computed on this Mac.") }
            Section {
                Toggle("AI news feeds", isOn: $newsFeeds)
                Toggle("New models from OpenRouter", isOn: $newModels)
            } header: { Text("Timeline") } footer: { Text("News from OpenAI, Google DeepMind, Google AI, Hugging Face and Simon Willison's weblog, and models added to OpenRouter in the last two weeks. Public feeds, read without an account.") }
            Section {
                TextField("Accounts to follow", text: $xHandles, prompt: Text("thsottiaux, OpenAIDevs"))
                if store.hasXToken && !removeXToken {
                    HStack {
                        Text("Bearer token saved in Keychain").foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove") { removeXToken = true }
                    }
                } else {
                    SecureField("Bearer token", text: $xToken, prompt: Text("From your X developer app"))
                }
                LabeledContent("Estimated X API cost this month", value: store.xCost().plainText)
            } header: { Text("Posts on X") } footer: {
                Text("Optional. Shows posts from these accounts in the Timeline, such as announcements of limit resets, checked every 30 minutes. X bills your developer account about US$0.005 per post read and US$0.01 per account lookup; Unifai only asks for posts newer than the last one it saw. [Get a token](https://console.x.com)")
            }
        }
        .sheet(isPresented: $showBackups) { BackupsView(onRestore: { dismiss() }) }
        .onAppear {
            displayCurrency = store.state.displayCurrency ?? ""
            budgetAmount = store.state.monthlyBudget.map { "\($0.amount)" } ?? ""
            budgetCurrency = store.state.monthlyBudget?.currency ?? store.state.displayCurrency ?? Locale.current.currency?.identifier ?? "USD"
            autoRefresh = store.state.autoRefresh != false
            notifications = Notifier.shared.enabled
            xHandles = (store.state.xHandles ?? []).joined(separator: ", ")
            newsFeeds = store.state.newsFeeds != false
            newModels = store.state.newModels != false
        }
    }
    private func save() {
        do {
            let trimmed = budgetAmount.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { try store.setMonthlyBudget(nil) }
            else {
                guard let amount = Money.parseAmount(trimmed) else { throw ValidationError.message("Enter a budget like 400.00, or leave it blank.") }
                try store.setMonthlyBudget(Money(amount, budgetCurrency))
            }
            try store.setAutoRefresh(autoRefresh)
            try store.setXHandles(xHandles)
            if newsFeeds != (store.state.newsFeeds != false) { try store.setNewsFeeds(newsFeeds) }
            if newModels != (store.state.newModels != false) { try store.setNewModels(newModels) }
            if removeXToken { try store.setXToken(nil) }
            else if !xToken.trimmingCharacters(in: .whitespaces).isEmpty { try store.setXToken(xToken) }
            Notifier.shared.enabled = notifications
            let target = displayCurrency.isEmpty ? nil : displayCurrency
            if target != store.state.displayCurrency { Task { await store.setDisplayCurrency(target) } }
            Notifier.shared.evaluate(store)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
