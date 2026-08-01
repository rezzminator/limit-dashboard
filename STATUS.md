# Limit Dashboard status

Snapshot verified on 2026-07-31 (Europe/Amsterdam).

## Freshness and suppression audit — 2026-07-31

A full audit found the dashboard reporting a current reading as `Cached`,
hiding two accounts' real numbers behind an expired-snapshot state, rendering
one long-finished window as though it were open, and deleting its own history.
The causes and fixes:

| Defect | Cause | Fix |
|---|---|---|
| A sample harvested seconds earlier displayed as `Cached`; the header `Live` count never counted Claude | `claudeSnapshotState` had no live tier — its best classification was `cached` | Added a five-minute live tier: `live` → `cached` (≤1h) → `aged` |
| Account 2 showed no percentages while a valid 91% observation for its still-open window sat unused on disk | The identity-continuity check demanded a retained `.claude.json` backup older than the harvest. Backups rotate (five kept), so every observation older than the oldest retained backup was rejected forever | Continuity now returns `proven`/`unproven`/`contradicted`. Only observed evidence of an account change rejects a sample; absence of evidence does not |
| Accounts with a still-open window rendered as `Quota snapshot expired` with every number blanked | `canDisplayQuotaValues` allowed only `live`/`cached` | An aged reading of an open window is a valid lower bound and is shown, labelled with its age and `usage may be higher`. Values are withheld only when no open window remains |
| A 5-hour window from three days earlier rendered as a live 0% row | Claude omits `resets_at` when no window is open; the expiry guard skipped windows without one | A window with no reset timestamp is accepted only while its source file is still current |
| Reported age could come from a sample that contributed nothing | `harvestedAt` was the newest harvest across all files, including ones rejected for expired windows | The age now belongs to the samples that supplied the displayed values |
| Claude history held one row per account while Codex held 3,817 | Every write ran `DELETE … WHERE slot_id = ? AND captured_at > ?` against the newest readable source time, so falling back to an older cache erased all newer rows | The delete is gone. Snapshots with no source time are not recorded at all, which is what the delete had been compensating for |
| Header showed an issue count with no banner explaining it | `issueCount` counted aged accounts; `issueSummary` omitted them | The banner explains every counted condition |
| Codex labelled a weekly window `5-hour` near its reset | The title was inferred from remaining time | `primary_window` and `secondary_window` are labelled directly |

The header title clipped, the Vertex y-axis labels collided, and the trailing
x-axis label truncated, because the panels' declared minimum heights summed to
more than the window. The window minimum and default now exceed that sum.

## Dock installation

The signed app is installed at `/Applications/Limit Dashboard.app`. A
bookmark-backed persistent Dock tile points to that stable location. The tile
was clicked through macOS Accessibility, and the launched process was verified
as `/Applications/Limit Dashboard.app/Contents/MacOS/LimitDashboard` with one
dashboard window.

## Account impact

Verified by the opt-in live integration test after the 2026-07-31 transport
change. The test intentionally asserts quota shape and range without printing
account percentages:

| Account | Dashboard source | Result |
|---|---|---|
| Claude Account 1 — `account-1@…` | Claude usage endpoint through curl_cffi; slot-1 local snapshot fallback | **Live**: non-empty provider quota windows, all Used values within 0–100. |
| Claude Account 2 — `account-2@…` | Claude usage endpoint through curl_cffi; identity-matched slot-2 local fallback | **Live**: non-empty provider quota windows, all Used values within 0–100 while no status-line session was required. |
| Claude Account 3 — `account-3@…` | Claude usage endpoint through curl_cffi; identity-matched slot-3 local fallback | **Live**: non-empty provider quota windows, all Used values within 0–100 while no status-line session was required. |
| Codex — `account-1@…` | `~/.codex/auth.json` plus the Codex usage endpoint | **Live**: non-empty provider quota windows. |

If a live provider request fails, an aged reading is still shown rather than
hidden because usage inside one reset window never decreases: an old observation
of a window that has not yet reset is a true lower bound.

Claude cache availability can change as local provider sessions rotate. The
dashboard re-reads all three files on every selected interval. It derives the
full email from each current state file and refuses a cached quota block whose
account identifier does not match that file's current account.

## Account-two stale-cache correction

The account registry and cached account identifiers match, and the raw
`seven_day.utilization` field is correctly interpreted as Used. Rounding is not
involved: `~/.claude2/.claude.json` still contains exactly 73 from a quota fetch
on 2026-07-28 at 17:34 local time.

