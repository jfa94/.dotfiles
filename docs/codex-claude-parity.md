# Claude Code → Codex CLI parity

Audited against `.claude/settings.json`, `.claude/plugins.txt`, and the Codex plugin catalog in July 2026. Superpowers state is excluded; plugin availability is covered explicitly below.

## Mapping

| Claude behavior              | Codex implementation                                                                                                                                                                           | Parity                                                                                               |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Read broadly                 | `workspace-net` filesystem `/ = read`, including `.env*` under trusted workspaces                                                                                                              | Exact for local context; subprocess environment inheritance remains filtered                         |
| Write trusted repos/temp     | Explicit dotfiles, Projects, workspace roots (including `.git`), `$TMPDIR`, `/tmp`, `/private/tmp`, `/var/tmp` writes                                                                          | Exact                                                                                                |
| Protect credentials/secrets  | Current-turn confirmation for edits plus the pre-commit hook; no filesystem read-denies, since any deny entry silently keeps `require_escalated` sandboxed                                             | Approximate; reads are unrestricted and edit authorization is conversational                         |
| Bash allowlist               | `.codex/rules/default.rules` exact argv prefixes                                                                                                                                               | Approximate; wildcard `git -C` prompts                                                               |
| AWS integration              | AWS `aws-core` plugin for knowledge/skills plus generated CLI read rules; Outsidey project config injects `AWS_PROFILE`; MCP API/script/presigned-URL tools denied                             | Broader guidance than legacy `aws-serverless`; authenticated resource access remains direct CLI-only |
| Web search                   | `web_search = "live"`; limited trusted-domain network profile                                                                                                                                  | Exact for search; shell networking remains allowlisted                                               |
| Default/high planning effort | Low normal reasoning, high Plan-mode override                                                                                                                                                  | Exact                                                                                                |
| Approval review              | `approval_policy = "on-request"` with `approvals_reviewer = "user"`                                                                                                                            | Eligible escalations are shown to the user                                                           |
| Auto-compaction              | `model_auto_compact_token_limit = 200000`                                                                                                                                                      | Approximate; Claude's five-minute window has no mapping                                              |
| Fullscreen                   | `tui.alternate_screen = "always"`                                                                                                                                                              | Exact native equivalent                                                                              |
| Unfocused notifications      | Native TUI notifications with `notification_condition = "unfocused"`                                                                                                                           | Exact native equivalent                                                                              |
| Status line                  | Native model, project, Git state, context, and usage-limit items                                                                                                                               | Codex-native persisted selection                                                                     |
| Shift/Ctrl+Enter newline     | `tui.keymap.editor.insert_newline`                                                                                                                                                             | Exact                                                                                                |
| Protected-file edits         | Current-turn conversational confirmation                                                                                                                                                       | Codex hooks cannot originate Claude's `ask` decision                                                 |
| SQL/Supabase                 | Project-scoped `read_only=true` MCP; confirmed mutations use `agent-env-run` with the Supabase CLI                                                                                              | MCP cannot mutate; the CLI route remains explicit                                                    |
| Compound/dangerous commands  | Conversational confirmation plus narrow exec-policy prompts; only literal critical recursive-force deletion is hook-denied                                                                     | Approximate; prefix rules cannot represent every shell shape                                         |
| npm → pnpm                   | `updatedInput` rewrite hook                                                                                                                                                                    | Exact for recognized shell forms                                                                     |
| Pre-commit secrets           | Protected names, regex scan, required TruffleHog                                                                                                                                               | Approximate scanner coverage; failures deny                                                          |
| Pre-push quality             | Required pnpm quality or typecheck/lint/test/deps gates                                                                                                                                        | Exact when project scripts opt in; failures deny                                                     |
| Semgrep                      | Changed-file scan with required valid scanner output                                                                                                                                           | Approximate `.semgrepignore` handling; failures deny                                                 |
| Post-edit Prettier           | Project-local configured formatter                                                                                                                                                             | Exact for supported extensions; missing/failing formatter surfaces error                             |
| SessionStart startup         | Dotfiles symlink-integrity warning                                                                                                                                                             | Intentional replacement for Claude model mutation                                                    |
| SessionStart compact         | First/latest genuine rollout `event_msg.user_message`, capped with rollout pointer                                                                                                             | Approximate; visible warning on unreadable/schema-changed rollouts                                   |
| Read-once                    | Dormant                                                                                                                                                                                        | Exact: inactive in Claude                                                                            |
| Code review                  | Codex-only `.codex/skills/code-review` router references Claude's canonical specialist prompts                                                                                                 | Equivalent reviewer roles; runtime orchestration differs                                             |

