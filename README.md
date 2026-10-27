# Unifai

Unifai is a local macOS app that shows where your AI money stands: remaining credit across provider wallets, what you have actually paid, upcoming subscription renewals, and what changed: usage resets, limits, cost spikes, outages and releases. It also ships a read-only MCP server, so your coding agents can ask the same questions.

![Unifai overview](docs/screenshots/overview.png)

- **Overview** opens on a billboard that rolls between total spent on AI, this month's spend and the credit you have left.
- **Wallets** read live balances from OpenRouter and DeepSeek, your ChatGPT plan with Codex usage limits and credits, your Claude plan, and OpenAI API spend. Any other provider can be tracked as a manual account.
- **Payments** keeps a currency-preserving ledger of top-ups, subscription charges and refunds, with spend charts.
- **Subscriptions** tracks expected renewals separately from money actually paid.
- **Timeline** logs usage resets, limits reached, free resets, cloud cost spikes, provider outages, releases and posts from X accounts you follow. It catches early resets, such as when OpenAI resets Codex limits for everyone, and shows which wallet has room right now.
- **Widgets** put AI spend, wallets and which wallet has room right now on your desktop or in Notification Center.
- **Agent access** exposes balances, spend, renewals, headroom and the timeline to Claude Code, Codex, Cursor or any MCP client, read-only.

Everything stays on your Mac. There is no account, server or sync. The first native milestone was verified on 2026-10-19; [verification evidence](evidence/VERIFICATION.md) records the checks and their limits.

| Wallets | Payments |
| --- | --- |
| ![Wallets](docs/screenshots/wallets.png) | ![Payments](docs/screenshots/payments.png) |
| **Subscriptions** | **Catalogue** |
| ![Subscriptions](docs/screenshots/subscriptions.png) | ![Catalogue](docs/screenshots/catalogue.png) |
| **Timeline** | **Azure wallet detail** |
| ![Timeline](docs/screenshots/timeline.png) | ![Azure resources](docs/screenshots/azure-detail.png) |

Screenshots use the synthetic demo workspace described below; no real account data is shown.

## Install

Install the signed, notarized app with Homebrew:

```sh
brew tap kennykankush/unifai https://github.com/kennykankush/unifAI
brew trust kennykankush/unifai   # newer Homebrew requires this for third-party taps
brew install --cask unifai
```

Update with `brew upgrade --cask unifai`. The cask also links `unifai-mcp` onto your PATH. Releases are built for Apple silicon and need macOS 14 or later.

## Develop locally

Use a Mac with Xcode and Swift installed. This checkout was built with Swift 6.2 and Xcode 26.0.1 on macOS 26.5, Apple silicon. The deployment target is macOS 14; an actual macOS 14 machine has not been tested.

Build the local development app and open it:

```sh
git clone https://github.com/kennykankush/unifAI.git
cd Unifai
bash scripts/build-app.sh
open ".build/Unifai Dev.app"
```

**Unifai Dev** is a separate app from the official **Unifai**. It shows a Dev tag, stores data in `~/Library/Application Support/Unifai Dev` and uses its own Keychain service, so you can run a development build next to the Homebrew install without either touching the other's accounts or records.

The build uses no package dependencies and applies a local ad-hoc signature. It requires no Apple developer account.

The window opens on **Overview** with an empty state. Click **Add Wallet**, or open **Catalogue** in the top bar, to add an account. The floating top bar (Liquid Glass on macOS 26) switches between Overview, Wallets, Payments, Subscriptions, Timeline and Catalogue, and its lime button runs the current page's main action. A dot marks Wallets when a reading failed or went stale, Subscriptions when a renewal is due within a week, and Timeline when something important happened in the last day. Press Command-F to search the current page and Command-N for the main action. Use the menu bar stack icon for the companion. **File > Show Companion** opens the same panel; **File > Show Unifai** returns to the main window. Closing the window keeps the companion running. Quit from the app menu or companion.

## Connect accounts and record money

Each account has its own label, billing owner and Keychain item. Add personal and work accounts separately. Connect a billing owner once; replace its key through **Edit Account** when needed. Matching labels or emails do not establish whether two accounts share billing.

