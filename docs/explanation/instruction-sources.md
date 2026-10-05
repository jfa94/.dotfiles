# Instruction sources

One file, two runtimes: authoring guidance once avoids drift between Claude Code and Codex, while
each runtime keeps its own tool-specific section and discovery rules.

Both runtime entry points share one `instructions/AGENTS.md`: setup links it to
`~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`. Source sharing is exact; runtime
policies and discovery differ. Edit the canonical file, not the runtime links.
Frontend/backend guidance lives beside it and is read on demand. Dotfiles root
`AGENTS.md` remains project-specific; root `CLAUDE.md` contains only `@AGENTS.md`
so Claude loads it even without native AGENTS support. Codex reads AGENTS.md
natively. Its global `AGENTS.override.md`, if present, supersedes AGENTS.md.

Claude native AGENTS support requires more than v2.1.277: it also depends on
feature-flag availability and session settings, and can be unavailable on the
first session after installation/upgrading, with telemetry disabled, or on
third-party providers. Outsidey retains native loading without a compatibility
stub; verify it in a fresh supported session. A project/ancestor CLAUDE.md or
CLAUDE.local.md can suppress native loading under the default setting. See
[Claude loading rules](https://code.claude.com/docs/en/memory#agents-md) and
[Codex discovery](https://learn.chatgpt.com/docs/agent-configuration/agents-md).

goodbyespy shares its project rules through AGENTS.md and imports them from a
CLAUDE.md with explicitly Claude-only workflow instructions. Codex uses the
existing native code-review router rather than Claude-only review skills.
