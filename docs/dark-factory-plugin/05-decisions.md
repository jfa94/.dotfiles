# Dark Factory Plugin — Design Decisions & Open Questions

## Design Decisions

### Decision 1: Deterministic-First Architecture

**Choice:** ~3:1 ratio of deterministic components (bin scripts, hooks) to non-deterministic (agents). If a step CAN be a script, it MUST be a script.

**Alternatives considered:**

| Option                                       | Pros                                                            | Cons                                                                                                   |
| -------------------------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| **A: Agent-heavy (7+ agents, 4+ skills)**    | Natural language flexibility, easier to write                   | Agent instructions followed ~70%, non-deterministic state management, hard to test                     |
| **B: Script-heavy (pure Bash orchestrator)** | 100% deterministic, testable, debuggable                        | Cannot spawn Claude Code agents (Agent tool only available to agents), loses plugin framework benefits |
| **C: Hybrid — deterministic-first (chosen)** | Scripts for reliability where needed, agents for judgment tasks | More components to maintain, two paradigms to reason about                                             |

**Evidence:**

- Concrete operational rules outperform abstract directives by 123% (research report)
- Agent instructions followed ~70% of the time; hooks/scripts enforce at 100%
- METR RCT: perception gap of 39pp between believed and actual AI productivity — unreliable self-assessment extends to agents

**Result:** 21 bin scripts, 4 plugin agents, 4 hooks, 8+ existing agents reused. Scripts handle validation, state, classification, parsing. Agents handle code generation, review, spec creation.

---

### Decision 2: Orchestrator-as-Agent with Script Delegation

**Choice:** The orchestrator is an agent (required to spawn subagents via Agent tool), but it delegates ALL deterministic work to bin/ scripts via Bash calls.

**Why not a pure script orchestrator?**
The Claude Code plugin system has no process manager primitive. Only agents can use the `Agent` tool to spawn subagents. A shell script cannot spawn `spec-generator`, `task-executor`, or `task-reviewer` agents.

**Why not pure agent orchestration?**
State management, circuit breakers, DAG traversal, and classification MUST be 100% reliable. Agent instructions for these would fail ~30% of the time — unacceptable for pipeline control flow.

**Risk:** The orchestrator itself is non-deterministic. It might not call bin scripts in the right order, might misinterpret their output, or might skip steps.

**Mitigations:**

1. **State persistence** — every state transition is written by a bin script. If the orchestrator crashes/misbehaves, state reflects reality.
2. **Circuit breakers** — deterministic limits prevent runaway execution regardless of orchestrator behavior.
3. **Idempotent scripts** — re-running a script with the same input produces the same output. Safe to retry.
4. **Resume capability** — interrupted runs recover from persisted state, not agent memory.
5. **Explicit instructions** — orchestrator instructions are operational and concrete, not abstract directives.

---

### Decision 3: Reuse Existing Agents by Reference

**Choice:** Spawn the user's existing agents (spec-reviewer, code-reviewer, architecture-reviewer, security-reviewer, test-writer, scout, simple-task-runner, scribe) by name via the Agent tool rather than creating plugin-internal copies.

**Alternatives considered:**

- **Copy agents into plugin:** Guarantees stable interface, but diverges from user's evolving setup. Updates to user's agents don't propagate.
- **Reuse by reference (chosen):** User improvements propagate automatically. Pipeline benefits from the user's customizations.

**Trade-off:** If the user modifies an agent's output format, the pipeline's `pipeline-parse-review` script might break. Mitigated by:

- Parsing is best-effort with fallback patterns
- Review output format is specified by `review-protocol` skill, which we inject
- Spec-reviewer has a stable scoring format (score/60, PASS/NEEDS_REVISION)

---

### Decision 4: Separate task-reviewer from code-reviewer

**Choice:** Create a new `task-reviewer` agent in the plugin rather than reusing the existing `code-reviewer` directly.

**Why:**

1. `task-reviewer` adds acceptance-criteria validation (checking each criterion against code with PASS/FAIL evidence)
2. `task-reviewer` validates holdout criteria (criteria the executor never saw)
3. `task-reviewer` outputs machine-parseable structured format (parsed by `pipeline-parse-review`)
4. `task-reviewer` is round-aware (includes round number, focuses on previous findings in subsequent rounds)

**The existing `code-reviewer` is still used** as a fallback when Codex is unavailable AND `review-protocol` skill needs to be injected for adversarial posture.

**Result:** `task-reviewer` is the primary pipeline reviewer. `code-reviewer` is a fallback option. Both can receive `review-protocol` skill injection.

---

### Decision 5: Holdout Specs in Plugin Data, Not Repo

**Choice:** Store withheld acceptance criteria in `${CLAUDE_PLUGIN_DATA}/holdouts/`, outside the git worktree.

**Why:**