| Connection | Working coverage | Required setup and limits |
| --- | --- | --- |
| OpenRouter account | Remaining USD credit, reported purchased credits and consumption | Enter a management key, then click Refresh. This key has broad authority; the app only sends the credits GET request. Credit totals do not establish cash receipts or daily history. |
| DeepSeek API | Current balances and purchased/promotional components, preserving currency | Enter an API key, then click Refresh. This endpoint supplies no payment or consumption history. |
| ChatGPT & Codex | ChatGPT plan, Codex 5-hour and weekly limits with reset times, Codex credits, free resets and daily token use | Install Codex (`brew install codex`), then **Sign in with ChatGPT** in Unifai or run `codex login`. Unifai talks to the local Codex app (`codex app-server`) and stores no OpenAI credential. |
| Claude subscription / Code | Claude plan (Pro, Max, Team) and sign-in state | Install Claude Code, then **Sign in with Claude** (opens `claude auth login` in Terminal). Anthropic does not share subscription usage limits with other apps, so those stay in Claude Code's `/usage`. |
| Kimi API (Moonshot) | Available, cash and voucher balance in US dollars | Enter a platform.kimi.ai API key. Unifai only sends `GET /v1/users/me/balance`. |
| Vercel AI Gateway | Remaining AI Gateway Credits and total used, in US dollars; detects later top-ups | Enter an AI Gateway API key. Unifai only sends `GET /v1/credits`. The totals cover the whole team and include free credits, so record purchases made before connecting from receipts. |
| ElevenLabs | Plan, characters used against the allowance and the reset date | Enter an API key with User read access. Unifai only sends `GET /v1/user/subscription`. Record the subscription as a schedule so renewals count toward spend. |
| Claude API / Console | API spend for the last 30 days | Enter an Admin key (`sk-ant-admin01-...`), which Anthropic only issues to Console organizations. Unifai only calls the Cost API; Anthropic has no remaining-credit endpoint, so import credit top-ups from receipts. |
| OpenAI API Platform | API spend per currency for the last 30 days | Enter an organization Admin key (`sk-admin-...`). Unifai only calls the Costs API; OpenAI has no prepaid balance endpoint. |
| Azure subscriptions | Month-to-date spend, daily cost, every service and every billed resource: virtual machines with size and power state, Foundry accounts with their deployed models, storage and networking, each with its meters. Click the wallet card to see it all. | Install the Azure CLI and run `az login` (or **Sign in with Azure**). Unifai runs read-only Cost Management queries through `az` and stores no Azure credential. The account needs Cost Management Reader for costs and Reader for the resource list. |
| AWS, Google Cloud, Vercel, Cloudflare, DigitalOcean, Hetzner and other hosting | Invoices, top-ups and recurring plans | Manual wallets under **Cloud & infrastructure**; import invoices from CSV and add schedules for fixed plans. |
| Manual financial accounts | Payments, refunds and expected renewals | Add confirmed records from receipts. Automatic balances and allowances remain unavailable. |
| Public GitHub releases | Recent releases in the Timeline, with notes and which of your wallets they affect | Add `owner/repository` with **Follow Repository**. Adding a Codex or Claude wallet follows `openai/codex` or `anthropics/claude-code` once. No credential is accepted or needed. |

The catalogue separates implemented connectors, manual records and planned capabilities. Planned financial services offer **Add Manual Account**. Planned news sources have no connection action. Claude API, Claude subscriptions, Codex allowances and OpenAI API billing remain separate entries.

Top-ups you forget to log are caught too. When OpenRouter's total of purchased credits rises between two readings, Unifai records the purchase as an **Estimate**, including OpenRouter's 5.5% card fee (0.80 minimum); a rise in DeepSeek's purchased balance is recorded as a lower bound. Importing the receipt replaces the Estimate.

Click an Overview spending amount, its **this month** chip, or **View breakdown** to see the contributing entries. Confirmed payments, estimates, automatic renewals and usage not yet invoiced have separate subtotals. Converted entries show the original amount and the reference rate used. Entries without a rate remain visible but are excluded from the total.

You can **Confirm** or **Edit** a detected payment inside its wallet as well as on the Payments page. New detections retain their before-and-after balance readings after confirmation. Older entries may not have this evidence.