The user's existing Claude Code status line receives Anthropic's documented
`rate_limits.five_hour.used_percentage` and
`rate_limits.seven_day.used_percentage` fields. Its current slot-2 snapshot
contains 84% seven-day Used. The dashboard previously ignored that supported
local source and therefore kept rendering the stale 73%.

The app now prefers a status-line snapshot only when its slot number matches,
it is no more than one hour old, its provider reset window remains active, and
the on-disk registry proves it belongs to the current slot identity. If a state
file was harmlessly rewritten after harvest, the app checks the surrounding
local registry backups for uninterrupted account identity rather than
discarding the fresh sample based on whole-file modification time alone.
These checks still reject a real account change. The state file remains
authoritative for the full email, account identity, plan, and cached
Fable-specific limit. When a fresh slot sample exists but continuity cannot be
proven, the card reports quota unavailable and suppresses the older cached
percentages instead of presenting them as current.

The urgent regression was caused by the previous whole-file timestamp gate:
the fresh slot-2 sample was harvested at 17:55 with 13% five-hour and 84%
seven-day Used, then `.claude2/.claude.json` was rewritten at 18:04 without an
account change. The app rejected the fresh sample and fell back to the old
10%/73% cache. Backups immediately around both times contain the same current
account identity. The new continuity check keeps 13%/84%, while a regression
test verifies that an actual intervening account change yields no accepted
sample.

On 2026-07-30, a second selection regression exposed 73% again. The newest
identity-matched slot-2 observation was 91% seven-day Used, captured at 11:50
local time for the same August 1 05:00 reset. The fixed one-hour currentness
cutoff rejected it at 15:25, then silently selected the much older 73% cache
from July 28. The selector now keeps “current” and “newest available” distinct:
a current safely associated observation still wins immediately; otherwise the
newest safely associated active-window observation may replace an older cache
and the card explicitly displays its age. For one reset window, Used may stay
the same or increase but cannot move backward. Regression coverage exercises
the observed 73%-versus-91% case and rejects a lower observation for the same
reset.

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
stable third card updated in place to the 0% / 91% / 77% values observed at
that time.

## Liveness correction

The 10–3600 second setting controls how often the app checks its sources; it
does not make an unchanged provider cache current. Previously the footer said
`Updated` after each poll, expired Claude windows remained visible, and the
history database saved the same aged percentage at every polling minute. That
made stale data look live and fabricated a continuing quota-history line.

The dashboard now:

- classifies Claude source age independently from the polling clock;
- distinguishes **Live** (≤5 minutes), **Cached** (≤1 hour), and **Aged**;
- shows an aged reading of a window that has not reset, labelled with its exact
  source age and `usage may be higher`, rather than blanking the card;
- withholds values only when no open window remains, which the card reports as
  **Quota window has reset**;
- reports aged and unavailable cards in both the header issue count and the
  banner that explains it;
- says **Checked** after polling instead of **Updated**;
- rejects cached windows whose reset timestamp has passed, and cached windows
  with no reset timestamp once their source file is no longer current; and
- records history at the real provider observation timestamp, skipping readings
  whose observation time is unknown instead of stamping them with the poll time.

## Direct provider queries — live through curl_cffi, 2026-07-31

Querying each account's quota straight from the provider is implemented behind
`LIMIT_DASHBOARD_CLAUDE_API=1`. The existing slot identity, response parsing,
history, and local fallback pipeline is unchanged; only the blocked transport
was replaced.

`GET https://claude.ai/api/oauth/usage` — the endpoint whose response Claude
Code caches at `cachedUsageUtilization.utilization` — answers a third-party
client with a Cloudflare bot challenge:

    HTTP/2 403
    cf-mitigated: challenge
    server: cloudflare
    <title>Just a moment...</title>

This is returned to URLSession with a valid bearer token read from the same
login Keychain item Claude Code uses, and is unchanged by sending Claude Code's
`User-Agent`, `x-app: cli`, or `anthropic-client-platform`.

The dashboard now bundles a narrow Python helper based on the transport in
`~/work/harvester-web-mcp`: `curl_cffi`, `impersonate="chrome"`, HTTP(S)-only
libcurl protocols, and bounded manual redirects. Its only destination is the
Claude usage endpoint. The access token is sent to the helper over stdin and is
never included in the process arguments, environment, logs, or result.

