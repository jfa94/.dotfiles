#!/usr/bin/env bash
# run-factory.sh — combined autonomous pipeline: scaffolding + task execution
set -euo pipefail

# --- Resolve paths ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# --- Help ---
show_help() {
  cat <<'HELP'
Usage: .claude/run-factory.sh <feature-spec-name>

Autonomous factory pipeline — sets up scaffolding if needed, then
executes each task from a feature spec on isolated branches.

Arguments:
  <feature-spec-name>   Name of the feature spec under specs/features/

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
  MAX_MINUTES              Max pipeline runtime in minutes (default: 120)
  MAX_CONSECUTIVE_FAILURES Max consecutive failures before stop (default: 3)
  MUTATION_FEEDBACK        Enable mutation testing feedback loop (default: false)
HELP
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  show_help
  exit 0
fi

# --- Validate args ---
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <feature-spec-name>"
  echo "Run with --help for more information."
  exit 1
fi

SPEC_NAME="$1"
SPEC_DIR="specs/features/$SPEC_NAME"
TASKS_FILE="$SPEC_DIR/tasks.json"

# --- Circuit breaker defaults (override via env vars) ---
MAX_TASKS=${MAX_TASKS:-20}
MAX_MINUTES=${MAX_MINUTES:-120}
MAX_CONSECUTIVE_FAILURES=${MAX_CONSECUTIVE_FAILURES:-3}
PIPELINE_START=$(date +%s)
TASKS_RUN=0
CONSECUTIVE_FAILURES=0

# --- Settings swap with trap ---
SETTINGS_FILE="$SCRIPT_DIR/settings.json"
SETTINGS_BAK="$SCRIPT_DIR/settings.json.factory-bak"
SETTINGS_AUTO="$SCRIPT_DIR/settings.autonomous.json"

STATUS_FILE=""
PR_FILE=""

cleanup() {
  if [[ -f "$SETTINGS_BAK" ]]; then
    mv "$SETTINGS_BAK" "$SETTINGS_FILE"
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

if [[ -f "$SETTINGS_FILE" ]]; then
  cp "$SETTINGS_FILE" "$SETTINGS_BAK"
fi
cp "$SETTINGS_AUTO" "$SETTINGS_FILE"
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

  # Model routing by task complexity
  COMPLEXITY=$(jq -r ".[] | select(.task_id==\"$TASK_ID\") | .complexity // \"standard\"" "$TASKS_FILE")
  case "$COMPLEXITY" in
    simple)  MODEL_FLAG="--model haiku" ;;
    complex) MODEL_FLAG="--model opus" ;;
    *)       MODEL_FLAG="" ;;
  esac

  # Export task ID for audit log correlation
  export FACTORY_TASK_ID="$TASK_ID"

  # Create isolated branch from staging
  BRANCH="feat/$TASK_ID"
  git checkout -b "$BRANCH"

  # Run Claude Code in headless mode
  EXIT_CODE=0
  claude -p $MODEL_FLAG "You are implementing task '$TITLE' for this project.

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
    --max-turns 40 \
    --output-format json > "$LOG_DIR/$TASK_ID.json" 2>&1 || EXIT_CODE=$?

  if [ $EXIT_CODE -eq 0 ]; then
    # Quality gate
    if pnpm quality; then
      git push -u origin "$BRANCH"
      PR_URL=$(gh pr create \
        --title "feat: $TITLE" \
        --body "## Task: $TASK_ID
$DESC

## Acceptance Criteria
$CRITERIA

## Tests
$TESTS" \
        --base staging) || true

      if [[ -n "$PR_URL" ]]; then
        PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$')
        echo "${TASK_ID}=ok" >> "$STATUS_FILE"
        echo "${TASK_ID}=${PR_NUMBER}" >> "$PR_FILE"
        echo "=== $TASK_ID: PR #$PR_NUMBER created ==="
      else
        echo "=== $TASK_ID: PR CREATION FAILED ==="
        echo "${TASK_ID}=failed" >> "$STATUS_FILE"
      fi
    else
      echo "=== $TASK_ID: QUALITY GATE FAILED ==="
      echo "${TASK_ID}=failed" >> "$STATUS_FILE"
    fi
  else
    echo "=== $TASK_ID: AGENT FAILED (exit $EXIT_CODE) ==="
    echo "${TASK_ID}=failed" >> "$STATUS_FILE"
  fi

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