Receipt imports replace at most one matching estimate per receipt. If the match is ambiguous, nothing in that import is saved. Edit the matching estimate with the receipt's amount, date and reference, then import again. When you have several wallets for one provider, include **account_label** in the CSV.

Auto renewals, detected top-ups and month-end usage estimates stay marked until a receipt confirms them. While any remain, **Payments** shows a **Close the books** banner with an **Unconfirmed** filter. **Copy Receipt Request** copies a prompt for an agent with mail access: it lists each entry and asks for a CSV in the import format. On the first three days of a month, a notification reminds you if last month still has unconfirmed entries.

In **Payments**, record settled charges using a positive amount and an ISO currency code such as USD or CNY. Choose **Refund** to reduce the paid total. A receipt reference detects duplicates within the same account. Edit or remove records through their row controls; removals require confirmation.

To bring in past payments, choose **Import CSV** on the Payments page. The file needs a header row with `date` (YYYY-MM-DD), `amount` and `currency`, and can add `description`, `kind` (subscription, top-up, usage or refund), `account` (a catalogue service such as `claude-api`), `account_label` and `reference`. Rows already recorded for the same wallet and receipt reference are skipped, a missing wallet is created as a manual account, and any invalid row rejects the whole file so nothing is half-imported.

Unifai also looks for recurring charges in your payments. A monthly or yearly pattern on one wallet appears under **Detected from your payments** on the Subscriptions page; **Add Schedule** opens it pre-filled, and **Check price** marks suggestions based on a prorated or changing charge.

Schedules can record each renewal automatically. When a renewal date passes, Unifai adds the charge to Payments, marked **Auto**, and moves the schedule forward; this runs at launch, when the app becomes active and every 30 minutes. Importing the real receipt replaces the Auto entry, and **Confirm Payment** marks it as verified. Renewals dated before the schedule existed are never back-filled.

In **Subscriptions**, save an expected amount, cadence and renewal date. A schedule creates no payments. After a renewal settles, choose **Record Settled Payment**, confirm the receipt, and update the next expected date. A ChatGPT plan shared with Codex should be recorded once.

Spending can be combined into one currency: choose **Combine** on the Overview card (or **All in …** from any currency menu). Each payment is converted at the European Central Bank reference rate for its own date, downloaded once a day from the ECB data API and cached as `exchange-rates.json`. Combined figures are labelled approximate because card issuers use their own rates; recorded amounts never change, and **Each currency separately** turns conversion off. The MCP server adds `paidTotalConverted` when conversion is on.

Total spent on AI is money paid plus this month's pay-as-you-go usage (Azure and similar), which becomes a recorded payment when the month closes. Money paid, provider-reported consumption, remaining credit and expected renewals otherwise stay separate. A USD 100 top-up followed by USD 30 of consumption is USD 100 paid and USD 70 remaining. Currencies are only combined in the optional converted view. Payment history shows its start and whether you have confirmed completeness for that period; it does not claim a lifetime total from a current balance.

## Billing models, budget and alerts

Every service is tagged with how it charges, and Unifai counts each accordingly:

| Model | Examples | How it is counted |
| --- | --- | --- |
| Prepaid credits | OpenRouter, DeepSeek, Claude API, OpenAI API | Top-ups are payments; the wallet shows remaining credit |
| Subscription | ChatGPT, Cursor, domains | Schedules record each renewal automatically on its date |
| Plan with usage limits | ChatGPT & Codex, Claude | Plan plus usage windows and reset times |
| Pay as you go | Azure, AWS, Google Cloud | Usage this month shows as accruing; at month end the last reading is recorded as an Estimate until the invoice is imported |

Open **Settings** (Command-comma) to set the display currency, a monthly budget, background refresh and notifications. With background refresh on, live wallets update every hour while Unifai runs. Notifications cover low credit (per-wallet thresholds in **Edit**), failed refreshes, renewals due tomorrow, recorded renewals, usage limits resetting, and 80% and 100% of the budget. The menu bar shows this month's spend, including pay-as-you-go usage, and Codex's weekly usage.

## Timeline

