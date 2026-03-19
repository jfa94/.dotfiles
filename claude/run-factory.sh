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
  2. Create/checkout develop branch
  3. Check scaffolding (claude-progress.json, feature-status.json, init.sh)
     — runs AI setup if any are missing
  4. For each task (in dependency order):
     a. Branch feat/<task-id> from develop
     b. Run Claude Code in headless mode
     c. Quality gate (pnpm quality)
     d. Push + open PR against develop
  5. Restore original settings.json

Logs are written to logs/<timestamp>-<spec-name>/.
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

# --- Settings swap with trap ---
SETTINGS_FILE="$SCRIPT_DIR/settings.json"
SETTINGS_BAK="$SCRIPT_DIR/settings.json.factory-bak"
SETTINGS_AUTO="$SCRIPT_DIR/settings.autonomous.json"

restore_settings() {
  if [[ -f "$SETTINGS_BAK" ]]; then
    mv "$SETTINGS_BAK" "$SETTINGS_FILE"
    echo "Settings restored."
  fi
}
trap restore_settings EXIT

if [[ ! -f "$SETTINGS_AUTO" ]]; then
  echo "Error: settings.autonomous.json not found at $SETTINGS_AUTO"
  exit 1
fi

if [[ -f "$SETTINGS_FILE" ]]; then
  cp "$SETTINGS_FILE" "$SETTINGS_BAK"
fi
cp "$SETTINGS_AUTO" "$SETTINGS_FILE"
echo "Settings swapped to autonomous mode."

# --- Ensure develop branch exists ---
if ! git show-ref --verify --quiet refs/heads/develop; then
  echo "Creating develop branch from main..."
  git checkout -b develop main
  git push -u origin develop
else
  git checkout develop
  git pull origin develop
fi

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

FAILED=0

for TASK_ID in $TASK_IDS; do
  echo "=== Starting task: $TASK_ID ==="

  # Extract task details
  TITLE=$(jq -r ".[] | select(.task_id==\"$TASK_ID\") | .title" "$TASKS_FILE")
  DESC=$(jq -r ".[] | select(.task_id==\"$TASK_ID\") | .description" "$TASKS_FILE")
  FILES=$(jq -r ".[] | select(.task_id==\"$TASK_ID\") | .files | join(\", \")" "$TASKS_FILE")
  CRITERIA=$(jq -r ".[] | select(.task_id==\"$TASK_ID\") | .acceptance_criteria | join(\"; \")" "$TASKS_FILE")
  TESTS=$(jq -r ".[] | select(.task_id==\"$TASK_ID\") | .tests_to_write | join(\"; \")" "$TASKS_FILE")

  # Create isolated branch from develop
  git checkout develop
  git pull origin develop
  BRANCH="feat/$TASK_ID"
  git checkout -b "$BRANCH"

  # Run Claude Code in headless mode
  claude -p "You are implementing task '$TITLE' for this project.

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
    --output-format json > "$LOG_DIR/$TASK_ID.json" 2>&1

  EXIT_CODE=$?

  if [ $EXIT_CODE -eq 0 ]; then
    # Verify quality gate (belt and braces — Stop hook should catch this)
    if pnpm quality; then
      git push -u origin "$BRANCH"
      gh pr create \
        --title "feat: $TITLE" \
        --body "## Task: $TASK_ID
$DESC

## Acceptance Criteria
$CRITERIA

## Tests
$TESTS" \
        --base develop
      echo "=== $TASK_ID: PR created ==="
    else
      echo "=== $TASK_ID: QUALITY GATE FAILED post-session ==="
      FAILED=$((FAILED + 1))
    fi
  else
    echo "=== $TASK_ID: AGENT FAILED (exit $EXIT_CODE) ==="
    FAILED=$((FAILED + 1))
  fi

  # Return to develop for next task
  git checkout develop
done

echo "=== Pipeline complete. $FAILED task(s) failed. ==="
echo "=== Logs in $LOG_DIR ==="
