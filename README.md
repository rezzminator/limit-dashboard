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
  profile's `.claude.json`. They are always labeled `Cached`; a profile without
  a cache is labeled `Keychain access not granted`.
- Full account email addresses are shown as local identity labels. Tokens and
  other credential fields are never shown.
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
the new snapshot automatically. Each Claude card also shows **Extra usage** from
cached paid-usage metadata. If the cache says it is disabled or omits a value,
the app reports that state instead of inventing a number. Unavailable sessions
remain visible without asking for a password.