The **Timeline** page starts with **Right now**, which ranks your live wallets by the room they have left. Plan allowances with room come first, then prepaid credit and Codex credits, then pay-as-you-go accounts, then anything used up. Plan advice appears under the ranking, for example when you hit Codex's weekly limit twice in four weeks, or used the plan on 3 or fewer of the last 14 days.

Below it, events are grouped by day, with filters for your accounts, status pages, releases and posts:

| Event | Where it comes from |
| --- | --- |
| Reset and **Early reset** | Unifai compares each Codex reading with the last one. Usage that drops more than 15 minutes before the scheduled reset counts as an early reset. |
| Limit reached | A usage window reaches 100%. |
| Free reset | Codex grants a rate-limit reset credit. Redeem it in Codex. |
| Cost spike | An Azure service's latest full day costs at least twice its median over the week before and at least 1.00 more, or a service starts costing 1.00 a day. A single daily query covers the month-to-date total too. |
| Status | Public status pages for the providers you have wallets with: OpenAI, Anthropic, Azure and DeepSeek. Unifai keeps OpenAI incidents only when they mention products you use. |
| Release | Followed repositories. Unifai marks releases that mention a provider you pay for as **Yours**. |
| New model | Models added to OpenRouter's public list in the last two weeks, with context length and price per million tokens. Models from providers you pay for are marked **Your provider**. Checked every six hours. |
| News | OpenAI News, Google DeepMind, Google AI, Hugging Face and Simon Willison's weblog, from their public feeds. Anthropic publishes no feed. Turn news and models off in **Settings**. |
| Post | X accounts you follow, using your own X API bearer token, both set in **Settings**. Unifai asks only for posts newer than the last one it saw. X bills about US$0.005 per post read and US$0.01 per account lookup; Settings shows the estimated cost this month. Posts about resets or limits get a **Resets** tag. |

The **Status** panel shows each provider's state now: operational, or the ongoing incident. The **Releases** panel suggests widely used AI tools to follow, such as Ollama, llama.cpp, vLLM and LiteLLM. Unifai checks status pages, news, posts and releases every 30 minutes while it runs, or when you click **Check Now**. Early resets, free resets, cost spikes and reset posts also arrive as notifications.

## Desktop widgets

Unifai has three widgets. To add one, Control-click the desktop, choose **Edit Widgets**, and search for Unifai:

| Widget | Sizes | Shows |
| --- | --- | --- |
| **Right Now** | Small, medium | The wallet with the most room, its usage left, when it resets and any free resets. Medium adds the next two wallets. |
| **AI Spend** | Small, medium | This month's AI and cloud spend with your budget or pay-as-you-go usage. Medium adds the last six months and the next renewal. |
| **Wallets** | Small, medium, large | Balances, plans and usage limits. Large adds the latest timeline event. |

When an app is in front, macOS draws desktop widgets without colour; Unifai's widgets switch to outlines and logo marks so they stay readable. To keep them in colour all the time, set **System Settings > Desktop & Dock > Widget style** to **Full-color**. Click a widget to open Unifai on the matching page. The app writes a small snapshot to a shared container (`~/Library/Group Containers/<Team ID>.dev.unifai`) whenever its data changes. The widget is sandboxed and only reads that file: it has no keys and makes no network requests. Widgets show figures as of the app's last refresh, so keep Unifai running (it can sit in the menu bar) for them to stay current.

## Let agents read your balances (MCP)

`unifai-mcp` is a read-only MCP server over stdio. Any MCP client, such as Claude Code, Codex or Cursor, can use it to answer "how much credit do I have left?" from the same data the app shows.

With the Homebrew install, the server ships inside the app:

```sh
claude mcp add --scope user unifai -- /Applications/Unifai.app/Contents/MacOS/unifai-mcp
```

The white **Agent access** button in the app's top bar copies the exact setup line for whichever app you are running. Development builds register as `unifai-dev` and point at the Unifai Dev data folder. To build only the server from source, run `bash scripts/build-mcp.sh`.

