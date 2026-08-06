# Dotfiles Repository Instructions

- `.claude/` is canonical for shared agents, skills, prompts, and supporting assets. Codex-specific routers must reference those resources rather than copy them.
- Do not weaken or incidentally rewrite protected-file, dangerous-command, SQL, commit, push, or quality controls.
- Direct commits to this repository's `main` branch are permitted. Force-push is prohibited.
- Run relevant shell tests for each change. Run the complete `tests/*.sh` suite for setup, hook, rule, or shared-skill architecture changes.