## Plugin inventory

Claude's inventory contains 19 plugins. Codex requirements intentionally include useful integrations that are disabled in Claude; enabled state is not treated as the only signal of importance.

| Claude plugin                                  | Claude state | Codex decision                       | Classification                                                                                                                                                                                                                                                                                             |
| ---------------------------------------------- | ------------ | ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `typescript-lsp@claude-plugins-official`       | Enabled      | No plugin                            | Gap; use project-native type checking                                                                                                                                                                                                                                                                      |
| `commit-commands@claude-plugins-official`      | Enabled      | No plugin                            | Gap; `gh` is not a commit-command replacement                                                                                                                                                                                                                                                              |
| `security-guidance@claude-plugins-official`    | Enabled      | Repository hooks plus `$code-review` | Approximate; dedicated Codex Security workflows are intentionally not installed                                                                                                                                                                                                                            |
| `claude-md-management@claude-plugins-official` | Enabled      | No plugin                            | Gap                                                                                                                                                                                                                                                                                                        |
| `playground@claude-plugins-official`           | Enabled      | No plugin                            | Gap; Visualize has different output semantics                                                                                                                                                                                                                                                              |
| `superpowers@claude-plugins-official`          | Enabled      | None                                 | Intentionally not mirrored; native Plan mode and global instructions cover the workflow                                                                                                                                                                                                                    |
| `codex@openai-codex`                           | Enabled      | None                                 | Not applicable inside Codex                                                                                                                                                                                                                                                                                |
| `factory@jfa94`                                | Enabled      | No plugin                            | Gap; Claude-only packaging                                                                                                                                                                                                                                                                                 |
| `ponytail@ponytail`                            | Enabled      | None                                 | Intentionally not mirrored; global instructions already require minimal solutions                                                                                                                                                                                                                          |
| `agent-sdk-dev@claude-plugins-official`        | Disabled     | None                                 | Intentionally not mirrored                                                                                                                                                                                                                                                                                 |
| `plugin-dev@claude-plugins-official`           | Disabled     | Built-in plugin/skill creation tools | Native workflow, not a required installed plugin                                                                                                                                                                                                                                                           |
| `frontend-design@claude-plugins-official`      | Disabled     | None                                 | Intentionally not mirrored                                                                                                                                                                                                                                                                                 |
| `playwright@claude-plugins-official`           | Disabled     | None                                 | Intentionally not mirrored                                                                                                                                                                                                                                                                                 |
| `supabase@claude-plugins-official`             | Disabled     | Project-native MCP                   | Outsidey uses optional bearer auth with project scoping and server-side read-only mode                                                                                                                                                                                                                     |
| `stripe@claude-plugins-official`               | Disabled     | Project-native MCP                   | Outsidey uses a restricted read-oriented key plus a Codex tool allowlist                                                                                                                                                                                                                                   |
| `posthog@claude-plugins-official`              | Disabled     | Project-native MCP                   | Single `posthog` server, full catalogue, silently allowed; safety is the PostHog API key's own scopes, not a permission split; the plugin's 25 `mcp__plugin_posthog_posthog__*` allow entries were removed as dead config — the plugin is disabled and CLI mode no longer exposes those per-tool names anyway |
| `figma@claude-plugins-official`                | Disabled     | None required                        | Intentionally disabled; install separately when needed                                                                                                                                                                                                                                                     |
| `web-designer@javier-plugins`                  | Enabled      | `web-designer@javier-plugins`        | Direct shared-skill parity; runtime-specific invocation syntax                                                                                                                                                                                                                                             |
| `aws-core@agent-toolkit-for-aws`               | Disabled     | `aws-core@agent-toolkit-for-aws`     | Required in Codex; official successor to legacy `aws-serverless`                                                                                                                                                                                                                                           |

