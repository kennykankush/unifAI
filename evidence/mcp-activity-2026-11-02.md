# MCP activity and declared purchases

Implemented in the local development build on 2026-11-02. This adds a shared MCP activity reader and an “I subscribed” flow. No MCP provider subscription is inferred from usage.

## What works

- Open Subscriptions > MCP activity · I subscribed, or File > MCP Activity
- Opt in to reading local Claude Code and Codex JSONL histories; saved state defaults to off
- Direct MCP call metadata produces 30-day counts, sessions, explicit reported errors, missing-result counts, most-used tool and last observation
- Raw prompts, tool arguments, output content, paths and credentials are not saved; session/call identifiers are hashed
- Record a service, matching activity name, subscription date, monthly/annual/lifetime/one-time plan and payment amount/currency
- Create one explicitly declared payment, or link an existing payment without adding another or changing its confirmation status
- Monthly/annual renewals are optional and expected only; automatic recording is off. Lifetime/one-time plans never get renewal schedules
- Read-only `get_mcp_activity` exposes saved summaries and purchase links to agents

## Verification

- Full suite with `UNIFAI_TEST_MCP_HISTORY=1`: 149 tests, 8 other opt-in checks skipped, 0 failures
- Tests cover metadata projection, explicit failures, unknown outcomes, wrapper exclusion, malformed names, old events, fork deduplication, symlink exclusion, purchase persistence, duplicate rejection, existing-payment linking, no lifetime renewal, transaction rollback and tracking disabled by default
- A bounded actual local-history scan found Refero and other MCP services. The scan only retained metadata in memory for the test and printed service names/counts; no personal history was added to app state
- Packaged MCP smoke check: 13 tools; argument errors, corrupt-state refusal and unchanged fixture data passed
- Native synthetic UI: opened the activity sheet through Subscriptions, opened the declaration form, entered Refero and a synthetic USD 99 amount, selected Lifetime, verified renewal controls disappeared, saved, and saw the linked purchase/date with zero observed calls and explicit unknown-coverage wording
- Screenshots were emitted during native checks. The fixture app was closed afterward
- `git diff --check` passed

## Coverage limits

Local transcript formats are implementation-dependent, not stable provider usage APIs. This version reads direct `mcp__server__tool` calls in Claude Code message blocks and Codex response items. It does not execute or parse JavaScript inside execution wrappers. Hosted sessions, other clients/devices, deleted logs, and indirect tools remain outside coverage.

Each scan covers a 90-day window, at most 500 recent files per source, 20 MiB per file, 128 MiB per source, 256 MiB total, and 20,000 retained calls. Per-client file counts and skipped data are visible. Previously observed metadata stays until the 90-day/20,000-call retention boundary. Disabling tracking stops new reads but retains saved observations.

“Returned” is not proof of success. Only explicit Claude tool-result error flags are counted as reported errors. No provider credit balance, quota, billable-unit conversion or actual tool-runtime duration is inferred. A zero observed count never proves a service was unused.

No receipt upload or Resend ingestion was implemented in this change. No subscription was recorded in the real app; the native purchase used the synthetic workspace. The official installed release was unchanged at this verification checkpoint; release publication is a separate step.
