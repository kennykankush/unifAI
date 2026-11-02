# Product updates and benefit-page monitoring

Implemented in the local development build on 2026-11-02. The published 0.9.14 app was not replaced during this work.

## Implemented behavior

The Timeline reads five public official sources: ChatGPT release notes, ChatGPT Pro benefits, Claude release notes, Claude Max benefits, and Claude API release notes. It checks them every six hours while the app's refresh loop runs; Check Now forces a check. Settings can disable these reads independently of general news feeds.

Dated announcements appear under Updates with their publication date and observation time. Initial history is browsable without generating notification bursts. Plan-benefit pages establish a silent baseline; later changes retain before/after excerpts. Markup-only and reordered-text changes are suppressed. Source failures preserve the last successful snapshot and show a warning.

New notices carry topic, source, evidence and provider relevance. Relevance means a provider appears in the wallet list, not that a particular account or plan is eligible. The app never changes allowance or payment records based on announcements. It never infers permanence, deadlines or activation success from source wording.

Posts from already configured X accounts now classify usage/benefits, pricing, retirements and features, with social-source labels. No X accounts were added and no new paid subscription or credential was configured.

A catch-up panel shows recent Timeline items and saves an explicit read marker. Repeated identical titles from one source share a summary slot, while individual Timeline events remain intact. The existing read-only Timeline MCP response includes notice evidence and excerpts.

## Verification

- Full suite with `UNIFAI_TEST_PRODUCT_UPDATES=1`: 156 tests, 9 other opt-in checks skipped, zero failures
- Public HTTP reads and decoding succeeded for all five official pages: 43 OpenAI release-note sections, one OpenAI policy baseline, six Claude release-note sections, one Claude policy baseline, and 20 Claude API release-note sections in the retained date window
- The actual OpenAI allowance announcement was found, Pro 100/Pro 200 scope wording retained, and its duplicate published section collapsed
- Fixture tests cover dated HTML, Claude paragraph headings, Markdown notes, silent baselines, before/after edits, duplicate suppression, reordered/markup-only text, malformed pages, failure preservation, refresh spacing, disablement, read-marker persistence and social-source uncertainty
- Native fixture checks exercised the Updates filter, expanded source details with published/observed timestamps, and Mark caught up clearing the summary. Screenshots were emitted during the session; the fixture app was closed afterward
- Packaged MCP smoke check exercises all 13 tools and verifies unchanged fixture data
- `git diff --check` passed

Logs: `.build/product-updates-final-tests.log`, `.build/product-updates-live.log`, `.build/product-updates-qa-build.log` and `.build/product-updates-dev-build.log`.

## Limits

This is a bounded source watcher, not exhaustive AI-news coverage. It adds these five sources to the existing news, models, status and GitHub-release mechanisms. It does not add a universal model-price history, every provider's plans, automatic promotion-expiry reminders, installed-version vulnerability matching, or a general web crawler.

HTML/Markdown extraction and topic classification are deterministic. Source layout changes can require parser maintenance. Notes retain up to 60 recent sections within 45 days; new dated notices normally cover the last 14 days. Policy matching selects benefit-related text; unrelated page edits can remain outside that scope. Topic labels do not establish whether a benefit increased or decreased.

Eligibility, rollout completion and exact effective/expiry times remain in the original source unless independently established through account data. No authenticated provider calls, paid X reads or real-user financial records were used in verification. Native QA used the existing desktop layout; minimum-window and VoiceOver checks were not run.
