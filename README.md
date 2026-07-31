# Limit Dashboard

A single-window native macOS dashboard for the three local Claude Code profiles
and the local Codex subscription on this Mac.

## Run

Double-click **Limit Dashboard.app**. It refreshes on launch, every 20 seconds
by default, and with `⌘R`.

The numeric **Every … sec** control changes automatic refresh immediately. The
value is clamped to 10–3600 seconds and retained across app launches.
Automatic polls keep all four card views in place: the dashboard compares
visible snapshot values and publishes only cards whose content changed. It
does not replace the dashboard with a loading state or animate the collection
on every poll.

The interval field does not receive initial focus. The window opens with a
neutral window focus, and background refreshes preserve that focus instead of
placing a caret in the numeric field.

The interface uses native SwiftUI materials, restrained provider accents,
rounded system typography, and subtle static shadows. It contains no broad
refresh animation or web-style navigation chrome.

The quota and Vertex chart regions use bounded, Dynamic Type-aware heights.
They grow only modestly and stop before dominating a tall window. All four
account cards share one equal, Dynamic Type-aware height, while any remaining
window space is left as intentional whitespace above the footer.

Every quota row shows its own live reset countdown in
`1D 12H 05M` format. Countdowns advance locally once per minute without
triggering a provider refresh or replacing the account card. A row whose
authorized source has no reset timestamp says **Reset unavailable** instead of
inventing a time.

## Local history and Vertex charts

The dashboard keeps unlike measurements in two separate chart boxes:

- **Quota window state** plots saved primary-window **Used quota percentages**
  over 24 hours. Claude uses its 5-hour window; Codex uses its primary weekly
  window. These are quota-state snapshots, not token counts or activity
  inferred between refreshes.
- **Vertex AI token usage** plots actual Cloud Monitoring token **sum totals**
  over the last 30 days in one-day buckets, on its own token axis. A visible
  zero line and explanatory status are shown when the provider reports no
  tokens in the window; zero usage is not treated as an error.

The quota x-axis is always the full 24-hour range. Only actual SQLite
measurements are plotted from the stored `used_percent` column: the app does
not synthesize, backfill, invert Remaining, or carry a value backward before
its first saved snapshot. Five-minute groups use the timestamp of their first
real measurement, so a newly created history database leaves the earlier part
of the chart blank. An idle primary window stored as 0% Used stays at zero; its
100% Remaining counterpart is never plotted as activity.

The Vertex chart is fetched from Cloud Monitoring and is not persisted in the
quota SQLite database. The two charts do not normalize or equate quota
percentages with token counts.

The Vertex chart and its summary are one full-width unified card: the summary
sits directly below the plot and shows only input tokens, output tokens, total
tokens, and the default 30-day estimated EUR list-price spend. It contains no
cache fields or cache-availability messages. The estimate is labeled as not an
invoice.

On every refresh, the app records locally available quota windows in:

```text
~/Library/Application Support/LimitDashboard/quota-history.sqlite3
```

The database stores only stable local slot IDs, metric IDs, timestamps, a
primary-metric flag, and Used/Remaining percentages. It does not store email
addresses, provider account IDs, tokens, credentials, plan labels, or raw
provider responses. Writes are upserted per account/metric/minute and retained
for 90 days.

History timestamps come from each provider observation, not from the dashboard
poll. Re-reading one unchanged local snapshot does not extend a flat line into
the future. When the app recognizes legacy poll-stamped rows newer than the
latest real source observation, it removes those invalid rows.

## Build from source

```sh
./build_app.sh
```

Requirements: macOS 14 or later and the Apple Swift/Xcode command-line tools.
For live Claude quota, the `curl_cffi` runtime from
`~/work/harvester-web-mcp/.venv/bin/python` must also exist. Set
`LIMIT_DASHBOARD_CURL_CFFI_PYTHON` to another Python executable when
`curl_cffi` is installed elsewhere.

## Credential and network behavior

- By default the app does not access the macOS Keychain and never triggers a
  Keychain prompt. Only `LIMIT_DASHBOARD_CLAUDE_API=1` changes that; see below.
