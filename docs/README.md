<!-- last-documented: 9863c41e2c05187887d42bb09fa28d52401e1d14 -->

# Dotfiles documentation

This repository is a personal workstation and coding-agent configuration. It provisions a macOS (or
cloud Linux) development machine — shell, editor, Homebrew packages, desktop apps — and, more
substantially, it is the single source of truth for how two coding agents, Claude Code and the
Codex CLI, are configured and constrained.

The problem it solves is keeping two agent runtimes consistent and safe without maintaining two
copies of everything. One global instruction file (`instructions/AGENTS.md`) is linked into both
runtimes. `.claude/` is canonical for shared agents, skills, prompts, and supporting assets. Codex
gets thin routers that point at those resources instead of copying them. `setup.sh` links
everything into place idempotently. `cloud-setup.sh` reproduces the same setup on
claude.ai/code cloud VMs.

Safety is enforced in layers rather than by instruction alone: permission rules, PreToolUse hooks,
commit and push gates, and credential isolation (see [architecture overview](architecture/overview.md#safety-layers)).

The intended reader is the repository owner, or an agent working in this repository, who needs to
understand why a runtime behaves the way it does or how the two runtimes differ.

The repository also ships a TypeScript project scaffold (`ts/`), including an ESLint config that
enforces layer boundaries for frontend projects. It also includes review skills
(`/focused-code-review`, `/comprehensive-code-review`, and Codex `$code-review`) whose internals
are documented inside each skill directory under `.claude/skills/`.

## Contents

### Tutorial

- [Getting started](getting-started.md) — provision a new machine with `setup.sh`

### Architecture

- [Overview](architecture/overview.md) — delivery paths, shared sources, safety layers

### How-to guides

| Guide                                                                          | Task                                                          |
| ------------------------------------------------------------------------------ | ------------------------------------------------------------- |
| [set-up-agent-credentials.md](guides/set-up-agent-credentials.md)              | New-machine 1Password, provider login, and credential checks  |
| [configure-project-credentials.md](guides/configure-project-credentials.md)    | Per-project `.agent-env` and `.envrc` selectors               |
| [rotate-agent-credential.md](guides/rotate-agent-credential.md)                | Rotate a 1Password-backed agent credential                    |
| [configure-project-aws-account.md](guides/configure-project-aws-account.md)    | Select and verify a project's AWS account in both runtimes    |
| [set-up-cloud-environment.md](guides/set-up-cloud-environment.md)              | claude.ai/code environment shim, inputs, network, checklist   |
| [maintain-cloud-setup.md](guides/maintain-cloud-setup.md)                      | Sync with `setup.sh`, force rebuilds, bump the 1Password SDK  |
| [update-codex-plugins.md](guides/update-codex-plugins.md)                      | Upgrade Codex plugin marketplaces safely                      |
| [verify-codex-parity.md](guides/verify-codex-parity.md)                        | Run parity checks and rollout smoke tests                     |
| [troubleshoot-codex-sandbox.md](guides/troubleshoot-codex-sandbox.md)          | Network, pnpm, and Chromium failures under the Codex sandbox  |
| [troubleshoot-claude-auto-mode.md](guides/troubleshoot-claude-auto-mode.md)    | Auto-mode confirmation prompts and reliable validation runs   |
| [migrate-app-to-homebrew-cask.md](guides/migrate-app-to-homebrew-cask.md)      | Move an existing app under cask ownership                     |
| [replace-duplicate-cli-install.md](guides/replace-duplicate-cli-install.md)    | Remove a Homebrew/npm Claude Code or Codex install            |

### Reference

| Document                                                             | Covers                                                                                                                           |
| -------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| [setup.md](reference/setup.md)                                       | `setup.sh` behavior, conflicts, exit status, shell startup, skill links, CLI ownership, Linux                                   |
| [agent-credentials.md](reference/agent-credentials.md)               | Runner, Keychain cache, `op-read-locked`, env-file format, Stripe, PostHog, Supabase                                            |
| [aws-agent-toolkit.md](reference/aws-agent-toolkit.md)               | AWS Agent Toolkit plugins, installs, setup boundaries, Codex AWS read access, Outsidey identity                                 |
| [cloud-environments.md](reference/cloud-environments.md)             | Cloud VM behavior, platform facts, 1Password project variables, non-replicated features                                         |
| [codex-claude-parity.md](reference/codex-claude-parity.md)           | Claude-to-Codex behavior mapping, plugin inventory, browser automation, code-review artifacts, intentional gaps                 |
| [verification-records.md](reference/verification-records.md)         | Past parity verification results                                                                                                 |

### Explanation

- [Instruction sources](explanation/instruction-sources.md) — one instruction file, two runtimes
- [Shared skills](explanation/shared-skills.md) — why skills are linked per directory and what is not shared
- [Package ownership](explanation/package-ownership.md) — selective Brewfile, vendor-owned agent CLIs
- [Codex permission and catalog corrections](explanation/codex-permission-corrections.md) — September 2026 changes and rationale
- [Claude Auto-mode denials](explanation/claude-auto-mode-denials.md) — classifier fallback investigation and masked validation failures

### Historical design records

These are point-in-time plans, specs, reviews, and test baselines. They are kept as records and
may not match the current code.

- [plans/2026-05-29-workflow-managed-code-review.md](superpowers/plans/2026-05-29-workflow-managed-code-review.md)
- [plans/2026-06-04-relational-database-design-skill.md](superpowers/plans/2026-06-04-relational-database-design-skill.md)
- [specs/2026-06-04-relational-database-design-skill-design.md](superpowers/specs/2026-06-04-relational-database-design-skill-design.md)
- [reviews/2026-06-04-relational-database-design-skill-review.md](superpowers/reviews/2026-06-04-relational-database-design-skill-review.md)
- [testing/2026-06-04-rdbd-baseline.md](superpowers/testing/2026-06-04-rdbd-baseline.md)
