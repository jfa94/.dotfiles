# Report Format Reference

## File locations

```
<runDir>/                            # .code-review/runs/<runId>/
├── report.md                        # final consolidated report (this format) — the only human render
├── run.json                         # runtime/profile/run identity + lifecycle status
└── raw/                             # machine record; no per-reviewer or Codex .md renders
    ├── workflow-result.json         # reviewer fan-out output (persisted by the workflow)
    ├── codex-adversarial.json       # Codex structured machine output (source of truth)
    ├── codex-verify-result.json     # Codex refutation pass output (when Phase 6.5 ran)
    ├── changed-files.txt            # input to verify-citations.mjs
    └── verified-findings.json       # verify-citations.mjs output (findings/previouslyAdjudicated/dropped/stats)

<repoRoot>/.code-review/dispositions.json   # cross-run adjudication ledger (committed to git;
                                            # written by review-run.mjs disposition, read via --dispositions)
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
- Excluded local/generated outputs: .code-review, dist, build, out, .next, .nuxt, .svelte-kit, .output, coverage, _.min.js, _.min.css, \*.map
- Lines changed: +<M> -<K> (omit for --full)
- Coverage note: <only when applicable — `--full`: "hotspot-prioritized sampling, not exhaustive";
  diff modes with >2000-line diff: "manifest mode: full diff at <runDir>/raw/full-diff.patch,
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
missing tracks). NEEDS-CHANGES: `stats.blocking > 0` in verified-findings.json — ≥1 verified
critical, or ≥1 verified important from a blocking reviewer (test-coverage, simplification,
comment-accuracy, and documentation findings never block; important+theoretical is already
downgraded to minor upstream). SHIP: none of the above. Reviewer prose verdicts
(REQUEST_CHANGES, VIOLATION, BLOCKED-as-verdict, …) are informational only and never gate.)_

**Total findings: <N>** _(post-dedup; <n> duplicates merged across reviewers)_

- critical: <n>
- important: <n>
- minor: <n>

**Previously adjudicated: <n>** _(matched the disposition ledger; excluded from the verdict — see
Previously Adjudicated below. Omit this line when 0.)_

**Recommendation: STOP-LOOPING** _(render only when run.json `passNumber` ≥ 3 AND the verdict is
NEEDS-CHANGES: three passes without convergence means a human should adjudicate the remaining
blockers — further passes add armor, not correctness.)_

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
finding titles it explains. Omit the section when no shared root cause exists. Themes may cite only
findings present in the report body: refuted or previously-adjudicated findings and their residuals
never seed or support a theme — Iron Law 5.)_

## Fix-Scope Contract

_(rendered verbatim into every report — binds any fixer or loop-caller acting on it)_

- Fix ONLY what a verified finding explicitly cites; smallest diff that resolves it.
- Deletion is a valid fix — prefer removing the defect over guarding around it.
- No new tests, guards, or validation beyond a finding's explicit scope.
- New comments: max 1 line, never narrating a refuted or adjudicated scenario.
- Residuals of refuted findings are dead (Iron Law 5) — do not fix, soften, or "harden against" them.
- Previously-adjudicated findings are out of scope; the only path back is a new finding with
  `challenges_disposition: <id>` citing NEW evidence.

---

## Findings by Category

_(sorted severity DESC, then file ASC within each category. Findings tagged `outside_diff` — verified
but citing a file not in the changed-files list (diff modes only) — get the title suffix
"(outside diff)" so pre-existing issues are distinguishable from findings on the change.)_

### Architecture

#### [critical|important|minor] `file:line` — <one-line title>

- **Reviewer**: architecture
- **Quote**: `<verbatim ≥10 chars>`
- **Why**: <reasoning from reviewer output>
- **Fix sketch**: <one sentence>
- **Also flagged by**: <other reviewers, only when the finding was deduped across reviewers — omit otherwise>

---

### Security

#### [critical|important|minor] `file:line` — <one-line title>

- **Reviewer**: security
- **Quote**: `<verbatim ≥10 chars>`
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
- **Quote**: `<verbatim ≥10 chars — primary anchor (anchors[0])>`
- **Chain anchors**:
  - `file:line` — `<verbatim>` _(role)_
  - `file:line` — `<verbatim>` _(role)_
- **Why**: <reasoning from reviewer output>
- **Fix sketch**: <one sentence>

---

### Implementation-vs-Spec

_(only present if --spec provided)_

### Adversarial-Codex

_(only present if Codex ran. Codex findings are existence-checked and — for native
critical/high/medium — refuter-verified via the workflow's in-script Codex-verify stage, but not
quote-verified: the review schema has no `verbatim` field. They carry their native severity +
confidence. Refuted Codex findings appear in Dropped Findings like any refuted reviewer finding.
When Codex is DONE via the degraded narrative fallback (structured output unavailable), the
Reviewers-table Verdict cell is suffixed `(degraded — narrative fallback)`, this section opens with
a line stating the findings were recovered from raw model text and are **not schema-validated**,
and no refutation pass runs.)_

#### [critical|important|minor] `file:line_start[-line_end]` — <one-line title>

- **Reviewer**: codex-adversarial
- **Codex severity**: <critical|high|medium|low> · **Confidence**: <0–1>
- **Quote**: _n/a — existence-checked (review schema has no verbatim field)_
- **Why**: <body>
- **Fix sketch**: <recommendation>

### Other

_(findings that don't fit above categories — reviewer name preserved)_

---

## Previously Adjudicated

_(verified findings whose fingerprint matched an active entry in `.code-review/dispositions.json` —
already decided in a prior pass; excluded from the verdict, from Themes, and from fix scope. A
finding that challenges its disposition stays in Findings by Category instead, tagged
"⚑ challenges disposition #<id>". Omit the section when empty.)_

| #   | Status        | File — claim                 | Re-raised by      | Adjudication reason    |
| --- | ------------- | ---------------------------- | ----------------- | ---------------------- |
| 10  | accepted-risk | src/upload.ts — "TOCTOU ..." | codex-adversarial | single-writer topology |

---

## Dropped Findings

_(findings that failed citation verification or were adversarially refuted — listed for
transparency. `refuted` rows include the refuter's counter-evidence so they can be audited, but
refuted findings are never resurrected into the report body. Refuted Codex findings (Phase 6.5)
appear here too, with reviewer `codex-adversarial`.)_

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

Full reviewer outputs are in `<runDir>/raw/`.
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
  "verbatim": "<quote ≥10 chars; omitted for Codex — its review schema has no verbatim field>",
  "title": "<one-line title>",
  "why": "<reasoning>",
  "fix_sketch": "<one sentence>",
  "confidence": "<0-1; Codex findings only>",
  "codex_severity": "<critical|high|medium|low; Codex findings only, native level pre-mapping>",
  "also_flagged_by": [
    "<reviewer names; only on findings deduped across reviewers>"
  ],
  "reachability": "<direct|conditional|theoretical; reviewer-set on critical/important findings>",
  "downgraded_from": "<'important'; only when important+theoretical was auto-downgraded to minor>",
  "blocking": "<boolean; drives the Summary verdict — critical, or important from a blocking reviewer>",
  "challenges_disposition": "<ledger id; only on findings challenging a prior disposition>",
  "challenge_unmatched": "<true; the challenge id matched no active ledger entry — kept and surfaced>",
  "outside_diff": "<true; only on non-systemic findings citing a file outside changedFiles (diff modes)>",
  "refute_reason": "<refuter counter-evidence; only when verification is refuted>",
  "verification": "ok|relocated_ok|refuted|dropped_no_match|dropped_no_citation|dropped_quote_too_short|dropped_systemic_incomplete|dropped_systemic_anchor_unverified|codex_file_missing|codex_line_out_of_range"
}
```

`relocated_ok` = the quote did not match at the claimed line but was found at exactly one other line
in the file (line-number drift); the finding is kept with the corrected line.

Entries in `verified-findings.json`'s `previouslyAdjudicated[]` array are the same finding shape
plus `disposition_id`, `disposition_status` (`accepted-risk|wont-fix|refuted`), and
`disposition_reason` — they render only in the Previously Adjudicated section, never in Findings
by Category.

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
