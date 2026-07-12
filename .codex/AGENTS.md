# Global Codex Instructions

## Role and Style

- Be concise everywhere, including commit messages — sacrifice grammar for brevity.
- Push back on flawed logic; offer options with trade-offs instead of defaulting to agreement; prefer durable fixes over tactical ones when the trade-off is worth it.

## When Working

- Before broad exploration or research, read a project's `/docs` directory when it exists.
- Use subagents for exploration or review that spans 3 or more files, sources, or logs.
- After meaningful code changes (new features, changed APIs/architecture/config), update project documentation when the repository has a `/docs` system.
- Ask, don't assume: if intent, architecture, or requirements are unclear, ask before coding — no silent assumptions. Running unattended, choose the most reasonable interpretation, proceed, and flag the assumption in your closing summary.
- Flag uncertainty; don't fake confidence. When useful, run a small, low-risk experiment and bring the hypothesis and result back to discuss.
- End each plan with a concise list of unresolved questions, if any.
- Before calling a task done, verify it works: exercise the changed behavior, confirm every plan step landed, and check for regressions.

## Testing and Quality

- Write tests for every new feature — happy path and edge cases — unless told otherwise.
- Never edit or delete a test to make it pass; fix the implementation instead.
- Never hardcode return values to satisfy specific test inputs.
- Never write fallback code that silently degrades functionality; surface the error.
- Never disable, downgrade, or skip lint, typecheck, tests, or quality gates to silence failures — fix the cause.
- Keep tests independent — no shared mutable state.
- For functions with broad input domains, use property-based testing (fast-check).

## Coding Standards

- Match solution complexity to the problem; don't over-engineer or add flexibility before it's needed.
- Don't touch unrelated code; raise any smells you spot as a separate issue rather than fixing inline.

## Safety

- Never drop a database table without the user's explicit, same-turn confirmation.
- Never run `DROP`, `TRUNCATE`, unbounded `DELETE`/`UPDATE`, schema-changing SQL, or Supabase `apply_migration` without explicit user confirmation in the current turn.
- Store secrets only in environment files such as `.env*`; never place API keys or tokens in source files.
- Never modify `.env`, `.env.*`, credential files, private keys, or `secrets/` without explicit user confirmation.
- Never force-push in any form: `--force`, `-f`, `--force-with-lease`, `--force-if-includes`, or a `+refspec` (`git push origin +branch`).
- Never use git bypass flags such as `--no-verify`, `--no-gpg-sign`, or `-n`.
- Never publish packages with `pnpm publish`, `npm publish`, or `yarn publish`.
- Never push, merge, or close PRs outside the dotfiles repo without explicit confirmation. Direct commits to `main` in this dotfiles repo are allowed.
- Never disable or rewrite the protected-files, dangerous-patterns, SQL read-only, pre-commit, pre-push, or pre-PR hooks as part of unrelated work.

## Preferred Stack

- Frontend: TypeScript, React, Next.js App Router, Tailwind CSS.
- Database and auth: Supabase and Supabase Auth.
- Analytics: PostHog.
- Payments: Stripe.
- Icons: Lucide.
- Backend language/runtime: TypeScript on Node.

## Frontend Conventions

- Bootstrap linting/formatting/testing with `ts/configure.sh frontend <project-dir>` — installs the latest dev-dep versions via `pnpm add -D` (no manual `pnpm install` needed).
- Shared components live under `src/components/`; page-specific components live next to the relevant `page.tsx`.
- Co-locate component tests, for example `Button.tsx` and `Button.test.tsx`.
- Use TypeScript strict mode with `noUncheckedIndexedAccess`.
- Keep `globals.css` for global styles only.
- Next.js server functions return `[data, error]` tuples.
- Reuse existing global CSS utilities before adding duplicates.
- Tailwind class order: layout, box model, background, borders, typography, effects, filters, transitions/animations, transforms, interactivity, SVG.
- Responsive Tailwind classes start at the base class and increase by breakpoint.
- Use arrow functions for callbacks.
- Define prop interfaces above components.
- Do not import services directly from React components; use hooks or server actions.

## Backend Conventions

- Manage dependencies via `package.json` (pnpm); avoid ad-hoc global installs.
- Use ESM: set `"type": "module"` and explicit `.js` extensions on relative imports.
- Bootstrap linting/formatting/testing with `ts/configure.sh node <project-dir>` — installs the latest dev-dep versions via `pnpm add -D` (no manual `pnpm install` needed).
- Commands (from the scaffold): `pnpm typecheck`, `pnpm lint`, `pnpm test`, `pnpm format`.

## Common Commands

- Quality gate: `pnpm quality`
- Build: `pnpm build`
- Test: `pnpm test`
- Coverage: `pnpm test:coverage`
- Type-check: `pnpm typecheck`
- Lint: `pnpm lint`
- Format: `pnpm format`
- Dependency validation: `pnpm deps:validate`
- Mutation testing: `pnpm test:mutation`

## Environment Notes

- Trusted local repos: `/Users/Javier/.dotfiles` and `/Users/Javier/Projects/*`.
- Trusted package registries: npm, pnpm, and GitHub.
- PostHog project `Outsidey` (id 107700) belongs to the user; reads are safe, writes require explicit confirmation.
- Supabase list/read tools are safe. SQL execution is gated by the read-only SQL hook.

## Codex Parity Notes

- This dotfiles repo stores user-level Codex config at `.codex/user-config.toml`; setup links it to `~/.codex/config.toml` so Codex does not also load it as project-local config. Other authored Codex files remain under `.codex/` and are linked path-for-path.
- Do not duplicate Claude agents or skills under `.codex/`. The source of truth for Claude-owned agents and skills remains `.claude/`.
- Codex uses native `tui.status_line` items in `.codex/user-config.toml` for its footer; it does not support Claude-style arbitrary stdin-fed shell rendering.
- Codex hooks cover Bash, `apply_patch`/Edit/Write, MCP tools, and lifecycle events. There is no exact Claude `Read` hook equivalent; Claude has since retired its read-once hook as well (see `.codex/reference/read-once.md`).
- Codex `PreToolUse` does not support Claude-style `ask`; hooks that used to ask now deny with retry instructions or rely on Codex's normal approval flow.
- Codex SessionStart warns when dotfiles symlinks drift and restores capped original/latest user requests from rollout JSONL after compaction. Claude's model-lock mutation has no Codex counterpart; static reasoning config is authoritative. Superpowers reinjection remains excluded.
- Claude WebFetch domain allowlists are not a direct Codex web-search control. Sandboxed shell networking is governed by the `workspace-net` permission profile.
- Codex appends a machine-specific `[hooks.state]` section (hook `trusted_hash` values) to `config.toml`. A git clean filter (`.codex/strip-hooks-state.sh`, wired via `.gitattributes` + `setup.sh`) strips this trailing section on commit, so the working file keeps it (hooks stay trusted) but git ignores the churn. Assumes `[hooks.state]` stays the last section — if Codex ever writes config after it, the filter would over-strip.
