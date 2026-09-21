# Dotfiles Repository Instructions

- `.claude/` is canonical for shared agents, skills, prompts, and supporting assets. Codex-specific routers must reference those resources rather than copy them.
- Do not weaken or incidentally rewrite protected-file, dangerous-command, SQL, commit, push, or quality controls.
- Direct commits to this repository's `main` branch are permitted. Force-push is prohibited.
- Run relevant shell tests for each change. Run the complete `tests/*.sh` suite for setup, hook, rule, or shared-skill architecture changes.

## Global instructions

- `instructions/AGENTS.md` is the canonical global instructions file linked to both `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`. Edit the canonical file, never through the runtime links. Stack guidance lives alongside it; `.claude/` remains canonical for shared agents, skills, prompts, and their supporting assets.

## Codex source naming

- `.codex/user-config.toml` and `.codex/user-hooks.json` are the canonical
  tracked user-level sources. Setup links them to the discovered runtime paths
  `~/.codex/config.toml` and `~/.codex/hooks.json`.
- Do not rename the tracked sources to `config.toml` or `hooks.json`: Codex
  would discover them project-locally in this repository as well as globally.
