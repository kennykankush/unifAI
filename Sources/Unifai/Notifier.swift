import AppKit
import UserNotifications
import UnifaiCore

/// Local macOS notifications for things that need attention. Everything is computed from saved
/// state on this Mac; nothing is sent anywhere. Each alert fires once per transition.
@MainActor final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private let defaults = UserDefaults.standard
    private var knownErrors: Set<UUID>?
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    var enabled: Bool {
        get { defaults.object(forKey: "notificationsEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notificationsEnabled"); if !newValue { center.removeAllPendingNotificationRequests() } }
    }

    func start() {
        guard !AppRuntime.fixtureMode else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    static func defaultThreshold(for currency: String) -> Decimal { ConnectedAccount.defaultLowBalance(for: currency) }

    func evaluate(_ store: AppStore) {
        guard enabled, !AppRuntime.fixtureMode else { return }
        let state = store.state
        // Refresh failures: only for wallets that newly gain an error.
        let errors = Set(state.accounts.filter { $0.lastError != nil }.map(\.id))
        if let known = knownErrors {
            for account in state.accounts where errors.subtracting(known).contains(account.id) {
                post("error-\(account.id)", title: "\(name(account)) could not refresh", body: account.lastError ?? "Open Unifai to see the error.")
            }
        }
        knownErrors = errors

        // Low credit, once until it recovers.
        var alerted = Set(defaults.stringArray(forKey: "lowBalanceAlerted") ?? [])
        for account in state.accounts where account.mode == .live {
            guard let balance = account.snapshot?.balances.first else { continue }
            let threshold = account.lowBalanceAlert ?? Self.defaultThreshold(for: balance.currency)
            let key = account.id.uuidString
            if balance.amount < threshold {
                if !alerted.contains(key) {
                    alerted.insert(key)
                    post("low-\(key)", title: "\(name(account)) is running low", body: "\(balance.amountText) \(balance.currency) left, below your \(Money(threshold, balance.currency).amountText) alert.")
                }
            } else { alerted.remove(key) }
        }
        defaults.set(Array(alerted), forKey: "lowBalanceAlerted")

        // Budget: 80% and 100%, once per month each.
        if let budget = state.monthlyBudget, budget.amount > 0 {
            let spent = state.monthToDateSpend(in: budget.currency, rates: store.rates, includeAccruing: true).spent
            let ratio = NSDecimalNumber(decimal: spent.amount / budget.amount).doubleValue
            let month = Date.now.formatted(.iso8601.year().month())
            for (level, title) in [(1.0, "You have reached your AI budget"), (0.8, "80% of your AI budget is used")] where ratio >= level {
                let key = "budget-\(month)-\(Int(level * 100))"
                if !defaults.bool(forKey: key) {
                    defaults.set(true, forKey: key)
                    post(key, title: title, body: "\(spent.amountText) of \(budget.amountText) \(budget.currency) spent this month.")
                }
                break
            }
        }
        notifyTimeline(state)
        remindToCloseMonth(state)
        scheduleUpcoming(state)
    }

    /// Early resets, free resets, cost spikes and reset posts, once each. Events already saved when
    /// notifications first run are only marked seen.
    private func notifyTimeline(_ state: PersistentState) {
        let notable: Set<TimelineKind> = [.earlyReset, .resetCredit, .anomaly, .post, .recorded, .productUpdate, .policyChange]
        let events = (state.events ?? []).filter { $0.important && notable.contains($0.kind) }
        guard let seenList = defaults.stringArray(forKey: "notifiedEvents") else {
            defaults.set(events.map(\.id), forKey: "notifiedEvents"); return
        }
        var seen = Set(seenList)
        for event in events where !seen.contains(event.id) {
            seen.insert(event.id)
            guard event.date > Date.now.addingTimeInterval(-12 * 3600) || event.kind != .post else { continue }
            post("event-\(event.id)", title: event.title, body: event.detail)
        }
        defaults.set(Array(seen.prefix(800)), forKey: "notifiedEvents")
    }

    /// On the first days of a month, once: last month still has Auto or Estimate entries without a receipt.
    private func remindToCloseMonth(_ state: PersistentState) {
        let calendar = Calendar.current
        guard calendar.component(.day, from: .now) <= 3,
              let lastMonth = calendar.date(byAdding: .month, value: -1, to: .now),
              let interval = calendar.dateInterval(of: .month, for: lastMonth) else { return }
        let open = state.payments.filter { $0.autoRecorded && interval.contains($0.paidAt) }
        let key = "closeMonth-\(lastMonth.formatted(.iso8601.year().month()))"
        guard !open.isEmpty, !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        post(key, title: "Close \(lastMonth.formatted(.dateTime.month(.wide)))",
             body: "\(open.count) payment\(open.count == 1 ? " is" : "s are") still Auto or Estimate. Import the receipts or confirm them in Payments.")
    }

    /// Renewal reminders the day before at 9:00, and limit-reset notices at the reset time.
    private func scheduleUpcoming(_ state: PersistentState) {
        let ids = state.subscriptions.map { "renewal-\($0.id)" } + state.accounts.flatMap { account in (account.snapshot?.allowances ?? []).map { "reset-\(account.id)-\($0.name)" } }
        center.getPendingNotificationRequests { pending in
            let stale = pending.map(\.identifier).filter { ($0.hasPrefix("renewal-") || $0.hasPrefix("reset-")) && !ids.contains($0) }
            Task { @MainActor in self.center.removePendingNotificationRequests(withIdentifiers: stale) }
        }
        for plan in state.subscriptions {
            guard let dayBefore = Calendar.current.date(byAdding: .day, value: -1, to: plan.nextRenewal),
                  let fireAt = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: dayBefore), fireAt > .now else { continue }
            schedule(id: "renewal-\(plan.id)", at: fireAt, title: "\(plan.name) renews tomorrow",
                     body: "Expected \(plan.price.amountText) \(plan.price.currency)\(plan.recordsAutomatically ? ". Unifai will record it automatically." : ".")")
        }
        for account in state.accounts {
            for window in account.snapshot?.allowances ?? [] where window.usedPercent >= 100 {
                guard let reset = window.resetsAt, reset > .now else { continue }
                schedule(id: "reset-\(account.id)-\(window.name)", at: reset, title: "\(name(account)): \(window.name.lowercased()) has reset",
                         body: "Your usage allowance is available again.")
            }
        }
    }

    func renewalsRecorded(_ payments: [PaymentRecord]) {
        guard enabled, !payments.isEmpty, !AppRuntime.fixtureMode else { return }
        let list = payments.map { "\($0.description) \($0.money.amountText) \($0.money.currency)" }.joined(separator: ", ")
        post("recorded-\(payments[0].id)", title: "Renewal recorded", body: "\(list). Marked Auto until a receipt confirms it.")
    }

    private func name(_ account: ConnectedAccount) -> String {
        "\(Catalogue.integration(account.integrationID)?.name ?? account.integrationID) (\(account.label))"
    }

    private func post(_ id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private func schedule(id: String, at date: Date, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
    }
}
