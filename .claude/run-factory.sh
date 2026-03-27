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

Autonomous factory pipeline — sets up scaffolding if needed, then
executes each task from a feature spec on isolated branches.

Arguments:
  <feature-spec-name>   Name of the feature spec under specs/features/ (interactive if omitted)

Prerequisites:
  claude    Claude Code CLI
  jq        JSON processor
  gh        GitHub CLI (authenticated)
  pnpm      Package manager
  git       With a configured remote

Expected project structure:
  specs/features/<name>/tasks.json    Task definitions with dependencies
  .claude/settings.autonomous.json    Autonomous permissions/hooks

Pipeline steps:
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
     g. Push + open PR against staging with auto-merge enabled
  5. Print summary (ok/failed/skipped) and restore settings

Logs are written to logs/<timestamp>-<spec-name>/.

Environment variables:
  MAX_TASKS                Max tasks before circuit breaker (default: 20)
  MAX_MINUTES              Max pipeline runtime in minutes (default: 360)
  MAX_CONSECUTIVE_FAILURES Max consecutive failures before stop (default: 3)
  MAX_RETRIES              Max retries per failed task (default: 2, 0 = no retry)
  MUTATION_FEEDBACK        Enable mutation testing feedback loop (default: false)
HELP
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  show_help
  exit 0
fi