- The task-executor runs in an isolated worktree. If holdout criteria were in the repo, the executor could read them.
- `${CLAUDE_PLUGIN_DATA}` is a plugin-specific directory outside any git repo. Agents operating in worktrees cannot access it unless explicitly given the path.
- The `pipeline-build-prompt` script writes holdouts to this directory. The orchestrator passes holdout criteria to the task-reviewer separately.

**Trade-off:** Holdout criteria are not version-controlled. If a run is interrupted and resumed, holdouts must still exist in plugin data. Mitigated by: holdouts are stored per-run, and resume reads from the same run directory.

---

### Decision 6: Three-Tier Component Model (Hooks → Scripts → Agents)

**Choice:** Three distinct tiers of components with clear responsibility boundaries:

| Tier                            | Reliability                    | Responsibility                                                       | Example                                               |
| ------------------------------- | ------------------------------ | -------------------------------------------------------------------- | ----------------------------------------------------- |
| **Hooks** (un-bypassable)       | 100% enforcement               | Safety constraints that MUST never be violated                       | Branch protection, audit logging                      |
| **Bin scripts** (deterministic) | 100% correct given valid input | Logic that has a single correct answer                               | Validation, state management, classification, parsing |
| **Agents** (non-deterministic)  | ~70% instruction following     | Tasks requiring judgment, creativity, natural language understanding | Code generation, code review, spec creation           |

**Why not just hooks + agents?**
Hooks fire on specific events (PreToolUse, PostToolUse, Stop, SubagentStop). They cannot be called on-demand by the orchestrator. Bin scripts fill the gap: on-demand deterministic logic that agents call via Bash.

**Why not just scripts + agents?**
Hooks are un-bypassable. Even if the orchestrator agent ignores its instructions, hooks still fire. Branch protection via hook means force-push to main is blocked regardless of what any agent tries to do.

---

### Decision 7: No External State Server

**Choice:** JSON files in `${CLAUDE_PLUGIN_DATA}` for all state management.

**Alternatives considered:**

- **SQLite:** Better querying, atomic transactions. But adds dependency, harder to inspect, and the current pipeline uses JSON files successfully.
- **Redis/PostgreSQL:** Overkill for single-machine pipeline.
- **JSON files (chosen):** Same pattern as Bash pipeline. Human-readable, trivially inspectable with `jq`, no dependencies.

**Exception:** The metrics MCP server uses SQLite (`metrics.db`) because metrics queries benefit from SQL (aggregation, filtering, time ranges). State management stays JSON.

**Atomic writes:** All state writes use `write-to-temp + mv` pattern to prevent corruption from partial writes or interrupted sessions.

---

### Decision 8: Worktree Isolation Replaces Directory Locking

**Choice:** Each task-executor runs in its own git worktree. The `pipeline-lock` script is a secondary safety mechanism (prevents two orchestrators, not two executors).

**Why worktrees over locks:**

- **True isolation:** Each executor has its own working directory and branch. No possibility of git conflicts between concurrent tasks.
- **No deadlocks:** Lock-based concurrency can deadlock if a process dies holding a lock. Worktrees don't have this problem.
- **Native support:** Claude Code's `isolation: "worktree"` agent frontmatter creates and manages worktrees automatically.

**Lock still exists because:** Two orchestrator instances running simultaneously would cause state corruption. The lock prevents this edge case (e.g., user accidentally runs `/dark-factory:run` twice).

---

### Decision 9: Adversarial Review with Vendor Fallback

**Choice:** Use OpenAI Codex's adversarial review mode as primary reviewer when available; fall back to Claude Code's code-reviewer + review-protocol skill.

**Why Codex as primary:**

- Codex has a purpose-built `/codex:adversarial-review` command designed for threat-modeling code
- Using a DIFFERENT vendor for review than for implementation creates genuine independence (different model biases, different failure modes)
- Actor-Critic pattern is strongest when Actor and Critic are distinct systems

**Why Claude Code as fallback:**

- Codex may not be installed or authenticated
- Fallback must be fully functional, not degraded
- `review-protocol` skill injects adversarial posture into any reviewer
- The existing `code-reviewer` agent already has a strong review methodology

**Detection is deterministic:** `pipeline-detect-reviewer` checks Codex availability via `command -v codex && codex status --auth`. No agent judgment involved.

**Trade-off:** External dependency on Codex (npm package, OpenAI auth). Mitigated: detection is fast, fallback is automatic, and the fallback reviewer is fully capable.

---

### Decision 10: Local LLM Fallback via Ollama

**Choice:** When Anthropic rate limits approach threshold, route routine-tier tasks to local Ollama models instead of stalling the pipeline.

**Why not always use cloud models?**
Rate limits cause pipeline stalls. A 20-task pipeline might hit limits mid-execution, wasting all prior work's context and forcing a resume.

