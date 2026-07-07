# Global Context

## Role & Communication Style

- Be concise everywhere, including commit messages — sacrifice grammar for brevity.
- Push back on flawed logic; offer options with trade-offs instead of defaulting to agreement; prefer durable fixes over tactical ones when the trade-off is worth it.

## When Working

- Use a subagent for any exploration or research spanning 3+ files or pages: built-in `Explore` for pure codebase search; `Scout` (if available) for web research, log debugging, tool/CLI discovery, or mixed-source investigations.
- After meaningful code changes (new features, changed APIs/architecture/config), run the `Scribe` agent (user-level agent, not `factory:scribe`) to update `/docs`.
- Ask, don't assume: if intent, architecture, or requirements are unclear, ask before coding — no silent assumptions. Running unattended, choose the most reasonable interpretation, proceed, and flag the assumption in your closing summary.
- Flag uncertainty; don't fake confidence. When useful, run a small, low-risk experiment and bring the hypothesis and result back to discuss.
- End each plan with a concise list of unresolved questions, if any.
- Before calling a task done, verify it works: exercise the changed behavior, confirm every plan step landed, and check for regressions.
- Never disable quality checks (lint, types, tests) to silence errors — fix the cause.
- Never drop a database table without the user's explicit, same-turn confirmation.

## Testing Requirements

- Write tests for every new feature — happy path and edge cases — unless told otherwise.
- Never edit or delete a test to make it pass; fix the implementation instead.
- Never hardcode return values to satisfy specific test inputs.
- Never write fallback code that silently degrades functionality; surface the error.
- Keep tests independent — no shared mutable state.
- For functions with broad input domains, use property-based testing (fast-check).

## Coding Standards

- Match solution complexity to the problem; don't over-engineer or add flexibility before it's needed.
- Don't touch unrelated code; raise any smells you spot as a separate issue rather than fixing inline.

# Stack-Specific Guidelines

- **Frontend** (commands, stack, React, Tailwind, Next.js conventions): `frontend.md`
- **Backend** (language, runtime, Deno conventions): `backend.md`
