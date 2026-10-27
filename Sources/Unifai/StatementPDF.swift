import SwiftUI
import AppKit
import UnifaiCore

/// Renders a monthly statement as an A4 PDF. Always light, like a printed statement, whatever the
/// app's appearance.
@MainActor enum StatementPDF {
    static let page = CGSize(width: 595, height: 842)
    static let margin: CGFloat = 40
    static let rowHeight: CGFloat = 30

    static func render(_ statement: MonthlyStatement) -> Data {
        let pages = paginate(statement)
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: page)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle as String: statement.fileName] as CFDictionary) else { return Data() }
        for (index, rows) in pages.enumerated() {
            let view = StatementPage(statement: statement, rows: rows, number: index + 1, count: pages.count)
                .frame(width: page.width, height: page.height)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(page)
            renderer.render { _, draw in
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
            }
        }
        context.closePDF()
        return data as Data
    }

    /// Splits the entries, oldest first, across pages. The first page also carries the summary and
    /// account subtotals; the last keeps room for the notes.
    static func paginate(_ statement: MonthlyStatement) -> [[SpendingBreakdown.Entry]] {
        let entries = Array(statement.breakdown.entries.reversed())
        let chrome: CGFloat = margin * 2 + 92 + 40 // header band, footer
        let firstExtra: CGFloat = 150 + CGFloat(statement.breakdown.byAccount.count) * 20 + 40
        let notesHeight: CGFloat = 40 + CGFloat(statement.notes.count) * 26
        let firstCapacity = max(0, Int((page.height - chrome - firstExtra - 28) / rowHeight))
        let laterCapacity = Int((page.height - chrome - 28) / rowHeight)
        var pages: [[SpendingBreakdown.Entry]] = [Array(entries.prefix(firstCapacity))]
        var rest = Array(entries.dropFirst(firstCapacity))
        while !rest.isEmpty { pages.append(Array(rest.prefix(laterCapacity))); rest = Array(rest.dropFirst(laterCapacity)) }
        let lastCapacity = pages.count == 1 ? firstCapacity : laterCapacity
        if CGFloat(lastCapacity - pages[pages.count - 1].count) * rowHeight < notesHeight { pages.append([]) }
        return pages
    }
}

private enum Ink {
    static let text = Color(red: 0.08, green: 0.09, blue: 0.12)
    static let secondary = Color(red: 0.42, green: 0.44, blue: 0.50)
    static let rule = Color(red: 0.88, green: 0.89, blue: 0.92)
    static let band = LinearGradient(colors: [Color(red: 0.29, green: 0.23, blue: 0.91), Color(red: 0.49, green: 0.30, blue: 1.0), Color(red: 0.75, green: 0.39, blue: 0.94)],
                                     startPoint: .leading, endPoint: .trailing)
    static func status(_ status: SpendingBreakdown.Status) -> Color {
        switch status {
        case .confirmed: return Color(red: 0.05, green: 0.55, blue: 0.40)
        case .estimate: return Color(red: 0.75, green: 0.48, blue: 0.05)
        case .automatic: return Color(red: 0.30, green: 0.36, blue: 0.85)
        case .accruing: return Color(red: 0.55, green: 0.30, blue: 0.85)
        }
    }
}