**Why not always use local models?**
Local model quality is significantly lower than cloud models. Research evidence:

- Qwen 2.5-Coder 7B: good for simple tasks, but struggles with complex logic
- Even Qwen 2.5-Coder 32B (requiring 24GB+ VRAM) is not comparable to Claude for security-critical or architecturally complex code

**Restrictions:**

- Only `routine` tier tasks (by default) routed to local models
- `feature` and `security` tier tasks ALWAYS use cloud (wait for rate limit reset if needed)
- Quality gates are unchanged — local model output must pass identical gates
- Configurable: `userConfig.localLlm.allowedTiers` can be expanded by user

**Detection is proactive:** `pipeline-model-router` parses Anthropic response headers (`anthropic-ratelimit-tokens-remaining`) BEFORE hitting 429. Threshold is configurable (default 20% remaining).

**Advanced option:** LiteLLM proxy at `http://localhost:4000` for unified routing. Adds dependency but simplifies multi-provider management. Optional — not required for basic Ollama fallback.

---

### Decision 11: Existing User Hooks Fire Automatically

**Choice:** Do NOT duplicate any of the user's existing hooks in the plugin. They fire automatically for all plugin agents.

**Why:**

- The user's `.claude/settings.json` defines hooks for pre-commit, pre-push, dangerous patterns, SQL safety, etc.
- These hooks fire for ALL agent sessions, including plugin agents
- Duplicating them in the plugin's `hooks.json` would cause double-execution
- The user may customize these hooks — the plugin should inherit, not override

**Plugin-specific hooks** (branch-protection, run-tracker, stop-gate, subagent-stop-gate) cover pipeline-specific concerns that the user's hooks don't address.

---

## Plugin System Constraints & Workarounds

### Constraint: Agents Cannot Use Hooks

**Impact:** Plugin agents cannot have per-agent hook configurations. All hooks in `hooks.json` fire for all agents.

**Workaround:** Hook scripts check context to decide whether to act:

- `run-tracker` checks if `${CLAUDE_PLUGIN_DATA}/runs/current` exists (only logs during active pipeline runs)
- `branch-protection` checks the target branch (applies universally — this is desirable)

### Constraint: Agents Cannot Use mcpServers

**Impact:** Individual agents cannot declare MCP server dependencies in their frontmatter.

**Workaround:** MCP servers are declared in `.mcp.json` at the plugin root. They're available to all agents in the plugin. The `pipeline-metrics` MCP server tools are accessible from the orchestrator agent.

### Constraint: Agents Cannot Use permissionMode

**Impact:** Cannot set per-agent permission modes (e.g., read-only for reviewers).

**Workaround:** `settings.json` at plugin root defines default permissions. Reviewer agents are instructed to only use Read/Grep/Glob/Bash (no Write/Edit). This is an instruction (~70% reliable), not enforcement. Mitigated: reviewers don't need to write files; if they accidentally do, it's in a worktree that gets cleaned up.

### Constraint: No Process Manager Primitive

**Impact:** Cannot define a Bash-like pipeline orchestration flow declaratively.

**Workaround:** Orchestrator-as-agent pattern (Decision 2). The agent IS the control loop, delegating deterministic work to scripts.

### Constraint: Background Agent Output Reading

**Impact:** When the orchestrator spawns a background agent, how does it read the result?

**Workaround approaches (to be validated):**

1. **SubagentStop hook** writes completion status to state files → orchestrator reads state
2. **Agent tool return** — when a background agent completes, the orchestrator receives its output on the next turn
3. **Polling state files** — orchestrator periodically checks `pipeline-state` for task status changes

### Constraint: Turn Budget (200 turns)

**Impact:** Orchestrator at 200 turns may not be sufficient for 20+ task pipelines.

**Workaround options:**

1. **Phase orchestrators** — split into spec-phase (40 turns) and execution-phase (160 turns) orchestrators
2. **Efficient turn usage** — batch multiple bin script calls per turn where possible
3. **Reduce per-task turns** — current estimate is ~16 turns/task; optimize by combining related calls

---

## Open Questions (Require Validation)

### 1. Cross-Boundary Agent Spawning

**Question:** Can a plugin agent spawn an agent defined in the user's `.claude/agents/` directory?

**Expected:** Yes — the Agent tool takes a `subagent_type` parameter that should resolve against all available agents (plugin + user).

**Validation:** Test with `claude --plugin-dir ./dark-factory-plugin` and have the orchestrator spawn `spec-reviewer`.

**Fallback if no:** Copy agent definitions into the plugin (loses auto-propagation of user improvements).

### 2. Background Agent Result Reading

**Question:** When the orchestrator spawns a background agent (`run_in_background: true`), how does it receive the result?

**Expected:** The system notifies the orchestrator when the background agent completes, and the result is available on the next turn.

