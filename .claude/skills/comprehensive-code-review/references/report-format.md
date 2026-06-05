# Report Format Reference

## File locations

```
.comprehensive-code-review/
├── report-<UTC-iso>.md          # final consolidated report (this format)
└── raw/
    ├── architecture-<ts>.md
    ├── quality-<ts>.md
    ├── security-<ts>.md
    ├── implementation-<ts>.md   # omitted if --spec not provided
    ├── silent-failures-<ts>.md
    ├── test-coverage-<ts>.md
    ├── type-design-<ts>.md
    ├── comment-accuracy-<ts>.md
    ├── simplification-<ts>.md
    ├── documentation-<ts>.md
    ├── codex-adversarial.json       # Codex structured machine output (source of truth)
    └── codex-adversarial-<ts>.md    # human-readable render of codex-adversarial.json
```

## Report skeleton

```markdown
<!-- comprehensive-code-review report -->

# Comprehensive Code Review — <UTC-ISO-8601 timestamp>

## Scope

- Mode: <full | base | working-tree>
- Agent scope: <e.g., "ENTIRE CODEBASE (current state)" | "abc123...HEAD" | "working tree vs HEAD">
- Codex scope: <mirrors the agents in base/working-tree modes; under --full it is the bounded recent window (HEAD~10...HEAD), narrower than the agents on purpose to stay within Codex's context limit>
- Files reviewed: <N>
- Lines changed: +<M> -<K> (omit for --full)

## Reviewers

| Reviewer          | Status                       | Verdict                         | Findings |
| ----------------- | ---------------------------- | ------------------------------- | -------- |
| architecture      | DONE                         | APPROVE/WARNING/VIOLATION       | <n>      |
| quality           | DONE                         | APPROVED/REQUEST_CHANGES        | <n>      |
| security          | DONE                         | SECURE/CONDITIONAL/BLOCKED      | <n>      |
| implementation    | SKIPPED — no --spec provided | —                               | —        |
| silent-failures   | DONE                         | —                               | <n>      |
| test-coverage     | DONE                         | —                               | <n>      |
| type-design       | DONE                         | —                               | <n>      |
| comment-accuracy  | DONE                         | —                               | <n>      |
| simplification    | DONE                         | —                               | <n>      |
| documentation     | DONE                         | DOCS_OK/DOCS_DRIFT/DOCS_BLOCKED | <n>      |
| codex-adversarial | DONE/SKIPPED/BLOCKED         | APPROVE/NEEDS-ATTENTION         | <n>      |

## Summary

**Total findings: <N>**

- critical: <n>
- important: <n>
- minor: <n>

By category:

- Architecture: <n>
- Security: <n>
- Quality: <n>
- Tests: <n>
- Types: <n>
- Comments: <n>
- Simplification: <n>
- Silent Failures: <n>
- Documentation: <n>
- Implementation-vs-Spec: <n>
- Adversarial-Codex: <n>
- Other: <n>

---

## Findings by Category

_(sorted severity DESC, then file ASC within each category)_

### Architecture

#### [critical|important|minor] `file:line` — <one-line title>

- **Reviewer**: architecture
- **Quote**: `<verbatim ≥5 chars>`
- **Why**: <reasoning from reviewer output>
- **Fix sketch**: <one sentence>

---

### Security

#### [critical|important|minor] `file:line` — <one-line title>

- **Reviewer**: security
- **Quote**: `<verbatim ≥5 chars>`
- **Why**: <reasoning>
- **Fix sketch**: <one sentence>

---

### Quality

_(same structure)_

### Tests

_(same structure)_

### Types

_(same structure)_

### Comments

_(same structure)_

### Simplification

_(same structure)_

### Silent Failures

_(same structure)_

### Documentation

_(same structure)_

### Implementation-vs-Spec

_(only present if --spec provided)_

### Adversarial-Codex

_(only present if Codex ran. Codex findings are existence-checked, not quote-verified — the review
schema has no `verbatim` field — and carry their native severity + confidence.)_

#### [critical|important|minor] `file:line_start[-line_end]` — <one-line title>

- **Reviewer**: codex-adversarial
- **Codex severity**: <critical|high|medium|low> · **Confidence**: <0–1>
- **Quote**: _n/a — existence-checked (review schema has no verbatim field)_
- **Why**: <body>
- **Fix sketch**: <recommendation>

### Other

_(findings that don't fit above categories — reviewer name preserved)_

---

## Dropped Findings

_(findings that failed citation verification — listed for transparency)_

| Reviewer | Claimed file:line | Verbatim   | Drop reason                    |
| -------- | ----------------- | ---------- | ------------------------------ |
| quality  | src/foo.ts:42     | `someText` | verification: dropped_no_match |

---

## Raw Outputs

Full reviewer outputs are in `.comprehensive-code-review/raw/`.
```

## Severity mapping

When a reviewer uses its own severity vocabulary, map to the standard set as follows:

| Reviewer vocabulary    | Standard severity |
| ---------------------- | ----------------- |
| CRITICAL / P0          | critical          |
| HIGH / P1 / important  | important         |
| MEDIUM / P2            | important         |
| LOW / P3 / minor / low | minor             |
| WARNING (non-blocking) | minor             |

Codex's `critical|high|medium|low` map by the same rule (`critical→critical`, `high→important`,
`medium→important`, `low→minor`); keep the native level as **Codex severity** on the rendered finding so
the 4→3 collapse loses no signal.

## Finding JSON schema (for machine parsing)

```json
{
  "category": "Architecture|Security|Quality|Tests|Types|Comments|Simplification|Silent Failures|Documentation|Implementation-vs-Spec|Adversarial-Codex|Other",
  "severity": "critical|important|minor",
  "reviewer": "<agent name>",
  "file": "path/to/file.ts",
  "line": 42,
  "verbatim": "<quote ≥5 chars; omitted for Codex — its review schema has no verbatim field>",
  "title": "<one-line title>",
  "why": "<reasoning>",
  "fix_sketch": "<one sentence>",
  "confidence": "<0-1; Codex findings only>",
  "codex_severity": "<critical|high|medium|low; Codex findings only, native level pre-mapping>",
  "verification": "ok|dropped_no_match|dropped_no_citation|codex_file_missing|codex_line_out_of_range"
}
```

## Category assignment rules

Assign each finding to the first matching category:

1. **Architecture** — import violations, layer violations, coupling, god objects, circular deps
2. **Security** — injection, auth/authz, secrets, crypto, CORS, rate limiting
3. **Quality** — logic errors, edge cases, null safety, error swallowing, AI anti-patterns
4. **Tests** — missing coverage, weak assertions, unrealistic mocks, brittle tests
5. **Types** — invariant weakness, encapsulation gaps, anemic models
6. **Comments** — inaccurate docstrings, stale comments, misleading descriptions
7. **Simplification** — dead code, over-engineering, copy-paste drift, nested ternaries
8. **Silent Failures** — empty catch blocks, swallowed errors, unjustified fallbacks
9. **Documentation** — Scribe tree gaps, stale marker, content inaccuracies, type-purity violations
10. **Implementation-vs-Spec** — unmet acceptance criteria, misinterpreted requirements
11. **Adversarial-Codex** — design challenges, assumption failures, wrong approach findings
12. **Other** — anything that doesn't fit above; preserve reviewer name
