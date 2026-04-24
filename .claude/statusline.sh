#!/bin/bash
input=$(cat)

MODEL=$(echo "$input" | jq -r '.model.display_name' | sed 's/ [0-9][0-9.]*$//')
DIR_PATH=$(echo "$input" | jq -r '.workspace.current_dir')
DIR=$(echo "$DIR_PATH" | sed 's|.*/||')
RESETS=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')

GIT=""
if BRANCH=$(git -C "$DIR_PATH" branch --show-current 2>/dev/null) && [ -n "$BRANCH" ]; then
    INDICATORS=""
    git -C "$DIR_PATH" diff --quiet 2>/dev/null || INDICATORS+="*"
    git -C "$DIR_PATH" diff --cached --quiet 2>/dev/null || INDICATORS+="+"
    GIT=" (${BRANCH}${INDICATORS})"
fi

CTX=$(echo "$input" | jq -r '
  if (.context_window.used_percentage == null) then "0\t0\tnull"
  else [(.context_window.context_window_size * .context_window.used_percentage / 100 | round), .context_window.context_window_size, .context_window.used_percentage] | @tsv
  end' | awk -F'\t' '{
  used=$1; max=$2; pct=$3;
  if (pct == "null") { printf "0.0k tokens (100%%)"; next }
  if (max >= 1000000) { max_str = sprintf("%.1fM", max/1000000) }
  else { max_str = sprintf("%dk", max/1000) }
  printf "%.1fk/%s tokens (%d%%)", used/1000, max_str, pct
}')

if [ -n "$RESETS" ]; then
    NOW=$(date +%s)
    REMAINING=$((RESETS - NOW))
    HOURS=$((REMAINING / 3600))
    MINS=$(((REMAINING % 3600) / 60))
    USAGE=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // 0' | cut -d. -f1)
    REMAINING_PCT=$((100 - USAGE))
    echo "$MODEL in $DIR$GIT | $CTX | ${REMAINING_PCT}% left for ${HOURS}h ${MINS}m"
else
    echo "$MODEL in $DIR$GIT | $CTX"
fi