- Claude identities and fallback usage snapshots come from each local account
  state file: `~/.claude.json`, `~/.claude2/.claude.json`, and
  `~/.claude3/.claude.json`.
- If the user's existing Claude Code status-line command has written a current
  snapshot under `/tmp/cc-rate-limits`, the app prefers its officially
  supported `rate_limits.five_hour` and `rate_limits.seven_day` values. A file
  is accepted only for the matching config slot and while its reset window is
  still active. A sample harvested within five minutes is **Live**; one up to
  an hour old is **Cached**. Older readings of a window that has not yet reset
  are shown as **Aged**, labelled with their exact source age and a note that
  usage may be higher — usage inside one reset window never decreases, so an
  old observation is a true lower bound rather than a wrong number. Values are
  withheld only when every window has reset, which the card reports as **Quota
  window has reset**. Within the same reset window, an older/lower observation
  can never reduce the selected Used percentage.
- A later rewrite of `.claude.json` is not treated as an account change on its
  own, because Claude rewrites that file constantly for unrelated reasons. The
  app rejects a sample only when the retained registry backups actually show a
  different account across the harvest instant. Those backups rotate, so an
  observation older than the oldest retained backup cannot be proven either
  way; it stays usable, and its age is stated on the card.
- Full account email addresses come from each file's
  `oauthAccount.emailAddress`, with the configured label used only if that
  field is absent. Tokens and other credential fields are never shown.
- Cached quota values are used only when the cache `accountUuid` matches the
  state file's `oauthAccount.accountUuid`. If a signed-in profile currently
  contains another account's cache, its card reports **Quota unavailable** and
  renders none of those borrowed values.
- Codex credentials are read from `~/.codex/auth.json`.
- With `LIMIT_DASHBOARD_CLAUDE_API=1`, every Claude card reads its account's
  Claude Code credential from the login Keychain and queries
  `https://claude.ai/api/oauth/usage`. The bundled helper reuses
  harvester-web-mcp's `curl_cffi` Chrome transport because a normal URLSession
  request receives Cloudflare's `cf-mitigated: challenge` response. The token
  crosses the local process boundary only on stdin and is never placed in
  arguments, environment variables, logs, or output.
- The helper has a fixed `https://claude.ai` destination, follows redirects
  manually only within that origin, limits the response size, and returns the
  provider body to the existing parser. A failed transport, rejected session,
  or changed response falls back to the identity-matched local status-line/cache
  snapshot rather than blanking the card.
- Without `LIMIT_DASHBOARD_CLAUDE_API=1`, Claude remains local-only: no Keychain
  read and no Anthropic request.
- Access tokens are kept in memory only. The app has no token logging,
  analytics, crash uploader, cookies, or persistent response cache.
- Requests go only to:
  - `https://chatgpt.com/backend-api/wham/usage` (Codex)
  - `https://claude.ai/api/oauth/usage` (Claude) — **only** when
    `LIMIT_DASHBOARD_CLAUDE_API=1`.
- The app never asks for passwords, directly refreshes tokens, rotates refresh
  tokens, overwrites credentials, or exports credentials. When an access token
  has expired it runs `CLAUDE_CONFIG_DIR=<account> claude auth status`, which
  performs no model call and lets Claude Code renew and persist its own session.

Claude cards query the provider at the selected interval when the feature flag
is enabled. They also refresh their non-Keychain fallback view, so an update to
a status-line snapshot or profile cache is picked up automatically. Claude Code
documents `rate_limits.*.used_percentage` as the consumed percentage from 0 to
100 and `resets_at` as Unix epoch seconds:
<https://code.claude.com/docs/en/statusline#rate-limit-usage>.

The refresh interval is a local **check** interval, not a promise that a
provider created new data. The footer therefore says **Checked**, source age is
evaluated independently of polling time, and an aged Claude percentage is never
presented as current — it is shown with its age instead. A window whose reset
has passed is dropped rather than displayed, as is a cached window that carries
no reset timestamp once its source file is no longer current.

