# Live connector coverage

Updated 2026-11-01. The proposed 105 manual catalogue additions were removed. This document lists implemented API routes; it does not treat catalogue presence or fixture tests as proof that a particular account has connected.

## New live connectors

| Connector | Actual read route | What it shows | Required access and limits |
| --- | --- | --- | --- |
| Vercel | `GET /v2/teams/{team}`, `GET /v9/projects`, optional `POST /v2/billing/costs` read query | Current plan, observed changes, visible projects, deployment states, returned usage meters and gross charges | Team ID and scoped token. Billing follows the CLI implementation, not a stable public REST contract. Current UTC calendar month. No historical upgrade date inferred. |
| GitHub personal billing | `GET /users/{username}/settings/billing/usage` | Net metered usage by product, SKU and billed repository | Token with Plan user permission (read), enhanced billing eligibility. Current UTC month. |
| GitHub organization billing | `GET /organizations/{org}/settings/billing/usage` | Organization-billed metered usage by product, SKU and billed repository | Administration organization permission (read) and billing access. Separate from personal billing. |
| Cloudflare | `GET /client/v4/accounts/{account}/billable-usage` | Current billing-cycle metered quantities, charges by currency/service/zone | Account ID and Billing Read token; Pay-as-you-go accounts. Daily updates. Excludes fixed subscriptions and enterprise contracts. |
| DigitalOcean | `GET /v2/customers/my/balance` | Month-to-date usage, signed account balance and month-to-date balance | API token with billing read access. Provider generation time controls freshness. Debt is not presented as available cash. |
| Supabase | `GET /v1/projects`, `GET /v1/projects/{ref}/billing/addons` | Selected organization's visible projects, status, region and selected compute/add-ons | Organization slug and Management API token. Up to 100 projects; missing add-on permissions are reported. No billing total, CPU consumption, plan or upgrade-history claim. |

These are network-enabled connectors in the development build. Enter credentials through Add Account, then Refresh. Tokens stay in per-account Keychain entries. Testing used synthetic responses; no personal/work provider credentials were read or used during development.

## Accounting and scope

Provider reports appear on the wallet card and detail screen, and in the MCP account-detail snapshot. Their periods and meanings differ: GitHub returns net metered amounts, Vercel returns gross charges, Cloudflare reports a provider billing cycle, and DigitalOcean returns signed balances. These reports stay separate from payments and calendar-month accrual to avoid treating debt, credits or usage as cash paid. Existing invoice imports and payment records remain available.

Personal and organization GitHub billing use separate connectors. Cloudflare and Supabase require explicit scopes. Supabase inventory is filtered before requesting add-ons. No database query, deployment, plan change, resource start or other provider mutation occurs.

A failed mandatory read preserves the prior snapshot. Supabase add-ons and Vercel usage are optional detail reads: a failure retains current inventory with an explicit coverage limitation. Empty usage responses have no monetary total instead of an invented zero. Unknown currencies and malformed numeric data fail validation.

Only providers that actually return a plan participate in plan-change observations. A first observation is not a historical upgrade date. GitHub billing, Cloudflare usage, DigitalOcean balances and Supabase inventory do not provide plan-change history through the routes used here.

## Existing live coverage retained

- OpenRouter, DeepSeek and Kimi balances
- Vercel AI Gateway credits
- ElevenLabs character allowance
- OpenAI and Anthropic API cost reports
- Codex plan, allowances and credits; Claude Code plan/sign-in status
- Azure cost/resource inventory and Neon usage-priced estimates
- Existing public release, status and configured discovery feeds

No new manual entries were added in this correction. Pre-existing manual service IDs remain so saved wallets and invoices retain their provider associations.

## Source contracts

- [Vercel team API](https://vercel.com/docs/rest-api/teams/get-a-team), [projects API](https://vercel.com/docs/rest-api/projects/retrieve-a-list-of-projects), and [usage CLI implementation](https://github.com/vercel/vercel/blob/main/packages/cli/src/commands/usage/index.ts)
- [GitHub billing usage API](https://docs.github.com/en/rest/billing/usage)
- [Cloudflare billable usage API announcement](https://blog.cloudflare.com/billable-usage-api), [billing-cycle semantics](https://developers.cloudflare.com/billing/manage/billable-usage/), and [official TypeScript API types](https://github.com/cloudflare/cloudflare-typescript/blob/main/src/resources/billing/usage.ts)
- [DigitalOcean balance API](https://docs.digitalocean.com/reference/pydo/reference/balance/get/) and [official balance schema](https://github.com/digitalocean/openapi/blob/main/specification/resources/billing/models/balance.yml)
- [Supabase public OpenAPI document](https://api.supabase.com/api/v1-json) and [Management API documentation](https://supabase.com/docs/reference/api/introduction)

## Remaining gaps

This is an implemented set, not every vendor. AWS/GCP billing, additional model-provider balances and other services need their own supported credentials, data contracts and validation. Supabase's public schema was checked for usage/billing/subscription routes; it exposes project-level add-on selections, but no complete organization monetary report was established. Those capabilities were not fabricated or represented as new manual placeholders.
