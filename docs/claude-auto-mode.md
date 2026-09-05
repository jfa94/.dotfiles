# Claude Auto-mode troubleshooting

## Confirmation after repeated denials

Auto mode falls back to confirmation after three consecutive classifier denials
or twenty total denials. The counter spans actions, so a lint prompt can follow
blocked database cleanup commands. The prompt alone does not establish a bug.
See [Claude's permission modes](https://code.claude.com/docs/en/permission-modes).

The September 5, 2026 goodbyespy session (Claude Code 2.1.258) prompted for:

```sh
corepack pnpm@10.34.3 exec eslint . 2>&1 | tail -5
env -u NEXT_PUBLIC_SUPABASE_URL -u NEXT_PUBLIC_SUPABASE_KEY -u NEXT_SECRET_SUPABASE_KEY corepack pnpm@10.34.3 exec vitest run utils/sweep/createSweep.test.ts 2>&1 | tail -8
```

The inspected user and project settings had no matching allow rules for these
wrapped commands. Direct `pnpm eslint` and `pnpm vitest` allowances do not cover
the Corepack forms. All seven configured Bash PreToolUse hooks passed both
commands through unchanged when checked with their original command inputs.
The transcript records classifier denials, including database cleanup denials
before the validation prompts.

The exact classifier rationale is unresolved. `Blocked by classifier` is a
generic verdict, not an explanation identifying Corepack, environment cleanup,
or output filtering as the cause. Neither denial is proven to be a false
positive. See [Claude's denial diagnostics](https://code.claude.com/docs/en/auto-mode-config#fix-a-denial-with-an-allow-rule-an-environment-entry-or-a-retry).

Keep classifier review enabled. Missing preapproval for these commands is
consistent with that choice. When prompted, review the preceding actions and
approve the specific intended action if appropriate. Selecting a permanent
`corepack *` allowance would also preapprove unrelated commands. There is no
confirmed cause here that warrants an approval hook, classifier-policy change,
or version change.

## Preserve validation failures

Two command defects were independently reproduced during the investigation:

- Without `pipefail`, `command | tail` returns the status of `tail`, which can
  succeed when the validator fails. The session's chained form could print
  `LINT_TSC_OK` even when both validation commands failed.
- The session attempted to print `${PIPESTATUS[0]}` under zsh and received
  `tsc exit` with no status value. `PIPESTATUS` is Bash-specific; zsh uses
  `pipestatus`. An appended successful `echo` also masks the command's failure.

See the [Bash pipeline reference](https://www.gnu.org/software/bash/manual/html_node/Pipelines.html)
and [zsh parameters](https://zsh.sourceforge.io/Doc/Release/Parameters.html).
These defects establish unreliable status reporting, not the cause of the
classifier decisions or evidence that the reported lint/test runs failed.

Run validation commands individually without output-filter pipelines. For
goodbyespy, execute each of these in a separate tool call from the project root:

```sh
corepack pnpm@10.34.3 exec tsc --noEmit
```

```sh
corepack pnpm@10.34.3 exec eslint .
```

```sh
env -u NEXT_PUBLIC_SUPABASE_URL -u NEXT_PUBLIC_SUPABASE_KEY -u NEXT_SECRET_SUPABASE_KEY corepack pnpm@10.34.3 exec vitest run utils/sweep/createSweep.test.ts
```

The pinned Corepack invocation is a goodbyespy project requirement. Its documented
`env -u` prefix removes inherited hosted Supabase settings from the child process
so Vitest can load local test settings. It does not edit environment files. The
suite uses a real local database with a localhost guard; keep that isolation and
the project's test prerequisites. These examples are not global package-version
or test-environment defaults.

If output filtering is necessary, enable `set -o pipefail` in the same Bash or
zsh invocation, and leave the pipeline as the final command:

```sh
set -o pipefail
corepack pnpm@10.34.3 exec eslint . 2>&1 | tail -5
```

A nonzero result requires inspecting the full diagnostics before reporting the
outcome. Do not infer a passing gate from empty output or a printed success
marker. Standalone commands are the default; shell-specific status arrays and
custom wrappers add no value for these examples.

## Verification and limits

Harmless `true`/`false` probes in Bash and zsh confirmed that standalone commands
and pipelines with `pipefail` preserve success and failure. With `pipefail`, a
failed pipeline also prevents an `&& echo LINT_TSC_OK` success marker.

The canonical guidance is in `.claude/CLAUDE.md`. This change improves validation
reporting without changing permission rules, hooks, or classifier configuration.
It does not guarantee fewer classifier prompts.
