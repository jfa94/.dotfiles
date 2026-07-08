# Read-Once Parity Gap

Claude used a `Read` hook to track large files already loaded into context and nudge agents away from repeated reads.

Codex hooks currently cover Bash, `apply_patch`/Edit/Write, MCP tool calls, and lifecycle events. They do not cover every internal file read path, so the old read-once behavior is not active in this Codex configuration.

Do not emulate this with brittle shell wrappers or transcript scraping. Treat it as a documented parity gap until Codex exposes a stable read hook.

Update (2026-07): Claude retired read-once too — the `Read` hook was unwired from `.claude/settings.json` — so there is currently nothing to be at parity with. This doc stays as history in case the pattern returns.
