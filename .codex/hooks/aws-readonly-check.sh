#!/usr/bin/env bash
set -euo pipefail

. "${HOME}/.codex/hooks/hook-lib.sh"

INPUT=$(cat)
CMD=$(json_get "$INPUT" '.tool_input.command // empty')
[[ -z "$CMD" ]] && exit 0

set +e
read -r -a ARGS <<< "$CMD"
set -e

[[ "${ARGS[0]:-}" == "aws" ]] || exit 0

i=1
while [[ $i -lt ${#ARGS[@]} && "${ARGS[$i]}" == --* ]]; do
  case "${ARGS[$i]}" in
    --profile|--region|--output|--endpoint-url|--query|--cli-input-json)
      i=$((i + 2))
      ;;
    *)
      i=$((i + 1))
      ;;
  esac
done

SERVICE="${ARGS[$i]:-}"
OP="${ARGS[$((i + 1))]:-}"
[[ -n "$SERVICE" ]] || exit 0

case "$SERVICE" in
  help)
    exit 0
    ;;
  s3)
    if [[ "$OP" == "ls" ]]; then
      exit 0
    fi
    if [[ "$OP" == "cp" && "${ARGS[$((i + 2))]:-}" == s3://* && "${ARGS[$((i + 3))]:-}" == "-" ]]; then
      exit 0
    fi
    deny "AWS s3 is restricted to ls and streaming s3:// objects to stdout."
    exit 0
    ;;
  secretsmanager)
    case "$OP" in
      list-*|describe-*) exit 0 ;;
      *)
        deny "AWS Secrets Manager is restricted to list-* and describe-* operations."
        exit 0
        ;;
    esac
    ;;
  logs)
    case "$OP" in
      describe-*|filter-log-events|get-log-events|get-query-results|start-query|stop-query|tail|list-*) exit 0 ;;
      *)
        deny "AWS CloudWatch Logs is restricted to read/query operations."
        exit 0
        ;;
    esac
    ;;
  configure)
    case "$OP" in
      list|list-profiles|get) exit 0 ;;
      *)
        deny "aws configure is restricted to list, list-profiles, and get."
        exit 0
        ;;
    esac
    ;;
esac

case "$OP" in
  describe-*|list-*|get-*|head-*|scan|query|batch-get-*|transact-get-*|search-*|select-*|simulate-*|check-*|test-dns-answer|view-billing|decode-authorization-message|download-db-log-file-portion)
    exit 0
    ;;
  *)
    deny "AWS command is not read-oriented. Allowed operations are describe-*, list-*, get-*, head-*, batch-get-*, transact-get-*, search-*, select-*, simulate-*, check-*, scan, and query, with service-specific restrictions for s3, logs, secretsmanager, and configure."
    ;;
esac
