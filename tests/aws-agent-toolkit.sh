#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZSHRC="$ROOT/.zshrc"
CLAUDE="$ROOT/.claude/CLAUDE.md"
CLAUDE_PLUGINS="$ROOT/.claude/plugins.txt"
CLAUDE_SETTINGS="$ROOT/.claude/settings.json"
AWS_DOC="$ROOT/docs/aws-agent-toolkit.md"
PARITY_DOC="$ROOT/docs/codex-claude-parity.md"

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

grep -qxF "aws-core@agent-toolkit-for-aws" "$CLAUDE_PLUGINS"
if grep -qF "aws-serverless@claude-plugins-official" "$CLAUDE_PLUGINS"; then
  echo "Retired aws-serverless plugin remains in Claude inventory" >&2
  exit 1
fi

plugin_count="$(
  sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$CLAUDE_PLUGINS" |
    sort -u |
    wc -l |
    tr -d '[:space:]'
)"
[[ "$plugin_count" == "19" ]]

jq -e '
  .enabledPlugins["aws-core@agent-toolkit-for-aws"] == false and
  (.enabledPlugins | has("aws-serverless@claude-plugins-official") | not) and
  .extraKnownMarketplaces["agent-toolkit-for-aws"].source.source == "github" and
  .extraKnownMarketplaces["agent-toolkit-for-aws"].source.repo == "aws/agent-toolkit-for-aws"
' "$CLAUDE_SETTINGS" >/dev/null

grep -qF 'official AWS CLI in user-local storage when it is absent or older than 2.35.0' "$AWS_DOC"
grep -qF "Setup does not edit \`~/.aws/config\`, \`~/.aws/credentials\`, run \`aws login\`" "$AWS_DOC"
grep -qF "Repository hooks deny authenticated AWS MCP \`call_aws\`, \`run_script\`, and presigned-URL operations" "$AWS_DOC"
grep -qF "Trusted workspace \`.env*\` files are readable by Codex" "$AWS_DOC"
grep -qF "review the new AWS MCP read-only hook by exact hash" "$AWS_DOC"

grep -qF 'Claude'\''s inventory contains 19 plugins' "$PARITY_DOC"
grep -qF "\`posthog@openai-curated\`" "$PARITY_DOC"
grep -qF "GitHub is deliberately CLI-only through \`gh\`" "$PARITY_DOC"
grep -qF "\`.env*\` reads are limited to trusted workspaces" "$PARITY_DOC"

echo "OK"
