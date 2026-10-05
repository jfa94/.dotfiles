# Troubleshoot the Codex sandbox profile

## Network or `.git` writes fail

Symptoms: `could not resolve host: github.com`, `gh` cannot reach `api.github.com`, or `.git` refuses writes. Claude WebFetch domain allowlists do not control Codex shell networking; first suspect that the session's `workspace-net` permission profile was replaced rather than a DNS or allowlist failure.

Changing approval or permission mode from the TUI mode picker replaces the custom profile with a built-in preset that disables network access and makes `.git` read-only.

1. Confirm the diagnosis:

   ```sh
   sqlite3 ~/.codex/state_5.sqlite "select id,cwd,substr(sandbox_policy,1,80) from threads order by updated_at desc limit 5;"
   ```

   `special/root` indicates the downgraded built-in profile; `path:"/"` indicates the expected `workspace-net` profile.

2. The picker cannot restore `workspace-net`; start a new session instead of repeatedly escalating commands.

## pnpm reports `unable to open database file`

pnpm keeps its content-addressable store and dlx cache outside the workspace, so a project with a `packageManager` pin fails with `[ERROR] unable to open database file` when the profile lacks its pnpm write grants (or was replaced by a TUI preset). Restore the grants; do not shim Corepack — its cache is equally unwritable.

## Chromium or Electron commands die at launch

Codex's embedded macOS seatbelt policy is `(deny default)` with no `mach-register` grant, so any Chromium- or Electron-based command (Playwright, Puppeteer, the bundled `browser`/`computer-use` plugins) dies at launch:

```
FATAL:base/apple/mach_port_rendezvous_mac.cc:159] Check failed: kr == KERN_SUCCESS.
bootstrap_check_in org.chromium.Chromium.MachPortRendezvousServer.<pid>: Permission denied (1100)
```

There is no user-extensible seatbelt hook to add the missing rule (openai/codex#24742 is open, unimplemented), so the only fix is to run the command with `sandbox_permissions="require_escalated"`, which drops the seatbelt entirely. Escalation only works when the active permission profile has zero `= "deny"` filesystem entries — a single deny-read entry makes Codex silently keep the command sandboxed instead of honoring escalation, with no warning surfaced. `workspace-net` is kept deny-free for exactly this reason; reintroducing a deny entry breaks escalation for every command, not just browsers.
