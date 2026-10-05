# Codex permission and catalog corrections (September 2026)

These were configuration gaps. Remaining platform differences include argv-prefix matching, sandbox behavior, hook capabilities, and nondeterministic reviewer decisions. The resulting behavior is listed in [Codex parity reference](../reference/codex-claude-parity.md).

## Models

Normal work uses Sol medium; native Plan mode uses Sol xhigh. There is no separate planning profile. The existing model-availability metadata is preserved.

## Automatic review

The previous reviewer setting sent eligible escalations directly to the user. `approvals_reviewer = "auto_review"` now enables Codex's built-in reviewer while retaining `approval_policy = "on-request"` and `workspace-net`. No custom reviewer policy is installed. Explicit denials require a materially safer approach or user intervention; review reduces prompts but does not guarantee Claude Auto-mode decisions. Protected-file confirmation, dangerous-command controls, SQL/Supabase restrictions, secret scanning, and commit/push quality gates still apply. See [automatic review](https://learn.chatgpt.com/docs/sandboxing/auto-review).

## Git `workdir` instead of `git -C`

Run ordinary Git commands with the exec tool's explicit `workdir`, for example `{"cmd":"git status","workdir":"/Users/Javier/.dotfiles"}`. The compound-command hook recommends this form. `git -C <path>` does not match ordinary Git prefixes; existing Git and Playwright rules need no widening.

## AWS read-rule generator

The AWS generator previously covered ten service lists plus STS/configure, leaving 22 canonical services absent (and some allowances in existing services unrepresented). It now derives all 35 service groups, including local configure commands, from `.claude/settings.json`. It expands each operation pattern against installed `aws <service> help`, validates the generated policy with native exec-policy parsing, and atomically replaces the output. Missing help, unmatched patterns, unsupported allowance syntax, and validation failures stop generation visibly and preserve the old file. Rerun `bash .codex/rules/generate-aws-read.sh` after AWS CLI or canonical allowance changes. Argument-dependent `aws s3 cp s3://* -` remains reviewable. Only exact enumerated operations are allowed; generic read-verb rules are not used.

## Skill catalog budget

The combined available-skills description catalog caused truncation; the earlier diagnostic found 54 CLI-discovered skills, including 24 AWS skills. `[skills] max_context_tokens = 10000` raises the catalog budget to the supported explicit maximum without disabling skills or editing vendor assets. Inventory counts can change as plugins update. See the [configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).
