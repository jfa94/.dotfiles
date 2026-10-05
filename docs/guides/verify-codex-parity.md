# Verify Codex parity

Run every shell test separately and preserve its exit status; any failed script fails the suite. Past results are in [verification records](../reference/verification-records.md).

1. Run the static and policy checks from the repository root:

   ```sh
   jq empty .codex/user-hooks.json
   shellcheck .codex/hooks/*.sh tests/codex-parity.sh
   bash tests/codex-parity.sh
   for test in tests/*.sh; do bash "$test" || exit "$?"; done
   codex execpolicy check --rules .codex/rules/default.rules '<command>'
   codex --strict-config doctor
   bash .codex/plugin-doctor.sh
   ```

   The plugin doctor reports bundle, app dependency, OAuth, tool-discovery, and hook-validation layers separately so a missing connector is not misreported as a missing bundle.

2. Start fresh CLI and app sessions to load the new settings; existing sessions may retain previous settings.
3. Check Sol medium, Plan xhigh, catalog warnings, ordinary Git/test commands, and harmless automatic escalations. Exercise dangerous cases only through policy fixtures.
4. Smoke-test fresh startup, resume, manual compaction, and automatic compaction at 200,000 tokens interactively.
5. Fresh approval testing should verify automatic review, approve/decline paths on disposable `.env` and migration files, and harmless quoted diagnostics; do not smoke-test live force-pushes, publishing, Supabase mutations, or destructive deletion.

## Notes

- User config and user hooks are authored at `.codex/user-config.toml` and `.codex/user-hooks.json`, then linked to `~/.codex/config.toml` and `~/.codex/hooks.json`. Their non-discovered source names prevent Codex from also loading them as project-local configuration inside this repository.
- The seven parallel Bash policy handlers deliberately share the generic `Checking shell command policy` status so Codex can collapse their activity without claiming that a command-specific gate is running before each script self-filters.
- The clean filter must preserve authored configuration above trailing `[hooks.state]` while stripping only trusted hashes. Because the tracked file never contains `[hooks.state]`, restoring or checking out `.codex/user-config.toml` drops every hook-trust hash and the hooks need re-review via `/hooks`; fix drifted keys (`approvals_reviewer`, `default_permissions`) in place instead.
- To upgrade plugin marketplaces, see [Update Codex plugins](update-codex-plugins.md).
