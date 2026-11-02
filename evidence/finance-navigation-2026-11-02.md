# Timeline, Connectors and monthly review verification

Implemented locally on 2026-11-02. The installed 0.9.15 release was unchanged at this verification checkpoint; publication and installation are separate steps.

## Changes

- Timeline filters paginate after filtering and searching, with 25 events per page, Previous/Next controls, range/count labels and deterministic ordering. Changing the filter or search resets the page; pagination scrolls to the event section.
- The Catalogue navigation label is now Connectors. Its MCP activity tab embeds the activity/purchase flow. The old entry under Subscriptions is removed; the File menu and Settings shortcut route into Connectors.
- Expected monthly subscription totals include every currency. A selected display currency uses available reference rates, labelled approximate; missing rates leave all original currency totals visible. Annual schedules are normalized to monthly amounts.
- Payments includes Review October (or the latest closed month), a month picker, recorded totals, confirmation-state amounts, refunds, wallet subtotals, prior-month comparison and outstanding confirmation items.
- Budget history is saved by month from this version onward. Existing historical months remain unknown unless explicitly declared. Editing a historical budget does not alter the current budget or payment records. Missing exchange rates suppress budget comparisons.
- A monthly review reminder is scheduled for the first day of the next month at 09:00 local time. It opens the corresponding review. An unscheduled, unreviewed previous month gets a catch-up reminder when Unifai next runs. Notification identifiers and persisted month keys suppress duplicates. Existing notification preferences remain in force.

## Evidence

Read-only diagnosis confirmed that the reported MCP renewal already existed; the header displayed only the first currency subtotal. No real payment, schedule or budget was edited during this work.

- Full suite: 163 tests, 10 opt-in checks skipped, zero failures
- Monthly reviews and downloadable statements use a half-open calendar-month boundary, including final fractional-second payments and excluding the next month
- New tests exercise pagination bounds/order/empty/filter cases; combined and missing-rate subscription totals; annual normalization; refunds and estimates; historical-budget uncertainty; over/under-budget comparisons; prior-month totals; month-boundary reminder dates; duplicate prevention; and historical-budget edits preserving current budget and payments
- All 13 read-only MCP tools passed the stdio smoke check
- Native QA used `.qa/finance-navigation-fixture`, with synthetic payment/schedule/budget data. It showed both original currencies and their combined subscription total, MCP activity embedded under Connectors, Timeline pages 1 and 2 with 25 items each, and filter changes returning to page 1
- Native Review October checks showed confirmed and estimated amounts, refunds included in wallet totals, the prior-month comparison and a budget comparison. Editing the fixture budget changed the result from under to over budget. Mark reviewed persisted and remained reopenable from Payments
- Screenshots were emitted during QA. The fixture app was closed afterward
- `git diff --check` passed

Logs: `.build/finance-navigation-final-tests.log`, `.build/month-review-targeted.log`, `.build/finance-qa-build.log`, `.build/finance-navigation-dev-build.log`.

## Limits

Review totals cover recorded data, not undiscovered charges. Reference-rate conversion can differ from the card settlement amount; estimates remain provisional. Historical budgets are not inferred from today's budget. The next month's scheduled notification carries a generic review prompt because final spending cannot be known in advance; the review computes current saved totals when opened.

The reminder/date/deduplication logic was tested. Actual macOS notification delivery and clicking an OS-delivered notification were not exercised; delivery depends on system permissions and Focus settings. The next-month reminder is scheduled while Unifai runs, rather than by a new background service. Native QA covered the existing desktop layout, not VoiceOver or every window size.
