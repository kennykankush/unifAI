# Live connector implementation verification

The user rejected the manual catalogue expansion. All 105 newly added manual entries and their registry were removed. Existing manual IDs remain for compatibility with saved accounts. This checkpoint adds real read-only HTTP clients for GitHub personal and organization billing, Cloudflare billable usage, DigitalOcean balances, and Supabase project/add-on inventory.

## Verified locally

- Full suite: 140 tests, 8 opt-in checks skipped, 0 failures
- Nine new tests exercise the actual `BalanceClient` dispatch and request construction with an injected HTTP transport
- Verified fixed provider hosts, GET-only requests, explicit account scope, GitHub API version/date parameters and organization/personal route separation
- Verified net rather than gross GitHub cost, currency preservation, per-period rather than cumulative Cloudflare charges, signed DigitalOcean balances and provider-generation freshness
- Verified Supabase organization filtering before add-on reads, selected versus available add-ons, unavailable billing totals and partial add-on permissions
- Verified malformed reports, wrong-month reports, unexpected pagination, authorization errors and invalid scoped credentials fail without returning invented zero readings
- Snapshot Codable round-trip checked; existing store/vault tests and Vercel persistence tests remain green
- Native fixture app: overview cards, DigitalOcean signed balance detail, Supabase inventory-only detail and health status, Cloudflare live catalogue entry and account/token setup form inspected; screenshots emitted during the session
- Final UI cleanup corrects project singular/plural, distinguishes inventory from metered-usage fixture labels, and reuses the existing GitHub logo and green database palette
- Development bundle rebuilt at `.build/Unifai Dev.app`; official installed app and release were not replaced

Logs remain in `.build/cloud-connectors-full-tests.log`, `.build/cloud-connector-tests.log`, and `.build/live-connectors-dev-build.log`.

## Not verified

No authenticated provider account was queried. No ambient CLI token, browser session or secret store was inspected. The user must enter provider credentials through the app before account-specific access, plan eligibility and production response compatibility can be verified. Synthetic UI fixtures are not live provider evidence.

Supabase coverage is project status, region and selected add-ons only. Cloudflare excludes fixed subscriptions and enterprise billing. GitHub uses enhanced billing and excludes fixed subscription payments. DigitalOcean reports balances and usage, not resource inventory. No additional historical upgrade detection was inferred from these reports.

New provider reports retain their period/currency meanings and stay outside cash-payment and calendar-accrual totals. The MCP account-detail response includes the saved report. No provider mutation, purchase, plan change, deployment, production-data edit or publication occurred.

Native testing used the existing fixed wallet-sheet size. VoiceOver and other display sizes were not exercised. Final copy/palette cleanup was compiled after the captured inspections.
