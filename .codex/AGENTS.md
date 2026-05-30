# Global Codex Instructions

## Role and Style

- Be concise, direct, and willing to push back on flawed logic or risky approaches.
- Prefer the native Codex tools and MCP/app tools over shell equivalents when they fit the task.
- Before broad exploration or research, read a project's `/docs` directory when it exists.
- Use subagents for exploration or review that needs 3 or more files, sources, or logs.
- If you make meaningful code changes, update project documentation when the repository has a `/docs` system.
- Present options with trade-offs when the right approach is not obvious.
- Ask only when a missing fact cannot be discovered locally and a reasonable assumption would be risky.
- Verify work before calling it complete: exercise changed behavior, run relevant checks, and look for regressions.

## Testing and Quality

- Write tests for new features unless explicitly told not to.
- Do not delete, weaken, or rewrite existing tests to make failures disappear. Fix the implementation.
- Do not disable, downgrade, or skip lint, typecheck, tests, or quality gates to silence failures.
- Do not hardcode return values for specific test inputs.
- Do not add silent fallback behavior that hides real failures.
- Keep tests independent; avoid shared mutable state.
- For broad input domains, prefer property-based testing, such as `fast-check` in TypeScript projects.

## Safety

- Never drop a database table.
- Never run `DROP`, `TRUNCATE`, unbounded `DELETE`/`UPDATE`, schema-changing SQL, or Supabase `apply_migration` without explicit user confirmation in the current turn.
- Store secrets only in environment files such as `.env*`; never place API keys or tokens in source files.
- Never modify `.env`, `.env.*`, credential files, private keys, or `secrets/` without explicit user confirmation.
- Never force-push in any form: `--force`, `-f`, `--force-with-lease`, or `--force-if-includes`.
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
- Backend language/runtime: TypeScript on Deno when starting fresh.

## Frontend Conventions

- Shared components live under `src/components/`; page-specific components live next to the relevant `page.tsx`.
- Co-locate component tests, for example `Button.tsx` and `Button.test.tsx`.
- Use TypeScript strict mode with `noUncheckedIndexedAccess`.
- Keep `globals.css` for global styles only.
- Next.js server functions return `[data, error]` tuples.
- Reuse existing global CSS utilities before adding duplicates.
- Tailwind class order: layout, box model, background, borders, typography, effects, filters, transitions/animations, transforms, interactivity, SVG.
- Responsive Tailwind classes start at the base class and increase by breakpoint.
- React components use functions, with callback functions written as arrows.
- Define prop interfaces above components.
- Do not import services directly from React components; use hooks or server actions.

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

- This dotfiles repo stores authored Codex config under `.codex/`. Setup symlinks those files into `~/.codex/`.
- Do not duplicate Claude agents or skills under `.codex/`. The source of truth for Claude-owned agents and skills remains `.claude/`.
- Codex uses native `tui.status_line` items in `.codex/config.toml` for its footer; it does not support Claude-style arbitrary stdin-fed shell rendering.
- Codex hooks cover Bash, `apply_patch`/Edit/Write, MCP tools, and lifecycle events. There is no exact Claude `Read` hook equivalent, so the old read-once behavior is documented but inactive.
- Codex `PreToolUse` does not support Claude-style `ask`; hooks that used to ask now deny with retry instructions or rely on Codex's normal approval flow.
- Claude WebFetch domain allowlists are not a direct Codex web-search control. Sandboxed shell networking is governed by the `workspace-net` permission profile.
