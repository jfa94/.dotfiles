# Claude Code → Codex CLI parity

Audited against `.claude/settings.json`, `.claude/plugins.txt`, and the Codex plugin catalog in July 2026. Superpowers state is excluded; plugin availability is covered explicitly below.

## Mapping

| Claude behavior              | Codex implementation                                                                                         | Parity                                                                                            |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------- |
| Read broadly                 | `workspace-net` filesystem `/ = read`, including `.env*` under trusted workspaces                             | Exact for local context; subprocess environment inheritance remains filtered                      |
| Write trusted repos/temp     | Explicit dotfiles, Projects, workspace roots (including `.git`), `$TMPDIR`, `/tmp`, `/private/tmp`, `/var/tmp` writes | Exact                                                                                      |
| Protect credentials/secrets  | Filesystem denies plus protected-files and pre-commit hooks, except the explicitly readable AWS shared-credentials file; Linux recursive deny snapshots scan to depth 32 | Approximate; filename patterns cannot identify every secret |
| Bash allowlist               | `.codex/rules/default.rules` exact argv prefixes                                                             | Approximate; wildcard `git -C` prompts                                                            |
| AWS integration              | AWS `aws-core` plugin for knowledge/skills plus generated CLI read rules; Outsidey project config injects `AWS_PROFILE`; MCP API/script/presigned-URL tools denied | Broader guidance than legacy `aws-serverless`; authenticated resource access remains direct CLI-only |
| Web search                   | `web_search = "live"`; limited trusted-domain network profile                                                | Exact for search; shell networking remains allowlisted                                            |
| Default/high planning effort | Low normal reasoning, high Plan-mode override                                                                | Exact                                                                                             |
| Approval review              | `approval_policy = "on-request"` with `approvals_reviewer = "auto_review"`                                   | Escalations decided by a risk-based reviewer subagent instead of prompting the user                |
| Auto-compaction              | `model_auto_compact_token_limit = 200000`                                                                    | Approximate; Claude's five-minute window has no mapping                                           |
| Fullscreen                   | `tui.alternate_screen = "always"`                                                                            | Exact native equivalent                                                                           |
| Unfocused notifications      | Native TUI notifications with `notification_condition = "unfocused"`                                         | Exact native equivalent                                                                           |
| Status line                  | Native model, project, Git state, context, and usage-limit items                                              | Codex-native persisted selection                                                                  |
| Shift/Ctrl+Enter newline     | `tui.keymap.editor.insert_newline`                                                                           | Exact                                                                                             |
| Config/protected file hooks  | Codex PreToolUse scripts                                                                                     | Approximate; current workspace `.codex` uses native sandbox approval, cross-workspace writes deny |
| SQL read-only                | Supabase `execute_sql` matcher plus SQL parser                                                               | Approximate parser; fail closed on recognized mutation forms                                      |
| Compound/dangerous commands  | Bash hooks plus exec-policy hard denies                                                                      | Approximate; unified-exec hook interception is incomplete                                         |
| npm → pnpm                   | `updatedInput` rewrite hook                                                                                  | Exact for recognized shell forms                                                                  |
| Pre-commit secrets           | Protected names, regex scan, required TruffleHog                                                             | Approximate scanner coverage; failures deny                                                       |
| Pre-push quality             | Required pnpm quality or typecheck/lint/test/deps gates                                                      | Exact when project scripts opt in; failures deny                                                  |
| Semgrep                      | Changed-file scan with required valid scanner output                                                         | Approximate `.semgrepignore` handling; failures deny                                              |
| Pre-PR mutation              | Stryker gate for configured TypeScript projects                                                              | Approximate scope selection; fetch/tool failures deny                                             |
| Post-edit Prettier           | Project-local configured formatter                                                                           | Exact for supported extensions; missing/failing formatter surfaces error                          |
| SessionStart startup         | Dotfiles symlink-integrity warning                                                                           | Intentional replacement for Claude model mutation                                                 |
| SessionStart compact         | First/latest genuine rollout `event_msg.user_message`, capped with rollout pointer                           | Approximate; visible warning on unreadable/schema-changed rollouts                                |
| Read-once                    | Dormant                                                                                                      | Exact: inactive in Claude                                                                         |
| Code review                  | Codex-only `.codex/skills/code-review` router references Claude's canonical specialist prompts               | Equivalent reviewer roles; runtime orchestration differs                                          |

