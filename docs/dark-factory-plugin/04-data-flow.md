# Dark Factory Plugin — Data Flow & Orchestration

## End-to-End Pipeline Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        /dark-factory:run                                │
│  Parse mode → pipeline-validate → pipeline-init → spawn orchestrator   │
└──────────────────────────────────┬──────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      STAGE A: Input & Discovery                         │
│  [discover mode] gh issue list --label PRD → issue numbers              │
│  [prd mode] use provided issue number                                   │
│  [task mode] skip to Stage D                                            │
│  [resume mode] pipeline-state resume-point → skip to last incomplete    │
│                                                                         │
│  For each issue: pipeline-fetch-prd → PRD body JSON                     │
└──────────────────────────────────┬──────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      STAGE B: Spec Generation                           │
│                                                                         │
│  orchestrator spawns spec-generator agent (worktree)                    │
│    ├── spec-generator uses prd-to-spec skill (steps 1-4, 6-7)          │
│    ├── step 5 (quiz user) SKIPPED in autonomous mode                    │
│    ├── outputs: spec.md + tasks.json                                    │
│    └── pipeline-validate-spec checks output                             │
│                                                                         │
│  orchestrator spawns spec-reviewer agent (existing)                     │
│    ├── scores on 6 dimensions (max 60)                                  │
│    ├── if score < 48 → NEEDS_REVISION → regenerate (max 3 iterations)   │
│    └── if score ≥ 48 → PASS → continue                                 │
└──────────────────────────────────┬──────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      STAGE C: Task Decomposition                        │
│                                                                         │
│  pipeline-validate-tasks < tasks.json                                   │
│    ├── field validation (task_id, title, files ≤ 3, etc.)               │
│    ├── cycle detection (DFS)                                            │
│    ├── dangling dep detection                                           │
│    ├── topological sort (Kahn's algorithm)                              │
│    └── parallel group assignment                                        │
│                                                                         │
│  Output: execution_order with parallel groups                           │
│    [                                                                    │
│      {task_id: "task_1", parallel_group: 0},  ← run concurrently       │
│      {task_id: "task_2", parallel_group: 0},  ← run concurrently       │
│      {task_id: "task_3", parallel_group: 1},  ← after group 0 done     │
│    ]                                                                    │
└──────────────────────────────────┬──────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      STAGE D: Task Execution Loop                       │
│                                                                         │
│  For each parallel_group in execution_order:                            │
│    For each task in group (up to maxConcurrent):                        │
│                                                                         │
│      ┌─ DETERMINISTIC (bin scripts) ──────────────────────────────┐     │
│      │ 1. pipeline-circuit-breaker <run-id>                       │     │
│      │    → if tripped: STOP pipeline                             │     │
│      │ 2. pipeline-state deps-satisfied <run-id> <task-id>        │     │
│      │    → if not: WAIT                                          │     │
│      │ 3. pipeline-classify-task <task-json>                      │     │
│      │    → {tier, model, maxTurns}                               │     │
│      │ 4. pipeline-classify-risk <task-json>                      │     │
│      │    → {tier, review_rounds, extra_reviewers}                │     │
│      │ 5. pipeline-model-router --task-tier <tier>                │     │
│      │    → {provider, model, base_url}                           │     │
│      │ 6. pipeline-build-prompt <task> <spec> --holdout 20%       │     │
│      │    → structured prompt (holdout criteria saved separately) │     │
│      │ 7. pipeline-state write <run-id> <task-id> executing       │     │
│      └────────────────────────────────────────────────────────────┘     │
│                                                                         │
│      ┌─ NON-DETERMINISTIC (agent) ────────────────────────────────┐     │
│      │ 8. spawn task-executor agent                               │     │
│      │    - isolation: worktree                                   │     │
│      │    - background: true (if parallel group)                  │     │
│      │    - model/maxTurns: from classify-task                    │     │
│      │    - env overrides: from model-router (if Ollama)          │     │
│      │    - input: structured prompt from build-prompt            │     │
│      │                                                            │     │
│      │    executor internally:                                    │     │
│      │      a. Read spec + task metadata                          │     │
│      │      b. Implement code changes                             │     │
│      │      c. Write tests (property-based where applicable)      │     │
│      │      d. Run tests; if fail → fix (max 3 auto-fix loops)   │     │
│      │      e. Commit with task_id reference                      │     │
│      └────────────────────────────────────────────────────────────┘     │
│                                                                         │
│    Wait for all tasks in parallel group to complete                     │
│    → Continue to Stage E for each completed task                        │
└──────────────────────────────────┬──────────────────────────────────────┘
                                   │
                                   ▼
                          (continues in Stage E)
```

---

## Stage E-H: Review, Dependency Resolution & Completion

```
┌─────────────────────────────────────────────────────────────────────────┐
│                STAGE E: Quality Gates (per task)                         │
│                                                                         │
│  Layer 1: Static Analysis                                               │
│    → fires automatically via existing pre-commit hooks                  │
│    → lint, format, type-check (handled by user's hook config)           │
│                                                                         │
│  Layer 2: Test Suite                                                    │
│    → runs as part of task-executor's internal loop                      │
│    → existing Stop hook also runs vitest on session end                 │
│                                                                         │
│  Layer 3: Coverage Regression                                           │
│    → pipeline-coverage-gate <before> <after>                            │
│    → BLOCK if any coverage metric decreased                             │
│    → if blocked: task-executor must add tests to restore coverage       │
│                                                                         │
│  Layer 4: Holdout Validation                                            │
│    → orchestrator reads holdout criteria from                           │
│      ${CLAUDE_PLUGIN_DATA}/runs/<run-id>/holdouts/<task-id>.json        │
│    → passes holdout criteria to task-reviewer for verification          │
│    → task-executor never saw these criteria                             │
│                                                                         │
│  Layer 5: Mutation Testing (if enabled)                                 │
│    → orchestrator spawns test-writer agent if mutation score < 80%      │
│    → test-writer kills surviving mutants by writing targeted tests      │
│    → re-run mutation testing; if still < 80% → log warning, continue    │
└──────────────────────────────────┬──────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────────┐
│            STAGE F: Adversarial Code Review (per task)                   │
│                                                                         │
│  ┌─ DETERMINISTIC ────────────────────────────────────────────────┐     │
│  │ 1. pipeline-detect-reviewer                                    │     │
│  │    → {reviewer: "codex"|"claude-code", command: "..."}         │     │
│  │ 2. pipeline-classify-risk output → review_rounds (1/3/5)      │     │
│  └────────────────────────────────────────────────────────────────┘     │
│                                                                         │
│  Review Loop (max review_rounds iterations):                            │
│                                                                         │
│    ┌─ Round N ──────────────────────────────────────────────────┐       │
│    │                                                            │       │
│    │  IF reviewer == "codex":                                   │       │
│    │    invoke /codex:adversarial-review --base <ref> --wait    │       │
│    │  ELSE:                                                     │       │
│    │    spawn task-reviewer agent                               │       │
│    │      - skills: review-protocol (Actor-Critic injected)     │       │
│    │      - input: diff, acceptance criteria, holdout criteria  │       │
│    │      - fresh context (zero implementation knowledge)       │       │
│    │                                                            │       │
│    │  pipeline-parse-review <output>                            │       │
│    │    → {verdict, round, findings[], criteria_check[]}        │       │
│    │                                                            │       │
│    │  IF risk == security:                                      │       │
│    │    also spawn security-reviewer agent                      │       │
│    │    also spawn architecture-reviewer agent                  │       │
│    │                                                            │       │
│    │  IF verdict == APPROVE:                                    │       │
│    │    → break loop, proceed to Stage G                        │       │
│    │                                                            │       │
│    │  IF verdict == REQUEST_CHANGES:                            │       │
│    │    → pipeline-build-prompt --fix-instructions <findings>   │       │
│    │    → re-spawn task-executor with fix instructions          │       │
│    │    → continue to Round N+1                                 │       │
│    │                                                            │       │
│    │  IF verdict == NEEDS_DISCUSSION:                           │       │
│    │    → pause for human input (if humanReviewLevel allows)    │       │
│    │    → OR escalate after timeout                             │       │
│    └────────────────────────────────────────────────────────────┘       │
│                                                                         │
│  IF max rounds exhausted with REQUEST_CHANGES:                          │
│    → mark task as needs_human_review                                    │
│    → pause pipeline for this task (continue other independent tasks)    │
│                                                                         │
│  Record: metrics_record review_round {run_id, task_id, round,           │
│           reviewer, verdict, findings_count}                            │
└──────────────────────────────────┬──────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────────┐
│            STAGE G: PR Creation & Dependency Resolution                  │
│                                                                         │
│  For each approved task:                                                │
│    1. Create PR via gh pr create                                        │
│       - title: task title                                               │
│       - body: task description + acceptance criteria + review summary   │
│       - base: depends on branching strategy (main or parent task branch)│
│                                                                         │
│    2. IF humanReviewLevel == 0 (full autonomy):                         │
│       → enable auto-merge                                               │
│    ELSE:                                                                │
│       → wait for human review/merge                                     │
│                                                                         │
│    3. IF task has downstream dependents:                                 │
│       → pipeline-wait-pr <pr-number> --timeout 45 --interval 60        │
│       → on merge: pipeline-state write <task-id> merged                 │
│       → on timeout: mark as blocked, continue other tasks               │
│       → on close-without-merge: mark as rejected                        │
│                                                                         │
│    4. IF humanReviewLevel ≥ 2 (review checkpoint):                      │
│       → pause and wait for human approval before creating PR            │
└──────────────────────────────────┬──────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      STAGE H: Completion                                │
│                                                                         │
│  After all tasks processed:                                             │
│                                                                         │
│  1. pipeline-summary <run-id>                                           │
│     → aggregate: tasks completed/failed, review rounds, quality scores, │
│       cost, tokens, model usage, PRs created                            │
│                                                                         │
│  2. spawn scribe agent (existing)                                       │
│     → update /docs for any architectural changes                        │
│                                                                         │
│  3. pipeline-cleanup <run-id>                                           │
│     → --close-issues (if all tasks for issue merged)                    │
│     → --delete-branches (merged feature branches)                       │
│     → --remove-worktrees (any remaining)                                │
│     → archive run state                                                 │
│                                                                         │
│  4. metrics_record run_end {status, duration, tokens, cost}             │
│                                                                         │
│  5. stop-gate hook fires on session end                                 │
│     → validates final state consistency                                 │
│     → removes ${CLAUDE_PLUGIN_DATA}/runs/current symlink                │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Local LLM Fallback Routing Flow

```
                    ┌──────────────────────────┐
                    │  Before each task spawn   │
                    └────────────┬─────────────┘
                                 │
                                 ▼
              ┌──────────────────────────────────────┐
              │  pipeline-model-router                │
              │    read last-headers.json              │
              │    parse tokens_remaining              │
              └──────────────────┬───────────────────┘
                                 │
                    ┌────────────┴────────────┐
                    │                         │
            tokens > 20%?              tokens ≤ 20%?
                    │                         │
                    ▼                         ▼
           ┌──────────────┐      ┌─────────────────────┐
           │ Use Anthropic │      │ Check Ollama status  │
           │ (normal path) │      │ curl localhost:11434 │
           └──────────────┘      └──────────┬──────────┘
                                             │
                                ┌────────────┴────────────┐
                                │                         │
                         Ollama running?           Ollama down?
                         Model loaded?                    │
                                │                         ▼
                                ▼                ┌────────────────┐
                    ┌──────────────────┐         │ Use Anthropic   │
                    │ Check task tier   │         │ (wait for reset)│
                    └────────┬─────────┘         └────────────────┘
                             │
                ┌────────────┴────────────┐
                │                         │
        tier in allowedTiers?     tier NOT in allowedTiers?
        (default: routine only)   (feature, security)
                │                         │
                ▼                         ▼
       ┌────────────────┐        ┌────────────────┐
       │ Use Ollama      │        │ Use Anthropic   │
       │ base_url:       │        │ (wait for reset)│
       │  localhost:11434│        └────────────────┘
       │ model:          │
       │  qwen2.5-coder  │
       └────────────────┘
```

**Environment override for Ollama tasks:**

When `pipeline-model-router` returns Ollama, the orchestrator sets these env vars before spawning `task-executor`:

```
ANTHROPIC_BASE_URL=http://localhost:11434/v1
ANTHROPIC_AUTH_TOKEN=dummy
```

The task-executor agent operates identically — it doesn't know it's running on a local model. Quality gates are unchanged: if the local model produces inferior code, it fails the same gates and triggers the same fix-retry loop.

---

## Orchestration Design

### Orchestrator-as-Agent Pattern

The plugin has no process manager primitive. The `pipeline-orchestrator` agent IS the control loop. It:

- **Makes judgment calls**: retry vs skip, escalate vs continue, which reviewer feedback to prioritize
- **Delegates deterministic work**: every validation, state check, classification, and data transformation is a bin/ script call via Bash

**Why not a pure script orchestrator?**

A shell script cannot spawn Claude Code agents. The Agent tool is only available to agents (and the user session). The orchestrator MUST be an agent to use Agent tool for spawning subagents.

**Why not pure agent logic?**

Agent instructions are followed ~70% of the time. State management, circuit breakers, and validation MUST be 100% reliable. Bin scripts guarantee this.

**The hybrid:**

```
Orchestrator Agent (judgment + control flow)
  │
  ├── Bash: pipeline-* scripts (deterministic, 100% reliable)
  │     ├── state transitions
  │     ├── circuit breaker checks
  │     ├── classification
  │     ├── prompt construction
  │     └── review parsing
  │
  └── Agent: subagent spawns (non-deterministic, judgment tasks)
        ├── spec-generator (code generation)
        ├── task-executor (code generation)
        ├── task-reviewer (code review)
        ├── spec-reviewer (spec quality — existing)
        ├── security-reviewer (security review — existing)
        ├── architecture-reviewer (architecture review — existing)
        ├── test-writer (mutation killing — existing)
        └── scribe (docs update — existing)
```

### Parallel Execution

Tasks in the same parallel group can run concurrently. The orchestrator:

1. Reads parallel groups from `pipeline-validate-tasks` output
2. For each group, spawns up to `maxConcurrent` (default 3) task-executors as background agents with worktree isolation
3. Waits for all tasks in the group to complete (via SubagentStop hook writing completion status)
4. Proceeds to next parallel group

**Worktree isolation ensures:**

- No git conflicts between parallel tasks
- Each executor has its own branch and working tree
- Merging happens via PR, not local git merge

### Turn Budget

The orchestrator has 200 turns. Approximate turn consumption per task:

| Operation                                      | Turns   |
| ---------------------------------------------- | ------- |
| Circuit breaker + state checks (3 Bash calls)  | 3       |
| Classification (2 Bash calls)                  | 2       |
| Model routing + prompt building (2 Bash calls) | 2       |
| Spawn task-executor (1 Agent call)             | 1       |
| Wait + state update (2 calls)                  | 2       |
| Spawn reviewer + parse (3 calls)               | 3       |
| State update + PR creation (3 calls)           | 3       |
| **Total per task**                             | **~16** |

At 200 turns: ~12 tasks safely, ~15 tasks if reviews pass first round. For 20+ task pipelines, the orchestrator may need to be split into phases (spec phase orchestrator → execution phase orchestrator).

---

## State Management

### Directory Structure

```
${CLAUDE_PLUGIN_DATA}/
├── config.json                    # Populated from userConfig at init
├── last-headers.json              # Last Anthropic API response headers (for rate limiting)
├── pipeline.lock                  # Lock file (PID + timestamp)
├── metrics.db                     # SQLite database (MCP server)
│
├── runs/
│   ├── current -> run-20260407-123456/   # Symlink to active run
│   │
│   ├── run-20260407-123456/
│   │   ├── state.json             # Run state
│   │   ├── audit.jsonl            # Append-only audit log
│   │   ├── metrics.jsonl          # Append-only metrics (legacy, alongside SQLite)
│   │   ├── holdouts/
│   │   │   ├── task_1.json        # Withheld acceptance criteria for task_1
│   │   │   └── task_3.json
│   │   └── reviews/
│   │       ├── task_1_round_1.json
│   │       ├── task_1_round_2.json
│   │       └── task_3_round_1.json
│   │
│   └── run-20260406-091500/       # Previous run (or archived)
│       └── ...
│
└── archive/                       # Completed runs moved here by pipeline-cleanup
    └── run-20260405-143000/
        └── ...
```

### `state.json` Schema

```json
{
  "run_id": "run-20260407-123456",
  "status": "running|completed|partial|failed|interrupted",
  "mode": "discover|prd|task|resume",
  "started_at": "2026-04-07T12:34:56Z",
  "updated_at": "2026-04-07T13:15:00Z",
  "ended_at": null,

  "input": {
    "issue_numbers": [42, 43],
    "resumed_from": null
  },

  "spec": {
    "status": "pending|generating|reviewing|approved|failed",
    "path": "/path/to/spec/dir",
    "review_iterations": 2,
    "review_score": 52
  },

  "tasks": {
    "task_1": {
      "status": "pending|executing|reviewing|done|failed|interrupted|needs_human_review",
      "tier": "simple|medium|complex",
      "risk_tier": "routine|feature|security",
      "model_used": "sonnet",
      "provider": "anthropic|ollama",
      "branch": "dark-factory/42/task-1-setup-auth",
      "worktree_path": "/tmp/worktrees/task_1",
      "pr_number": 123,
      "pr_status": "open|merged|closed",
      "review_rounds": [
        {
          "round": 1,
          "reviewer": "codex|claude-code",
          "verdict": "REQUEST_CHANGES",
          "blocking_findings": 2,
          "timestamp": "2026-04-07T12:45:00Z"
        },
        {
          "round": 2,
          "reviewer": "codex|claude-code",
          "verdict": "APPROVE",
          "blocking_findings": 0,
          "timestamp": "2026-04-07T12:55:00Z"
        }
      ],
      "quality_gates": {
        "coverage": { "passed": true, "delta": 0.9 },
        "holdout": {
          "passed": true,
          "criteria_checked": 2,
          "criteria_passed": 2
        },
        "mutation": { "passed": true, "score": 85 }
      },
      "started_at": "2026-04-07T12:40:00Z",
      "ended_at": "2026-04-07T13:00:00Z",
      "tokens_used": 45000,
      "error": null
    },
    "task_2": {
      "status": "executing",
      "...": "..."
    }
  },

  "circuit_breaker": {
    "tasks_completed": 3,
    "consecutive_failures": 0,
    "runtime_minutes": 26
  },

  "cost": {
    "total_tokens": 120000,
    "estimated_usd": 0.85,
    "by_model": {
      "opus": { "tokens": 30000, "usd": 0.45 },
      "sonnet": { "tokens": 80000, "usd": 0.35 },
      "ollama/qwen2.5-coder:7b": { "tokens": 10000, "usd": 0.0 }
    }
  }
}
```

### State Transitions

```
Task lifecycle:
  pending → executing → reviewing → done
                │           │
                │           └→ executing (fix round)
                │           └→ needs_human_review (max rounds)
                └→ failed
                └→ interrupted (session ended mid-task)

Run lifecycle:
  running → completed (all tasks done/failed)
         → partial (some tasks done, some failed)
         → failed (circuit breaker tripped)
         → interrupted (session ended mid-run)
```

All state writes are atomic: write to temp file, then `mv` to target. This prevents corrupt state from partial writes.

---

## Resume Capability

### How Resume Works

1. User invokes `/dark-factory:run resume`
2. Command calls `pipeline-state interrupted <run-id>` to find interrupted run
3. If found, calls `pipeline-state resume-point <run-id>` → returns first incomplete task
4. Spawns orchestrator with `--resume <run-id>` context
5. Orchestrator reads state.json, skips completed tasks, resumes from resume point

### What Gets Preserved on Interrupt

- All completed task statuses and their PRs
- All review verdicts and quality gate results
- Audit log entries
- Spec and tasks.json
- Feature branches and worktrees (may need cleanup)

### What Gets Rebuilt on Resume

- Orchestrator re-reads execution order from `pipeline-validate-tasks`
- Skips tasks with status `done` or `merged`
- Re-attempts tasks with status `interrupted` or `executing` (from beginning)
- Tasks with status `failed` are skipped (unless `--retry-failed` flag)
- Tasks with status `needs_human_review` are skipped (unless human has since provided input)

### Edge Cases

| Scenario                           | Behavior                                               |
| ---------------------------------- | ------------------------------------------------------ |
| Interrupted during spec generation | Re-run spec generation from scratch                    |
| Interrupted during task execution  | Re-run task from scratch (worktree may be dirty)       |
| Interrupted during review          | Re-run review (reviewer has no memory anyway)          |
| Interrupted during PR wait         | Re-check PR status; if merged, continue                |
| Worktree exists but is dirty       | `pipeline-branch worktree-remove` + recreate           |
| Multiple interrupted runs          | Resume most recent; list all via `pipeline-state list` |

---

## Human Review Integration Points

Based on `humanReviewLevel` (0-4), the pipeline pauses at different points:

| Level                 | Pauses At                                                                                     | How Pipeline Pauses                                    | How It Resumes                                       |
| --------------------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------ | ---------------------------------------------------- |
| 4 (full supervision)  | After spec, after each task decomposition, after each task execution, after each review round | Writes `awaiting_human` status, prints context to user | User runs `/dark-factory:run resume` after reviewing |
| 3 (spec approval)     | After spec generation + review                                                                | Same                                                   | Same                                                 |
| 2 (review checkpoint) | After adversarial review, before PR creation                                                  | Same                                                   | Same                                                 |
| 1 (PR approval)       | Never — creates PR and waits for human merge                                                  | `pipeline-wait-pr` polls until merged                  | Automatic on merge                                   |
| 0 (full autonomy)     | Never — enables auto-merge                                                                    | No pause                                               | Fully automatic                                      |

At each pause point:

1. `pipeline-state write <run-id> <key> awaiting_human`
2. Orchestrator outputs context: what was done, what's next, what needs review
3. Pipeline session ends (stop-gate hook marks state)
4. User reviews at their leisure
5. User runs `/dark-factory:run resume` to continue
