# Limit Dashboard status

Snapshot verified on 2026-07-28 (Europe/Amsterdam).

## Account impact

| Account | Dashboard source | Result |
|---|---|---|
| Claude — `mrez9090@gmail.com` | `~/.claude/.claude.json` | No usage cache is present. The card is **Unavailable**, says **Keychain access not granted**, and reports **Extra usage unavailable in local cache**. |
| Claude — `reza@freudche.com` | `~/.claude2/.claude.json` | No usage cache is currently present. The card is **Unavailable**, says **Keychain access not granted**, and reports **Extra usage unavailable in local cache**. |
| Claude — `reza.khosravivala@gmail.com` | `~/.claude3/.claude.json` | **Cached**: 72% of the 5-hour window and 30% of the 7-day window remained in the latest inspected cache. **Extra usage: Not enabled.** |
| Codex — `mrez9090@gmail.com` | `~/.codex/auth.json` plus the Codex usage endpoint | **Live**: the app implementation successfully fetched the current weekly window. |

Claude cache availability can change as local provider sessions rotate. The
dashboard re-reads all three files on every selected interval and flags duplicate
provider account identifiers whenever multiple readable caches contain one.

## No-Keychain policy

- The app does not link the macOS Security framework.
- It contains no Keychain query code or Claude credential service names.
- It makes no Claude network requests.
- It never asks for a password.
- Claude cards read only non-Keychain `.claude.json` cache data.
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
- Swift tests: 6 executed, 5 passed and 1 opt-in live test skipped by default.
- Opt-in live Codex integration test: passed.
- App signature and `Info.plist`: passed.
- Binary linkage check: no Security framework.
- Source audit: no `SecItem`, `kSec`, Claude Keychain service, or Anthropic
  endpoint path.
- Window render: visually inspected with all four cards, full emails, cached
  and unavailable states, the persisted 20-second control, Claude Extra usage,
  and live Codex state.