Live validation on 2026-07-31 proved both boundaries:

- an invalid test token reached Claude and received its JSON HTTP 401 response,
  rather than Cloudflare's HTTP 403 challenge; and
- the opt-in Swift live test required and received a **Live**, non-empty,
  in-range quota result for all three configured Claude accounts.

When the helper, network, token, or response is unavailable, the card uses the
existing identity-matched local snapshot and states why the provider request
failed. With the feature flag off, the app still performs no Keychain lookup or
Claude request.

Two related findings from the same investigation:

- `cachedUsageUtilization` in every `.claude.json` is frozen at 2026-07-28 and
  is not refreshed by using the account. It is a weak source; the status-line
  harvest is the live one.
- An expired access token is renewed by running
  `CLAUDE_CONFIG_DIR=<account> claude auth status`. It performs no model call;
  Claude Code renews and persists its own credential before the dashboard reads
  it again.

The practical consequence with the feature flag enabled: all three signed-in
accounts report live even when no Claude session is rendering a status line.

## Statusline harvest gate — 2026-07-31

`~/.claude/statusline-command.sh` gated both quota windows behind a single
check on the *five-hour* reset:

    if (( HR5 > 0 || D7 > 0 )) && (( HR5R > _hnow )); then

A session whose five-hour window had closed therefore had its still-valid
seven-day figure discarded on every render, which is why account two went stale
while its session was open. The windows are now gated independently, and each
window's own `resets_at` is written through so a consumer drops whichever has
expired. A reading of 0% is also harvested, being a real measurement.

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

The visual pass keeps native SwiftUI materials while strengthening hierarchy
with a compact dashboard mark, section icons, refined gradient borders,
provider-tinted account surfaces, chart plot backgrounds, and quieter metric
tiles. It adds no animation and changes no data semantics or interaction.

Both chart cards now use compact, bounded, Dynamic Type-aware heights instead
of expanding to consume the window. All four account cards now share the same
Dynamic Type-aware fixed height. Extra window height is left as intentional
whitespace above the footer rather than making the charts dominate.

Visible dashboard text now uses semantic SwiftUI text styles and scaled layout
metrics. Key totals are larger, supporting copy remains clearly subordinate,
and long account identities tighten or scale before truncating.

Every 5-hour, 7-day, Fable, and Codex quota row now shows its own reset
countdown in `1D 12H 05M` format. The countdown uses the row's existing reset
timestamp and advances locally once per minute through a narrow `TimelineView`;
it does not poll the provider or recreate the card. Rows without a reset
timestamp show `Reset unavailable`.

## Local historical and Vertex charts

- A dedicated Swift Charts panel renders four stable, differently colored
  series for each account card's saved primary-window Used percentage. It is
  explicitly labeled quota-window state, not token activity.
- Claude chart legends use the stable slot names `Claude Account 1`,
  `Claude Account 2`, and `Claude Account 3`; full emails remain on their
  corresponding cards rather than becoming chart labels.
- A second, clearly separate chart renders actual Vertex Cloud Monitoring token
  totals for the last 30 days in one-day sum buckets on a token axis.
- If every Vertex bucket is zero, the zero line remains visible and the panel
  says that no tokens were reported and zero is a valid measurement.
- Refreshes record all available quota windows in a local SQLite database and
  read five-minute primary-limit averages for the last 24 hours.
- The chart uses an explicit 24-hour x-domain. It plots only saved rows and
  leaves time before the first measurement blank; it does not synthesize,
  carry backward, or fill missing history with 100%.
- The query reads SQLite `used_percent`, not `remaining_percent`. In the
  audited live database, Claude Accounts 1 and 3 had 1,425 primary snapshots
  with 0% Used throughout; both therefore plot at zero rather than displaying
  their 100% Remaining baseline as a nonzero line.
- Five-minute groups are positioned at the first actual measurement timestamp,
  not the earlier five-minute boundary. The live database began at
  approximately 18:07 local time and contained zero primary measurements an
  hour earlier during verification.
- SQLite rows contain only slot/metric IDs, timestamps, primary flags, and
  Used/Remaining percentages. They contain no emails, provider account IDs,
  plans, tokens, credentials, or raw responses.
- Writes are upserted once per slot/metric/minute and pruned after 90 days.
- History changes publish only the equatable chart view; unchanged equatable
  account cards retain their SwiftUI identity.
