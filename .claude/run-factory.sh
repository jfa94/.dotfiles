#!/usr/bin/env bash
# run-factory.sh — combined autonomous pipeline: scaffolding + task execution
set -euo pipefail

# --- Resolve paths ---
SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# --- Help ---
show_help() {
  cat <<'HELP'
Usage: .claude/run-factory.sh [<feature-spec-name>]
       .claude/run-factory.sh --issue <number>
       .claude/run-factory.sh --discover

Autonomous factory pipeline — generates specs from PRDs, reviews them,
then executes each task on isolated branches with quality gates.

Modes:
  <feature-spec-name>   Execute tasks from an existing spec (interactive if omitted)
  --issue <number>      Generate specs from a [PRD] GitHub issue, review, then execute
  --discover            Find all open [PRD] issues, prompt for parallel/sequential

Prerequisites:
  claude    Claude Code CLI
  jq        JSON processor
  gh        GitHub CLI (authenticated)
  pnpm      Package manager
  git       With a configured remote

Pipeline steps:
  0. (--issue/--discover) Generate specs from PRD, review via spec-reviewer
     agent, refine until approved or max iterations reached
  1. Swap settings.json to autonomous mode (restored on exit)
  2. Reconcile staging with develop (create if needed, ff or merge if behind)
  2.5 Deploy quality gate workflow to .github/workflows/ if missing
  2.6 Set up branch protection on staging (require quality + mutation checks)
  3. Check scaffolding (claude-progress.json, feature-status.json, init.sh)
     — runs AI setup if any are missing
  4. For each task (in dependency order):
     a. Check dependencies — skip if any dep failed or was skipped
     b. Wait for dependency PRs to auto-merge via GitHub Actions (45m timeout)
     c. Pull latest staging to pick up merged changes
     d. Branch feat/<task-id> from staging
     e. Run Claude Code in headless mode
     f. Quality gate (pnpm quality)
     f2. Code review via separate Claude session (if ENABLE_CODE_REVIEW=true)
     g. Push + open PR against staging with auto-merge enabled
  5. Print summary (ok/failed/skipped) and restore settings

Logs are written to logs/<timestamp>-<spec-name>/.

Environment variables:
  MAX_TASKS                Max tasks before circuit breaker (default: 20)
  MAX_MINUTES              Max pipeline runtime in minutes (default: 360)
  MAX_CONSECUTIVE_FAILURES Max consecutive failures before stop (default: 3)
  MAX_RETRIES              Max retries per failed task (default: 2, 0 = no retry)
  MUTATION_FEEDBACK        Enable mutation testing feedback loop (default: false)
  ENABLE_CODE_REVIEW       Enable AI code review before PR merge (default: true)
  REVIEW_TURNS             Max turns for code review session (default: 40)
  MAX_SPEC_ITERATIONS      Max spec review-refine iterations (default: 3)
  SPEC_GEN_TURNS           Turn budget for spec generation session (default: 80)
  SPEC_PASS_THRESHOLD      Min total score for spec approval, out of 60 (default: 48)
HELP
}

# --- Parse arguments ---
MODE=""
ISSUE_NUMBER=""
SKIP_SETTINGS_SWAP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_help
      exit 0
      ;;
    --issue)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --issue requires an issue number."
        exit 1
      fi
      MODE="issue"
      ISSUE_NUMBER="$2"
      shift 2
      ;;
    --discover)
      MODE="discover"
      shift
      ;;
    --skip-settings-swap)
      SKIP_SETTINGS_SWAP=true
      shift
      ;;
    -*)
      echo "Unknown flag: $1"
      echo "Run with --help for usage."
      exit 1
      ;;
    *)
      MODE="named"
      SPEC_NAME="$1"
      shift
      ;;
  esac
done

if [[ -z "$MODE" ]]; then
  MODE="interactive"
fi

# --- Spec generation defaults ---
MAX_SPEC_ITERATIONS=${MAX_SPEC_ITERATIONS:-3}
SPEC_GEN_TURNS=${SPEC_GEN_TURNS:-80}
SPEC_PASS_THRESHOLD=${SPEC_PASS_THRESHOLD:-48}

# --- Settings swap with trap (early, so spec generation has autonomous permissions) ---
SETTINGS_LOCAL="$SCRIPT_DIR/settings.local.json"
SETTINGS_LOCAL_BAK="$SCRIPT_DIR/settings.local.json.factory-bak"
SETTINGS_AUTO="$SCRIPT_DIR/settings.autonomous.json"

STATUS_FILE=""
PR_FILE=""
FACTORY_TMPDIR=$(mktemp -d /tmp/factory-run.XXXXXX)
LOCK_DIR=""

cleanup() {
  if [[ "$SKIP_SETTINGS_SWAP" == "true" ]]; then
    # Child process — don't touch settings, parent manages them
    [[ -n "$STATUS_FILE" ]] && rm -f "$STATUS_FILE"
    [[ -n "$PR_FILE" ]] && rm -f "$PR_FILE"
    rm -rf "$FACTORY_TMPDIR"
    return
  fi
  if [[ -f "$SETTINGS_LOCAL_BAK" ]]; then
    mv "$SETTINGS_LOCAL_BAK" "$SETTINGS_LOCAL"
    echo "Settings restored."
  elif [[ -f "$SETTINGS_LOCAL" ]]; then
    rm -f "$SETTINGS_LOCAL"
    echo "Settings restored."
  fi
  [[ -n "$STATUS_FILE" ]] && rm -f "$STATUS_FILE"
  [[ -n "$PR_FILE" ]] && rm -f "$PR_FILE"
  [[ -n "$LOCK_DIR" ]] && rmdir "$LOCK_DIR" 2>/dev/null || true
  rm -rf "$FACTORY_TMPDIR"
}
trap cleanup EXIT

if [[ "$SKIP_SETTINGS_SWAP" != "true" ]]; then
  # Prevent concurrent factory runs from racing on settings/branches
  LOCK_DIR="/tmp/factory-$(echo "$PROJECT_DIR" | tr '/' '-').lock.d"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Error: another factory instance is running for this project."
    echo "  Lock: $LOCK_DIR"
    exit 1
  fi

  if [[ ! -f "$SETTINGS_AUTO" ]]; then
    echo "Error: settings.autonomous.json not found at $SETTINGS_AUTO"
    exit 1
  fi

  if [[ -f "$SETTINGS_LOCAL" ]]; then
    cp "$SETTINGS_LOCAL" "$SETTINGS_LOCAL_BAK"
  fi
  cp "$SETTINGS_AUTO" "$SETTINGS_LOCAL"
  echo "Settings swapped to autonomous mode."
fi

# --- Helpers ---
slugify_title() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/\[prd\] *//' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//'
}

