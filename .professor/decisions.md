# Decisions

One entry per irreversible or expensive-to-revisit decision. Newest first.

## 2026-08-09 — A session is looked up by account, not by config directory

Extends the decision below one layer down. A config directory records where a
session was stored, not whose it is: the same account is signed in under
several at once, and Claude Code renews only the copy it uses, so a slot's own
directory can hold a cleared or expired item while a valid session for the
identical account is live elsewhere. When the slot's own directory holds
nothing usable, the app searches hidden directories two levels under the home
whose registry was written within 12 hours (newest first, at most six opened)
and accepts only ones recording the same `oauthAccount.accountUuid`. Bounds are
load-bearing: visible folders are never read (macOS privacy prompts) and the
freshness window is what keeps ~180 archived session directories from becoming
~180 Keychain reads per refresh.

## 2026-08-05 — Attribution is by account identity, never by slot number

Statusline stdin carries no account identity (verified against Claude Code 2.1.222's binary, its docs, and a live capture), the config-dir↔account mapping is unstable across /login and swaps, and upstream bug anthropics/claude-code#68772 makes concurrently-harvested `rate_limits` untrustworthy across accounts. Therefore: harvest samples are stamped with the registry's `accountUuid` at write time and matched by that stamp; the per-account OAuth usage query (each account's own token, ≥180s cadence) is the primary source; the account list lives in `~/.config/limit-dashboard/accounts.json` (Vertex-loader pattern) with `enabled` flags. Full research record: `RR/dev-claude-auth-attribution-2026-08-05.md` (gitignored, local).

## 2026-08-05 — Fast RR runs on Sonnet with Haiku nested

RR research lanes must never inherit an expensive session model. "Fast RR" = a Sonnet research agent that fans out to Haiku for grunt lookups. Code-writing agents are Sonnet.
