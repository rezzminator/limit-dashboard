# Limit Dashboard status

Snapshot verified on 2026-07-28 (Europe/Amsterdam).

## Account impact

| Account | Dashboard source | Result |
|---|---|---|
| Claude — `mrez9090@gmail.com` | `~/.claude.json` | **Cached**: 0% used / 100% remaining in the 5-hour window, 90% used / 10% remaining in the 7-day window, and 97% used / 3% remaining in the weekly Fable limit. The first card now renders correctly. |
| Claude — `reza.khosravivala@gmail.com` | `~/.claude2/.claude.json` | **Cached**: 10% used / 90% remaining in the 5-hour window, **73% used / 27% remaining in the 7-day window**, and 26% used / 74% remaining in the weekly Fable limit. |
| Claude — `reza@intuita.health` | `~/.claude3/.claude.json` | **Cached and matching**: 0% used / 100% remaining in the 5-hour window, 91% used / 9% remaining in the 7-day window, and 77% used / 23% remaining in the weekly Fable limit. |
| Codex — `mrez9090@gmail.com` | `~/.codex/auth.json` plus the Codex usage endpoint | **Live**: **91% remaining** / 9% used in the current weekly window during the latest render. |

Claude cache availability can change as local provider sessions rotate. The
dashboard re-reads all three files on every selected interval. It derives the
full email from each current state file and refuses a cached quota block whose
account identifier does not match that file's current account.

## Rendering and mapping correction

The first card was reading `~/.claude/.claude.json`, an empty per-config file.
Claude's primary account state is actually the root file `~/.claude.json`, so
the primary cache was never rendered.

Two additional bugs made the account rows misleading:

- hardcoded email labels overrode each state file's current
  `oauthAccount.emailAddress`, so cache data could appear on the wrong named
  card after an account switch;
- the UI inverted raw `utilization` into Remaining and filled the bar with that
  inverse without also labeling Used. The observed raw seven-day value `73`
  therefore did not appear as `73% used`.

The app now uses the exact canonical state paths, prefers the on-disk full
email, checks cache/account identifiers, and renders `73% used · 27% remaining`
with a 73%-filled bar for the observed case.

The third Claude profile was exhaustively checked across its current state,
session metadata, backups/history, Claude desktop support files, CodexBar
caches, and local usage-history files. It was correctly rendered as
authenticated-but-quota-unavailable while its cache belonged to account two.
The active `.claude3` process later wrote its own matching cache, and the same
stable third card updated in place to the 0% / 91% / 77% values above.

## Refresh rendering correction

The previous poll path set every card to `.loading` before fetching, then
replaced the whole snapshot array. That caused the entire dashboard to flash
every 20 seconds.

The app now:

- keeps the four stable slot/card identities throughout a poll;
- never replaces existing cards with loading placeholders after launch;
- compares visible snapshot content at the model layer, intentionally ignoring
  fetch timestamps;
- publishes only snapshot indices whose visible values changed; and
- uses equatable card views so header/footer changes do not redraw unchanged
  cards.

Manual refresh alone shows activity in the footer. Automatic refresh remains
20 seconds by default and does not animate numeric fields or the card grid.

## Local historical and Vertex charts

- A Swift Charts panel at the top renders four stable, differently colored
  series for each account card's primary Remaining percentage.
- Refreshes record all available quota windows in a local SQLite database and
  read five-minute primary-limit averages for the last 24 hours.
- SQLite rows contain only slot/metric IDs, timestamps, primary flags, and
  Used/Remaining percentages. They contain no emails, provider account IDs,
  plans, tokens, credentials, or raw responses.
- Writes are upserted once per slot/metric/minute and pruned after 90 days.
- History changes publish only the equatable chart view; unchanged equatable
  account cards retain their SwiftUI identity.
- The database currently contains primary rows for all four stable slot IDs.
- A separate token-scale panel renders the last 8 hours of Vertex token totals
  in 20-minute sum buckets by default, beside the independent 30-day token and
  estimated-spend summary. Its range labels come from the script result rather
  than fixed display strings.

The refresh interval TextField is explicitly unfocused on appearance, and a
one-time AppKit bridge clears the window's initial first responder. Runtime
Accessibility inspection after opening and after an automatic refresh returned
`AXWindow`, not `AXTextField`.

## No-Keychain policy