# --- Resolve spec name ---
if [[ $# -eq 1 ]]; then
  SPEC_NAME="$1"
elif [[ $# -eq 0 ]]; then
  AVAILABLE_SPECS=()
  for tasks_file in specs/features/*/tasks.json; do
    [[ -f "$tasks_file" ]] || continue
    AVAILABLE_SPECS+=("$(basename "$(dirname "$tasks_file")")")
  done

  if [[ ${#AVAILABLE_SPECS[@]} -eq 0 ]]; then
    echo "No feature specs found in specs/features/."
    echo "Create a spec first (try the prd-to-spec skill)."
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
else
  echo "Usage: $0 [<feature-spec-name>]"
  echo "Run with --help for more information."
  exit 1
fi

SPEC_DIR="specs/features/$SPEC_NAME"
TASKS_FILE="$SPEC_DIR/tasks.json"

# --- Circuit breaker defaults (override via env vars) ---
MAX_TASKS=${MAX_TASKS:-20}
MAX_MINUTES=${MAX_MINUTES:-360}
MAX_CONSECUTIVE_FAILURES=${MAX_CONSECUTIVE_FAILURES:-3}
MAX_RETRIES=${MAX_RETRIES:-2}
PIPELINE_START=$(date +%s)
TASKS_RUN=0
CONSECUTIVE_FAILURES=0

# --- Settings swap with trap ---
SETTINGS_LOCAL="$SCRIPT_DIR/settings.local.json"
SETTINGS_LOCAL_BAK="$SCRIPT_DIR/settings.local.json.factory-bak"
SETTINGS_AUTO="$SCRIPT_DIR/settings.autonomous.json"

STATUS_FILE=""
PR_FILE=""

cleanup() {
  if [[ -f "$SETTINGS_LOCAL_BAK" ]]; then
    mv "$SETTINGS_LOCAL_BAK" "$SETTINGS_LOCAL"
    echo "Settings restored."
  elif [[ -f "$SETTINGS_LOCAL" ]]; then
    rm -f "$SETTINGS_LOCAL"
    echo "Settings restored."
  fi
  [[ -n "$STATUS_FILE" ]] && rm -f "$STATUS_FILE"
  [[ -n "$PR_FILE" ]] && rm -f "$PR_FILE"
}
trap cleanup EXIT

if [[ ! -f "$SETTINGS_AUTO" ]]; then
  echo "Error: settings.autonomous.json not found at $SETTINGS_AUTO"
  exit 1
fi

if [[ -f "$SETTINGS_LOCAL" ]]; then
  cp "$SETTINGS_LOCAL" "$SETTINGS_LOCAL_BAK"
fi
cp "$SETTINGS_AUTO" "$SETTINGS_LOCAL"
echo "Settings swapped to autonomous mode."

# --- Smart staging functions ---
reconcile_staging_with_develop() {
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

  while [[ $elapsed -lt $timeout_secs ]]; do
    local state
    state=$(gh pr view "$pr_number" --json state -q '.state')
    if [[ "$state" == "MERGED" ]]; then
      return 0
    fi
    if [[ "$state" == "CLOSED" ]]; then
      return 1
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
    --output-format json > logs/initialiser.json 2>&1

  echo "Project setup complete. Log: logs/initialiser.json"
fi

# --- Validate tasks file ---
if [[ ! -f "$TASKS_FILE" ]]; then
  echo "Error: $TASKS_FILE not found."
  echo "Create a tasks.json in $SPEC_DIR before running the factory."
  exit 1
fi

# --- Init tracking ---
STATUS_FILE=$(mktemp /tmp/factory-status.XXXXXX)
PR_FILE=$(mktemp /tmp/factory-prs.XXXXXX)

# --- Factory loop ---
LOG_DIR="logs/$(date +%Y%m%d-%H%M%S)-$SPEC_NAME"
mkdir -p "$LOG_DIR"

# Topological sort of tasks by dependency order
TASK_IDS=$(jq -r '
  def topo:
    . as $tasks |
    [.[] | select(.depends_on | length == 0) | .task_id] as $ready |
    if ($ready | length) == 0 then []
    else $ready + ([$tasks[] | select(.task_id as $id | $ready | index($id) | not) | .depends_on -= $ready] | topo)
    end;
  topo | .[]
' "$TASKS_FILE")

for TASK_ID in $TASK_IDS; do
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
  DEPS=$(jq -r ".[] | select(.task_id==\"$TASK_ID\") | .depends_on // [] | .[]" "$TASKS_FILE")
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
  TITLE=$(jq -r ".[] | select(.task_id==\"$TASK_ID\") | .title" "$TASKS_FILE")
  DESC=$(jq -r ".[] | select(.task_id==\"$TASK_ID\") | .description" "$TASKS_FILE")
  FILES=$(jq -r ".[] | select(.task_id==\"$TASK_ID\") | .files | join(\", \")" "$TASKS_FILE")
  CRITERIA=$(jq -r ".[] | select(.task_id==\"$TASK_ID\") | .acceptance_criteria | join(\"; \")" "$TASKS_FILE")
  TESTS=$(jq -r ".[] | select(.task_id==\"$TASK_ID\") | .tests_to_write | join(\"; \")" "$TASKS_FILE")

  # Model + turn-budget routing by task complexity
  COMPLEXITY=$(jq -r ".[] | select(.task_id==\"$TASK_ID\") | .complexity // \"standard\"" "$TASKS_FILE")
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
  TASK_OUTCOME=""
  FAILURE_TYPE=""
  PREV_QUALITY_LOG=""
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
      esac
    fi

    # Run Claude Code in headless mode
    LOG_FILE="$LOG_DIR/${TASK_ID}.attempt-${ATTEMPT}.json"
    EXIT_CODE=0
    claude -p $MODEL_FLAG "${RETRY_CONTEXT}You are implementing task '$TITLE' for this project.

## Phase 1: Orient (do this BEFORE writing any code)
1. Run pwd to confirm your working directory
2. Read claude-progress.json to understand what previous sessions accomplished
3. Read feature-status.json to see which features pass and which don't
4. Run git log --oneline -10 to see recent changes
5. Run init.sh to start the dev server and verify the app is in a working state
6. If the app is broken, fix existing bugs BEFORE starting new work

## Phase 2: Implement (one task only)
Task: $DESC
Files to create/modify: $FILES
Acceptance criteria: $CRITERIA
Tests to write: $TESTS

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
- Do NOT leave broken code on the branch" \
      --max-turns "$TURN_BUDGET" \
      --output-format json > "$LOG_FILE" 2>"$LOG_DIR/${TASK_ID}.attempt-${ATTEMPT}.stderr.log" || EXIT_CODE=$?

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
      git push -u origin "$BRANCH"
      PR_URL=$(gh pr create \
        --title "feat: $TITLE" \
        --body "## Task: $TASK_ID
$DESC

## Acceptance Criteria
$CRITERIA

## Tests
$TESTS" \
        --base staging 2>/dev/null) || true

      # Inline retry for PR creation failure
      if [[ -z "$PR_URL" ]]; then
        echo "  PR creation failed, retrying in 5s..."
        sleep 5
        git push -u origin "$BRANCH" 2>/dev/null || true
        PR_URL=$(gh pr create \
          --title "feat: $TITLE" \
          --body "## Task: $TASK_ID
$DESC

## Acceptance Criteria
$CRITERIA

## Tests
$TESTS" \
          --base staging 2>/dev/null) || true
      fi

      if [[ -n "$PR_URL" ]]; then
        PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$')
        echo "${TASK_ID}=${PR_NUMBER}" >> "$PR_FILE"
        echo "=== $TASK_ID: PR #$PR_NUMBER created (attempt $ATTEMPT, cost \$$TASK_COST) ==="
        TASK_OUTCOME="ok"
      else
        echo "=== $TASK_ID: PR CREATION FAILED ==="
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
  TASK_STATUS=$(grep "^${TASK_ID}=" "$STATUS_FILE" | tail -1 | cut -d= -f2)
  case "$TASK_STATUS" in
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
          TASK_DETAILS="${TASK_DETAILS}\n- \`${tid}\`: ok (PR #${tid_pr})"
          ;;
        failed)
          TASK_DETAILS="${TASK_DETAILS}\n- \`${tid}\`: **failed** — check logs in \`${LOG_DIR}/${tid}.json\`"
          ;;
        skipped)
          # Find which dependency caused the skip
          skip_deps=$(jq -r ".[] | select(.task_id==\"$tid\") | .depends_on[]" "$TASKS_FILE" 2>/dev/null)
          skip_reason=""
          for sd in $skip_deps; do
            sd_status=$(grep "^${sd}=" "$STATUS_FILE" | tail -1 | cut -d= -f2)
            if [[ "$sd_status" == "failed" || "$sd_status" == "skipped" ]]; then
              skip_reason="dependency \`${sd}\` ${sd_status}"
              break
            fi
          done
          TASK_DETAILS="${TASK_DETAILS}\n- \`${tid}\`: **skipped** — ${skip_reason:-unknown reason}"
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
      for tid in $TASK_IDS; do
        branch="feat/$tid"
        if git show-ref --verify --quiet "refs/heads/$branch"; then
          git branch -D "$branch" 2>/dev/null && echo "  Deleted local branch: $branch"
        fi
      done

      # Delete remote feat/ branches (may already be gone via GitHub auto-delete)
      for tid in $TASK_IDS; do
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
      if [[ -n "$(git ls-files --deleted -- specs/ 2>/dev/null)" ]] || \
         [[ -n "$(git status --porcelain -- specs/ 2>/dev/null)" ]]; then
        git add -A specs/
        git commit -m "chore: clean up $SPEC_NAME spec after completion"
        git push origin staging
        echo "  Cleanup committed and pushed."
      fi

      echo "=== Cleanup complete ==="
    else
      COMMENT_BODY="$(printf "Pipeline finished with issues.\n\n**Summary:** %d succeeded, %d failed, %d skipped\n\n**Task breakdown:**\n%b\n\n**PRs created:** %s" \
        "$OK_COUNT" "$FAILED_COUNT" "$SKIPPED_COUNT" "$TASK_DETAILS" "${PR_LIST:-none}")"
      gh issue comment "$PRD_ISSUE" --body "$COMMENT_BODY"
      echo "PRD issue #$PRD_ISSUE left open (not all tasks succeeded)."
    fi
  fi
fi