GitHub is deliberately CLI-only through `gh`; the local GitHub plugin is disabled and the account connector is not installed. Outsidey's project-native MCP servers receive process-scoped bearer variables from 1Password in Codex. Outsidey pins project 107700 in its PostHog MCP URLs and CLI environment. Claude resolves fixed 1Password references through `headersHelper`. Supabase and Stripe are non-required, project-scoped where supported, and read-only at the server, token, or tool-list layer. PostHog is a single server (`posthog`) exposing its full `exec` catalogue on one project-scoped credential — no `readonly` URL param, no second write server or `permissions.ask` entry. Safety relies entirely on the PostHog API key's own scopes; both Claude and Codex allow every `posthog` call silently — Claude additionally carries a `PreToolUse` hook (`posthog-plan-allow.sh`) so plan mode's own no-annotations-means-prompt fallback doesn't override the allow rule.

Codex keeps Browser, Chrome, Computer Use, Sites, Visualize, Documents, PDF, Spreadsheets, Presentations, and artifact-template capabilities globally available. The desktop-managed `codex-app-tools` bundle is also enabled; app-managed marketplace sources remain tracked in the user configuration.

AWS setup registers `aws/agent-toolkit-for-aws`, installs `aws-core`, `uv`/`uvx`, and an official user-local AWS CLI version at least 2.35.0. It never edits AWS credentials or profiles. Codex permits AWS knowledge, documentation, skill, and region tools but repository hooks deny authenticated MCP `call_aws`, `run_script`, and presigned-URL operations.

## Code-review skills and artifacts

Claude retains `/focused-code-review` and `/comprehensive-code-review` under `.claude/skills/`. Codex exposes its own `$code-review` router from `.codex/skills/code-review`; this keeps the Codex interface out of Claude Code while avoiding copied reviewer prompts. Claude-owned agents, prompts, and verification assets remain canonical under `.claude/skills/comprehensive-code-review/` and the Codex router references them directly.

Both sides link skills per directory rather than per file. `setup.sh` links each `.claude/skills/<name>/` directory containing a `SKILL.md` to `~/.claude/skills/<name>`, and `~/.agents/skills` already worked this way for Codex. Supporting assets a skill gains later — reviewer profiles, prompts, verification scripts — are visible to both runtimes immediately, so a Codex `$code-review` run cannot see a partially linked Claude skill.

Both runtimes use the same intent classification contract. Proven defects remain findings,
documented intended behavior is refuted, and concrete undocumented intent choices become independent
Open Questions. Each prompt receives the same prioritized path-only documentation manifest. The
shared verifier applies user-only `by-design` / `intent-confirmed` rulings, keeps questions out of
dedup and verdict math, and emits the same report section and disposition commands. Claude also runs
the external Codex adversarial track and verifies all structured severities; native Codex omits
recursive self-review but otherwise uses the same vote thresholds and verifier.

Both runtimes write each review to a unique directory:

```text
.code-review/runs/<UTC timestamp>-<profile>-<nonce>/
├── report.md
├── run.json
└── raw/
```

Both runtimes gather scope and materialize large launch inputs beneath `raw/inputs/` through the
same deterministic preflight (`scripts/review-preflight.mjs`; Codex passes `--runtime codex`) and
pass only absolute artifact and canonical charter paths to reviewer agents. Claude's single
Workflow call is capped at 8 KiB and is auto-approved only by the active review skill after
validating the bundled workflow, roster, current-run paths, and Codex launcher, plus deep-equality
against the preflight's recorded `launch-args.json`; a review-shaped launch (preflight `runId`)
that names anything other than the bundled script, or inlines it, is denied. There is no global
`Workflow` permission rule, but the Workflow tool gates `scriptPath` by Read path-permission on
the literal path and its realpath, so `settings.json` carries `Read(//…/.claude/skills/**)` and
`Read(//…/.dotfiles/.claude/skills/**)`; without them the launch fails outside `~/.dotfiles` in
every mode except bypass. Neither runtime reads charter bodies into the main agent: spawned reviewers read their own
charter from disk first, and charter bodies are never duplicated in spawned task text.

