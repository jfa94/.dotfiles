# Shared skills

`.claude/` is canonical for shared agents, skills, prompts, and supporting assets. Codex gets thin
routers that reference those resources instead of copies, so a prompt fix lands in both runtimes at
once. Link details are in the [setup reference](../reference/setup.md#shared-skill-links).

## Directory links, not file links

Both sides link skills per directory rather than per file. Supporting assets a skill gains later —
reviewer profiles, prompts, verification scripts — are visible to both runtimes immediately, so a
Codex `$code-review` run cannot see a partially linked Claude skill. The same holds on cloud VMs,
where `cloud-setup.sh` mirrors `link_claude_skills`.

## What is not shared

Claude's `comprehensive-code-review` and `focused-code-review` skills are deliberately excluded
from Codex because they depend on Claude Workflow APIs; Codex uses its own `code-review` router from
`.codex/skills/code-review`, which references Claude's canonical specialist prompts.

## Portability limits

Codex normally detects skill changes automatically. Restart it if an update does
not appear. Discovery does not translate Claude-specific tools or metadata, so
skills that depend on Claude-only runtime features may need separate portability
work before Codex can execute every step.
