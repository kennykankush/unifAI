import SwiftUI
import UnifaiCore

struct MonthlyReviewView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var month: Date
    @State private var editingBudget = false
    @State private var budgetAmount = ""
    @State private var budgetCurrency = "USD"
    @State private var error: String?
    init(month: Date) { _month = State(initialValue: Calendar.current.dateInterval(of: .month, for: month)!.start) }
    private var review: MonthlyReview { MonthlyReview(state: store.state, month: month, rates: store.rates) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(review.title).font(.system(size: 26, weight: .bold))
                Spacer()
                Picker("Month", selection: $month) {
                    ForEach(Array(Set(MonthlyReview.availableMonths(store.state) + [month])).sorted(by: >), id: \.self) { date in Text(date.formatted(.dateTime.month(.wide).year())).tag(date) }
                }.frame(width: 210)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("RECORDED SPENDING").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(review.totalText).font(.system(size: 34, weight: .bold)).monospacedDigit()
                        if let comparison = review.comparisonText { Text(comparison).foregroundStyle(.secondary) }
                        HStack(alignment: .top, spacing: 20) {
                            stat("Confirmed", status: .confirmed)
                            stat("Estimates", status: .estimate)
                            stat("Awaiting confirmation", status: .automatic)
                        }
                        Text("Refunds reduce the total. These are your recorded payments, not proof that every charge has been captured.")
                            .font(.caption).foregroundStyle(.secondary)
                        if !review.breakdown.complete { InlineNotice(text: "Some exchange rates are unavailable. Totals are shown by currency and the budget comparison is withheld.") }
                    }.surface(padding: 20, radius: 22)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Budget").font(.headline); Spacer()
                            Button("Set \(month.formatted(.dateTime.month(.wide))) budget") {
                                budgetAmount = review.budgetRecord?.budget?.amount.description ?? ""
                                budgetCurrency = review.budgetRecord?.budget?.currency ?? store.state.displayCurrency ?? "USD"
                                editingBudget = true
                            }.buttonStyle(PillButtonStyle(compact: true))
                        }
                        Text(review.budgetText).font(.callout)
                        if let record = review.budgetRecord { Text("Budget recorded \(record.recordedAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
                        if review.unconfirmedCount > 0 { Text("Includes \(review.unconfirmedCount) estimated or unconfirmed record\(review.unconfirmedCount == 1 ? "" : "s"). Confirm the charges before treating this comparison as final.").font(.caption).foregroundStyle(.secondary) }
                    }.surface(padding: 20, radius: 22)
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeading(title: "Where your money went", subtitle: "By wallet · refunds included")
                        if review.breakdown.byAccount.isEmpty { Text("No payments recorded for this month.").foregroundStyle(.secondary) }
                        ForEach(review.breakdown.byAccount) { row in
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.name).font(.system(size: 13, weight: .medium)); Spacer(minLength: 18)
                                Text(amounts(review.breakdown.entries.filter { ($0.accountID?.uuidString ?? "unassigned") == row.id })).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                            }
                        }
                    }.surface(padding: 20, radius: 22)
                    if review.unconfirmedCount > 0 {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeading(title: "Needs confirmation", subtitle: "\(review.unconfirmedCount) record\(review.unconfirmedCount == 1 ? "" : "s")")
                            ForEach(review.breakdown.entries.filter { $0.status != .confirmed }.prefix(10)) { row in
                                HStack { Text(row.description).font(.callout); Spacer(); Text(row.original.plainText).font(.callout.monospacedDigit()) }
                            }
                            Text("Use Payments → Unconfirmed to match receipts or correct these records.").font(.caption).foregroundStyle(.secondary)
                        }.surface(padding: 20, radius: 22)
                    }
                    if review.hasConversion { Text("Converted amounts use reference rates for each payment's date. Your bank's exchange rate may differ.").font(.caption).foregroundStyle(.secondary) }
                    if let error { InlineNotice(text: error) }
                }
            }
            HStack {
                Text("Your payment history remains editable; this review updates when you reconcile a receipt.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button((store.state.reviewedMonths ?? []).contains(review.key) ? "Reviewed" : "Mark reviewed") {
                    do { try store.markMonthReviewed(month) } catch { self.error = error.localizedDescription }
                }.buttonStyle(PillButtonStyle(kind: .primary)).disabled((store.state.reviewedMonths ?? []).contains(review.key))
            }
        }.padding(24).frame(width: 840, height: 740).background(Palette.canvas)
        .sheet(isPresented: $editingBudget) {
            EditorFrame(title: "Budget for \(month.formatted(.dateTime.month(.wide).year()))", saveLabel: "Save Budget", error: error, save: {
                do {
                    let amount = budgetAmount.trimmingCharacters(in: .whitespaces)
                    let budget: Money?
                    if amount.isEmpty { budget = nil }
                    else { guard let value = Money.parseAmount(amount) else { throw ValidationError.message("Enter a budget amount.") }; budget = Money(value, budgetCurrency.uppercased()) }
                    try store.setBudgetForMonth(month, budget: budget); error = nil; editingBudget = false
                } catch { self.error = error.localizedDescription }
            }) {
                TextField("Budget amount", text: $budgetAmount)
                TextField("Currency", text: $budgetCurrency)
                Text("This is the budget you intended for this month. Leave the amount blank to record that no budget was set. It does not change today's budget or any payment.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func amounts(_ entries: [SpendingBreakdown.Entry]) -> String {
        guard !entries.isEmpty else { return Money(0, review.breakdown.currency).plainText }
        if review.breakdown.complete { return Money(entries.compactMap(\.converted).reduce(0) { $0 + $1.amount }, review.breakdown.currency).plainText }
        let groups = Dictionary(grouping: entries, by: { $0.original.currency })
        return groups.keys.sorted().map { Money(groups[$0]!.reduce(0) { $0 + $1.original.amount }, $0).plainText }.joined(separator: " + ")
    }
    private func stat(_ label: String, status: SpendingBreakdown.Status) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(label).font(.caption).foregroundStyle(.secondary); Text(amounts(review.breakdown.entries.filter { $0.status == status })).font(.system(size: 15, weight: .semibold)).monospacedDigit() }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