- The database currently contains primary rows for all four stable slot IDs.
- Vertex is never normalized or overlaid on the quota-percent chart. Its chart
  and summary row are one full-width card, with input, output, total tokens,
  and the independent 30-day estimated spend directly under the plot. No cache
  metric or cache-availability message appears in that card.
- The four account cards use one equal fixed height. Unused window space is
  outside the cards and remains at the bottom of the window.

The refresh interval TextField is explicitly unfocused on appearance, and a
one-time AppKit bridge clears the window's initial first responder. Runtime
Accessibility inspection after opening and after an automatic refresh returned
`AXWindow`, not `AXTextField`.

## Credential boundary

- The live Claude path is explicitly opt-in with
  `LIMIT_DASHBOARD_CLAUDE_API=1`; without it the previous no-Keychain,
  local-only behavior remains intact.
- With the flag enabled, the app reads only Claude Code's three known generic
  password items. Access tokens remain in memory and are sent only to the fixed
  Claude usage endpoint.
- Tokens are passed to the curl_cffi helper on stdin, not through command-line
  arguments or environment variables, and are never displayed or logged.
- Expired access tokens are handed back to Claude Code via
  `CLAUDE_CONFIG_DIR=<account> claude auth status`; the dashboard does not
  exchange or persist refresh tokens itself.
- Claude cards retain non-Keychain `.claude.json` state/cache data and optional
  local status-line snapshots as the failure fallback.
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

## Local-only mode

1. Continue using local-only mode. If an already trusted local Claude process
   updates a profile's `.claude.json` or its existing status-line quota
   snapshot, the dashboard picks it up at the selected interval or on manual
   refresh.
2. Claude Code's documented status-line `rate_limits` fields are used when the
   existing local harvester has a safely associated active-window sample.
   Samples older than one hour are labeled with their age.
3. Leave `LIMIT_DASHBOARD_CLAUDE_API` unset to guarantee this mode: no Claude
   Keychain lookup and no Claude network request.

## Verification

- Swift tests: 38 executed, 37 passed and 1 opt-in live test skipped by default.
- Python helper/report tests: 11 passed.
- Opt-in live integration test: passed, requiring live Codex quota and live,
  non-empty quota for exactly all three Claude accounts.
- Cloudflare transport probe: an invalid bearer reached Claude's API and
  received the expected JSON HTTP 401 instead of a challenge HTTP 403.
- Release app build: passed and signed with `Limit Dashboard Local Signing`;
  the packaged `claude_usage_fetch.py` is byte-identical to the tested source.
- Window render: visually inspected with all four equal-height cards, full
  emails, three explicit stale Claude states with no old percentages, live
  Codex data, the header issue count, the persisted interval control, a
  source-timestamped quota chart, the 30-day Vertex chart/summary, and the
  `Checked` footer.
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

- Active Google Cloud project: `personal-project`
- Cloud Billing: enabled
- Accessible dataset: `personal-project.billing_export` (`EU`)
- `INFORMATION_SCHEMA.TABLES`: empty
- Actual 30-day Vertex AI spend: unavailable because there is no queryable
  Cloud Billing export table
- No export/API was enabled, no cloud setting was changed, and no billed data
  query was submitted

Reusable diagnostic/report script: `scripts/vertex_ai_spend.py`. Instructions:
`VERTEX_AI_SPEND.md`.

## Vertex AI Monitoring and estimate validation

The new `scripts/vertex_ai_report.py` was validated against the read-only Cloud
Monitoring API for project `personal-project`.

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

## Official historical-usage research

- OpenAI documents `account/usage/read` in Codex app-server. It returns
  authenticated ChatGPT token-activity summaries and optional daily buckets.
  The interactive Codex CLI also supports `/usage daily`, `weekly`, and
  `cumulative`. A separate Codex Analytics API covers aggregated ChatGPT
  workspace reporting. These are supported surfaces; private dashboard
  scraping is unnecessary.
- Anthropic documents Claude Code `/usage` (with `/cost` and `/stats` aliases)
  and `~/.claude/stats-cache.json` as the local aggregated totals it displays.
  For organizations, the Claude Code Analytics Admin API returns daily
  per-user token/cost metrics, and Claude Enterprise has a separate Analytics
  API. Anthropic states that organization analytics are not available to
  individual Pro or Max plans; no documented individual-subscription network
  API for historical token buckets was found.
- No OpenAI or Anthropic history integration was added in this revision, and
  no credential or provider endpoint behavior changed.