The shared directory is ignored by Git. Legacy `.comprehensive-code-review/` and `.focused-code-review/` ignore entries remain for historical artifacts; new runs must not use them.

## Intentional gaps

- Codex treats current-turn conversational confirmation as authoritative for editing `.env*`, credentials, private keys, `secrets/`, or existing/applied migrations; destructive/unbounded/schema-changing SQL and remote Supabase mutations; force-push and leading `+` refspecs; commit-safeguard bypasses; package publishing; recursive-force deletion; `chmod 777`; and downloaded-content-to-shell pipelines. Native prompt rules supplement this for exact argv prefixes and can produce a second UI prompt. Hooks cannot originate an approval prompt, and `PermissionRequest` only observes a prompt Codex already chose to show.
- AWS read auto-allow is scoped to actively used services (see `SERVICES` in `.codex/rules/generate-aws-read.sh`); Claude-allowed reads for other services prompt in Codex. `aws s3 cp s3://key -` also prompts — prefix rules cannot see the `-` destination that makes it a read. Codex hooks cannot express Claude's per-call "ask", so AWS writes prompt via the rules layer default rather than via hook.
- `.env*` reads are limited to trusted workspaces and require confirmation before edits or commits. Exact Outsidey parity makes `~/.aws/credentials` readable to Codex. SSH material, private keys/certificates, `secrets/`, and Codex authentication are also readable — filesystem read-denies were removed because any deny entry silently keeps `require_escalated` commands sandboxed (see Sandbox-profile troubleshooting). The pre-commit hook remains a conditional hard failure when staged content is sensitive.
- Hooks resolve their target directory from `tool_input.workdir` (`hook-lib.sh:project_dir`), falling back to the PreToolUse payload's session `cwd`. Codex instructs the model to always pass `workdir` per command and commonly starts sessions outside the project root, so the session `cwd` alone is stale for repo-scoped hooks (pre-commit, pre-push, Semgrep, prettier, `.codex` dir checks).
- The pre-commit gate scans the index plus whatever this same command's own `git add` would stage (`git add --dry-run`), because PreToolUse fires before the command runs — otherwise `git add secret.pem && git commit` would scan an empty index. Unresolvable `git add` arguments (shell substitution, redirects) deny rather than skip the scan.
- The pre-commit gate's secret-path pattern (`SECRET_PATH_RE`) is hand-kept identical between `.codex/hooks/pre-commit-check.sh` and `.claude/hooks/pre-commit-check.sh` — no shared library on the Claude side — and pinned equal by `tests/codex-permissions-aws-mcp.sh`. `.env.example`/`.sample`/`.template` remain exempted and committable by design.
- `critical-rm-check.sh` has one unconditional denial: an actual `rm` or direct `sudo rm` invocation with both recursive and force flags and a literal critical target. Static command and option words are recognized through syntactic quotes and backslashes without evaluation; expansion-bearing option words remain ambiguous. It blocks `/`, the exact home root, system-owned trees, and `/Users` outside the current home. Home descendants and temporary roots/subpaths are confirmable exceptions. It resolves parent components physically without following a plain final symlink, but literal trailing `/` and `/.` spellings follow that final component as `rm` does. Repository roots, sibling projects, non-system paths, and ambiguous expansions pass to conversational confirmation. Malformed input and internal parsing, dependency, serialization, or candidate-target resolution failures deny with fixed JSON. Quoted diagnostics and search arguments are not invocations.
- Conditional safeguards remain separate from promptable actions: pre-commit secret scanning and sensitive-path checks, pre-push quality gates, Semgrep, AWS secret-value protection, and AWS MCP routing can still deny until their reported condition is remediated.
- Supabase MCP URLs remain project-scoped with `read_only=true`. Approved mutations use `agent-env-run` and the Supabase CLI after explicit current-turn confirmation; Codex has no writable Supabase MCP path.
- No Codex model pin or startup model-lock mutation; static reasoning settings are authoritative.
- No Claude mobile-push semantics, automatic remote-control startup, away summaries, workflow-warning suppression, or five-minute compaction window.
- Dynamic Claude `ask` hooks use native sandbox/exec-policy prompts where expressible; unsupported Codex shapes use the conversational confirmation gate.
- Model-availability NUX and all Superpowers state remain untouched.
- Newline-containing filenames are an acknowledged limitation in changed-file scanner lists.