Each Claude card also shows **Fable usage**, the model-specific weekly limit,
when the live response or fallback state-file cache contains this exact entry:

```text
cachedUsageUtilization.utilization.limits[]
  kind = "weekly_scoped"
  scope.model.display_name = "Fable"
  percent = used percentage
  resets_at = reset timestamp
```

The app does not substitute paid/Extra usage data or infer a Fable value. If
that exact entry is absent or has no numeric `percent`, it shows **Unavailable
in local cache**.

Each card's large headline is **Remaining**, consistently for Claude and Codex.
Every quota row also labels the provider's raw `utilization`/`percent` as
**Used** and calculates **Remaining** separately. Progress bars represent Used,
matching the provider's field.

Anthropic documents Fable as a model-specific allowance drawn from weekly plan
usage:
<https://support.claude.com/en/articles/15424964-claude-fable-5-on-your-plan>.
A current public Claude Code issue includes the corresponding cached payload
shape:
<https://github.com/anthropics/claude-code/issues/78507>.

## Supported historical-usage surfaces

Official provider documentation confirms these distinct supported paths:

- Codex has a supported local app-server JSON-RPC method,
  `account/usage/read`, for authenticated ChatGPT token-activity summaries and
  optional daily buckets. The Codex CLI also exposes `/usage daily`,
  `/usage weekly`, and `/usage cumulative`. ChatGPT workspace administrators
  have a separate Codex Analytics API; the OpenAI Platform Organization Usage
  API is for API traffic, not personal ChatGPT subscription history. See the
  official [Codex app-server](https://developers.openai.com/codex/app-server),
  [Codex CLI commands](https://developers.openai.com/codex/cli/slash-commands),
  and [Codex Analytics API](https://learn.chatgpt.com/docs/enterprise/analytics-api)
  documentation.
- Claude Code's supported `/usage` command shows session cost, plan limits, and
  activity statistics; its documented `~/.claude/stats-cache.json` contains
  the aggregated historical totals shown by that command. Anthropic also
  offers daily Claude Code Analytics APIs for organizations, using an Admin
  API key or an Enterprise Analytics API key. Anthropic explicitly says the
  organization analytics feature is unavailable to individual Pro or Max
  accounts, and documents no authenticated individual-subscription API for
  historical token buckets. See the official
  [Claude Code commands](https://code.claude.com/docs/en/commands),
  [local data layout](https://code.claude.com/docs/en/claude-directory),
  [Claude Code Analytics API](https://platform.claude.com/docs/en/manage-claude/claude-code-analytics-api),
  and [analytics availability](https://support.claude.com/en/articles/12157520-claude-code-usage-analytics)
  documentation.

This release does not integrate either provider's historical-usage surface; it
only implements the requested Vertex chart layout.

## Vertex AI reporting helpers

Both Python helpers use existing `gcloud` authentication, make read-only calls,
use only the standard library, and never print or cache an access token.

- `scripts/vertex_ai_report.py` reports Cloud Monitoring token **sum totals** in
  arbitrary chart buckets and estimates EUR list-price spend over an
  independently configurable summary window. It performs one Monitoring query
  for the union of the two windows, then aggregates both locally.
  Catalog-cache, embedded-price, and unknown-model fallbacks are labeled. This
  is an estimate, not an exact charge.
- `scripts/vertex_ai_spend.py` separately discovers an existing Cloud Billing
  BigQuery export and, when a matching table exists, reports exact exported
  gross cost, credits, and net spend. It parameterizes filters, dry-runs first,
  and enforces a 1 GiB query cap.

See [VERTEX_AI_SPEND.md](VERTEX_AI_SPEND.md) for usage and the current
validated results. Neither helper enables an API/export or changes cloud
settings.

The Monitoring `explicit_caching` label is displayed only as
**explicit-cache-served input**. It is not treated as a cache-hit rate.
Historical implicit cache hits remain unavailable unless request-level
`UsageMetadata.cachedContentTokenCount` was captured.
