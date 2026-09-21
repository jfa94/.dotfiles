# Global Agent Instructions

Shared guidance for Claude Code and Codex. Each tool-specific section applies only to its named runtime.

## Communication

- Be concise, including in commit messages; clarity matters more than polished prose.
- Push back on flawed premises. Offer options and trade-offs instead of reflexive agreement, and prefer durable fixes when their cost is justified.
- State uncertainty. Use small, low-risk experiments when they can resolve it.
- Comments only where code needs clarification, never narration. Keep comments at most 3 lines; put detailed information in documentation.

## Working Method

- Before broad exploration or research, read relevant project documentation when a `docs/` directory exists.
- Ask before coding when intent, requirements, or architecture are materially ambiguous. When running unattended, choose the safest reasonable interpretation and flag it in the closing summary.
- Prefer repository-native tools and workflows. Inspect failures before changing code, and distinguish a verified cause from a working hypothesis.
- Keep plans current and end them with unresolved questions, if any.
- After meaningful changes to behavior, APIs, architecture, or configuration, update the project's documentation when it has a documentation system.
- Before declaring completion, exercise the changed behavior, confirm every planned step landed, and check relevant regressions.
- Run each validation command in a separate tool call, preserving its exit status and diagnostic output. Default to no output-filter pipelines; if filtering is necessary in Bash or zsh, enable `set -o pipefail` in that invocation and preserve the pipeline's failure status. Do not append commands that mask failure or use Bash's `PIPESTATUS` in zsh.
- Report a passing gate only after the validator completes successfully; empty output or a success marker alone is not evidence of success.

## Quality and Scope

- Write tests for new behavior, covering happy paths and meaningful edge cases, unless explicitly told otherwise.
- Fix implementations rather than weakening, deleting, or skipping tests and quality gates. Never hardcode test-specific bypasses.
- Surface failures clearly; do not silently degrade functionality.
- Keep solutions proportional to the problem. Do not add speculative flexibility.
- Avoid unrelated edits. Report adjacent issues separately.
- Keep tests independent, with no shared mutable state.
- For functions with broad input domains, use property-based testing (fast-check).

## Safety and Authorization

- Database mutations require care. Never run destructive or unbounded SQL, change schemas, or perform any remote Supabase mutation without explicit confirmation in the current turn. This includes applying existing migrations. Never drop a database table without explicit same-turn confirmation.
- Never edit `.env*`, credentials, private keys, `secrets/`, or existing/applied migrations without explicit confirmation in the current turn. Keep secrets in environment files or an approved secret store, never source code.
- Never force-push (including a leading `+` refspec), bypass commit safeguards, or publish packages without explicit confirmation in the current turn.
- Never run recursive-force `rm`, `chmod 777`, or pipe downloaded content into a shell without explicit confirmation in the current turn. The confirmation requirement applies regardless of command spelling, wrapper, or tool; a native approval prompt may still appear afterward.
- Treat external writes as authorization-sensitive. Outside the dotfiles repository, pushing branches and merging or closing pull requests require explicit confirmation. Read-only inspection is allowed when relevant.
- Authorization is scoped to the stated target and action; do not infer permission for adjacent repositories, accounts, deployments, messages, purchases, or other consequential operations.
- Supabase remains list/read-only unless a mutation is explicitly confirmed in the current turn.

## Technology Defaults

- Existing project conventions take precedence. For greenfield work, prefer TypeScript, React, Next.js App Router, Tailwind CSS, Supabase/Auth, PostHog, Stripe, Lucide, and TypeScript on Node.
- For frontend work, read and follow `~/.dotfiles/instructions/frontend.md` (commands, stack, React, Tailwind, and Next.js conventions).
- For backend work, read and follow `~/.dotfiles/instructions/backend.md` (language, runtime, and Node conventions).

## AWS

### Guidance

- Before starting a task, check whether a relevant AWS skill is available. Load the skill and prefer its guidance over general knowledge.
- When uncertain about specific AWS details (API parameters, permissions, limits, error codes), verify against documentation rather than guessing. State uncertainty explicitly if you cannot confirm.
- When creating infrastructure, prefer infrastructure-as-code (AWS CDK or CloudFormation) over direct CLI commands.
- When working with infrastructure, follow AWS Well-Architected Framework principles.
- Do not use em dashes in AWS resource names or descriptions. Use hyphens instead.

### Secret Safety

- MUST load the `aws-secrets-manager` skill first for any secret, credential, API key, token, or password task. MUST NOT call `secretsmanager get-secret-value` or `batch-get-secret-value`, and MUST NOT hit the Secrets Manager Agent daemon directly. MUST use `{{resolve:secretsmanager:secret-id:SecretString:json-key}}` with `asm-exec` so the secret resolves at runtime without entering context.

## PostHog

Project-native MCP is a single `posthog` server wrapping every PostHog operation behind one `exec` tool — full catalogue, no permission split. It runs silently, reads and writes alike; safety is the PostHog API key's own scopes, not a prompt. Only issue a write when one is actually intended.

- The user authorizes Outsidey PostHog project `107700` MCP calls, including writes, without an additional confirmation prompt. The `posthog` MCP server exposes its full catalogue (no read-only split), and its effective access is limited only by the API key's provider-side scopes.

## Claude Code

Only Claude Code follows this section.

- Use a subagent for any exploration or research spanning 3+ files or pages: built-in `Explore` for pure codebase search; `Scout` (if available) for web research, log debugging, tool/CLI discovery, or mixed-source investigations.
- After meaningful code changes (new features, changed APIs/architecture/config), run the `Scribe` agent (user-level agent, not `factory:scribe`) to update `/docs`.
- Prefer the AWS MCP Server for AWS interactions — it provides sandboxed execution, observability, and audit logging. If unavailable, use the AWS CLI directly.
- Load AWS skills with `retrieve_skill`.

## Codex

Only Codex follows this section.

- Run Git with an explicit exec-tool `workdir` and ordinary commands such as `git status`; avoid `cd ... && git ...` and `git -C ...`, which do not match ordinary Git allow rules.
- Use subagents only for independent, bounded work that benefits from parallel exploration or review.
- Run Chromium-based commands (Playwright, Puppeteer, Electron) with `sandbox_permissions="require_escalated"`: the seatbelt sandbox denies Chromium's Mach port registration outright.
- Use the ordinary AWS CLI for authenticated AWS resource access. AWS MCP is limited to knowledge, documentation, skill-discovery, and region tools; authenticated `call_aws`, `run_script`, and presigned-URL operations remain denied by repository hooks. AWS writes and unlisted CLI operations continue through approval review.
