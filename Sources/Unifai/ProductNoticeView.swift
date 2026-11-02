import SwiftUI
import UnifaiCore

struct ProductNoticeView: View {
    @Environment(\.dismiss) private var dismiss
    let event: TimelineEvent
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Text(event.title).font(.system(size: 23, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let notice = event.notice {
                Text(notice.evidence).font(.callout.weight(.semibold)).foregroundStyle(Palette.accentInk)
                Text(notice.relevance).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 18) {
                    if let date = notice.publishedAt { Text("Published \(date.formatted(date: .abbreviated, time: .omitted))") }
                    Text("Observed \(notice.observedAt.formatted(date: .abbreviated, time: .shortened))")
                }.font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let before = notice.previousExcerpt {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Previous wording").font(.headline)
                                Text(before).font(.callout).textSelection(.enabled)
                            }.surface(padding: 16, radius: 16)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text(notice.previousExcerpt == nil ? "Source excerpt" : "New wording").font(.headline)
                            Text(notice.excerpt).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }.surface(padding: 16, radius: 16)
                        Text("Excerpts may be shortened. Open the source for complete eligibility, timing and exceptions. Unifai does not infer permanent availability, a claim deadline or an account-level increase from this text.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let url = event.source { Link("Open \(event.sourceName)", destination: url).buttonStyle(PillButtonStyle(kind: .primary)) }
        }.padding(24).frame(width: 740, height: 650).background(Palette.canvas)
    }
}
