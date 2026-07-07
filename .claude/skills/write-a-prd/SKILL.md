---
name: write-a-prd
description: >-
  Create a PRD through user interview, codebase exploration, and module
  design, then submit as a GitHub issue. Output is optimized for the factory
  pipeline's autonomous coding agents (machine-extractable requirements,
  testable acceptance criteria). Use when user wants to write a PRD, create a
  product requirements document, or plan a new feature.
---

This skill will be invoked when the user wants to create a PRD. You may skip steps if you don't consider them necessary.

The PRD will be implemented by autonomous coding agents (the factory pipeline) that never ask the user anything — every
gap in the PRD becomes a decision an agent makes on its own. The pipeline also runs deterministic gates on the PRD
(requirement extraction, testability, traceability); the rules below exist to pass them.

1. Ask the user for a long, detailed description of the problem they want to solve and any potential ideas for
   solutions.

2. Explore the repo to verify their assertions and understand the current state of the codebase.

3. Invoke the `grill-me` skill to interview the user about the plan. Because the downstream pipeline never asks
   questions, grill until every decision an agent would otherwise make autonomously is closed — especially edge cases
   and error behavior, non-goals, data contracts, thresholds/limits, and auth rules.

4. Sketch out the major modules you will need to build or modify to complete the implementation. Actively look for
   opportunities to extract deep modules that can be tested in isolation.

A deep module (as opposed to a shallow module) is one which encapsulates a lot of functionality in a simple,
testable interface which rarely changes.

Module interfaces are durable decisions recorded under Implementation Decisions — NOT a work breakdown. The
pipeline decomposes work into vertical slices (end-to-end through all layers) and rejects layer-by-layer plans.

Check with the user that these modules match their expectations. Check with the user which modules they want
tests written for.

5. Once you have a complete understanding of the problem and solution, use the template below to write the PRD,
   following the language rules below. The PRD should be submitted as a GitHub issue. The issue title MUST be
   prefixed with `[PRD]` (e.g., `[PRD] User Onboarding Flow`).

6. Before creating the issue, verify:

- Every requirement is normative ("must"), atomic (one behavior), and observable
- Every requirement has 1–3 acceptance criteria sharing its key terms
- No banned vague phrases in requirements or criteria
- Out of Scope names adjacent features an agent might otherwise build
- Vocabulary is consistent throughout
- Body is well under 50KB (the pipeline truncates beyond that)

<language-rules>

Apply to Requirements and their acceptance criteria:

- The pipeline's testability gate blocks these phrases — never use them: "works well", "works correctly",
  "works properly", "as expected", "user-friendly", "easy to use", "intuitive", "fast enough", "performant",
  "good performance", "robust", "reliable", "handle errors gracefully", "looks good", "high quality", "etc.",
  "and so on".
- Operationalize every quality into a threshold or observable behavior: "rejects passwords under 8 characters",
  not "validates passwords properly".
- Use consistent vocabulary throughout the PRD. Requirement coverage is checked by keyword overlap, so "sign-in"
  in one section and "login" in another can cause spurious traceability failures.

</language-rules>

<prd-template>

## Problem Statement

The problem that the user is facing, from the user's perspective.

## Solution

The solution to the problem, from the user's perspective.

## User Stories

A concise, numbered list of user stories giving actor and benefit context. The canonical, exhaustive list of behavior
is `## Requirements` below — do not duplicate it here.

1. As an <actor>, I want a <feature>, so that <benefit>

<user-story-example>
1. As a mobile bank customer, I want to see balance on my accounts, so that I can make better informed
decisions about my spending
</user-story-example>

## Requirements

The canonical list of what the system must do. The pipeline extracts and traces this list bidirectionally: every item
must end up covered by the implementation, and all implementation work must ladder back to an item here.

A numbered list where each item:

- Is a normative statement: "The system must ..."
- Is atomic — exactly one observable behavior per item
- States a concrete behavior, not a quality

Nest each requirement's acceptance criteria under it (1–3 bullets): concrete assertions an automated test can check —
exact status codes, routes, messages, thresholds. Given-When-Then is welcome but not required. Litmus test: could two
agents disagree about whether a criterion passed? If yes, rewrite it. These criteria seed the pipeline's tasks, its
failing tests, and a held-out validation set, so each must be independently checkable.

<requirement-example>
1. The system must reject sign-up passwords shorter than 8 characters.
   - POST /signup with a 7-character password returns 400 with error code `password_too_short`
   - POST /signup with an 8-character password returns no password error
</requirement-example>

## Edge Cases & Error Handling

Agents treat unspecified edge cases as "no special handling needed" — enumerate them. Bullets in the form
`situation → expected behavior`, covering invalid input, empty states, boundaries, concurrency, and permission
failures.

- <situation> → <expected behavior>

## Implementation Decisions

A list of implementation decisions that were made. This can include:

- The modules that will be built/modified
- The interfaces of those modules that will be modified
- Technical clarifications from the developer
- Architectural decisions
- Schema changes
- API contracts
- Specific interactions

Do NOT include specific file paths or code snippets. They may end up being outdated very quickly.

## Testing Decisions

A list of testing decisions that were made. Include:

- A description of what makes a good test (only test external behavior, not implementation details)
- Which modules will be tested
- Prior art for the tests (i.e. similar types of tests in the codebase)

## Out of Scope

The things that are out of scope for this PRD. Be exhaustive about tempting adjacent features — anything not excluded
here is fair game for an autonomous agent.

Write this section as prose sentences, NOT bullets, and avoid the words "must", "shall", and "should" here — the
pipeline extracts bullets and normative sentences as requirements to implement, which would invert the meaning of
this section. Example: "This PRD excludes transaction history and balance push notifications."

## Further Notes

Any further notes about the feature.

</prd-template>
