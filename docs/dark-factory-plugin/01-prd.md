# Dark Factory Plugin — PRD: Problem, Goals & Feature List

## Problem Statement

The [dark-factory](https://github.com/jfa94/dark-factory) autonomous coding pipeline (~3,700 lines, 17 Bash modules) converts GitHub PRD issues into merged pull requests without human intervention. It works, but suffers from fundamental limitations inherent to a shell-based architecture:

**Shell fragility** — Bash lacks structured error handling, type safety, and composability. State management is ad-hoc (JSON files manipulated with `jq`), parallelism is limited to background processes with PID tracking, and recovery from partial failures requires manual intervention.

**No native Claude Code integration** — the pipeline invokes Claude Code as an external subprocess, losing access to the agent framework's native capabilities: worktree isolation, background agent execution, subagent spawning, skill injection, hook-based safety enforcement, and MCP server integration.

**Limited quality assurance** — the current pipeline has a single code review pass. Research evidence shows this is insufficient:

- AI-generated tests achieve 85-95% line coverage but only 30-40% mutation scores (tautological tests that assert what was written, not what should work)
- Veracode: AI code has 2.74x more vulnerabilities than human-written code
- LinearB: 67.3% of AI-generated PRs rejected vs 15.6% for human code
- DORA 2025: 90% AI adoption correlates with 154% PR size increase, 91% more review time, 9% bug rate climb

**No adversarial review** — the pipeline uses a single reviewer pass. Actor-Critic adversarial review (3-5 rounds) eliminates 90%+ issues at ~$0.20-$1.00/feature vs $50-$100/hr human review (Autonoma: 73% more issues caught, 71% fewer bugs, 42% less review time).

**No rate limit resilience** — when Anthropic API rate limits are reached, the pipeline stalls entirely. Local LLM fallback via Ollama could keep routine tasks progressing.

**Opportunity:** Claude Code's plugin system provides native primitives (agents, hooks, bin scripts, skills, commands, MCP servers) that map directly to pipeline concerns. A plugin re-implementation gains worktree isolation, background execution, un-bypassable hooks, skill injection, and persistent state — while maintaining the deterministic-first architecture that makes the Bash pipeline reliable.

---

## Goals

1. **Faithful reproduction** of ALL existing dark-factory pipeline functionality — every feature in every Bash module has a corresponding plugin component
2. **Deterministic-first architecture** — ~3:1 ratio of deterministic components (bin scripts, hooks) to non-deterministic (agents). Agent instructions are followed ~70%; hooks/scripts enforce at 100%. Concrete operational rules outperform abstract directives by 123%.
3. **Quality-first additions** from research:
   - 5-layer quality gate stack (static analysis → tests → coverage regression → holdout validation → mutation testing)
   - Adversarial code review (Actor-Critic, multi-round, Codex-first with Claude Code fallback)
   - Risk-based task classification (routine/feature/security → tiered review intensity)
   - Holdout validation (StrongDM Attractor pattern)
4. **Local LLM fallback** via Ollama when Anthropic rate limits are approached — keep routine tasks progressing instead of stalling
5. **Reuse existing `.claude/` setup** — spawn the user's spec-reviewer, code-reviewer, architecture-reviewer, security-reviewer, test-writer, scout, scribe, and simple-task-runner agents directly. Leverage existing hooks (pre-commit, pre-push, dangerous-patterns, etc.) that fire automatically.
6. **Observability and compliance** — tamper-evident audit logs, delegation chains, metrics (EU AI Act Aug 2026 readiness)
7. **Resume capability** — pipeline recovers from interruptions by reading persisted state

---

## Non-Goals

- **Not a general-purpose CI/CD system** — this is specifically an autonomous coding pipeline for converting PRD issues to merged PRs
- **Not replacing human architectural decisions** — the pipeline implements tasks from human-authored PRDs; it does not decide what to build
- **Not supporting non-GitHub platforms** — GitHub issues and PRs are the only supported input/output initially
- **Not guaranteeing local LLM quality parity** — Ollama fallback is explicitly for routine tasks only; complex/security tasks always use cloud models
- **Not a real-time system** — pipeline runs are batch operations; there is no streaming or event-driven architecture requirement

---

## User Personas

### Solo Developer (primary)

Runs the pipeline autonomously on personal projects. Wants to convert a PRD issue into a merged PR overnight. Values: speed, minimal supervision, cost efficiency. Uses local LLM fallback to stay within API budget.

### Team Lead

Configures the pipeline for team repositories. Sets human review levels (e.g., Level 1: PR approval required). Wants observability into what the pipeline did and why. Values: audit trails, configurable quality gates, team-safe defaults.

### Security-Conscious Developer

Works on repositories with auth, payment, or PII handling. Needs security-tier review (5 adversarial rounds + security-reviewer + architecture-reviewer). Wants tamper-evident logs for compliance. Values: defense in depth, zero silent failures.

---

## Complete Feature Inventory

### Stage A: Input & Discovery

| Feature                 | Existing Behavior (Bash)                              | Plugin Primitive                                                | Enhancements                                                 |
| ----------------------- | ----------------------------------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------ |
| **Issue number intake** | CLI accepts issue numbers as arguments                | `/dark-factory:run` command parses arguments                    | Same behavior, native slash command UX                       |
| **PRD tag detection**   | Searches for `[PRD]`-tagged open issues               | `pipeline-orchestrator` agent queries GitHub API via `gh`       | Same behavior                                                |
| **Multi-PRD batching**  | `multi-prd.sh` processes multiple issues sequentially | Orchestrator iterates issues, can parallelize independent specs | Parallel spec generation for independent PRDs                |
| **Issue body fetching** | `spec-gen.sh` calls `gh issue view`                   | `bin/pipeline-fetch-prd` script                                 | Deterministic, testable, same `gh` interface                 |
| **Input validation**    | `validator.sh` checks git remote, branch state        | `bin/pipeline-validate` script                                  | Adds plugin-specific checks (agents exist, skills available) |

### Stage B: Spec Generation

| Feature                    | Existing Behavior (Bash)                            | Plugin Primitive                                                                    | Enhancements                                                 |
| -------------------------- | --------------------------------------------------- | ----------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| **PRD → spec conversion**  | `spec-gen.sh` invokes Claude with prd-to-spec skill | `spec-generator` agent (opus, 40 turns, worktree) with `prd-to-spec` skill injected | Native skill injection; worktree isolation                   |
| **Autonomous mode**        | Skips interactive prompts                           | Skill step 5 (quiz user) skipped via agent instructions                             | Same behavior                                                |
| **Spec output validation** | Basic file existence checks                         | `bin/pipeline-validate-spec` script                                                 | Structured validation (file exists, non-empty, valid format) |
| **Spec review loop**       | Calls spec-reviewer, retries up to 3x               | Spawns existing `spec-reviewer` agent (score ≥48/60, PASS/NEEDS_REVISION)           | Same behavior, reuses user's agent directly                  |
| **tasks.json generation**  | Part of prd-to-spec output                          | Same — embedded in prd-to-spec skill                                                | Same behavior                                                |

### Stage C: Task Decomposition

| Feature                    | Existing Behavior (Bash)                   | Plugin Primitive                                                | Enhancements                                                                                             |
| -------------------------- | ------------------------------------------ | --------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| **Field validation**       | `task-validator.sh` checks required fields | `bin/pipeline-validate-tasks` script                            | Same checks: task_id, title, description, files (max 3), acceptance_criteria, tests_to_write, depends_on |
| **Cycle detection**        | Detects circular dependencies              | `bin/pipeline-validate-tasks` script                            | Same algorithm                                                                                           |
| **Dangling dep detection** | Finds references to non-existent tasks     | `bin/pipeline-validate-tasks` script                            | Same check                                                                                               |
| **Topological sort**       | Kahn's algorithm for execution order       | `bin/pipeline-validate-tasks` script                            | Same algorithm, outputs JSON execution order                                                             |
| **Execution order output** | Flat list of tasks in dependency order     | Script stdout: `[{"task_id":"task_1","parallel_group":0}, ...]` | Adds parallel group info for concurrent execution                                                        |

### Stage D: Task Execution

| Feature                       | Existing Behavior (Bash)                  | Plugin Primitive                                      | Enhancements                                                                                                             |
| ----------------------------- | ----------------------------------------- | ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| **Feature branch creation**   | `repository.sh` creates branches          | `bin/pipeline-branch` script                          | Same naming conventions, adds worktree-aware branching                                                                   |
| **Complexity classification** | `task-runner.sh` classifies by file count | `bin/pipeline-classify-task` script                   | Same heuristic: file count + dep count → haiku (simple, 40 turns) / sonnet (medium, 60 turns) / opus (complex, 80 turns) |
| **Risk classification**       | Not in Bash pipeline                      | `bin/pipeline-classify-risk` script                   | NEW: file-path heuristics → routine/feature/security tier. Auth/security/migration paths → security tier                 |
| **Code generation**           | Claude subprocess in feature branch       | `task-executor` agent (worktree-isolated, background) | Native worktree isolation, background execution, model/turns from classify-task                                          |
| **Test writing**              | Part of task execution                    | `task-executor` agent instructions                    | Adds property-based testing instructions (PGS framework: 15.7% improvement)                                              |
| **Auto-fix loop**             | Retry on test failure (max 3)             | `task-executor` retries internally                    | Same behavior                                                                                                            |
| **Parallel execution**        | Limited (background PIDs)                 | Background agents + worktrees, max 3 concurrent       | True parallel isolation via git worktrees                                                                                |
| **Prompt construction**       | `task-runner.sh` builds prompt            | `bin/pipeline-build-prompt` script                    | Adds `--holdout N%` flag to withhold acceptance criteria                                                                 |

### Stage E: Quality Gates

| Feature                          | Existing Behavior (Bash)                    | Plugin Primitive                                                         | Enhancements                                                                                                                                      |
| -------------------------------- | ------------------------------------------- | ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Layer 1: Static analysis**     | Pre-commit hooks (lint, format, type check) | Existing user hooks fire automatically                                   | No change needed — hooks are un-bypassable                                                                                                        |
| **Layer 2: Test suite**          | Runs test suite                             | Existing Stop hook runs vitest                                           | No change needed                                                                                                                                  |
| **Layer 3: Coverage regression** | Not in Bash pipeline                        | `bin/pipeline-coverage-gate` script                                      | NEW: compare before/after coverage, must not decrease. Evidence: agents delete failing tests to improve metrics; coverage regression catches this |
| **Layer 4: Holdout validation**  | Not in Bash pipeline                        | `bin/pipeline-build-prompt --holdout 20%` + holdout-validator evaluation | NEW: withhold 20% of acceptance criteria, verify task still satisfies them. StrongDM Attractor: 6-7K NLSpec → 32K+ production code                |
| **Layer 5: Mutation testing**    | Not in Bash pipeline                        | `test-writer` agent kills surviving mutants                              | NEW: target >80% mutation score. AI code has 15-25% higher mutation survival rates                                                                |
| **Anti-pattern detection**       | Not in Bash pipeline                        | `task-reviewer` instructions + existing hooks                            | NEW: hallucinated APIs, over-abstraction, copy-paste drift, dead code, excessive I/O, sycophantic generation                                      |

### Stage F: Code Review

| Feature                   | Existing Behavior (Bash)                        | Plugin Primitive                                              | Enhancements                                                                                          |
| ------------------------- | ----------------------------------------------- | ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| **Single review pass**    | `code-review.sh` runs one Claude review session | `task-reviewer` agent OR Codex adversarial review             | Upgraded to multi-round adversarial review                                                            |
| **Adversarial review**    | Not in Bash pipeline                            | `review-protocol` skill (Actor-Critic methodology)            | NEW: Critic reviews cold (zero implementation context), treats code as hostile artifact               |
| **Multi-round loop**      | Not in Bash pipeline                            | Orchestrator manages round loop (max configurable, default 3) | NEW: reviewer finds issues → executor fixes → re-review. Exit early on APPROVE.                       |
| **Codex-first detection** | Not in Bash pipeline                            | `bin/pipeline-detect-reviewer` script                         | NEW: check Codex installed + authenticated → use `/codex:adversarial-review`; fallback to Claude Code |
| **Structured verdicts**   | Human-readable review output                    | `bin/pipeline-parse-review` normalizes to JSON                | NEW: `{"verdict":"APPROVE\|REQUEST_CHANGES\|NEEDS_DISCUSSION","findings":[...],"round":N}`            |
| **Risk-tiered intensity** | Same review for all tasks                       | Orchestrator selects rounds by risk tier                      | NEW: routine=1 round, feature=3 rounds, security=5 rounds + security-reviewer + architecture-reviewer |
| **Human escalation**      | Not in Bash pipeline                            | After max rounds with REQUEST_CHANGES → pause for human       | NEW: prevents infinite review loops                                                                   |

### Stage G: Dependency Resolution

| Feature                     | Existing Behavior (Bash)             | Plugin Primitive                       | Enhancements                                                                   |
| --------------------------- | ------------------------------------ | -------------------------------------- | ------------------------------------------------------------------------------ |
| **PR merge polling**        | `orchestrator.sh` polls `gh pr view` | `bin/pipeline-wait-pr` script          | Same behavior, configurable timeout (default 45min) and interval (default 60s) |
| **Timeout handling**        | Fails after timeout                  | Script returns exit code 1             | Same behavior                                                                  |
| **Dependency satisfaction** | Checks task deps before execution    | `bin/pipeline-state` checks dep status | Same behavior, richer state tracking                                           |

### Stage H: Completion

| Feature               | Existing Behavior (Bash)             | Plugin Primitive                         | Enhancements                                                            |
| --------------------- | ------------------------------------ | ---------------------------------------- | ----------------------------------------------------------------------- |
| **Issue closing**     | `completion.sh` closes GitHub issues | `bin/pipeline-cleanup --close-issues`    | Same `gh` interface                                                     |
| **Branch cleanup**    | Deletes feature branches             | `bin/pipeline-cleanup --delete-branches` | Same behavior                                                           |
| **Execution summary** | Prints summary to stdout             | `bin/pipeline-summary` script            | Richer output: per-task status, quality gate results, model usage, cost |
| **Docs update**       | `docs-update.sh` runs scribe         | Spawns existing `scribe` agent           | Same behavior, reuses user's agent                                      |

### Stage I: Safety & Observability

| Feature                   | Existing Behavior (Bash)                   | Plugin Primitive                                                   | Enhancements                                                          |
| ------------------------- | ------------------------------------------ | ------------------------------------------------------------------ | --------------------------------------------------------------------- |
| **Circuit breakers**      | 20 tasks / 360min / 3 consecutive failures | `bin/pipeline-circuit-breaker` script                              | Same thresholds, configurable via userConfig                          |
| **Directory locking**     | SHA256 lock file (`lock.sh`)               | ELIMINATED — worktree isolation                                    | Better: true isolation vs mutual exclusion                            |
| **API rate monitoring**   | 90% cap, polling                           | `bin/pipeline-quota-check` script                                  | Adds proactive header parsing (before 429), Ollama fallback trigger   |
| **Resume capability**     | Reads state files on restart               | `pipeline-state` + orchestrator `--resume` flag                    | Same pattern, richer state schema                                     |
| **Git safety**            | Branch protection checks                   | `branch-protection` hook (PreToolUse)                              | Un-bypassable hook vs agent instruction                               |
| **Audit logging**         | Not in Bash pipeline                       | `run-tracker` hook (PostToolUse)                                   | NEW: every tool use logged to `audit.jsonl`. EU AI Act compliance.    |
| **Metrics collection**    | Not in Bash pipeline                       | `pipeline-metrics` MCP server                                      | NEW: token counts, durations, model usage, quality gate results, cost |
| **Run state consistency** | Basic state checks                         | `stop-gate` hook (Stop) + `subagent-stop-gate` hook (SubagentStop) | NEW: validates state on session end, marks interrupted runs           |

### Stage J: Local LLM Fallback

| Feature                       | Existing Behavior (Bash) | Plugin Primitive                                                       | Enhancements                                                                           |
| ----------------------------- | ------------------------ | ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| **Rate limit detection**      | 90% cap polling          | `bin/pipeline-quota-check` parses Anthropic response headers           | NEW: proactive detection via `anthropic-ratelimit-tokens-remaining` header             |
| **Ollama availability check** | Not in Bash pipeline     | `bin/pipeline-model-router` checks `curl -sf localhost:11434/api/tags` | NEW: verify Ollama running + model loaded                                              |
| **Model routing**             | Not in Bash pipeline     | `bin/pipeline-model-router` returns provider/model/base_url config     | NEW: route routine-tier tasks to Ollama when rate limited                              |
| **Tier restrictions**         | Not in Bash pipeline     | Configurable `localLlm.allowedTiers` (default: `["routine"]` only)     | NEW: security/complex tasks ALWAYS use cloud                                           |
| **Quality gate parity**       | Not in Bash pipeline     | Same quality gates regardless of model provider                        | NEW: local model output must pass identical gates                                      |
| **Model recommendations**     | Not in Bash pipeline     | userConfig.localLlm.model                                              | NEW: Qwen 2.5-Coder 7B (8GB), DeepSeek Coder V2 16B (16GB), Qwen 2.5-Coder 32B (24GB+) |
| **LiteLLM proxy**             | Not in Bash pipeline     | Optional advanced config                                               | NEW: unified gateway for multi-provider routing + cost tracking                        |

### Stage K: Configuration

| Feature                 | Existing Behavior (Bash)    | Plugin Primitive                | Enhancements                                 |
| ----------------------- | --------------------------- | ------------------------------- | -------------------------------------------- |
| **Pipeline settings**   | `settings.sh` + config file | `plugin.json` userConfig schema | Native Claude Code configuration             |
| **Permission defaults** | Manual setup                | `settings.json` in plugin       | Automatic permission grants for plugin tools |
| **Plugin manifest**     | `config-deployer.sh`        | `.claude-plugin/plugin.json`    | Native plugin metadata                       |

---

## Autonomy Spectrum

The plugin supports operating modes from least to most autonomous. Controlled by `userConfig.humanReviewLevel`:

### Level 4: Full Supervision

Human approves at every stage: spec, task decomposition, each task execution, each review round, PR creation.
**Use case:** First run on a new codebase, learning the pipeline's behavior.

### Level 3: Spec Approval

Pipeline pauses after spec generation for human review. Once approved, executes autonomously through PR creation.
**Use case:** Team repos where architecture decisions need human sign-off.

### Level 2: Review Checkpoint

Pipeline runs through spec + execution autonomously. Pauses after adversarial code review for human sign-off before PR.
**Use case:** Solo dev who trusts spec generation but wants to review code.

### Level 1: PR Approval (default)

Pipeline runs end-to-end autonomously, creates PR. Human reviews and merges.
**Use case:** Standard autonomous workflow — overnight PR generation.

### Level 0: Full Autonomy

Pipeline creates PR, enables auto-merge. Human reviews merged code post-hoc.
**Use case:** Low-risk routine tasks, trusted codebase with strong test coverage.

### Single-Task Mode

Execute one task from an existing spec. Useful for retrying a failed task or running a specific task manually.
**Invocation:** `/dark-factory:run --task <task_id> --spec <spec-dir>`

### Spec-to-PR Mode

Generate spec from PRD → execute all tasks → create single PR. No issue discovery or multi-PRD batching.
**Invocation:** `/dark-factory:run --prd <issue-number>`

### Full Dark Factory Mode

Discover `[PRD]`-tagged issues → generate specs → execute → review → merge → close issues. The original autonomous pipeline.
**Invocation:** `/dark-factory:run --discover`
