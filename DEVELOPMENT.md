# First local milestone

## November 2: official product updates and benefit changes

The local Timeline adds five official OpenAI/Anthropic sources, silent policy baselines, changed-wording excerpts, expanded social-post classification and an explicit catch-up marker. The full suite with public-source checks passed 156 tests with 9 skipped; all five real pages decoded, including the recent Codex allowance announcement. Native fixture checks covered the Updates filter, source-detail sheet and catch-up action. See [verification](evidence/product-updates-2026-11-02.md). Prepared for release 0.9.15.

## November 2: MCP activity and purchase declarations

The local development build adds metadata-only local-history scanning, a purchase declaration/linking form, and the read-only `get_mcp_activity` tool. Direct Claude Code MCP calls were observed in the real history check; Codex wrapper calls remain unexpanded. The full suite passed 149 tests with 8 skipped, and all 13 MCP tools passed the stdio smoke check. Native synthetic testing verified a dated Refero lifetime purchase without a renewal. [Verification](evidence/mcp-activity-2026-11-02.md) records coverage and limits. Prepared for release 0.9.14. No real-app purchase was created during verification.

## November 1: Vercel and connector coverage

Vercel hosting has a team-scoped connector for plan, projects, deployment states and optional gross usage. GitHub personal/organization billing, Cloudflare billable usage, DigitalOcean balances and Supabase project/add-on inventory now have read-only API clients and setup flows. The 105 manual additions were removed at the user's request. See [live coverage](docs/connector-map.md), the [Vercel verification](evidence/vercel-2026-11-01.md), and the [live connector verification](evidence/live-connectors-2026-11-01.md). Authenticated account verification still requires user-entered tokens.

This section records the October 19 milestone. Its deferred-work list is historical; see README.md for the current feature set.

## October 21: payment reliability, recovery and agent explanations

The local implementation adds one-to-one receipt reconciliation, observation-interval top-up matching, retained detection evidence, local backup recovery and a spending breakdown shared by the dashboard and MCP. Budget notifications now include accruing usage. Reconciled month-end invoices retain their source reference so the estimate is not recreated.

The MCP server is version 0.3.0 and exposes 12 read-only tools. New queries explain spending, inspect payment evidence, list unconfirmed records, inspect an account, project scheduled renewals and report data freshness. Existing payment reports include stable IDs and confirmation status. Headroom excludes stale or failed readings from usable capacity.

New code owners:

| Area | Location |
| --- | --- |
| Shared spending arithmetic and contributing entries | Sources/UnifaiCore/SpendingBreakdown.swift |
| Receipt matching | Sources/UnifaiCore/PaymentReconciliation.swift |
| Rich read-only queries and argument validation | Sources/UnifaiCore/AgentTools.swift |
| Native spending explanation and recovery sheets | Sources/Unifai/FinanceDetails.swift |
| Stdio smoke check with disposable data | scripts/check-mcp.py |

Verification: 110 tests passed, 8 opt-in checks skipped; debug and optimized builds passed. All 12 MCP tools passed the stdio smoke check. Native checks used a separate synthetic workspace for breakdown totals, keyboard dismissal, resizing, wallet confirmation/editing and backup restoration. Details are in [the verification receipt](evidence/reliability-2026-10-21.md).

These changes ship in version 0.9.7. The real ledger and credentials were not modified during implementation or fixture verification.

## October 19 record

Status: functioning native milestone verified on 2026-10-19. Live authentication against Hadi’s provider accounts remains a setup step. The current development owner continued the existing scaffold through Herdr and the requested `gptgpt` launcher. The old built-in agent remains stopped; no additional agents were used.

## Implemented behavior

Unifai has a SwiftUI main window and an AppKit menu bar status item hosting a SwiftUI companion. The companion and window observe the same store. The app supports keyboard-accessible native commands, window reopening, scrollable compact layouts, and native forms with inline errors.

The searchable catalogue distinguishes ready, manual and planned capabilities. OpenRouter and DeepSeek support multiple labelled billing accounts, per-account Keychain credentials and manual balance refreshes. Planned financial entries can create manual accounts without claiming that an API connector exists. Planned news entries expose no connection action.

Payments and refunds form a currency-preserving ledger. Recurring schedules remain expected charges and never generate historical payments. History has a coverage start and a user-confirmed completeness state. Snapshots retain their source, observation time, coverage explanation and error state. Failed refreshes preserve the last successful reading. Duplicate billing-owner checks reduce accidental duplicate balances; financial balances are never aggregated across account identities.

Public GitHub release watching uses an anonymous ephemeral session, a bounded page of 50 releases, ETag caching, prerelease filtering and original source links. A persisted 30-minute per-repository cooldown, 10-repository cap, 20-request hourly budget and shared server backoff bound refreshes. Concurrent rate-limit responses preserve the longest backoff.

