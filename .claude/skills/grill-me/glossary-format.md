# Glossary File Format

## Purpose & scope

`docs/glossary.md` is the ubiquitous-language glossary for a bounded context. It is co-authored by developers and domain experts. One file per bounded context (or one file per context under `docs/glossary/<context>.md` in multi-context repos).

The glossary is a **vocabulary**, not a spec or a scratchpad. It captures what domain terms mean to the people who live in the domain. It must be totally devoid of implementation details — no class names, no database schemas, no API shapes.

## Header schema

Every glossary file must begin with this header block:

```yaml
context: <name of this bounded context, or "root" for single-context repos>
purpose: <one sentence — what problem does this context solve?>
scope:
  in: <what concepts belong here>
  out: <what is explicitly excluded>
last-reviewed: YYYY-MM-DD
```

If Scribe scaffolded the file, `purpose:`, `scope.in`, and `scope.out` will be `TBD`. Replace them during a `/grill-me` session.

## Term entry schema

Each term is a level-3 heading followed by a fixed set of fields:

```markdown
### <TermName>

- **type**: Entity | Value Object | Aggregate Root | Domain Service | Domain Event | Policy | Role
- **status**: accepted | draft | orphaned
- **definition**: <one-paragraph plain-English meaning, no code>
- **invariants**: <business rules that must always hold; bullet list>
- **examples**: <concrete; include counter-examples>
- **relationships**: <links to other terms>
- **synonyms**: <name for this concept in other contexts, if any>
- **code anchor**: `<path/to/file.ext:Symbol>`
```

Field notes:

- **type** — pick the DDD building block that best describes the concept (Evans Part II)
- **status** — see lifecycle below; Scribe sets `draft`, humans promote to `accepted`
- **definition** — no code, no field names; a domain expert with zero code access should find this useful
- **invariants** — rules that are always true regardless of state; leave blank if none, but think hard before concluding none exist
- **examples** — at least one positive example and one counter-example where non-obvious
- **relationships** — use term names, not file paths; e.g. "belongs to Order", "emitted by Payment"
- **synonyms** — required when `docs/context-map.md` exists and the term appears under a different name in another context
- **code anchor** — the primary symbol that implements this concept; updated by Scribe on each run

## Status lifecycle

```
draft  ──→  accepted  ──→  orphaned
 ↑               │
 └──────── (re-draft if definition changes significantly)
```

- **draft** — scaffolded by Scribe or proposed during `/grill-me`; definition not yet confirmed by domain expert
- **accepted** — reviewed and confirmed by a human; Scribe will never overwrite `definition`, `invariants`, or `examples`
- **orphaned** — the implementing code was deleted; entry kept for historical reference; Scribe appends `(code removed at <hash>)` and flags for human review

## Cross-context synonyms

When `docs/context-map.md` exists, the `synonyms:` line is required for any term that appears under a different name in another context. Example:

```markdown
- **synonyms**: Billing calls this "Invoice"
```

The context map's cross-reference table should also list the synonym pair. `/grill-me` maintains both; Scribe maintains neither.

## Anti-patterns

| Anti-pattern                                                    | Why it's wrong                                                    |
| --------------------------------------------------------------- | ----------------------------------------------------------------- |
| Generic name (Manager, Data, Info, Handler)                     | Not a domain concept; names an implementation role                |
| Infrastructure term (DTO, Repository, Mapper, Factory, Service) | Leaks technical layer into ubiquitous language                    |
| Missing invariants on Aggregate Root                            | Aggregates exist to enforce invariants; empty = incomplete        |
| Definition contains field names or class names                  | Glossary describes the domain, not the code                       |
| One global glossary spanning multiple bounded contexts          | Terms shift meaning across contexts; split into per-context files |
| Glossary used as a spec or decision log                         | Use ADRs for decisions, specs for requirements                    |

## Maintenance

This file is co-authored interactively during `/grill-me` sessions. Scribe scaffolds draft entries and refreshes `code anchor` + `relationships` on each run. Humans are responsible for `definition`, `invariants`, and `examples`. Never let a tool be the sole author of accepted entries.
