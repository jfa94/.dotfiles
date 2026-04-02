#!/bin/bash
input=$(cat)

MODEL=$(echo "$input" | jq -r '.model.display_name' | sed 's/ [0-9][0-9.]*$//')
DIR=$(echo "$input" | jq -r '.workspace.current_dir' | sed 's|.*/||')
RESETS=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')

if [ -n "$RESETS" ]; then
    NOW=$(date +%s)
    REMAINING=$((RESETS - NOW))
    HOURS=$((REMAINING / 3600))
    MINS=$(((REMAINING % 3600) / 60))
    USAGE=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // 0' | cut -d. -f1)
    REMAINING_PCT=$((100 - USAGE))
    echo "$MODEL in $DIR | ${REMAINING_PCT}% left for ${HOURS}h ${MINS}m"
else
    echo "$MODEL in $DIR"
fi