## Code ownership and persistence

| Area | Location |
| --- | --- |
| Models, ledger and history coverage | `Sources/UnifaiCore/Models.swift` |
| Catalogue and capability descriptions | `Sources/UnifaiCore/Catalogue.swift` |
| HTTP clients, parsing, redirection refusal | `Sources/UnifaiCore/Connectors.swift` |
| Atomic JSON persistence | `Sources/UnifaiCore/Persistence.swift` |
| Scoped Keychain access | `Sources/UnifaiCore/Credentials.swift` |
| Save-before-publish mutations and refresh coordination | `Sources/UnifaiCore/AppStore.swift` |
| Read-only agent views of saved state | `Sources/UnifaiCore/AgentReport.swift` |
| MCP stdio server (`unifai-mcp`) | `Sources/UnifaiMCP/main.swift` |
| Design system, provider logos and charts | `Sources/Unifai/Design.swift`, `Sources/Unifai/Resources/Logos/` |
| Window, forms and companion | `Sources/Unifai/` |
| Accounting, connectors, persistence, concurrency and integration checks | `Tests/UnifaiCoreTests/` |

The Swift Package remains dependency-free and targets macOS 14+. It builds using Swift 6.2 with the scaffold’s Swift 5 language mode. Compiler caches, local bundles and test data stay inside the checkout. Normal runtime data uses the app’s Application Support directory; synthetic UI data uses `.qa/fixture-workspace`.

Schema 1 remains readable, including scaffold files without the new optional fields. Corrupt or future-schema data blocks writes and remains untouched. Credentials never enter JSON. New-account failures attempt credential rollback, and linked financial records prevent account removal.

## Verification achieved

- Debug app bundles and optimized executable build passed on Apple silicon, macOS 26.5, Xcode 26.0.1
- 32 tests passed with both explicit integration checks enabled, including synthetic Keychain isolation and one anonymous public GitHub request
- The native app’s synthetic Keychain check passed create, read, replacement, isolation and deletion
- Native UI checks covered empty startup, catalogue search, multi-account creation, provider fixture refreshes, permission errors retaining balances, payment validation and saving, subscription saving, release following, prerelease filtering and cooldown feedback
- Relaunch retained the synthetic account metadata, payment totals, schedules, snapshots, error state, followed repositories and release cache
- Standard and minimum window layouts were inspected, including the native payment form and Escape dismissal
- The menu bar companion opened as a native popover and its Open Unifai action returned to the main window
- The original `VISION.md` SHA-256 still matches, preserving all raw quotes

Commands, observed values and retained logs are indexed in [evidence/VERIFICATION.md](evidence/VERIFICATION.md). An earlier sandboxed Keychain run failed with OSStatus `-50`; the same synthetic check passed after the authorized Full Access launcher change. That failure remains in the historical log and is not the final result.

## Remaining qualification and deferred work

Authenticated OpenRouter and DeepSeek responses have not been witnessed against Hadi’s accounts. Their supported fields and failures were exercised with fixtures; real keys must be entered through the app. The anonymous public GitHub client was exercised live once. No paid API request, purchase, plan change or signing-account enrollment occurred. The repository was published to GitHub on 2026-10-19 at the owner's request.

Local builds are signed with this Mac's Developer ID certificate when it has one, which the widget's shared app group requires; without one they are signed ad hoc and ship no widget. Official releases come from `scripts/release.sh`. macOS 14 runtime compatibility, light appearance and VoiceOver operation remain unverified. The persisted store assumes one process per data directory and has no automatic backup or sync.

WidgetKit remains the intended follow-on surface. Quotas and reset windows, Claude and OpenAI reporting, invoice imports, public feeds, richer discovery and notifications remain deferred. X remains disabled. This milestone keeps the broader hub visible without claiming those integrations work.

## Channels and releases

`scripts/assemble-app.sh` builds every bundle from one place. The `dev` channel (`scripts/build-app.sh`) produces **Unifai Dev** with bundle identifier `dev.unifai.dev`, data in `Application Support/Unifai Dev` and Keychain service `dev.unifai.dev.account-credentials.v1`. The `fixture` channel produces the synthetic demo. The `release` channel produces the official **Unifai** (`dev.unifai.app`), which `scripts/release.sh` signs with Developer ID and hardened runtime, notarizes, publishes to GitHub Releases and announces through the cask in `Casks/unifai.rb` (this repository is its own tap). The version comes from `VERSION`; the build number is the commit count. Provider logos are copied into `Contents/Resources/Logos` rather than a SwiftPM resource bundle, which keeps Developer ID signing straightforward.

