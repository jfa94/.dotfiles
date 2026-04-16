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

if [ -n "$RESETS" ]; then
    NOW=$(date +%s)
    REMAINING=$((RESETS - NOW))
    HOURS=$((REMAINING / 3600))
    MINS=$(((REMAINING % 3600) / 60))
    USAGE=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // 0' | cut -d. -f1)
    REMAINING_PCT=$((100 - USAGE))
    echo "$MODEL in $DIR$GIT | ${REMAINING_PCT}% left for ${HOURS}h ${MINS}m"
else
    echo "$MODEL in $DIR$GIT"
fi