| Tool | Returns |
| --- | --- |
| `get_overview` | Remaining credit per account, money paid per currency, renewals due within 30 days, and accounts with stale or failed readings |
| `get_balances` | Per-account credit remaining, purchased/promotional components, reported consumption, observation time and staleness. Optional `provider` filter |
| `get_spending` | Recorded payments and refunds with per-currency totals and coverage. Optional `since` (YYYY-MM-DD) and `limit` |
| `get_renewals` | Expected renewals with amount, cadence and days until due. Optional `within_days` |
| `get_headroom` | Live wallets ranked by usable capacity now, with a one-line recommendation, reset times, free resets and the budget. For agents choosing where to run heavy work |
| `get_timeline` | Recent events: resets, limits, free resets, cost spikes, incidents, releases and posts. Optional `kinds`, `since` and `limit` |
| `get_spending_breakdown` | Dashboard arithmetic, entries, confirmation states, conversions and per-account subtotals. Defaults to this month; supports `period: "all"`, `since`, `through`, `currency`, `account_id`, `include_accruing`, `limit` and `offset` |
| `get_payment` | One payment's status, receipt reference and retained top-up evidence. Requires `payment_id` |
| `get_unconfirmed_payments` | Estimates and automatic renewals awaiting confirmation, totals per currency and a receipt-search prompt. Supports `account_id`, `limit` and `offset` |
| `get_account_details` | One wallet's reading, coverage, recent payments, renewals and available cloud service/resource costs. Requires `account_id`; optional payment `limit` |
| `get_renewal_outlook` | Expected charges over the next 1–366 days, with overdue schedules separated. Optional `within_days`, `currency` and `account_id` |
| `get_data_health` | Missing, stale, failed and manual wallets; history completeness; unconfirmed counts; exchange-rate age; and budget usage |

The server re-reads `state.json` on every call. It never opens Keychain, sends network requests, confirms payments, restores backups or writes data. Balances are as fresh as the last **Refresh** in the app. Headroom recommendations exclude stale or failed readings from usable capacity and list accounts without measurable capacity separately.

Every amount carries its currency. Original reports encode amounts as decimal strings; the detailed reports use JSON decimal numbers. Explicit converted totals name the target currency and explain the exchange-rate basis. Credit remaining, recorded payments, accruing usage and expected renewals stay separate.

For “why is my total this much?”, call **get_spending_breakdown**, then **get_payment** with an entry's ID for its evidence. For “what will renew next month?”, call **get_renewal_outlook**. Use **get_data_health** before treating missing or stale data as a current answer.

Breakdown and unconfirmed-payment pages return **totalEntries**, **offset** and **hasMore**. Totals cover all matching entries, even when the returned list is paginated. Date-only filters use the Mac's calendar; **through** includes that whole day. Current month-to-date usage is excluded from historical or partial-month ranges because it cannot be allocated reliably. Renewal projections use saved schedules and current reference rates; they do not forecast cloud usage or purchases.

To use a different data directory, pass `--data-directory <path>` or set `UNIFAI_DATA_DIR`. For example, to try the server against synthetic data, run `.build/release/unifai-mcp --data-directory .qa/fixture-workspace`.

## Refresh and storage behavior

Wallets refresh every hour in the background (turn this off in **Settings**) or with **Refresh**. Balance refreshes have a one-minute per-account cooldown. Failed refreshes preserve the previous reading and show the error; balance readings become stale after one hour.

GitHub uses one conditional request per refresh, at most 10 repositories, a 30-minute cooldown per repository, and a persisted budget of 20 requests per hour across the watchlist. Cooldowns apply to failures too. Server rate-limit backoff applies across repositories and survives relaunch. Other apps may use the same originating IP limit.

Normal data lives in `~/Library/Application Support/Unifai/state.json`. The file contains account metadata, readings, payment records, schedules and release caches, with mode `0600`. Credentials live separately in macOS Keychain, scoped by Unifai service and account UUID. The app does not enumerate other credentials, inspect browser sessions, or import local tool accounts.

Before changing existing saved data, Unifai creates local copies under **Backups** beside `state.json`. It keeps 30 recent versions and 14 daily checkpoints. Unchanged saves create no additional copies. If a backup cannot be written, the existing data is not overwritten.

