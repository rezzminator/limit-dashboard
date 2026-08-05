# Decisions

One entry per irreversible or expensive-to-revisit decision. Newest first.

## 2026-08-05 — Attribution is by account identity, never by slot number

Statusline stdin carries no account identity (verified against Claude Code 2.1.222's binary, its docs, and a live capture), the config-dir↔account mapping is unstable across /login and swaps, and upstream bug anthropics/claude-code#68772 makes concurrently-harvested `rate_limits` untrustworthy across accounts. Therefore: harvest samples are stamped with the registry's `accountUuid` at write time and matched by that stamp; the per-account OAuth usage query (each account's own token, ≥180s cadence) is the primary source; the account list lives in `~/.config/limit-dashboard/accounts.json` (Vertex-loader pattern) with `enabled` flags. Full research record: `RR/dev-claude-auth-attribution-2026-08-05.md` (gitignored, local).

## 2026-08-05 — Fast RR runs on Sonnet with Haiku nested

RR research lanes must never inherit an expensive session model. "Fast RR" = a Sonnet research agent that fans out to Haiku for grunt lookups. Code-writing agents are Sonnet.
