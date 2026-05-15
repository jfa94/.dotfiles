# ADR File Format

## When to write

Only offer to create an ADR when **all three** criteria are met:

1. **Hard to reverse** — the cost of changing your mind later is meaningful (data migration, API contract, team re-training)
2. **Surprising without context** — a future reader will wonder "why did they do it this way?"
3. **The result of a real trade-off** — there were genuine alternatives and you picked one for specific reasons

If any criterion is missing, skip the ADR. Most decisions don't qualify.

## File naming

```
docs/decisions/NNNN-kebab-case-title.md
```

- Four-digit zero-padded number, monotonically increasing within the context
- Single-context repos: all ADRs go directly under `docs/decisions/`
- Multi-context repos: system-wide ADRs go under `docs/decisions/system/`; context-specific ADRs go under `docs/decisions/<context>/`; numbering is per-directory

## Required sections

```markdown
# NNNN — Title

**Status**: Proposed | Accepted | Deprecated | Superseded by [ADR-NNNN](./NNNN-title.md)
**Date**: YYYY-MM-DD

## Context

<The situation and constraints that made a decision necessary. What forces are at play? What problem needs solving? Be concrete.>

## Decision

<What was decided. State it directly: "We will…" Not "We considered…">

## Consequences

<What becomes easier, harder, or different as a result. Include both positive and negative consequences. Future readers use this to judge whether the decision still makes sense.>
```

All five fields are required. Never omit Consequences — it is the most valuable section for future readers.

## Status lifecycle

```
Proposed → Accepted → Deprecated
                    ↘ Superseded by ADR-NNNN
```

- **Proposed** — under discussion; not yet binding
- **Accepted** — binding; team is following this decision
- **Deprecated** — no longer recommended but not replaced; context has changed
- **Superseded** — replaced by a newer ADR; link to the superseding record

## Index

`docs/decisions/README.md` is an index table maintained by Scribe. Its shape:

| #    | Title | Status   | Date       |
| ---- | ----- | -------- | ---------- |
| 0001 | ...   | Accepted | YYYY-MM-DD |

Scribe rebuilds this table on every run. `/grill-me` authors ADR bodies; Scribe only maintains the index. Never modify the index by hand — it will be overwritten.

## Anti-patterns

| Anti-pattern                             | Why it's wrong                                          |
| ---------------------------------------- | ------------------------------------------------------- |
| ADR for a trivially-reversible decision  | Adds noise; reserve ADRs for meaningful cost-of-change  |
| ADR without alternatives considered      | Signals the decision wasn't actually a trade-off        |
| ADR that doubles as a spec or design doc | ADRs record decisions, not designs; use a separate spec |
| Consequences section left blank          | The most valuable part; always fill it                  |
| Status never updated after acceptance    | Readers can't tell if the decision is still in force    |
