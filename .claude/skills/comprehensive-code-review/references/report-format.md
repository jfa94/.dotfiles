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
    ├── systemic-failure-<ts>.md
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
- Codex scope: <mirrors the agents in base/working-tree modes; under --full it is the bounded recent window (HEAD~30...HEAD), narrower than the agents on purpose to stay within Codex's context limit>
- Files reviewed: <N>
- Excluded build outputs: dist, build, out, .next, .nuxt, .svelte-kit, .output, coverage, _.min.js, _.min.css, \*.map
- Lines changed: +<M> -<K> (omit for --full)
- Coverage note: <only when applicable — `--full`: "hotspot-prioritized sampling, not exhaustive";
  diff modes with >2000-line diff: "manifest mode: full diff at .comprehensive-code-review/raw/full-diff.patch,
  reviewers instructed to read all of it in risk order"; add "partial coverage — diff exceeds a single
  reviewer's context, highest-risk files prioritized" only if the pathological fallback triggered>

## Reviewers

| Reviewer          | Status                       | Verdict                                   | Findings |
| ----------------- | ---------------------------- | ----------------------------------------- | -------- |
| architecture      | DONE                         | APPROVE/WARNING/VIOLATION                 | <n>      |
| quality           | DONE                         | APPROVED/REQUEST_CHANGES/NEEDS_DISCUSSION | <n>      |
| security          | DONE                         | SECURE/CONDITIONAL/BLOCKED                | <n>      |
| implementation    | SKIPPED — no --spec provided | —                                         | —        |
| silent-failures   | DONE                         | —                                         | <n>      |
| test-coverage     | DONE                         | —                                         | <n>      |
| type-design       | DONE                         | —                                         | <n>      |
| comment-accuracy  | DONE                         | —                                         | <n>      |
| simplification    | DONE                         | —                                         | <n>      |
| documentation     | DONE                         | DOCS_OK/DOCS_DRIFT/DOCS_BLOCKED           | <n>      |
| systemic-failure  | DONE                         | —                                         | <n>      |
| codex-adversarial | DONE/SKIPPED/BLOCKED         | APPROVE/NEEDS-ATTENTION                   | <n>      |

_(codex-adversarial Verdict gets the suffix `(degraded — narrative fallback)` when DONE via the degraded
path — see the Adversarial-Codex note below.)_

_(a reviewer's Findings cell gets the suffix `(+<m> capped)` when it reported `dropped_by_cap` = m > 0 —
it discarded m candidate findings to respect its findings cap, so coverage below its cap is not implied.)_

## Summary

**Overall: SHIP | NEEDS-CHANGES | INCOMPLETE**

_(deterministic rule — INCOMPLETE: ≥1 reviewer track BLOCKED (judge from what completed; name the
missing tracks). NEEDS-CHANGES: ≥1 verified critical finding, OR security verdict BLOCKED, OR
architecture verdict VIOLATION, OR quality verdict REQUEST_CHANGES. SHIP: none of the above.)_

**Total findings: <N>** _(post-dedup; <n> duplicates merged across reviewers)_

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
- Systemic: <n>
- Implementation-vs-Spec: <n>
- Adversarial-Codex: <n>
- Other: <n>

## Themes

_(≤3 bullets; only when ≥2 verified findings share a root cause — name the root cause and list the
finding titles it explains. Omit the section when no shared root cause exists.)_

---

## Findings by Category

_(sorted severity DESC, then file ASC within each category. Findings tagged `outside_diff` — verified
but citing a file not in the changed-files list (diff modes only) — get the title suffix
"(outside diff)" so pre-existing issues are distinguishable from findings on the change.)_

### Architecture

#### [critical|important|minor] `file:line` — <one-line title>

- **Reviewer**: architecture
- **Quote**: `<verbatim ≥5 chars>`
- **Why**: <reasoning from reviewer output>
- **Fix sketch**: <one sentence>
- **Also flagged by**: <other reviewers, only when the finding was deduped across reviewers — omit otherwise>

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

### Systemic

#### [critical|important|minor] `file:line` — <one-line title>

