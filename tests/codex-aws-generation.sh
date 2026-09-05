#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# Independently ensure the checked-in policy contains no operations beyond
# canonical allowances, including non-read operations accidentally matched.
python3 - "$ROOT" <<'PY'
import fnmatch
import json
from pathlib import Path
import re
import sys
root = Path(sys.argv[1])
allowed = json.loads((root / '.claude/settings.json').read_text())['permissions']['allow']
patterns = [entry[5:-1].split() for entry in allowed if entry.startswith('Bash(aws ')]
rules = (root / '.codex/rules/aws-read.rules').read_text()
groups = re.findall(r'AWS_([A-Z0-9_]+)_READ_OPS = \[([^\]]+)\]', rules)
assert groups, 'No generated AWS service groups'
for name, body in groups:
    service = name.lower().replace('_', '-')
    for operation in re.findall(r'"([a-z0-9-]+)"', body):
        assert any(len(p) >= 3 and p[1] == service and
                   fnmatch.fnmatchcase(operation, p[2]) and
                   (len(p) == 3 or p[3:] == ['*']) for p in patterns), (service, operation)
PY
TMP=$(mktemp -d)
trap 'rm -r "$TMP"' EXIT
mkdir -p "$TMP/.codex/rules" "$TMP/.claude" "$TMP/bin"
cp "$ROOT/.codex/rules/generate-aws-read.sh" "$TMP/.codex/rules/"
printf '%s\n' '{"permissions":{"allow":["Bash(aws ec2 describe-*)","Bash(aws ec2 get-item *)"]}}' > "$TMP/.claude/settings.json"
cat > "$TMP/bin/aws" <<'EOF'
#!/usr/bin/env bash
case "${AWS_FIXTURE:-good}" in
  fail) exit 7 ;;
  malformed) echo 'unexpected help format'; exit 0 ;;
esac
printf '%s\n' 'AVAILABLE COMMANDS' '       o describe-instances' '       o get-item' '       o get-other' '       o delete-item'
EOF
chmod +x "$TMP/bin/aws"
export PATH="$TMP/bin:$PATH"
bash "$TMP/.codex/rules/generate-aws-read.sh"
cp "$TMP/.codex/rules/aws-read.rules" "$TMP/expected"
grep -q '"describe-instances"' "$TMP/expected"
grep -q '"get-item"' "$TMP/expected"
if grep -q '"get-other"\|"delete-item"' "$TMP/expected"; then
  echo 'FAIL: generated operations exceed canonical allowances' >&2; exit 1
fi
for fixture in fail malformed; do
  if AWS_FIXTURE="$fixture" bash "$TMP/.codex/rules/generate-aws-read.sh" > "$TMP/log" 2>&1; then
    echo "FAIL: $fixture discovery succeeded" >&2; exit 1
  fi
  grep -q 'existing output preserved' "$TMP/log"
  cmp "$TMP/expected" "$TMP/.codex/rules/aws-read.rules"
done
printf '%s\n' '{"permissions":{"allow":["Bash(aws ec2 unknown-*)"]}}' > "$TMP/.claude/settings.json"
if bash "$TMP/.codex/rules/generate-aws-read.sh" > "$TMP/log" 2>&1; then
  echo 'FAIL: unmatched allowance succeeded' >&2; exit 1
fi
cmp "$TMP/expected" "$TMP/.codex/rules/aws-read.rules"
printf '%s\n' '{"permissions":{"allow":["Bash(aws ec2 describe-*)"]}}' > "$TMP/.claude/settings.json"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/codex"
chmod +x "$TMP/bin/codex"
if bash "$TMP/.codex/rules/generate-aws-read.sh" > "$TMP/log" 2>&1; then
  echo 'FAIL: invalid policy replaced output' >&2; exit 1
fi
cmp "$TMP/expected" "$TMP/.codex/rules/aws-read.rules"
echo 'AWS generation: exact matching and atomic failure preservation passed'
