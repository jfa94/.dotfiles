# Verification records

Point-in-time results of the [Codex parity verification](../guides/verify-codex-parity.md). Later changes may not be reflected.

## Instruction consolidation (2026-09-21)

Instruction consolidation verified September 21, 2026: all 28 shell test scripts
passed. The credential test required unsandboxed access to its disposable macOS
keychain. Both live global links resolve to `instructions/AGENTS.md`, and the
startup integrity check emits no warning. Fresh no-tool Claude sessions loaded
global and project rules in dotfiles, goodbyespy, and Outsidey; fresh no-tool
Codex sessions loaded the expected rules in dotfiles and goodbyespy, including
tool-specific delegation/AWS routing and the native review skill. The moved
frontend/backend files are unchanged. ShellCheck passes for the cloud setup and
changed tests; local setup/startup retain their pre-existing SC2329/SC1091
diagnostics. Existing sessions need restarting to load the new instructions.

## Codex permission and catalog corrections (September 2026)

September 2026 verification: all 26 `tests/*.sh` scripts passed, including 1,274 native policy/hook parity checks. Generator fixtures cover exact matching, discovery failures, malformed help, unmatched allowances, and policy-validation failures with output preservation. Startup fixtures cover correct settings, reviewer/profile drift, and missing/dangling links. Relevant ShellCheck checks pass with existing SC1091/SC2015/SC2016 diagnostics excluded.

Codex Doctor 0.153.4 loaded strict configuration with zero failures; macOS security inspection remained unavailable. Fresh CLI session metadata confirmed Sol medium, `on-request`, and `auto_review`; Git status, startup tests, and an automatically approved escalated `/usr/bin/true` succeeded. The app-bundled runtime (0.150.0-alpha.12.2) also passed fresh Git status and escalated `/usr/bin/true` checks. Sol prompt rendering exposed all 54 skills in both runtimes without a truncation warning. Plan xhigh is configuration-tested; an interactive Plan toggle and app UI restart remain rollout checks.

## Coverage locations

Instruction migration checks are in `tests/agent-instructions.sh`, cloud link
checks in `tests/cloud-setup.sh`, and startup link checks in
`tests/codex-startup.sh`. They cover migrations, custom conflicts, prompt choices,
missing sources, repeat setup, and owned-link cleanup. Run every shell test
separately and preserve its exit status; any failed script fails the suite.