- The app does not link the macOS Security framework.
- It contains no Keychain query code or Claude credential service names.
- It makes no Claude network requests.
- It never asks for a password.
- Claude cards read only non-Keychain `.claude.json` cache data.
- The primary Claude state path is `~/.claude.json` (not
  `~/.claude/.claude.json`).
- Fable is read only from
  `cachedUsageUtilization.utilization.limits[]`, selecting the
  `weekly_scoped` entry whose `scope.model.display_name` is `Fable`. Its
  `percent` is treated as used percentage and `resets_at` as the reset time.
- Extra/paid usage metadata is not used as a Fable substitute.
- Automatic refresh defaults to 20 seconds. Its visible numeric control accepts
  10–3600 seconds and persists the selected value.
- The normal card UI contains no security-method warning. Genuine
  quota-unavailable and stale/mismatched data states remain explicit.
- Codex tokens are read into memory, sent only to the Codex usage endpoint, and
  never displayed or logged.

## Non-Keychain alternatives

1. Continue using cached-only mode. If an already trusted local Claude process
   updates a profile's `.claude.json`, the dashboard picks it up at the selected
   interval or on manual refresh.
2. A future provider-supported, non-Keychain local session source can be added
   if one is configured. None was found for these three Claude profiles during
   this inventory.
3. Keychain behavior remains out of scope unless the user later explicitly
   authorizes a specific action.

## Verification

- Release build: passed.
- Swift tests: 13 executed, 12 passed and 1 opt-in live test skipped by default.
- Opt-in live Codex integration test: passed.
- App signature and `Info.plist`: passed.
- Binary linkage check: no Security framework.
- Source audit: no `SecItem`, `kSec`, Claude Keychain service, or Anthropic
  endpoint path.
- Window render: visually inspected with all four cards, full emails, cached
  states, the corrected first account, the second account at 73% seven-day
  Used, the matching third account at 91% seven-day Used, remaining-first
  headlines, the persisted interval control, Claude Fable usage, live Codex
  state, the four-series quota history chart, and the separately scaled Vertex
  chart/30-day estimate.
- Automatic-refresh render: before/after captures showed no loading replacement
  or layout/card redraw; only the freshness text advanced.

## Fable source research

- Anthropic documents Fable 5 as drawing from a plan's weekly usage and, for
  eligible plans, having a model-specific allowance:
  <https://support.claude.com/en/articles/15424964-claude-fable-5-on-your-plan>
- A current public issue in Anthropic's Claude Code repository shows the cached
  row labeled `Weekly · Fable` and the exact `weekly_scoped` payload fields:
  <https://github.com/anthropics/claude-code/issues/78507>

## Vertex AI spend diagnostic

- Active Google Cloud project: `freudche`
- Cloud Billing: enabled
- Accessible dataset: `freudche.billing_export` (`EU`)
- `INFORMATION_SCHEMA.TABLES`: empty
- Actual 30-day Vertex AI spend: unavailable because there is no queryable
  Cloud Billing export table
- No export/API was enabled, no cloud setting was changed, and no billed data
  query was submitted

Reusable diagnostic/report script: `scripts/vertex_ai_spend.py`. Instructions:
`VERTEX_AI_SPEND.md`.

## Vertex AI Monitoring and estimate validation

The new `scripts/vertex_ai_report.py` was validated against the read-only Cloud
Monitoring API for project `freudche`.

- 30-day summary: 132,247,169 input tokens not marked explicit-cache,
  28,859,150 output tokens, 161,106,319 total. Explicit-cache-served input was
  not reported by the returned metric labels; no `0%` cache-hit claim is made.
- Estimated list-price spend for that same token window: **~EUR 97.30**.
- The estimate clearly flagged embedded pricing for `gemini-2.5-flash` because
  the configured live Catalog SKU description was absent, plus unknown-model
  assumptions for `gemini-3.1-flash-lite` and `gemini-embedding-001`.
- One live Monitoring query covered independent windows: an 8-hour chart with
  24 distinct 20-minute sum buckets and the full 30-day summary above.
- Both ranges are dynamic: chart start/end or relative duration and bucket
  interval are independent of summary start/end or relative duration.
- Historical implicit cache-hit tokens/rate remain unavailable without
  request-level `UsageMetadata.cachedContentTokenCount` capture.
- Python unit tests: 8 passed, covering bucket boundaries, end exclusivity,
  independent windows/union selection, token aggregation, model separation,
  cache-label semantics, and fallback labeling.

The EUR result is not an exact bill. Exact exported spend remains blocked by
the empty Cloud Billing export dataset described above.
