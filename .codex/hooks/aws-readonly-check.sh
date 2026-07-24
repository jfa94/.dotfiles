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

# Approval routing lives in the execpolicy rules (aws-read.rules auto-allows
# enumerated reads; everything else prompts). This hook only enforces the
# secret-safety invariant: secret values must never enter the model context,
# so approving the prompt is not an option.
if [[ "$SERVICE" == "secretsmanager" ]]; then
  case "$OP" in
    get-secret-value|batch-get-secret-value)
      deny "Secret values must never enter the context. Use asm-exec with {{resolve:secretsmanager:secret-id:SecretString:json-key}} so the secret resolves at runtime."
      ;;
  esac
fi
exit 0