**Validation:** Test background agent spawning in a plugin context.

**Fallback if notification doesn't work:** Use SubagentStop hook to write results to state files; orchestrator polls state.

### 3. Hook Context Scoping

**Question:** Can hooks detect whether they're firing during a dark-factory pipeline run vs normal user activity?

**Proposed:** Hooks check for existence of `${CLAUDE_PLUGIN_DATA}/runs/current/state.json`.

**Validation:** Verify that `${CLAUDE_PLUGIN_DATA}` is available as an environment variable in hook scripts.

**Fallback if env var unavailable:** Use a well-known path (`~/.dark-factory/runs/current`) instead of plugin data directory.

### 4. Bin Script Environment Variables

**Question:** Do bin/ scripts automatically get `${CLAUDE_PLUGIN_DATA}` and `${CLAUDE_PLUGIN_ROOT}` as environment variables when called via Bash tool?

**Expected:** Yes — the plugin system should inject these into the environment for all plugin components.

**Validation:** Add `echo $CLAUDE_PLUGIN_DATA` to a test bin script, run via agent.

**Fallback if no:** Pass paths as arguments to every script call; store in a config file at a known location.

### 5. Codex Plugin Availability

**Question:** Is the Codex Claude Code plugin stable and publicly available? Do `/codex:setup` and `/codex:adversarial-review` commands exist?

**Risk:** Codex integration details were gathered from web research; the plugin may not be GA or may have a different API.

**Validation:** Check npm registry for `@openai/codex`, test installation and auth flow.

**Fallback:** Claude Code's code-reviewer + review-protocol skill is fully functional as fallback. Codex is an enhancement, not a requirement.

### 6. Ollama Model Routing via Environment Variables

**Question:** Can `ANTHROPIC_BASE_URL` be overridden per-subagent spawn, or is it process-global?

**Expected:** If the orchestrator sets env vars before spawning a subagent, the subagent should inherit them.

**Validation:** Test spawning an agent with env overrides in Agent tool parameters.

**Fallback if process-global:** Use LiteLLM proxy as an intermediary — always point at `http://localhost:4000`, configure LiteLLM to route based on model name.

### 7. Local Model Tool-Use Compatibility

**Question:** Does Claude Code's agent framework work correctly with Ollama models (non-Anthropic tool-use format)?

**Expected:** Ollama's OpenAI-compatible API (`/v1/chat/completions`) supports function calling for Llama 3.1+ and Qwen 2.5+ models. Claude Code may or may not handle OpenAI-format tool-use responses.

**Validation:** Set `ANTHROPIC_BASE_URL` to Ollama, run a simple agent task with tool calls.

**Fallback if incompatible:** Local models used only via direct Bash invocation (not via Agent tool). Limits local fallback to simpler use cases.

### 8. Turn Budget Sufficiency

**Question:** Is 200 turns sufficient for a 20-task pipeline?

**Estimate:** ~16 turns/task × 20 tasks = 320 turns. Exceeds budget.

**Options:**

1. Phase orchestrators (spec phase + execution phase)
2. Increase maxTurns if the plugin system allows >200
3. Batch more operations per turn
4. Accept limit of ~12 tasks per orchestrator session

**Validation:** Run a real pipeline and measure actual turn consumption.

---

## Risk Assessment

| Risk                                                | Likelihood | Impact                                         | Mitigation                                                |
| --------------------------------------------------- | ---------- | ---------------------------------------------- | --------------------------------------------------------- |
| Orchestrator ignores script delegation instructions | Medium     | High — unreliable state                        | Circuit breakers + state persistence + resume             |
| Turn budget exceeded for large pipelines            | High       | Medium — pipeline stops mid-run                | Phase orchestrators + resume capability                   |
| Codex plugin not available/stable                   | Medium     | Low — fallback is fully functional             | Claude Code reviewer with review-protocol skill           |
| Ollama model quality insufficient                   | Medium     | Low — quality gates catch bad output           | Tier restrictions + unchanged quality gates               |
| Cross-boundary agent spawning doesn't work          | Low        | High — must copy all agents into plugin        | Test early; fallback: copy agent definitions              |
| Rate limit detection via headers unreliable         | Low        | Medium — reactive (429) instead of proactive   | Catch 429 errors as secondary detection                   |
| User modifies existing agent breaking pipeline      | Low        | Medium — parse-review or spec validation fails | Best-effort parsing with fallback patterns                |
| Worktree cleanup fails leaving orphans              | Medium     | Low — disk space waste                         | pipeline-cleanup + manual `git worktree prune`            |
| State file corruption from concurrent writes        | Low        | High — pipeline state lost                     | Atomic writes (tmp + mv) + lock for orchestrator          |
| EU AI Act compliance gaps in audit log              | Low        | High — legal exposure                          | Tamper-evident sequence numbers + log completeness checks |
