<!-- last-documented: 218f7894a260c3af7d0c777ecc645996f3fa9fd6 -->

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

Safety is enforced in layers rather than by instruction alone:

- **Permission rules**: Claude `settings.json` allow/ask/deny lists and Codex exec-policy rules.
- **PreToolUse hooks**: protected-file and applied-migration gates, read-only SQL checks, git
  bypass and force-push denies, pnpm enforcement, critical recursive-delete denies, and AWS
  secret protection.
- **Commit and push gates**: secret scanning before commits, plus project quality checks and
  Semgrep SAST before pushes.
- **Credential isolation**: 1Password references are injected per process and never sourced into
  the interactive shell.

The intended reader is the repository owner, or an agent working in this repository, who needs to
understand why a runtime behaves the way it does or how the two runtimes differ.

The repository also ships a TypeScript project scaffold (`ts/`), including an ESLint config that
enforces layer boundaries for frontend projects. It also includes review skills
(`/focused-code-review`, `/comprehensive-code-review`, and Codex `$code-review`) whose internals
are documented inside each skill directory under `.claude/skills/`.

For installation steps, see the root [README](../README.md).

## Contents

| Document                                             | Covers                                                                                                                           |
| ---------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| [agent-credentials.md](agent-credentials.md)         | 1Password-backed agent tokens, per-project `.agent-env`, MCP authentication, new-machine and rotation steps                      |
| [aws-agent-toolkit.md](aws-agent-toolkit.md)         | AWS Agent Toolkit guidance, account selection, and Codex AWS read access                                                         |
| [claude-auto-mode.md](claude-auto-mode.md)           | Troubleshooting Claude Auto-mode confirmation fallbacks and wrapped lint/test commands                                           |
| [cloud-environments.md](cloud-environments.md)       | Replicating the local Claude Code workflow, and loading project variables from 1Password, on claude.ai/code cloud VMs           |
| [codex-claude-parity.md](codex-claude-parity.md)     | Claude-to-Codex behavior mapping, hook gates, plugin inventory, code-review artifacts, intentional gaps, sandbox troubleshooting |

### Historical design records

These are point-in-time plans, specs, reviews, and test baselines. They are kept as records and
may not match the current code.

- [plans/2026-05-29-workflow-managed-code-review.md](superpowers/plans/2026-05-29-workflow-managed-code-review.md)
- [plans/2026-06-04-relational-database-design-skill.md](superpowers/plans/2026-06-04-relational-database-design-skill.md)
- [specs/2026-06-04-relational-database-design-skill-design.md](superpowers/specs/2026-06-04-relational-database-design-skill-design.md)
- [reviews/2026-06-04-relational-database-design-skill-review.md](superpowers/reviews/2026-06-04-relational-database-design-skill-review.md)
- [testing/2026-06-04-rdbd-baseline.md](superpowers/testing/2026-06-04-rdbd-baseline.md)