- **Reviewer**: systemic-failure
- **Failure mode**: `<stuck-state|invariant-without-repair|unsafe-recovery|over-pinned-contract>`
- **Scenario**: <trigger → stuck/wrong state, one or two sentences>
- **Quote**: `<verbatim ≥5 chars — primary anchor (anchors[0])>`
- **Chain anchors**:
  - `file:line` — `<verbatim>` _(role)_
  - `file:line` — `<verbatim>` _(role)_
- **Why**: <reasoning from reviewer output>
- **Fix sketch**: <one sentence>

---

### Implementation-vs-Spec

_(only present if --spec provided)_

### Adversarial-Codex

_(only present if Codex ran. Codex findings are existence-checked, not quote-verified — the review
schema has no `verbatim` field — and carry their native severity + confidence. When Codex is DONE via
the degraded narrative fallback (structured output unavailable), the Reviewers-table Verdict cell is
suffixed `(degraded — narrative fallback)` and this section opens with a line stating the findings were
recovered from raw model text and are **not schema-validated**.)_

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

_(findings that failed citation verification or were adversarially refuted — listed for
transparency. `refuted` rows include the refuter's counter-evidence so they can be audited, but
refuted findings are never resurrected into the report body.)_

| Reviewer | Claimed file:line | Verbatim   | Drop reason                             |
| -------- | ----------------- | ---------- | --------------------------------------- |
| quality  | src/foo.ts:42     | `someText` | verification: dropped_no_match          |
| security | src/bar.ts:10     | `getUser(` | verification: refuted — <refute_reason> |

---

## Not Covered

This review is static analysis by LLM reviewers. It does NOT cover: runtime profiling (only
statically-visible performance defects — N+1, super-linear loops, blocking IO, unbounded growth — are
checked), timing-dependent concurrency races (only statically-visible async/shared-state hazards are
checked), dead code reachable only via dynamic dispatch/reflection, and cross-repo callers of a changed
public API (the contract change itself is flagged; its external blast radius is not traced). Migration
safety is checked statically (destructive ops, rollback paths, lock-heavy operations), not against
production data shapes or volumes. Absence of findings here is not evidence of absence.

**Emergent / systemic failure modes** _(conditional on reviewer roster)_:

- _If `systemic-failure-reviewer` was in the roster:_ Emergent and design-level failure modes were
  covered, but only where statically anchored to ≥2 verified sites reaching a concrete stuck or wrong
  state (taxonomy: `stuck-state`, `invariant-without-repair`, `unsafe-recovery`, `over-pinned-contract`).
  NOT covered: failures that require execution to manifest, cross-service or runtime-timing dependencies,
  or bugs that only emerge after many iterations. Runtime/infra flakes (e.g., a subagent failing to
  return structured output) are not statically reviewable and are out of scope.
- _If `systemic-failure-reviewer` was NOT in the roster:_ Emergent,
  design-level, and process/temporal failure modes were **not reviewed**. Absence of such findings is
  not evidence of their absence.

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
  "category": "Architecture|Security|Quality|Tests|Types|Comments|Simplification|Silent Failures|Documentation|Systemic|Implementation-vs-Spec|Adversarial-Codex|Other",
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
  "also_flagged_by": [
    "<reviewer names; only on findings deduped across reviewers>"
  ],
  "outside_diff": "<true; only on non-systemic findings citing a file outside changedFiles (diff modes)>",
  "refute_reason": "<refuter counter-evidence; only when verification is refuted>",
  "verification": "ok|relocated_ok|refuted|dropped_no_match|dropped_no_citation|dropped_quote_too_short|dropped_systemic_incomplete|dropped_systemic_anchor_unverified|codex_file_missing|codex_line_out_of_range"
}
```

`relocated_ok` = the quote did not match at the claimed line but was found at exactly one other line
in the file (line-number drift); the finding is kept with the corrected line.

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
10. **Systemic** — stuck-states, invariants without repair, unsafe/no-op recovery, over-pinned cross-stage contracts (systemic-failure-reviewer findings only)
11. **Implementation-vs-Spec** — unmet acceptance criteria, misinterpreted requirements
12. **Adversarial-Codex** — design challenges, assumption failures, wrong approach findings
13. **Other** — anything that doesn't fit above; preserve reviewer name
