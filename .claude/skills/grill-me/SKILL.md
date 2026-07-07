---
name: grill-me
description: >-
  Grilling session that challenges your plan against the existing domain
  model, sharpens terminology, and updates documentation (docs/glossary.md,
  ADRs) inline as decisions crystallise. Use when user wants to stress-test a
  plan against their project's language and documented decisions, or mentions
  'grill me'.
---

<what-to-do>

Interview me relentlessly about every aspect of this plan until we reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one.

Ask the questions one at a time, waiting for feedback on each question before continuing.

If a question can be answered by exploring the codebase, explore the codebase instead.

</what-to-do>

<supporting-info>

## Domain awareness

During codebase exploration, also look for existing documentation:

### File structure

Most repos have a single context:

```
/
├── docs/
│   ├── glossary.md
│   └── decisions/
│       ├── 0001-event-sourced-orders.md
│       └── 0002-postgres-for-write-model.md
└── src/
```

If a `docs/context-map.md` exists, the repo has multiple contexts. The map points to where each one lives:

```
/
├── docs/
│   ├── context-map.md
│   ├── glossary/
│   │   ├── ordering.md
│   │   └── billing.md
│   └── decisions/
│       ├── system/              ← system-wide decisions
│       ├── ordering/            ← context-specific decisions
│       └── billing/
└── src/
```

Create files lazily — only when you have something to write. If no `docs/glossary.md` exists, create one when the first term is resolved. If no `docs/decisions/` exists, create it when the first ADR is needed.

## During the session

### Challenge against the glossary

When the user uses a term that conflicts with the existing language in `docs/glossary.md`, call it out immediately. "Your glossary defines 'cancellation' as X, but you seem to mean Y — which is it?"

### Sharpen fuzzy language

When the user uses vague or overloaded terms, propose a precise canonical term. "You're saying 'account' — do you mean the Customer or the User? Those are different things."

### Discuss concrete scenarios

When domain relationships are being discussed, stress-test them with specific scenarios. Invent scenarios that probe edge cases and force the user to be precise about the boundaries between concepts.

### Close the open decisions

Before wrapping up, sweep the decision categories that most often stay silently open:

- Edge cases and error behavior — what exactly happens on each failure?
- Non-goals — name the tempting adjacent features that are explicitly excluded
- Data contracts — schema shapes, request/response formats, validation rules
- Thresholds and limits — timeouts, sizes, rates, pagination
- Auth/permission rules per action

### Cross-reference with code

When the user states how something works, check whether the code agrees. If you find a contradiction, surface it: "Your code cancels entire Orders, but you just said partial cancellation is possible — which is right?"

### Update docs/glossary.md inline

When a term is resolved, update `docs/glossary.md` right there. Don't batch these up — capture them as they happen. Use the format in [glossary-format.md](./glossary-format.md).

`docs/glossary.md` should be totally devoid of implementation details. Do not treat `docs/glossary.md` as a spec, a scratch pad, or a repository for implementation decisions. It is a glossary and nothing else.

### Offer ADRs sparingly

Only offer to create an ADR when all three are true:

1. **Hard to reverse** — the cost of changing your mind later is meaningful
2. **Surprising without context** — a future reader will wonder "why did they do it this way?"
3. **The result of a real trade-off** — there were genuine alternatives and you picked one for specific reasons

If any of the three is missing, skip the ADR. Use the format in [adr-format.md](./adr-format.md).

## Surviving compaction

A `<compaction-continuity>` block means the discussion above was compacted to a lossy summary; it carries the path to the full JSONL transcript. When wrapping up (before finalising glossary/ADRs) or when a discussed term or decision seems missing, Read that transcript and trust it over the summary.

</supporting-info>
