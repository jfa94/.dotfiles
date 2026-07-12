# Claude Code → Codex CLI parity

Audited against `.claude/settings.json` and Codex 0.144.1. Status-line behavior and all Superpowers state/hooks are excluded.

## Mapping

| Claude behavior | Codex implementation | Parity |
|---|---|---|
| Read broadly | `workspace-net` filesystem `/ = read` | Exact |
| Write trusted repos/temp | Explicit dotfiles, Projects, workspace roots, `$TMPDIR`, `/tmp`, `/private/tmp`, `/var/tmp` writes | Exact |
| Protect credentials/secrets | Filesystem denies plus protected-files and pre-commit hooks | Approximate; filename patterns cannot identify every secret |
| Bash allowlist | `.codex/rules/default.rules` exact argv prefixes | Approximate; wildcard `git -C` and AWS verbs prompt |
| Web search | `web_search = "live"`; limited trusted-domain network profile | Exact for search; shell networking remains allowlisted |
| Default/high planning effort | Low normal reasoning, high Plan-mode override | Exact |
| Auto-compaction | `model_auto_compact_token_limit = 200000` | Approximate; Claude's five-minute window has no mapping |
| Fullscreen | `tui.alternate_screen = "always"` | Exact native equivalent |
| Unfocused notifications | Native TUI notifications with `notification_condition = "unfocused"` | Exact native equivalent |
| Shift/Ctrl+Enter newline | `tui.keymap.editor.insert_newline` | Exact |
| Config/protected file hooks | Codex PreToolUse scripts | Approximate; current workspace `.codex` uses native sandbox approval, cross-workspace writes deny |
| SQL read-only | Supabase `execute_sql` matcher plus SQL parser | Approximate parser; fail closed on recognized mutation forms |
| Compound/dangerous commands | Bash hooks plus exec-policy hard denies | Approximate; unified-exec hook interception is incomplete |
| npm → pnpm | `updatedInput` rewrite hook | Exact for recognized shell forms |
| Pre-commit secrets | Protected names, regex scan, required TruffleHog | Approximate scanner coverage; failures deny |
| Pre-push quality | Required pnpm quality or typecheck/lint/test/deps gates | Exact when project scripts opt in; failures deny |
| Semgrep | Changed-file scan with required valid scanner output | Approximate `.semgrepignore` handling; failures deny |
| Pre-PR mutation | Stryker gate for configured TypeScript projects | Approximate scope selection; fetch/tool failures deny |
| Post-edit Prettier | Project-local configured formatter | Exact for supported extensions; missing/failing formatter surfaces error |
| SessionStart startup | Dotfiles symlink-integrity warning | Intentional replacement for Claude model mutation |
| SessionStart compact | First/latest genuine rollout `event_msg.user_message`, capped with rollout pointer | Approximate; visible warning on unreadable/schema-changed rollouts |
| Read-once | Dormant | Exact: inactive in Claude |

## Intentional gaps

- No Codex model pin or startup model-lock mutation; static reasoning settings are authoritative.
- No Claude mobile-push semantics, automatic remote-control startup, away summaries, workflow-warning suppression, or five-minute compaction window.
- Dynamic Claude `ask` hooks use native sandbox/exec-policy prompts where expressible; unsupported dynamic cases deny with manual retry guidance.
- Status-line colors/items, model-availability NUX, plugins, and all Superpowers files/state remain untouched.
- Newline-containing filenames are an acknowledged limitation in changed-file scanner lists.

## Verification

Run:

```sh
jq empty .codex/hooks.json
shellcheck .codex/hooks/*.sh tests/codex-parity.sh
bash tests/codex-parity.sh
for test in tests/*.sh; do bash "$test"; done
codex execpolicy check --rules .codex/rules/default.rules '<command>'
codex --strict-config doctor
```

Fresh startup, resume, manual compaction, and automatic compaction at 200,000 tokens require interactive smoke testing. User config is authored at `.codex/user-config.toml` and linked to `~/.codex/config.toml` so Codex does not also load it as project-local config. The clean filter must preserve authored configuration above trailing `[hooks.state]` while stripping only trusted hashes.