# --- Spec generation + review (Phase 0) ---
generate_and_review_spec() {
  local issue_number=$1
  local issue_json
  issue_json=$(gh issue view "$issue_number" --json title,body)
  local issue_title
  issue_title=$(echo "$issue_json" | jq -r '.title')
  local issue_body
  issue_body=$(echo "$issue_json" | jq -r '.body')

  SPEC_NAME=$(slugify_title "$issue_title")
  if [[ -z "$SPEC_NAME" ]]; then
    echo "Error: could not derive spec name from title '$issue_title'. Add a descriptive title after [PRD]."
    return 1
  fi
  SPEC_DIR="specs/features/$SPEC_NAME"
  TASKS_FILE="$SPEC_DIR/tasks.json"

  echo "=== Generating spec from issue #$issue_number: $issue_title ==="
  echo "  Spec name: $SPEC_NAME"

  local log_dir="logs/$(date +%Y%m%d-%H%M%S)-spec-gen-$SPEC_NAME"
  mkdir -p "$log_dir"

  # Read prd-to-spec skill and modify for autonomous use
  local skill_path="$SCRIPT_DIR/skills/prd-to-spec/SKILL.md"
  if [[ ! -f "$skill_path" ]]; then
    echo "Error: prd-to-spec skill not found at $skill_path"
    return 1
  fi

  # Strip YAML frontmatter from skill (expects --- on line 1 and closing ---)
  local skill_body
  if ! head -1 "$skill_path" | grep -q '^---$'; then
    echo "Warning: skill file missing YAML frontmatter, using full content"
    skill_body=$(cat "$skill_path")
  else
    skill_body=$(awk 'BEGIN{n=0} /^---$/{n++; if(n==2){found=1; next}} found' "$skill_path")
  fi

  local log_file="$log_dir/spec-gen.json"

  # Build prompt in a temp file — use quoted heredocs + printf to avoid shell injection
  # from PRD body content (issue_body could contain $(), backticks, etc.)
  local prompt_file
  prompt_file=$(mktemp "$FACTORY_TMPDIR/prompt.XXXXXX")

  # Write static header (quoted heredoc = no expansion)
  cat > "$prompt_file" << '__FACTORY_HEADER__'
You are generating implementation specs from a PRD stored in a GitHub issue.

__FACTORY_HEADER__

  # Inject dynamic values safely via printf (no shell interpretation)
  printf '## PRD (from issue #%s)\n\n**Title:** %s\n\n%s\n\n---\n\n' \
    "$issue_number" "$issue_title" "$issue_body" >> "$prompt_file"

  # Write instructions — quoted heredoc for static text, printf for dynamic values
  cat >> "$prompt_file" << '__FACTORY_INSTRUCTIONS__'
## Instructions

Follow these spec-generation instructions. IMPORTANT modifications:
- For step 1: the PRD is provided above, skip searching for issues.
- For step 5 (quiz the user): SKIP this step. Use your best judgment for granularity.
  A spec-reviewer agent will review your output separately.
- For step 8 (create tasks): ALWAYS create tasks.json. Do not ask for confirmation.
__FACTORY_INSTRUCTIONS__

  printf -- '- Write metadata.json with: { "prd_issue": %s }\n\n%s\n\n---\n\n' \
    "$issue_number" "$skill_body" >> "$prompt_file"

  cat >> "$prompt_file" << '__FACTORY_REVIEW__'
## Review loop

After generating all spec files and tasks.json, you MUST spawn the spec-reviewer agent
(via the Agent tool with subagent_type 'spec-reviewer') to review your work. Pass it:
__FACTORY_REVIEW__

  printf '  "Review the spec in %s. Read all .md files and tasks.json.\n' "$SPEC_DIR" >> "$prompt_file"
  printf '   The pass threshold for this review is %s/60 (use this, override the default). Return your verdict."\n\n' "$SPEC_PASS_THRESHOLD" >> "$prompt_file"

  cat >> "$prompt_file" << '__FACTORY_REVIEW2__'
The reviewer has a FRESH context and will catch issues you missed.

If the reviewer returns NEEDS_REVISION:
1. Read the blocking issues and findings carefully
2. Fix all blocking issues (these are non-negotiable)
3. Address suggestions for any dimension scoring below 8
4. Do NOT change parts that scored 8 or above unless they have blocking issues
5. Re-spawn the spec-reviewer agent to review the updated specs
__FACTORY_REVIEW2__

  printf '6. Repeat until the reviewer returns PASS or you have done %s review iterations\n\n' "$MAX_SPEC_ITERATIONS" >> "$prompt_file"
  printf 'Do NOT declare success until the reviewer returns a PASS verdict.\n' >> "$prompt_file"
  printf 'If after %s iterations the reviewer still returns NEEDS_REVISION,\n' "$MAX_SPEC_ITERATIONS" >> "$prompt_file"
  printf 'DELETE tasks.json (run: rm %s) before stopping. Report the final review findings.\n' "$TASKS_FILE" >> "$prompt_file"
  printf 'The pipeline uses tasks.json existence to signal success — if review failed, it must not exist.\n' >> "$prompt_file"

  claude -p --model opus \
    --max-turns "$SPEC_GEN_TURNS" \
    --output-format json < "$prompt_file" > "$log_file" 2>"$log_dir/spec-gen.stderr.log" || true

  local cost
  cost=$(jq -r '.total_cost_usd // 0' "$log_file" 2>/dev/null || echo "0")
  echo "  Spec generation cost: \$$cost"

  # Validate output
  if [[ ! -f "$TASKS_FILE" ]]; then
    echo "=== Spec generation produced no tasks.json, retrying with more turns ==="
    local retry_turns=$((SPEC_GEN_TURNS + 20))
    log_file="$log_dir/spec-gen.retry.json"

    prompt_file=$(mktemp "$FACTORY_TMPDIR/prompt-retry.XXXXXX")

    # Quoted heredoc for static header, printf for dynamic PRD content
    cat > "$prompt_file" << '__FACTORY_RETRY_HEADER__'
You are generating implementation specs from a PRD. A previous attempt failed to produce tasks.json.

__FACTORY_RETRY_HEADER__

    printf '## PRD (from issue #%s)\n\n**Title:** %s\n\n%s\n\n---\n\n' \
      "$issue_number" "$issue_title" "$issue_body" >> "$prompt_file"

    cat >> "$prompt_file" << '__FACTORY_SPEC_RETRY__'
## Instructions

__FACTORY_SPEC_RETRY__

    printf '%s\n\n' "$skill_body" >> "$prompt_file"
    printf 'CRITICAL: You MUST create the directory %s and write:\n' "$SPEC_DIR" >> "$prompt_file"

    cat >> "$prompt_file" << '__FACTORY_SPEC_RETRY2__'
1. Spec .md files for each vertical slice
2. tasks.json with all decomposed tasks
__FACTORY_SPEC_RETRY2__

    printf '3. metadata.json with { "prd_issue": %s }\n\n' "$issue_number" >> "$prompt_file"

    cat >> "$prompt_file" << '__FACTORY_SPEC_RETRY3__'
Modifications:
- Step 1: PRD is above, skip issue search
- Step 5: Skip user quiz, use best judgment
- Step 8: Always create tasks.json

After generating, spawn the spec-reviewer agent (subagent_type 'spec-reviewer') to review
__FACTORY_SPEC_RETRY3__

    printf 'your work. Pass it: "Review the spec in %s. Read all .md files and tasks.json.\n' "$SPEC_DIR" >> "$prompt_file"
    printf 'The pass threshold for this review is %s/60 (use this, override the default). Return your verdict."\n' "$SPEC_PASS_THRESHOLD" >> "$prompt_file"
    printf 'Fix blocking issues and re-review until PASS or %s iterations.\n' "$MAX_SPEC_ITERATIONS" >> "$prompt_file"
    printf 'If review never passes, DELETE tasks.json (run: rm %s) before stopping.\n' "$TASKS_FILE" >> "$prompt_file"

    claude -p --model opus \
      --max-turns "$retry_turns" \
      --output-format json < "$prompt_file" > "$log_file" 2>"$log_dir/spec-gen.retry.stderr.log" || true

    local retry_cost
    retry_cost=$(jq -r '.total_cost_usd // 0' "$log_file" 2>/dev/null || echo "0")
    echo "  Retry cost: \$$retry_cost"
  fi

  # Final validation
  if [[ ! -f "$TASKS_FILE" ]]; then
    echo "=== SPEC GENERATION FAILED: no tasks.json after 2 attempts ==="
    gh issue comment "$issue_number" --body "Spec generation failed after 2 attempts — no tasks.json produced. Manual intervention required." || true
    gh issue edit "$issue_number" --add-label "needs-manual-spec" 2>/dev/null || true
    return 1
  fi

  if ! jq empty "$TASKS_FILE" 2>/dev/null; then
    echo "=== SPEC GENERATION FAILED: tasks.json is not valid JSON ==="
    gh issue comment "$issue_number" --body "Spec generation produced invalid tasks.json. Manual intervention required." || true
    gh issue edit "$issue_number" --add-label "needs-manual-spec" 2>/dev/null || true
    return 1
  fi

  local task_count
  task_count=$(jq 'length' "$TASKS_FILE")
  if [[ "$task_count" -eq 0 ]]; then
    echo "=== SPEC GENERATION FAILED: tasks.json is empty ==="
    gh issue comment "$issue_number" --body "Spec generation produced an empty tasks.json. Manual intervention required." || true
    gh issue edit "$issue_number" --add-label "needs-manual-spec" 2>/dev/null || true
    return 1
  fi

  echo "=== Spec generation complete: $task_count tasks in $SPEC_DIR ==="
}