private struct StatementPage: View {
    let statement: MonthlyStatement
    let rows: [SpendingBreakdown.Entry]
    let number: Int
    let count: Int
    private var breakdown: SpendingBreakdown { statement.breakdown }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 18) {
                if number == 1 { summary; accounts }
                if !rows.isEmpty || number == 1 { transactions }
                if number == count { notes }
                Spacer(minLength: 0)
                footer
            }
            .padding(.horizontal, StatementPDF.margin)
            .padding(.top, 22).padding(.bottom, StatementPDF.margin - 8)
        }
        .foregroundStyle(Ink.text)
        .background(Color.white)
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Unifai").font(.system(size: 22, weight: .heavy)).tracking(-0.4)
                Text(number == 1 ? "Monthly statement" : "Monthly statement, continued").font(.system(size: 11, weight: .medium)).opacity(0.85)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(statement.title).font(.system(size: 18, weight: .bold))
                Text(statement.isCurrentMonth ? "Month to date" : "Full month").font(.system(size: 11, weight: .medium)).opacity(0.85)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, StatementPDF.margin).padding(.vertical, 22)
        .frame(height: 92)
        .background(Ink.band)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            if statement.converts {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total spent").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.secondary).textCase(.uppercase)
                    Text(breakdown.total.plainText).font(.system(size: 28, weight: .bold)).monospacedDigit()
                    if !breakdown.complete { Text("Some entries could not be converted; see notes.").font(.system(size: 9)).foregroundStyle(Ink.status(.estimate)) }
                }
                HStack(spacing: 0) {
                    stat("Confirmed", breakdown.confirmedPayments, .confirmed)
                    stat("Estimated", breakdown.estimatedPayments, .estimate)
                    stat("Awaiting confirmation", breakdown.automaticPayments, .automatic)
                    stat("Accruing usage", breakdown.accruingUsage, .accruing)
                }
            }
            if statement.originalTotals.count > 1 || !statement.converts {
                HStack(spacing: 14) {
                    Text("By currency").font(.system(size: 9, weight: .semibold)).foregroundStyle(Ink.secondary).textCase(.uppercase)
                    ForEach(statement.originalTotals) { Text($0.plainText).font(.system(size: 11, weight: .semibold)).monospacedDigit() }
                }
            }
        }
    }

    private func stat(_ title: String, _ money: Money, _ status: SpendingBreakdown.Status) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(Ink.status(status)).frame(width: 6, height: 6)
                Text(title).font(.system(size: 9, weight: .medium)).foregroundStyle(Ink.secondary)
            }
            Text(money.plainText).font(.system(size: 12, weight: .semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accounts: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("By account")
            ForEach(breakdown.byAccount) { subtotal in
                HStack {
                    Text(subtotal.name).font(.system(size: 10)).lineLimit(1)
                    Spacer()
                    Text(statement.converts ? subtotal.amount.plainText : statement.originalTotals(account: subtotal.id).map(\.plainText).joined(separator: " + "))
                        .font(.system(size: 10, weight: .medium)).monospacedDigit()
                }
                .frame(height: 20)
                .overlay(alignment: .bottom) { Ink.rule.frame(height: 0.5) }
            }
            if breakdown.byAccount.isEmpty { Text("Nothing recorded this month.").font(.system(size: 10)).foregroundStyle(Ink.secondary).frame(height: 20) }
        }
    }

    private var transactions: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle(number == 1 ? "Transactions" : "Transactions, continued")
            HStack(spacing: 10) {
                Text("Date").frame(width: 44, alignment: .leading)
                Text("Description").frame(maxWidth: .infinity, alignment: .leading)
                Text("Status").frame(width: 92, alignment: .leading)
                Text("Amount").frame(width: 82, alignment: .trailing)
                if statement.converts { Text(breakdown.currency).frame(width: 70, alignment: .trailing) }
            }
            .font(.system(size: 8, weight: .semibold)).foregroundStyle(Ink.secondary).textCase(.uppercase)
            .frame(height: 22)
            .overlay(alignment: .bottom) { Ink.text.opacity(0.7).frame(height: 0.8) }
            ForEach(rows) { entry in
                HStack(spacing: 10) {
                    Text(entry.date.formatted(.dateTime.month(.abbreviated).day())).font(.system(size: 10)).monospacedDigit().frame(width: 44, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.description).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        Text(entry.account ?? "Unassigned").font(.system(size: 8.5)).foregroundStyle(Ink.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 4) {
                        Circle().fill(Ink.status(entry.status)).frame(width: 5, height: 5)
                        Text(MonthlyStatement.status(entry.status)).font(.system(size: 8.5)).lineLimit(1)
                    }
                    .frame(width: 92, alignment: .leading)
                    Text(entry.original.plainText).font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 82, alignment: .trailing)
                    if statement.converts {
                        Text(entry.converted?.amountText ?? "–").font(.system(size: 10)).foregroundStyle(Ink.secondary).monospacedDigit().frame(width: 70, alignment: .trailing)
                    }
                }
                .frame(height: StatementPDF.rowHeight)
                .overlay(alignment: .bottom) { Ink.rule.frame(height: 0.5) }
            }
            if number == 1 && rows.isEmpty { Text("No transactions this month.").font(.system(size: 10)).foregroundStyle(Ink.secondary).frame(height: StatementPDF.rowHeight) }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Notes")
            ForEach(statement.notes, id: \.self) { Text($0).font(.system(size: 8.5)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private var footer: some View {
        HStack {
            Text("Generated \(breakdown.generatedAt.formatted(date: .abbreviated, time: .shortened)) by Unifai from your recorded payments. Not a tax invoice.")
            Spacer()
            Text("Page \(number) of \(count)")
        }
        .font(.system(size: 8)).foregroundStyle(Ink.secondary)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .bold)).padding(.bottom, 6)
    }
}
