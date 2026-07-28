# Limit Dashboard

A single-window native macOS dashboard for the three local Claude Code profiles
and the local Codex subscription on this Mac.

## Run

Double-click **Limit Dashboard.app**. It refreshes on launch, every 20 seconds
by default, and with `⌘R`.

The numeric **Every … sec** control changes automatic refresh immediately. The
value is clamped to 10–3600 seconds and retained across app launches.

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
  state file's `oauthAccount.accountUuid`. A stale cache from a switched
  account is reported honestly and its values are not rendered.
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

Every quota row labels both values explicitly: the provider's cached
`utilization`/`percent` is shown as **Used**, and **Remaining** is shown
separately. Progress bars represent Used, matching the provider's cached field.

Anthropic documents Fable as a model-specific allowance drawn from weekly plan
usage:
<https://support.claude.com/en/articles/15424964-claude-fable-5-on-your-plan>.
A current public Claude Code issue includes the corresponding cached payload
shape:
<https://github.com/anthropics/claude-code/issues/78507>.