## Sandbox-profile troubleshooting

Claude WebFetch domain allowlists do not control Codex shell networking. If a session reports `could not resolve host: github.com`, `gh` cannot reach `api.github.com`, or `.git` refuses writes, first suspect that its `workspace-net` permission profile was replaced rather than a DNS or allowlist failure.

Changing approval or permission mode from the TUI mode picker replaces the custom profile with a built-in preset that disables network access and makes `.git` read-only. The picker cannot restore `workspace-net`; start a new session instead of repeatedly escalating commands.

Confirm the diagnosis with:

```sh
sqlite3 ~/.codex/state_5.sqlite "select id,cwd,substr(sandbox_policy,1,80) from threads order by updated_at desc limit 5;"
```

`special/root` indicates the downgraded built-in profile; `path:"/"` indicates the expected `workspace-net` profile.

Codex's embedded macOS seatbelt policy is `(deny default)` with no `mach-register` grant, so any Chromium- or Electron-based command (Playwright, Puppeteer, the bundled `browser`/`computer-use` plugins) dies at launch:

```
FATAL:base/apple/mach_port_rendezvous_mac.cc:159] Check failed: kr == KERN_SUCCESS.
bootstrap_check_in org.chromium.Chromium.MachPortRendezvousServer.<pid>: Permission denied (1100)
```

There is no user-extensible seatbelt hook to add the missing rule (openai/codex#24742 is open, unimplemented), so the only fix is to run the command with `sandbox_permissions="require_escalated"`, which drops the seatbelt entirely. Escalation only works when the active permission profile has zero `= "deny"` filesystem entries — a single deny-read entry makes Codex silently keep the command sandboxed instead of honoring escalation, with no warning surfaced. `workspace-net` is kept deny-free for exactly this reason; reintroducing a deny entry breaks escalation for every command, not just browsers.

## Verification

Run:

```sh
jq empty .codex/user-hooks.json
shellcheck .codex/hooks/*.sh tests/codex-parity.sh
bash tests/codex-parity.sh
for test in tests/*.sh; do bash "$test"; done
codex execpolicy check --rules .codex/rules/default.rules '<command>'
codex --strict-config doctor
bash .codex/plugin-doctor.sh
```

Normal setup never upgrades existing plugin marketplaces. Use `bash .codex/update-plugins.sh` explicitly from outside an active Codex task; after it validates hook manifests and targets, restart Codex/ChatGPT and review changed hooks. The plugin doctor reports bundle, app dependency, OAuth, tool-discovery, and hook-validation layers separately so a missing connector is not misreported as a missing bundle.

Fresh startup, resume, manual compaction, and automatic compaction at 200,000 tokens require interactive smoke testing. User config and user hooks are authored at `.codex/user-config.toml` and `.codex/user-hooks.json`, then linked to `~/.codex/config.toml` and `~/.codex/hooks.json`. Their non-discovered source names prevent Codex from also loading them as project-local configuration inside this repository. The seven parallel Bash policy handlers deliberately share the generic `Checking shell command policy` status so Codex can collapse their activity without claiming that a command-specific gate is running before each script self-filters. Fresh approval testing should verify the user reviewer, approve/decline paths on disposable `.env` and migration files, and harmless quoted diagnostics; do not smoke-test live force-pushes, publishing, Supabase mutations, or destructive deletion. The clean filter must preserve authored configuration above trailing `[hooks.state]` while stripping only trusted hashes.
