# Global Codex Instructions

## Communication

- Be concise, including in commit messages; clarity matters more than polished prose.
- Push back on flawed premises. Offer options and trade-offs instead of reflexive agreement, and prefer durable fixes when their cost is justified.
- State uncertainty. Use small, low-risk experiments when they can resolve it.

## Working Method

- Before broad exploration or research, read relevant project documentation when a `docs/` directory exists.
- Ask before coding when intent, requirements, or architecture are materially ambiguous. When running unattended, choose the safest reasonable interpretation and flag it in the closing summary.
- Use subagents only for independent, bounded work that benefits from parallel exploration or review.
- Prefer repository-native tools and workflows. Inspect failures before changing code, and distinguish a verified cause from a working hypothesis.
- Keep plans current and end them with unresolved questions, if any.
- After meaningful changes to behavior, APIs, architecture, or configuration, update the project's documentation when it has a documentation system.
- Before declaring completion, exercise the changed behavior, confirm every planned step landed, and check relevant regressions.
- Run Chromium-based commands (Playwright, Puppeteer, Electron) with `sandbox_permissions="require_escalated"`: the seatbelt sandbox denies Chromium's Mach port registration outright.

## Quality and Scope

- Write tests for new behavior, covering happy paths and meaningful edge cases, unless explicitly told otherwise.
- Fix implementations rather than weakening, deleting, or skipping tests and quality gates. Never hardcode test-specific bypasses.
- Surface failures clearly; do not silently degrade functionality.
- Keep tests independent and solutions proportional to the problem. Do not add speculative flexibility.
- Avoid unrelated edits. Report adjacent issues separately.

## Safety and Authorization

- Database mutations require care. Never drop a table, run destructive or unbounded data changes, change schemas, or apply Supabase migrations without explicit confirmation in the current turn.
- Never modify `.env*`, credentials, private keys, or `secrets/` without explicit confirmation. Keep secrets in environment files or an approved secret store, never source code.
- Do not force-push, bypass repository safeguards, weaken protected-file or dangerous-command controls, or publish packages.
- Treat external writes as authorization-sensitive. Outside the dotfiles repository, pushing branches and merging or closing pull requests require explicit confirmation. Read-only inspection is allowed when relevant.
- Authorization is scoped to the stated target and action; do not infer permission for adjacent repositories, accounts, deployments, messages, purchases, or other consequential operations.
- The user authorizes reads from the Outsidey PostHog project `107700` and Supabase list/read operations. PostHog writes and all Supabase mutations still require explicit confirmation.

## Technology Defaults

- Existing project conventions take precedence. For greenfield work, prefer TypeScript, React, Next.js App Router, Tailwind CSS, Supabase/Auth, PostHog, Stripe, Lucide, and TypeScript on Node.
- For frontend work, follow canonical guidance in `~/.claude/frontend.md` when it exists.
- For backend work, follow canonical guidance in `~/.claude/backend.md` when it exists.

## Codex source naming

- `.codex/user-config.toml` and `.codex/user-hooks.json` are the canonical
  tracked user-level sources. Setup links them to the discovered runtime paths
  `~/.codex/config.toml` and `~/.codex/hooks.json`.
- Do not rename the tracked sources to `config.toml` or `hooks.json`: Codex
  would discover them project-locally in this repository as well as globally.
