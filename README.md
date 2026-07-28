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

## Local history and Vertex chart

The top panel keeps two separate scales:

- The quota chart shows the last 24 hours of the primary Remaining value for
  all four stable account slots, with a different color for each series.
  Claude's primary series is its 5-hour window; Codex uses its primary weekly
  window. Points are read as five-minute SQLite averages.
- The Vertex chart shows token **sum totals** on a token scale, defaulting to
  the last 8 hours in 20-minute buckets. Alongside it, a separate default
  30-day summary shows input not marked explicit-cache, explicit-cache-served
  input when reported, output tokens, and estimated EUR list-price spend.
  The estimate is labeled as not an invoice.

On every refresh, the app records locally available quota windows in:

```text
~/Library/Application Support/LimitDashboard/quota-history.sqlite3
```

The database stores only stable local slot IDs, metric IDs, timestamps, a
primary-metric flag, and Used/Remaining percentages. It does not store email
addresses, provider account IDs, tokens, credentials, plan labels, or raw
provider responses. Writes are upserted per account/metric/minute and retained
for 90 days.

## Build from source

```sh
./build_app.sh
```

Requirements: macOS 14 or later and the Apple Swift/Xcode command-line tools.

## Credential and network behavior

- The app does not access macOS Keychain and never triggers a Keychain prompt.
- Claude cards read only the existing cached usage snapshots in each local
  account state file: `~/.claude.json`, `~/.claude2/.claude.json`, and
  `~/.claude3/.claude.json`.
- Full account email addresses come from each file's
  `oauthAccount.emailAddress`, with the configured label used only if that
  field is absent. Tokens and other credential fields are never shown.
- Cached quota values are used only when the cache `accountUuid` matches the
  state file's `oauthAccount.accountUuid`. If a signed-in profile currently
  contains another account's cache, its card reports **Quota unavailable** and
  renders none of those borrowed values.
- Codex credentials are read from `~/.codex/auth.json`.
- Access tokens are kept in memory only. The app has no token logging,
  analytics, crash uploader, cookies, or persistent response cache.
- The app makes no Claude network requests in cached-only mode.
- Codex requests go only to:
  - `https://chatgpt.com/backend-api/wham/usage`
- The app never asks for passwords and never refreshes, rotates, overwrites, or
  exports provider credentials.

Claude cards refresh their non-Keychain cache view at the selected interval. If
another trusted local process updates a profile cache, the dashboard picks up
the new snapshot automatically. Each Claude card also shows **Fable usage**, the
model-specific weekly limit, when its cache contains this exact entry:

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