# --- Multi-PRD dispatch ---
sequential_execution() {
  local issue_list="$1"
  local succeeded=0
  local failed=0

  while IFS=$'\t' read -r issue_num title; do
    echo ""
    echo "========================================"
    echo "Processing PRD issue #$issue_num: $title"
    echo "========================================"
    if "$SCRIPT_DIR/run-factory.sh" --issue "$issue_num" --skip-settings-swap; then
      succeeded=$((succeeded + 1))
    else
      failed=$((failed + 1))
      echo "Pipeline failed for issue #$issue_num."
    fi
  done <<< "$issue_list"

  echo ""
  echo "=== Sequential execution complete: $succeeded succeeded, $failed failed ==="
}

parallel_worktree_execution() {
  local issue_list="$1"
  local pids=()
  local worktrees=()
  local issues=()

  # Ensure staging branch ref exists for worktree base (staging setup runs later in main flow)
  git fetch origin
  if ! git show-ref --verify --quiet refs/heads/staging; then
    if git show-ref --verify --quiet refs/remotes/origin/staging; then
      git branch staging origin/staging
    elif git show-ref --verify --quiet refs/heads/develop; then
      git branch staging develop
    else
      git branch staging HEAD
    fi
  fi

  while IFS=$'\t' read -r issue_num title; do
    local slug
    slug=$(slugify_title "$title")
    local worktree_path="../factory-$slug"

    if [[ -d "$worktree_path" ]]; then
      echo "Worktree $worktree_path already exists (duplicate slug?), skipping issue #$issue_num."
      continue
    fi

    echo "Creating worktree for issue #$issue_num at $worktree_path..."
    if ! git worktree add "$worktree_path" staging; then
      echo "Failed to create worktree for issue #$issue_num, skipping."
      continue
    fi
    worktrees+=("$worktree_path")
    issues+=("$issue_num")

    # Launch factory in background (skip settings swap — parent manages settings)
    (cd "$worktree_path" && .claude/run-factory.sh --issue "$issue_num" --skip-settings-swap) &
    pids+=($!)
    echo "  Launched PID ${pids[-1]}"
  done <<< "$issue_list"

  # Wait for all
  local failed=0
  local succeeded=0
  local failed_worktrees=()
  for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then
      succeeded=$((succeeded + 1))
      echo "Factory for ${worktrees[$i]} (issue #${issues[$i]}) succeeded."
      git worktree remove "${worktrees[$i]}" 2>/dev/null || true
    else
      failed=$((failed + 1))
      echo "Factory for ${worktrees[$i]} (issue #${issues[$i]}) failed."
      failed_worktrees+=("${worktrees[$i]}")
    fi
  done

  echo ""
  echo "=== Parallel execution complete: $succeeded succeeded, $failed failed ==="
  if [[ ${#failed_worktrees[@]} -gt 0 ]]; then
    echo "  Failed worktrees preserved for inspection:"
    for wt in "${failed_worktrees[@]}"; do
      echo "    $wt"
    done
    echo "  Clean up manually: git worktree remove <path>"
  fi
}

discover_and_process_prds() {
  local prd_issues
  prd_issues=$(gh issue list --search "[PRD] in:title" --state open --json number,title \
    -q '.[] | "\(.number)\t\(.title)"' 2>/dev/null || true)

  if [[ -z "$prd_issues" ]]; then
    echo "No open [PRD] issues found."
    exit 0
  fi

  local count
  count=$(echo "$prd_issues" | wc -l | tr -d ' ')

  if [[ "$count" -eq 1 ]]; then
    local single_issue
    single_issue=$(echo "$prd_issues" | cut -f1)
    local single_title
    single_title=$(echo "$prd_issues" | cut -f2)
    echo "Found one PRD issue: #$single_issue — $single_title"
    # Intentionally set outer-scope variables so caller can proceed with spec generation
    ISSUE_NUMBER="$single_issue"
    MODE="issue"
    return
  fi

  echo "Found $count PRD issues:"
  echo "$prd_issues" | while IFS=$'\t' read -r num title; do
    echo "  #$num — $title"
  done
  echo ""
  echo "How to process?"
  echo "  1) Sequential — process one at a time"
  echo "  2) Parallel — each PRD in its own worktree"
  read -rp "Choose [1/2]: " mode < /dev/tty

  case "$mode" in
    2)
      parallel_worktree_execution "$prd_issues"
      exit $?
      ;;
    *)
      sequential_execution "$prd_issues"
      exit $?
      ;;
  esac
}

# --- Resolve spec name based on mode ---
case "$MODE" in
  discover)
    discover_and_process_prds
    # If we get here, discover found exactly 1 issue and set MODE=issue
    generate_and_review_spec "$ISSUE_NUMBER" || {
      echo "Spec generation failed. Exiting."
      exit 1
    }
    ;;
  issue)
    generate_and_review_spec "$ISSUE_NUMBER" || {
      echo "Spec generation failed. Exiting."
      exit 1
    }
    ;;
  interactive)
    AVAILABLE_SPECS=()
    for tasks_file in specs/features/*/tasks.json; do
      [[ -f "$tasks_file" ]] || continue
      AVAILABLE_SPECS+=("$(basename "$(dirname "$tasks_file")")")
    done

    if [[ ${#AVAILABLE_SPECS[@]} -eq 0 ]]; then
      echo "No feature specs found in specs/features/."
      echo "Create a spec first (try the prd-to-spec skill or --issue flag)."
      exit 1
    fi

    if [[ ${#AVAILABLE_SPECS[@]} -eq 1 ]]; then
      SPEC_NAME="${AVAILABLE_SPECS[0]}"
      read -rp "Found one spec: $SPEC_NAME. Run it? [Y/n]: " confirm < /dev/tty
      if [[ "$confirm" =~ ^[Nn] ]]; then
        echo "Aborted."
        exit 0
      fi
    else
      echo "Available feature specs:"
      for i in "${!AVAILABLE_SPECS[@]}"; do
        task_count=$(jq 'length' "specs/features/${AVAILABLE_SPECS[$i]}/tasks.json" 2>/dev/null || echo "?")
        echo "  $((i + 1))) ${AVAILABLE_SPECS[$i]} ($task_count tasks)"
      done
      echo ""
      read -rp "Select spec [1-${#AVAILABLE_SPECS[@]}]: " choice < /dev/tty
      if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 || "$choice" -gt ${#AVAILABLE_SPECS[@]} ]]; then
        echo "Invalid selection."
        exit 1
      fi
      SPEC_NAME="${AVAILABLE_SPECS[$((choice - 1))]}"
    fi
    ;;
  named)
    # SPEC_NAME already set from argument
    ;;
esac

SPEC_DIR="specs/features/$SPEC_NAME"
TASKS_FILE="$SPEC_DIR/tasks.json"

# --- Circuit breaker defaults (override via env vars) ---
MAX_TASKS=${MAX_TASKS:-20}
MAX_MINUTES=${MAX_MINUTES:-360}
MAX_CONSECUTIVE_FAILURES=${MAX_CONSECUTIVE_FAILURES:-3}
MAX_RETRIES=${MAX_RETRIES:-2}
ENABLE_CODE_REVIEW=${ENABLE_CODE_REVIEW:-true}
REVIEW_TURNS=${REVIEW_TURNS:-40}
PIPELINE_START=$(date +%s)
TASKS_RUN=0
CONSECUTIVE_FAILURES=0

# --- Smart staging functions ---
reconcile_staging_with_develop() {
  # Ensure we're on staging before merging
  local current_branch
  current_branch=$(git branch --show-current)
  if [[ "$current_branch" != "staging" ]]; then
    echo "Error: reconcile_staging_with_develop called from branch '$current_branch', expected 'staging'"
    exit 1
  fi

  local merge_base develop_sha staging_sha
  merge_base=$(git merge-base staging develop)
  develop_sha=$(git rev-parse develop)
  staging_sha=$(git rev-parse staging)

  if [[ "$develop_sha" == "$staging_sha" ]]; then
    echo "Staging and develop at same commit, nothing to reconcile."
  elif [[ "$merge_base" == "$staging_sha" ]]; then
    echo "Staging behind develop, fast-forwarding..."
    git merge --ff-only develop
    git push origin staging
  elif [[ "$merge_base" == "$develop_sha" ]]; then
    echo "Staging ahead of develop, keeping as-is."
  else
    echo "Staging and develop diverged, merging develop into staging..."
    if ! git merge develop -m "merge: reconcile staging with develop"; then
      echo "Error: conflict reconciling staging with develop. Aborting pipeline."
      git merge --abort
      exit 1
    fi
    git push origin staging
  fi
}

setup_staging() {
  local has_local=false
  local has_remote=false

  git show-ref --verify --quiet refs/heads/staging && has_local=true
  git show-ref --verify --quiet refs/remotes/origin/staging && has_remote=true

  if [[ "$has_local" == "false" && "$has_remote" == "false" ]]; then
    echo "No staging branch found, creating from develop..."
    git checkout -b staging develop
    git push -u origin staging
  elif [[ "$has_local" == "false" && "$has_remote" == "true" ]]; then
    echo "Staging on remote only, checking out..."
    git checkout -b staging origin/staging
    reconcile_staging_with_develop
  elif [[ "$has_local" == "true" && "$has_remote" == "false" ]]; then
    echo "Staging local only, checking out and pushing..."
    git checkout staging
    git push -u origin staging
    reconcile_staging_with_develop
  else
    echo "Staging exists, checking out and pulling..."
    git checkout staging
    git pull origin staging
    reconcile_staging_with_develop
  fi
}

wait_for_pr_merge() {
  local pr_number=$1
  local timeout_secs=${2:-2700}
  local elapsed=0
  local interval=30
  local consecutive_errors=0
  local max_errors=5

  while [[ $elapsed -lt $timeout_secs ]]; do
    local state
    state=$(gh pr view "$pr_number" --json state -q '.state' 2>/dev/null) || true
    if [[ -z "$state" ]]; then
      consecutive_errors=$((consecutive_errors + 1))
      if [[ $consecutive_errors -ge $max_errors ]]; then
        echo "  Warning: GitHub API unreachable after $max_errors attempts for PR #$pr_number"
        return 1
      fi
      echo "  Warning: failed to fetch PR #$pr_number state (attempt $consecutive_errors/$max_errors)"
      sleep $interval
      elapsed=$((elapsed + interval))
      continue
    fi
    consecutive_errors=0
    if [[ "$state" == "MERGED" ]]; then
      return 0
    fi
    if [[ "$state" == "CLOSED" ]]; then
      return 1
    fi
    # Detect cancelled auto-merge (checks failed) — no point waiting the full timeout
    if [[ "$state" == "OPEN" ]]; then
      local auto_merge
      auto_merge=$(gh pr view "$pr_number" --json autoMergeRequest -q '.autoMergeRequest' 2>/dev/null) || true
      if [[ "$auto_merge" == "null" || -z "$auto_merge" ]]; then
        echo "  Auto-merge cancelled for PR #$pr_number (checks likely failed)"
        return 1
      fi
    fi
    sleep $interval
    elapsed=$((elapsed + interval))
  done
  return 1
}

# --- Ensure develop branch is up to date ---
if ! git show-ref --verify --quiet refs/heads/develop; then
  echo "Creating develop branch from main..."
  git checkout -b develop main
  git push -u origin develop
else
  git checkout develop
  git pull origin develop
fi

# --- Smart staging setup ---
git fetch origin
setup_staging

# --- Ensure quality gate workflow exists ---
WORKFLOW_SRC="$SCRIPT_DIR/quality-gate.yml"
WORKFLOW_DEST=".github/workflows/quality-gate.yml"

if [[ -f "$WORKFLOW_SRC" && ! -f "$WORKFLOW_DEST" ]]; then
  echo "Deploying quality gate workflow..."
  mkdir -p .github/workflows
  cp "$WORKFLOW_SRC" "$WORKFLOW_DEST"
  git add "$WORKFLOW_DEST"
  git commit -m "ci: add quality gate workflow"
  git push origin staging
fi

# --- Ensure branch protection on staging ---
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')

echo "Ensuring branch protection on staging..."
gh api "repos/$REPO/branches/staging/protection" \
  --method PUT \
  --silent \
  --input - <<'EOF' || echo "Warning: could not set branch protection (may need admin access)"
{
  "required_status_checks": {
    "strict": false,
    "contexts": ["quality", "mutation", "security"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null
}
EOF

# --- Scaffolding check ---
NEEDS_SETUP=false
for f in claude-progress.json feature-status.json init.sh; do
  if [[ ! -f "$f" ]]; then
    echo "Missing scaffolding file: $f"
    NEEDS_SETUP=true
  fi
done

if [[ "$NEEDS_SETUP" == "true" ]]; then
  echo "Running project setup..."
  mkdir -p logs

  claude -p "You are setting up a new project for autonomous AI development.

Read the CLAUDE.md and all spec files in specs/features/.

Create the following files:

1. **claude-progress.json** — A structured log of all agent sessions.
   Initialise it as: { \"sessions\": [], \"current_state\": \"initialised\" }

2. **feature-status.json** — A JSON array of every feature and acceptance
   criterion from all spec files. Each entry must have:
   - id: unique feature identifier
   - description: what the feature does
   - category: 'domain' | 'api' | 'frontend' | 'integration'
   - acceptance_criteria: array of testable criteria
   - passes: false (ALL start as false)
   - task_id: null (assigned during decomposition)

   DO NOT mark any feature as passing during initialisation.
   DO NOT remove or edit feature descriptions after creation.
   You may ONLY change the 'passes' field to true after verified testing.

3. **init.sh** — A script that:
   - Installs dependencies (pnpm install)
   - Runs the dev server in the background
   - Runs a basic smoke test (pnpm quality or a health check)

4. Make an initial git commit with message 'chore: initialise autonomous scaffolding'

Use JSON (not Markdown) for all status tracking files. The model is less
likely to inappropriately edit structured JSON compared to Markdown." \
    --max-turns 20 \
    --output-format json > logs/initialiser.json 2>logs/initialiser.stderr.log

  echo "Project setup complete. Log: logs/initialiser.json"
fi

# --- Validate tasks file ---
if [[ ! -f "$TASKS_FILE" ]]; then
  echo "Error: $TASKS_FILE not found."
  echo "Create a tasks.json in $SPEC_DIR before running the factory."
  exit 1
fi

# Validate required fields exist in every task
if ! jq -e 'if length == 0 then false else [.[] | has("task_id", "title", "depends_on", "acceptance_criteria")] | all end' "$TASKS_FILE" > /dev/null 2>&1; then
  echo "Error: tasks.json has entries missing required fields (task_id, title, depends_on, acceptance_criteria)."
  exit 1
fi

# --- Validate dependency references ---
INVALID_DEPS=$(jq -r '
  [.[].task_id] as $all_ids |
  [.[] | .task_id as $tid | .depends_on[] | select(. as $dep | $all_ids | index($dep) | not) | "\($tid) -> \(.)"] |
  .[]
' "$TASKS_FILE" 2>/dev/null)

if [[ -n "$INVALID_DEPS" ]]; then
  echo "=== ERROR: tasks.json has dangling dependency references ==="
  echo "$INVALID_DEPS" | while read -r line; do echo "  $line"; done
  exit 1
fi

# --- Init tracking ---
STATUS_FILE=$(mktemp "$FACTORY_TMPDIR/status.XXXXXX")
PR_FILE=$(mktemp "$FACTORY_TMPDIR/prs.XXXXXX")

# --- Factory loop ---
LOG_DIR="logs/$(date +%Y%m%d-%H%M%S)-$SPEC_NAME"
mkdir -p "$LOG_DIR"

# Topological sort of tasks by dependency order
TOTAL_TASKS=$(jq 'length' "$TASKS_FILE")
TASK_IDS=()
while IFS= read -r tid; do
  TASK_IDS+=("$tid")
done < <(jq -r '
  def topo:
    . as $tasks |
    [.[] | select(.depends_on | length == 0) | .task_id] as $ready |
    if ($ready | length) == 0 then []
    else $ready + ([$tasks[] | select(.task_id as $id | $ready | index($id) | not) | .depends_on -= $ready] | topo)
    end;
  topo | .[]
' "$TASKS_FILE")

# Cycle detection: if topo sort produced fewer IDs than tasks, there's a cycle
if [[ ${#TASK_IDS[@]} -lt $TOTAL_TASKS ]]; then
  echo "=== ERROR: Dependency cycle detected in tasks.json ==="
  echo "  Sorted ${#TASK_IDS[@]} of $TOTAL_TASKS tasks. Unsorted tasks have circular dependencies."
  # Show which tasks weren't sorted
  ALL_IDS=$(jq -r '.[].task_id' "$TASKS_FILE")
  for aid in $ALL_IDS; do
    found=false
    for sid in "${TASK_IDS[@]}"; do
      [[ "$aid" == "$sid" ]] && found=true && break
    done
    [[ "$found" == "false" ]] && echo "  Stuck in cycle: $aid"
  done
  exit 1
fi

for TASK_ID in "${TASK_IDS[@]}"; do
  echo ""

  # --- Circuit breakers ---
  TASKS_RUN=$((TASKS_RUN + 1))
  if [[ $TASKS_RUN -gt $MAX_TASKS ]]; then
    echo "=== CIRCUIT BREAKER: max tasks ($MAX_TASKS) reached ==="
    break
  fi

  ELAPSED=$(( ($(date +%s) - PIPELINE_START) / 60 ))
  if [[ $ELAPSED -gt $MAX_MINUTES ]]; then
    echo "=== CIRCUIT BREAKER: time limit (${MAX_MINUTES}m) reached ==="
    break
  fi

  echo "=== Starting task: $TASK_ID ==="

  # --- Dependency check ---
  DEPS=$(jq -r --arg tid "$TASK_ID" '.[] | select(.task_id==$tid) | .depends_on // [] | .[]' "$TASKS_FILE")
  SKIP=false

  for DEP in $DEPS; do
    DEP_LINE=$(grep "^${DEP}=" "$STATUS_FILE" || true)
    DEP_STATUS="${DEP_LINE#*=}"

    if [[ -z "$DEP_STATUS" ]]; then
      echo "=== $TASK_ID: SKIPPED (dependency $DEP has no status) ==="
      echo "${TASK_ID}=skipped" >> "$STATUS_FILE"
      SKIP=true
      break
    fi

    if [[ "$DEP_STATUS" == "failed" || "$DEP_STATUS" == "skipped" ]]; then
      echo "=== $TASK_ID: SKIPPED (dependency $DEP $DEP_STATUS) ==="
      echo "${TASK_ID}=skipped" >> "$STATUS_FILE"
      SKIP=true
      break
    fi

    # Dep succeeded — wait for its PR to merge into staging
    DEP_PR_LINE=$(grep "^${DEP}=" "$PR_FILE" || true)
    DEP_PR="${DEP_PR_LINE#*=}"

    if [[ -n "$DEP_PR" ]]; then
      echo "Waiting for $DEP PR #$DEP_PR to merge..."
      if ! wait_for_pr_merge "$DEP_PR"; then
        echo "=== $TASK_ID: SKIPPED ($DEP PR #$DEP_PR did not merge within timeout) ==="
        echo "${TASK_ID}=skipped" >> "$STATUS_FILE"
        SKIP=true
        break
      fi
      echo "$DEP PR #$DEP_PR merged."
    fi
  done

  if [[ "$SKIP" == "true" ]]; then
    continue
  fi

  # Pull latest staging (picks up merged dependency PRs)
  git checkout staging
  git pull origin staging

  # Extract task details
  TITLE=$(jq -r --arg tid "$TASK_ID" '.[] | select(.task_id==$tid) | .title' "$TASKS_FILE")
  DESC=$(jq -r --arg tid "$TASK_ID" '.[] | select(.task_id==$tid) | .description' "$TASKS_FILE")
  FILES=$(jq -r --arg tid "$TASK_ID" '.[] | select(.task_id==$tid) | .files | join(", ")' "$TASKS_FILE")
  CRITERIA=$(jq -r --arg tid "$TASK_ID" '.[] | select(.task_id==$tid) | .acceptance_criteria | join("; ")' "$TASKS_FILE")
  TESTS=$(jq -r --arg tid "$TASK_ID" '.[] | select(.task_id==$tid) | .tests_to_write | join("; ")' "$TASKS_FILE")

  # Model + turn-budget routing by task complexity
  COMPLEXITY=$(jq -r --arg tid "$TASK_ID" '.[] | select(.task_id==$tid) | .complexity // "standard"' "$TASKS_FILE")
  case "$COMPLEXITY" in
    simple)  MODEL_FLAG="--model haiku"; TURN_BUDGET=40 ;;
    complex) MODEL_FLAG="--model opus";  TURN_BUDGET=80 ;;
    *)       MODEL_FLAG="";              TURN_BUDGET=60 ;;
  esac

  # Export task ID for audit log correlation
  export FACTORY_TASK_ID="$TASK_ID"

  # --- Ralph loop retry ---
  BRANCH="feat/$TASK_ID"
  ATTEMPT=0
  TASK_OUTCOME="failed"  # default to failed; overwritten on success
  FAILURE_TYPE=""
  PREV_QUALITY_LOG=""
  PREV_REVIEW_FINDINGS=""
  PREV_EXIT_CODE=0
  TASK_COST=0

  while [[ $ATTEMPT -le $MAX_RETRIES ]]; do
    ATTEMPT=$((ATTEMPT + 1))

    # Time circuit breaker inside retry loop
    ELAPSED=$(( ($(date +%s) - PIPELINE_START) / 60 ))
    if [[ $ELAPSED -gt $MAX_MINUTES ]]; then
      echo "=== CIRCUIT BREAKER: time limit hit during retry ==="
      TASK_OUTCOME="failed"
      break
    fi

    if [[ $ATTEMPT -gt 1 ]]; then
      echo "--- $TASK_ID: retry $ATTEMPT/$((MAX_RETRIES + 1)) (reason: $FAILURE_TYPE) ---"
    fi

    # Branch handling
    if [[ $ATTEMPT -eq 1 ]]; then
      if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
        git checkout "$BRANCH"
        git reset --hard staging
      else
        git checkout -b "$BRANCH"
      fi
    else
      git checkout "$BRANCH"
      git checkout -- . 2>/dev/null || true
      git clean -fd 2>/dev/null || true
    fi

    # Build retry context
    RETRY_CONTEXT=""
    if [[ $ATTEMPT -gt 1 ]]; then
      RETRY_CONTEXT="## IMPORTANT: This is retry attempt $ATTEMPT of $((MAX_RETRIES + 1))

Previous attempt failed with: $FAILURE_TYPE
"
      case "$FAILURE_TYPE" in
        max_turns)
          RETRY_CONTEXT+="The previous session ran out of turns.
Work was committed to this branch — check git log and claude-progress.json.
Continue from where the last session stopped. Do NOT restart from scratch.

"
          ;;
        quality_gate)
          QUALITY_TAIL=$(tail -40 "$PREV_QUALITY_LOG" 2>/dev/null || echo "(no output captured)")
          RETRY_CONTEXT+="The implementation completed but pnpm quality failed afterward.
Quality gate output (last 40 lines):
\`\`\`
$QUALITY_TAIL
\`\`\`
Fix ALL quality failures. The previous work is committed on this branch.

"
          ;;
        agent_error)
          RETRY_CONTEXT+="The previous session ended with an error (exit code $PREV_EXIT_CODE).
Check git log and claude-progress.json for any partial work.

"
          ;;
        code_review)
          RETRY_CONTEXT+="The implementation passed quality gates but FAILED code review.
The reviewer (a separate AI with fresh context) found issues.

## Code Review Findings
$PREV_REVIEW_FINDINGS

Fix ALL CRITICAL and WARNING findings. The previous work is committed on this branch.
Do NOT introduce new issues while fixing these.
Run pnpm quality after fixes to ensure nothing regresses.

"
          ;;
      esac
    fi

    # Build task prompt in temp file (avoids ARG_MAX on large retry contexts)
    LOG_FILE="$LOG_DIR/${TASK_ID}.attempt-${ATTEMPT}.json"
    EXIT_CODE=0
    task_prompt_file=$(mktemp "$FACTORY_TMPDIR/task-prompt.XXXXXX")

    [[ -n "$RETRY_CONTEXT" ]] && printf '%s' "$RETRY_CONTEXT" > "$task_prompt_file"

    printf "You are implementing task '%s' for this project.\n\n" "$TITLE" >> "$task_prompt_file"

    cat >> "$task_prompt_file" << '__FACTORY_TASK__'
## Phase 1: Orient (do this BEFORE writing any code)
1. Run pwd to confirm your working directory
2. Read claude-progress.json to understand what previous sessions accomplished
3. Read feature-status.json to see which features pass and which don't
4. Run git log --oneline -10 to see recent changes
5. Run init.sh to start the dev server and verify the app is in a working state
6. If the app is broken, fix existing bugs BEFORE starting new work

## Phase 2: Implement (one task only)
__FACTORY_TASK__

    printf 'Task: %s\nFiles to create/modify: %s\nAcceptance criteria: %s\nTests to write: %s\n\n' \
      "$DESC" "$FILES" "$CRITERIA" "$TESTS" >> "$task_prompt_file"

    cat >> "$task_prompt_file" << '__FACTORY_TASK2__'
7. Read the project CLAUDE.md and follow all rules
8. Read existing code in the listed files (if they exist)
9. Implement the feature following acceptance criteria exactly
10. Write ALL specified tests — each must have meaningful assertions
11. Run pnpm quality and fix ALL failures
12. Do NOT modify any files outside the listed files
13. Do NOT add npm packages without checking they exist first

## Phase 3: Leave clean artefacts (do this BEFORE stopping)
14. Commit with conventional format: feat(scope): description
15. Update claude-progress.json: append a new session entry with task_id,
    status, summary of what you did, files changed, and any notes for
    the next session. Update current_state.
16. Update feature-status.json: set passes to true ONLY for features you
    have verified work end-to-end. Do NOT remove or edit any feature
    descriptions — only change the passes field.

CRITICAL: If you are running low on turns and cannot complete the task,
you MUST still leave the environment in a clean state:
- Revert any half-implemented changes (git checkout -- .)
- Update claude-progress.json with status 'incomplete' and notes on
  what remains to be done
- Do NOT leave broken code on the branch
__FACTORY_TASK2__

    # Run Claude Code in headless mode
    MODEL_ARGS=()
    [[ -n "$MODEL_FLAG" ]] && read -ra MODEL_ARGS <<< "$MODEL_FLAG"
    claude -p "${MODEL_ARGS[@]}" \
      --max-turns "$TURN_BUDGET" \
      --output-format json < "$task_prompt_file" > "$LOG_FILE" 2>"$LOG_DIR/${TASK_ID}.attempt-${ATTEMPT}.stderr.log" || EXIT_CODE=$?

    # Per-attempt cost logging
    ATTEMPT_COST=$(jq -r '.total_cost_usd // 0' "$LOG_FILE" 2>/dev/null || echo "0")
    TASK_COST=$(echo "$TASK_COST + $ATTEMPT_COST" | bc 2>/dev/null || echo "$TASK_COST")
    echo "  Cost: \$$ATTEMPT_COST (attempt $ATTEMPT, total \$$TASK_COST)"

    # Classify result — check subtype even on exit 0 (error_max_turns can return 0)
    RESULT_SUBTYPE=$(jq -r '.subtype // "unknown"' "$LOG_FILE" 2>/dev/null || echo "unknown")

    if [[ $EXIT_CODE -ne 0 || "$RESULT_SUBTYPE" == error_* ]]; then
      FAILURE_TYPE="agent_error"
      [[ "$RESULT_SUBTYPE" == "error_max_turns" ]] && FAILURE_TYPE="max_turns"
      PREV_EXIT_CODE=$EXIT_CODE
      echo "=== $TASK_ID: AGENT FAILED (exit=$EXIT_CODE, subtype=$RESULT_SUBTYPE, attempt=$ATTEMPT) ==="

      if [[ $ATTEMPT -le $MAX_RETRIES ]]; then
        continue
      fi
      TASK_OUTCOME="failed"
      break
    fi

    # Quality gate
    QUALITY_LOG="$LOG_DIR/${TASK_ID}.attempt-${ATTEMPT}.quality.log"
    if pnpm quality > "$QUALITY_LOG" 2>&1; then

      # --- Code review gate (optional) ---
      REVIEW_VERDICT="APPROVE"  # default when review disabled
      REVIEW_TEXT=""
      if [[ "$ENABLE_CODE_REVIEW" == "true" ]]; then
        echo "  Running code review ($TASK_ID, attempt $ATTEMPT)..."
        REVIEW_LOG="$LOG_DIR/${TASK_ID}.attempt-${ATTEMPT}.review.json"

        review_prompt_file=$(mktemp "$FACTORY_TMPDIR/review-prompt.XXXXXX")

        DIFF_STAT=$(git diff staging...HEAD --stat 2>/dev/null || git diff --stat)
        CHANGED_FILES=$(git diff staging...HEAD --name-only 2>/dev/null || git diff --name-only)

        cat > "$review_prompt_file" << '__REVIEW_PROMPT__'
You are a senior engineer performing a code review. You have a FRESH context -- you did not write this code. This separation is intentional: AI-generated code escapes review because well-formatted code triggers "looks fine" approval bias.

## Critical Principle: Signal Over Noise

Only report findings you are genuinely confident about. Score each finding mentally on likelihood (1-10) and impact (1-10). Drop anything below 5 on either axis. Keep total findings to 3-7. A review with 15+ comments is almost certainly noisy.

Do NOT flag: formatting, naming conventions, missing comments/docs, type annotations, lint violations. These are covered by deterministic tools.

DO flag: logic errors, unhandled edge cases, incorrect business logic, missing error handling that matters, weak test assertions, cross-file impact, AI-specific anti-patterns.

## Review Process

### Phase 1: Context
1. Read CLAUDE.md and any stack guidelines (frontend.md, backend.md) in the .claude/ directory
2. Run git diff staging...HEAD to read ALL changes
3. Run git log --oneline staging...HEAD to understand commit narrative

### Phase 2: Logic and Correctness
For each changed file, examine:
- Data flow correctness (trace inputs to outputs; off-by-one errors, wrong operators)
- Edge cases (empty, null/undefined, zero, negative, large inputs, concurrent access, network failures)
- Error handling that matters (errors that WILL happen in production -- not "add try-catch everywhere")
- Cross-file impact (does this break callers? grep for changed exports/signatures)
- AI-specific anti-patterns: hallucinated APIs, over-abstraction, copy-paste drift, missing null checks on external data, excessive I/O (N+1 queries, redundant API calls), dead code

### Phase 3: Test Quality
For each test file in the diff:
- Does it test BEHAVIOR or just run code? (tests without meaningful assertions create false confidence)
- Are assertions specific? (toBeDefined() alone is almost never sufficient)
- Would the test fail if the implementation returned a wrong value?
- Are mocks realistic? Do mock responses match the actual API/DB shape?

### Phase 4: Verification
Run pnpm quality to confirm all automated checks pass.

### Phase 5: Verdict

Group findings by severity:
- CRITICAL: Will cause bugs in production, data loss, or security issues
- WARNING: Likely to cause problems, should fix before merge
- NOTE: Minor improvements, non-blocking

For each finding: file path, line number, one-sentence issue, why it matters, suggested fix.

Your response MUST end with exactly one of these verdict lines (no other text after it):

**VERDICT: APPROVE**
**VERDICT: REQUEST_CHANGES**
**VERDICT: NEEDS_DISCUSSION**

Use APPROVE if changes are correct (explain WHY -- cite specific verification).
Use REQUEST_CHANGES if there are CRITICAL or WARNING findings.
Use NEEDS_DISCUSSION if you are uncertain about impact and a human should decide.
__REVIEW_PROMPT__

        printf '\n## Task Context\n\nTask: %s\nBranch: %s\n\nChanged files:\n%s\n\nDiff stats:\n%s\n' \
          "$TITLE" "$BRANCH" "$CHANGED_FILES" "$DIFF_STAT" >> "$review_prompt_file"

        REVIEW_EXIT=0
        claude -p --model sonnet \
          --max-turns "$REVIEW_TURNS" \
          --output-format json < "$review_prompt_file" > "$REVIEW_LOG" 2>"$LOG_DIR/${TASK_ID}.attempt-${ATTEMPT}.review.stderr.log" || REVIEW_EXIT=$?

        REVIEW_COST=$(jq -r '.total_cost_usd // 0' "$REVIEW_LOG" 2>/dev/null || echo "0")
        TASK_COST=$(echo "$TASK_COST + $REVIEW_COST" | bc 2>/dev/null || echo "$TASK_COST")
        echo "  Review cost: \$$REVIEW_COST (task total \$$TASK_COST)"

        REVIEW_TEXT=$(jq -r '.result // ""' "$REVIEW_LOG" 2>/dev/null || echo "")

        if echo "$REVIEW_TEXT" | grep -q 'VERDICT: REQUEST_CHANGES'; then
          REVIEW_VERDICT="REQUEST_CHANGES"
        elif echo "$REVIEW_TEXT" | grep -q 'VERDICT: NEEDS_DISCUSSION'; then
          REVIEW_VERDICT="NEEDS_DISCUSSION"
        elif echo "$REVIEW_TEXT" | grep -q 'VERDICT: APPROVE'; then
          REVIEW_VERDICT="APPROVE"
        elif [[ $REVIEW_EXIT -ne 0 ]]; then
          echo "  Warning: review session failed (exit=$REVIEW_EXIT), treating as APPROVE"
          REVIEW_VERDICT="APPROVE"
        else
          echo "  Warning: no verdict found in review output, treating as NEEDS_DISCUSSION"
          REVIEW_VERDICT="NEEDS_DISCUSSION"
        fi

        echo "  Review verdict: $REVIEW_VERDICT"
      fi

      # --- Act on review verdict ---
      if [[ "$REVIEW_VERDICT" == "REQUEST_CHANGES" ]]; then
        FAILURE_TYPE="code_review"
        PREV_REVIEW_FINDINGS="$REVIEW_TEXT"
        echo "=== $TASK_ID: CODE REVIEW REJECTED (attempt $ATTEMPT) ==="
        if [[ $ATTEMPT -le $MAX_RETRIES ]]; then
          continue
        fi
        TASK_OUTCOME="failed"
        break
      fi

      # APPROVE or NEEDS_DISCUSSION — proceed to push + PR
      git push -u origin "$BRANCH"

      # Build PR body in temp file to avoid shell expansion of AI-generated content
      pr_body_file=$(mktemp "$FACTORY_TMPDIR/pr-body.XXXXXX")
      printf '## Task: %s\n' "$TASK_ID" > "$pr_body_file"
      jq -r --arg tid "$TASK_ID" '.[] | select(.task_id==$tid) | .description' "$TASKS_FILE" >> "$pr_body_file"
      printf '\n## Acceptance Criteria\n' >> "$pr_body_file"
      jq -r --arg tid "$TASK_ID" '.[] | select(.task_id==$tid) | .acceptance_criteria | map("- " + .) | join("\n")' "$TASKS_FILE" >> "$pr_body_file"
      printf '\n## Tests\n' >> "$pr_body_file"
      jq -r --arg tid "$TASK_ID" '.[] | select(.task_id==$tid) | .tests_to_write | map("- " + .) | join("\n")' "$TASKS_FILE" >> "$pr_body_file"

      if [[ "$ENABLE_CODE_REVIEW" == "true" && -n "$REVIEW_TEXT" ]]; then
        printf '\n## Code Review\n\n**Verdict:** %s\n\n<details>\n<summary>Review findings</summary>\n\n%s\n</details>\n' \
          "$REVIEW_VERDICT" "$REVIEW_TEXT" >> "$pr_body_file"
      fi

      PR_URL=$(gh pr create \
        --title "feat: $TITLE" \
        --body-file "$pr_body_file" \
        --base staging 2>/dev/null) || true

      # Inline retry for PR creation failure
      if [[ -z "$PR_URL" ]]; then
        echo "  PR creation failed, retrying in 5s..."
        sleep 5
        git push -u origin "$BRANCH" 2>/dev/null || true
        PR_URL=$(gh pr create \
          --title "feat: $TITLE" \
          --body-file "$pr_body_file" \
          --base staging 2>/dev/null) || true
      fi

      if [[ -n "$PR_URL" ]]; then
        PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$')
        if [[ "$REVIEW_VERDICT" == "NEEDS_DISCUSSION" ]]; then
          echo "  Skipping auto-merge: code review returned NEEDS_DISCUSSION (needs human input)"
          gh pr comment "$PR_NUMBER" --body "## Code Review: NEEDS_DISCUSSION

This PR was flagged by automated code review as needing human discussion before merge.

<details>
<summary>Review findings</summary>

$REVIEW_TEXT
</details>" 2>/dev/null || true
        else
          gh pr merge --auto --merge "$PR_NUMBER" 2>/dev/null || true
        fi
        echo "${TASK_ID}=${PR_NUMBER}" >> "$PR_FILE"
        echo "=== $TASK_ID: PR #$PR_NUMBER created (attempt $ATTEMPT, cost \$$TASK_COST) ==="
        TASK_OUTCOME="ok"
      else
        echo "=== $TASK_ID: PR CREATION FAILED (code pushed to $BRANCH) ==="
        echo "  Manual recovery: gh pr create --head $BRANCH --base staging"
        TASK_OUTCOME="failed"
      fi
      break
    else
      FAILURE_TYPE="quality_gate"
      PREV_QUALITY_LOG="$QUALITY_LOG"
      echo "=== $TASK_ID: QUALITY GATE FAILED (attempt $ATTEMPT) ==="

      if [[ $ATTEMPT -le $MAX_RETRIES ]]; then
        continue
      fi
      TASK_OUTCOME="failed"
      break
    fi
  done

  # Record final outcome (only after all retries exhausted)
  echo "${TASK_ID}=${TASK_OUTCOME}" >> "$STATUS_FILE"

  # --- Consecutive failure tracking ---
  case "$TASK_OUTCOME" in
    failed)
      CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
      if [[ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]]; then
        echo "=== CIRCUIT BREAKER: $MAX_CONSECUTIVE_FAILURES consecutive failures ==="
        break
      fi
      ;;
    *) CONSECUTIVE_FAILURES=0 ;;
  esac

  # Return to staging for next task
  git checkout staging
done

# --- Summary ---
OK_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0
while IFS='=' read -r _ status; do
  case "$status" in
    ok) OK_COUNT=$((OK_COUNT + 1)) ;;
    failed) FAILED_COUNT=$((FAILED_COUNT + 1)) ;;
    skipped) SKIPPED_COUNT=$((SKIPPED_COUNT + 1)) ;;
  esac
done < "$STATUS_FILE"

echo ""
echo "=== Pipeline complete ==="
echo "  Succeeded: $OK_COUNT"
echo "  Failed:    $FAILED_COUNT"
echo "  Skipped:   $SKIPPED_COUNT"
echo "  Logs:      $LOG_DIR"

# --- Close PRD issue if all tasks succeeded ---
METADATA_FILE="$SPEC_DIR/metadata.json"
if [[ -f "$METADATA_FILE" ]]; then
  PRD_ISSUE=$(jq -r '.prd_issue // empty' "$METADATA_FILE")
  if [[ -n "$PRD_ISSUE" ]]; then
    # Build PR list from completed tasks
    PR_LIST=""
    while IFS='=' read -r tid pr_num; do
      PR_LIST="${PR_LIST:+$PR_LIST, }#$pr_num"
    done < "$PR_FILE"

    # Build per-task breakdown
    TASK_DETAILS=""
    while IFS='=' read -r tid status; do
      case "$status" in
        ok)
          tid_pr=$(grep "^${tid}=" "$PR_FILE" | cut -d= -f2)
          TASK_DETAILS+=$'\n'"- \`${tid}\`: ok (PR #${tid_pr})"
          ;;
        failed)
          TASK_DETAILS+=$'\n'"- \`${tid}\`: **failed** — check logs in \`${LOG_DIR}/${tid}.attempt-*.json\`"
          ;;
        skipped)
          # Find which dependency caused the skip
          skip_deps=$(jq -r --arg tid "$tid" '.[] | select(.task_id==$tid) | .depends_on[]' "$TASKS_FILE" 2>/dev/null)
          skip_reason=""
          for sd in $skip_deps; do
            sd_status=$(grep "^${sd}=" "$STATUS_FILE" | tail -1 | cut -d= -f2)
            if [[ "$sd_status" == "failed" || "$sd_status" == "skipped" ]]; then
              skip_reason="dependency \`${sd}\` ${sd_status}"
              break
            fi
          done
          TASK_DETAILS+=$'\n'"- \`${tid}\`: **skipped** — ${skip_reason:-unknown reason}"
          ;;
      esac
    done < "$STATUS_FILE"

    if [[ $FAILED_COUNT -eq 0 && $SKIPPED_COUNT -eq 0 ]]; then
      COMMENT_BODY="All $OK_COUNT tasks completed. PRs against staging: $PR_LIST"
      gh issue comment "$PRD_ISSUE" --body "$COMMENT_BODY"
      gh issue close "$PRD_ISSUE" --reason completed
      echo "PRD issue #$PRD_ISSUE closed."

      # --- Post-closure cleanup ---
      echo ""
      echo "=== Cleaning up completed feature artifacts ==="

      # Delete local feat/ branches
      for tid in "${TASK_IDS[@]}"; do
        branch="feat/$tid"
        if git show-ref --verify --quiet "refs/heads/$branch"; then
          git branch -D "$branch" 2>/dev/null && echo "  Deleted local branch: $branch"
        fi
      done

      # Delete remote feat/ branches (may already be gone via GitHub auto-delete)
      for tid in "${TASK_IDS[@]}"; do
        branch="feat/$tid"
        if git ls-remote --exit-code --heads origin "$branch" &>/dev/null; then
          git push origin --delete "$branch" 2>/dev/null \
            && echo "  Deleted remote branch: $branch" \
            || echo "  Remote branch already gone: $branch"
        fi
      done

      # Remove spec directory (fully consumed)
      if [[ -d "$SPEC_DIR" ]]; then
        rm -rf "$SPEC_DIR"
        echo "  Removed spec dir: $SPEC_DIR"
      fi
      # Clean up empty parent dirs
      if [[ -d "specs/features" ]] && [[ -z "$(ls -A specs/features 2>/dev/null)" ]]; then
        rmdir "specs/features"
        [[ -d "specs" ]] && [[ -z "$(ls -A specs 2>/dev/null)" ]] && rmdir "specs"
      fi

      # Remove log directory for this run (logs are gitignored)
      if [[ -d "$LOG_DIR" ]]; then
        rm -rf "$LOG_DIR"
        echo "  Removed log dir: $LOG_DIR"
      fi

      # Commit spec removal if there are tracked changes
      git checkout staging 2>/dev/null || true
      if [[ -n "$(git ls-files --deleted -- specs/ 2>/dev/null)" ]] || \
         [[ -n "$(git status --porcelain -- specs/ 2>/dev/null)" ]]; then
        git add -A specs/
        git commit -m "chore: clean up $SPEC_NAME spec after completion"
        git push origin staging
        echo "  Cleanup committed and pushed."
      fi

      echo "=== Cleanup complete ==="
    else
      COMMENT_BODY="$(printf "Pipeline finished with issues.\n\n**Summary:** %d succeeded, %d failed, %d skipped\n\n**Task breakdown:**\n%s\n\n**PRs created:** %s" \
        "$OK_COUNT" "$FAILED_COUNT" "$SKIPPED_COUNT" "$TASK_DETAILS" "${PR_LIST:-none}")"
      gh issue comment "$PRD_ISSUE" --body "$COMMENT_BODY"
      echo "PRD issue #$PRD_ISSUE left open (not all tasks succeeded)."
    fi
  fi
fi