Open **Settings → Review Local Backups** to inspect and restore a copy. A restore preserves the displaced file, even if it is corrupt. Files preserved by an explicit restore are not automatically deleted. If the main data file cannot load, **Review Local Backups** is also available in the main window. Recovery waits until active refreshes finish.

These are private local JSON files, not encrypted or off-device backups. They contain no Keychain credentials. Reconnect accounts whose keys are unavailable after recovery or moving to another Mac. Quit Unifai before making a separate manual copy, and run one normal app process per data directory.

## Try the synthetic workspace

Use this separate app to explore without provider credentials:

```sh
bash scripts/run-fixture.sh
```

**Unifai Fixtures** displays a persistent synthetic-data banner and disables all network transports. It stores records in `.qa/fixture-workspace`, uses in-memory account keys, and preserves edits across relaunch. Each launch also checks Keychain with newly created synthetic items in a unique test service, removes them, and writes `native-keychain-check.json` in the fixture directory.

Refresh its OpenRouter and DeepSeek accounts to see sample readings. In a fixture account’s **Edit Account** form, replace the key with `fixture-unauthorized` or `fixture-offline` to inspect failures. These strings are test selectors, not provider credentials. Fixture keys reset to valid synthetic values on relaunch; saved readings and errors remain until refreshed.

## Run the checks

Run the offline suite; live integration checks are skipped by default:

```sh
bash scripts/swift-local.sh test
python3 scripts/check-mcp.py
```

Opt in to the synthetic Keychain check and one anonymous public request to `swiftlang/swift` (add `UNIFAI_TEST_CODEX=1` or `UNIFAI_TEST_CLAUDE=1` to read the local Codex or Claude Code sign-in):

```sh
UNIFAI_TEST_KEYCHAIN=1 UNIFAI_TEST_PUBLIC_GITHUB=1 \
  bash scripts/swift-local.sh test
```

The offline suite currently discovers 118 tests, with 8 opt-in checks skipped. The MCP smoke check exercises all 12 tools through the stdio executable against disposable data and verifies that queries leave it unchanged. `UNIFAI_TEST_STATUS=1` reads the four public status pages and `UNIFAI_TEST_AZURE=1` runs a live Azure cost query. An earlier witnessed full run, with both integration checks enabled, passed 32 tests with no failures or skips. It retrieved 50 public GitHub releases in one request. Debug and optimized builds passed. [Native checks](evidence/VERIFICATION.md) covered empty state, account setup, both fixture balances, retained error readings, payments, schedules, catalogue search, releases, resizing and the companion.

## Release

Official releases come from `scripts/release.sh` on the release Mac. It runs the tests, builds an optimized app, signs the app and the embedded `unifai-mcp` with a Developer ID certificate and hardened runtime, notarizes and staples it, tags `v<VERSION>`, uploads the zip to GitHub Releases, and updates [`Casks/unifai.rb`](Casks/unifai.rb) in this repository, which is its own Homebrew tap.

```sh
# once: save notarization credentials (app-specific password from account.apple.com)
xcrun notarytool store-credentials unifai --apple-id <apple id> --team-id <team id>

# each release: bump VERSION, commit and push main, then
bash scripts/release.sh
```

`bash scripts/release.sh --dry-run` builds, signs and verifies locally without notarizing or publishing.

## Remaining limits

OpenRouter and DeepSeek have contract, parsing and failure-path validation with synthetic fixtures. Authentication against real provider accounts remains unverified until keys are entered. No paid provider or news request was made during development.

Claude subscription usage limits (Anthropic offers no interface for them), cost spikes for clouds other than Azure, and sync remain out of scope. Reset detection compares two readings, so Unifai dates a reset to the first reading that shows it, up to an hour after it happened. Light appearance, VoiceOver operation and macOS 14 hardware have not received hands-on verification. Releases are Apple silicon only.

## Credits

Provider logos come from [LobeHub Icons](https://github.com/lobehub/lobe-icons) (MIT License, included at `Sources/Unifai/Resources/Logos/LICENSE`). Logos and product names are trademarks of their respective owners and are used only to identify each service.

[VISION.md](VISION.md) preserves the original intent and raw quotes unchanged. [DEVELOPMENT.md](DEVELOPMENT.md) describes the implementation and current status.