## Plugin inventory

Claude's inventory contains 19 plugins. Codex requirements intentionally include useful integrations that are disabled in Claude; enabled state is not treated as the only signal of importance.

| Claude plugin | Claude state | Codex decision | Classification |
| --- | --- | --- | --- |
| `typescript-lsp@claude-plugins-official` | Enabled | No plugin | Gap; use project-native type checking |
| `commit-commands@claude-plugins-official` | Enabled | No plugin | Gap; `gh` is not a commit-command replacement |
| `security-guidance@claude-plugins-official` | Enabled | Repository hooks plus `$code-review` | Approximate; dedicated Codex Security workflows are intentionally not installed |
| `claude-md-management@claude-plugins-official` | Enabled | No plugin | Gap |
| `playground@claude-plugins-official` | Enabled | No plugin | Gap; Visualize has different output semantics |
| `superpowers@claude-plugins-official` | Enabled | None | Intentionally not mirrored; native Plan mode and global instructions cover the workflow |
| `codex@openai-codex` | Enabled | None | Not applicable inside Codex |
| `factory@jfa94` | Enabled | No plugin | Gap; Claude-only packaging |
| `ponytail@ponytail` | Enabled | None | Intentionally not mirrored; global instructions already require minimal solutions |
| `agent-sdk-dev@claude-plugins-official` | Disabled | None | Intentionally not mirrored |
| `plugin-dev@claude-plugins-official` | Disabled | Built-in plugin/skill creation tools | Native workflow, not a required installed plugin |
| `frontend-design@claude-plugins-official` | Disabled | None | Intentionally not mirrored |
| `playwright@claude-plugins-official` | Disabled | None | Intentionally not mirrored |
| `supabase@claude-plugins-official` | Disabled | Project-native MCP | Outsidey uses a required, OAuth-authenticated, project-scoped, server-side read-only MCP; mutations remain CLI-only |
| `stripe@claude-plugins-official` | Disabled | `stripe@openai-curated` | Required but partial; not every Claude command, agent, or skill maps |
| `posthog@claude-plugins-official` | Disabled | `posthog@openai-curated` | Required direct integration; Outsidey reads allowed, writes ask |
| `figma@claude-plugins-official` | Disabled | None required | Intentionally disabled; install separately when needed |
| `web-designer@javier-plugins` | Enabled | `web-designer@javier-plugins` | Direct shared-skill parity; runtime-specific invocation syntax |
| `aws-core@agent-toolkit-for-aws` | Disabled | `aws-core@agent-toolkit-for-aws` | Required in Codex; official successor to legacy `aws-serverless` |

GitHub is deliberately CLI-only through `gh`; the local GitHub plugin is disabled and the account connector is not installed. Stripe and PostHog connector authentication remains interactive. Outsidey's native Supabase MCP uses OAuth stored in the OS keyring. PostHog must connect to Outsidey project `107700`, with writes configured to ask.

Codex keeps Browser, Computer Use, Sites, and Visualize globally available. Document, PDF, spreadsheet, presentation, and artifact-template plugins are intentionally omitted and can be installed when needed.

AWS setup registers `aws/agent-toolkit-for-aws`, installs `aws-core`, `uv`/`uvx`, and an official user-local AWS CLI version at least 2.35.0. It never edits AWS credentials or profiles. Codex permits AWS knowledge, documentation, skill, and region tools but repository hooks deny authenticated MCP `call_aws`, `run_script`, and presigned-URL operations.

## Code-review skills and artifacts

Claude retains `/focused-code-review` and `/comprehensive-code-review` under `.claude/skills/`. Codex exposes its own `$code-review` router from `.codex/skills/code-review`; this keeps the Codex interface out of Claude Code while avoiding copied reviewer prompts. Claude-owned agents, prompts, and verification assets remain canonical under `.claude/skills/comprehensive-code-review/` and the Codex router references them directly.

