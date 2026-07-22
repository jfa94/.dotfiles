#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZSHRC="$ROOT/.zshrc"
CLAUDE="$ROOT/.claude/CLAUDE.md"

grep -qxF "export PATH=\"\$HOME/.local/bin:\$PATH\"" "$ZSHRC"
grep -qxF "command -v direnv &>/dev/null && eval \"\$(direnv hook zsh)\"" "$ZSHRC"
grep -qxF '## AWS' "$CLAUDE"
grep -qF 'Prefer the AWS MCP Server for AWS interactions' "$CLAUDE"
grep -qF 'check whether a relevant AWS skill is available' "$CLAUDE"
grep -qF 'verify against documentation rather than guessing' "$CLAUDE"
grep -qF 'prefer infrastructure-as-code (AWS CDK or CloudFormation)' "$CLAUDE"
grep -qF 'follow AWS Well-Architected Framework principles' "$CLAUDE"
grep -qF 'Do not use em dashes in AWS resource names or descriptions' "$CLAUDE"
grep -qF "MUST load the \`aws-secrets-manager\` skill first" "$CLAUDE"
grep -qF "MUST NOT call \`secretsmanager get-secret-value\` or \`batch-get-secret-value\`" "$CLAUDE"
grep -qF "MUST use \`{{resolve:secretsmanager:secret-id:SecretString:json-key}}\` with \`asm-exec\`" "$CLAUDE"

echo "OK"
