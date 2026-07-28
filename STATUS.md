# Limit Dashboard status

Snapshot verified on 2026-07-28 (Europe/Amsterdam).

## Account impact

| Account | Dashboard source | Result |
|---|---|---|
| Claude — `mrez9090@gmail.com` | `~/.claude.json` | **Cached**: 0% used / 100% remaining in the 5-hour window, 90% used / 10% remaining in the 7-day window, and 97% used / 3% remaining in the weekly Fable limit. The first card now renders correctly. |
| Claude — `reza.khosravivala@gmail.com` | `~/.claude2/.claude.json` | **Cached**: 10% used / 90% remaining in the 5-hour window, **73% used / 27% remaining in the 7-day window**, and 26% used / 74% remaining in the weekly Fable limit. |
| Claude — `reza@intuita.health` | `~/.claude3/.claude.json` | The account identity is locally readable, but its cached quota `accountUuid` belongs to the second account. The card shows the full email and a distinct **Stale cache** state instead of displaying the other account's stale 28% / 70% / 24% values. |
| Codex — `mrez9090@gmail.com` | `~/.codex/auth.json` plus the Codex usage endpoint | **Live**: 7% used / 93% remaining in the current weekly window during the latest render. |

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
- Swift tests: 10 executed, 9 passed and 1 opt-in live test skipped by default.
- Opt-in live Codex integration test: passed.
- App signature and `Info.plist`: passed.
- Binary linkage check: no Security framework.
- Source audit: no `SecItem`, `kSec`, Claude Keychain service, or Anthropic
  endpoint path.
- Window render: visually inspected with all four cards, full emails, cached
  and stale-cache states, the corrected first account, the second account at
  73% seven-day Used, the persisted 20-second control, Claude Fable usage, and
  live Codex state.

## Fable source research

- Anthropic documents Fable 5 as drawing from a plan's weekly usage and, for
  eligible plans, having a model-specific allowance:
  <https://support.claude.com/en/articles/15424964-claude-fable-5-on-your-plan>
- A current public issue in Anthropic's Claude Code repository shows the cached
  row labeled `Weekly · Fable` and the exact `weekly_scoped` payload fields:
  <https://github.com/anthropics/claude-code/issues/78507>