Both runtimes write each review to a unique directory:

```text
.code-review/runs/<UTC timestamp>-<profile>-<nonce>/
├── report.md
├── run.json
└── raw/
```

The shared directory is ignored by Git. Legacy `.comprehensive-code-review/` and `.focused-code-review/` ignore entries remain for historical artifacts; new runs must not use them.

## Intentional gaps

- AWS read auto-allow is scoped to actively used services (see `SERVICES` in `.codex/rules/generate-aws-read.sh`); Claude-allowed reads for other services prompt in Codex. `aws s3 cp s3://key -` also prompts — prefix rules cannot see the `-` destination that makes it a read. Codex hooks cannot express Claude's per-call "ask", so AWS writes prompt via the rules layer default rather than via hook.
- `.env*` reads are limited to trusted workspaces and remain protected from edits and commits. Exact Outsidey parity makes `~/.aws/credentials` readable to Codex; SSH material, private keys/certificates, `secrets/`, and Codex authentication remain unreadable.
- Hooks resolve their target directory from `tool_input.workdir` (`hook-lib.sh:project_dir`), falling back to the PreToolUse payload's session `cwd`. Codex instructs the model to always pass `workdir` per command and commonly starts sessions outside the project root, so the session `cwd` alone is stale for repo-scoped hooks (pre-commit, pre-push, Semgrep, prettier, protected-files, `.codex` dir checks).
- The pre-commit gate scans the index plus whatever this same command's own `git add` would stage (`git add --dry-run`), because PreToolUse fires before the command runs — otherwise `git add secret.pem && git commit` would scan an empty index. Unresolvable `git add` arguments (shell substitution, redirects) deny rather than skip the scan.
- The pre-commit gate's secret-path pattern (`SECRET_PATH_RE`) is hand-kept identical between `.codex/hooks/pre-commit-check.sh` and `.claude/hooks/pre-commit-check.sh` — no shared library on the Claude side — and pinned equal by `tests/codex-permissions-aws-mcp.sh`. `.env.example`/`.sample`/`.template` are exempted and committable by design, matching `protected-files-check.sh`'s write-side exemption.
- No Codex model pin or startup model-lock mutation; static reasoning settings are authoritative.
- No Claude mobile-push semantics, automatic remote-control startup, away summaries, workflow-warning suppression, or five-minute compaction window.
- Dynamic Claude `ask` hooks use native sandbox/exec-policy prompts where expressible; unsupported dynamic cases deny with manual retry guidance.
- Model-availability NUX and all Superpowers state remain untouched.
- Newline-containing filenames are an acknowledged limitation in changed-file scanner lists.
- Linux/WSL expands recursive filesystem deny globs to depth 32 before starting `bubblewrap`. Deeper matches are outside the shell-level snapshot, while raising the cap increases startup scanning work.

## Verification

Run:

```sh
jq empty .codex/hooks.json
shellcheck .codex/hooks/*.sh tests/codex-parity.sh
bash tests/codex-parity.sh
for test in tests/*.sh; do bash "$test"; done
codex execpolicy check --rules .codex/rules/default.rules '<command>'
codex --strict-config doctor
bash .codex/plugin-doctor.sh
```

Normal setup never upgrades existing plugin marketplaces. Use `bash .codex/update-plugins.sh` explicitly from outside an active Codex task; after it validates hook manifests and targets, restart Codex/ChatGPT and review changed hooks. The plugin doctor reports bundle, app dependency, OAuth, tool-discovery, and hook-validation layers separately so a missing connector is not misreported as a missing bundle.

Fresh startup, resume, manual compaction, and automatic compaction at 200,000 tokens require interactive smoke testing. User config is authored at `.codex/user-config.toml` and linked to `~/.codex/config.toml` so Codex does not also load it as project-local config. The clean filter must preserve authored configuration above trailing `[hooks.state]` while stripping only trusted hashes.
