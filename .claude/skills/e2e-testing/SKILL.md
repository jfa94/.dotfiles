---
name: e2e-testing
description: Use when asked to find e2e/end-to-end testing gaps, check whether critical user flows or "money paths" are covered by browser tests, write or run missing e2e tests, or set up e2e CI. Applies to any repo with a web UI — Playwright, Cypress, or no test framework at all. Triggers include "e2e gaps", "are our critical flows tested", "missing e2e tests", "/e2e-testing".
---

# E2E Testing

## Overview

Static review proves the code looks right; only executing the app in a real browser proves it works. Keep the e2e layer thin and honest: a handful of trustworthy tests on the money paths, everything else pushed down the pyramid.

The default deliverable is a **gap report**. Writing tests, running them, and scaffolding CI happen only when the user asks for them.

## Iron Laws

```
1. NO ACTION BEYOND THE REPORT WITHOUT AN EXPLICIT REQUEST.
   The default deliverable is the gap report. Writing tests, running suites, bootstrapping
   Playwright, and scaffolding CI each require the user to ask. No exceptions.

2. NO SPEC CODE BEFORE THE PLAN GATE IS APPROVED.
   Steps + exact outcome assertions are presented and approved first. Approval covers what
   was presented — a changed assertion means a re-ask. No exceptions.

3. NO UNEXECUTED SPEC DELIVERED AS DONE.
   A spec either ran against the live app before delivery, or it is marked test.fixme with
   a header naming why it is unverified and what blocks the launch. No exceptions.

4. THE USER OWNS THE COVERAGE MODEL.
   Journeys come from docs/critical-journeys.md or a user-confirmed proposal persisted
   there. Never analyse gaps against a journey list the user has not seen. No exceptions.

5. NO GAP REPORT PERSISTED TO THE REPO.
   Chat + session scratchpad only. The journey list is the only durable artifact this
   skill writes to the repo. No exceptions.

6. NEVER CHANGE REPO OR GITHUB SETTINGS.
   Scaffold workflow files only. Branch protection / required status checks are flipped
   by the user, told explicitly where. No exceptions.
```

## Phase 1 — Understand the repo

Dispatch `Scout` (or an Explore agent if Scout is unavailable) to map: docs (`docs/glossary.md`, context map, PRDs), routes/pages, the auth model, existing test infrastructure (framework, configs, CI workflows), and every existing e2e spec.

Framework stance — Playwright-opinionated, incumbent-respecting:

- **Playwright present** → work within it.
- **Cypress (or other) present** → do the analysis and write tests in the incumbent. Note once in the report that Playwright is the recommended default; migration is a separate decision, don't push it.
- **Nothing present** → that is itself a top-line finding. Offer Playwright bootstrap (`npm init playwright@latest` + config + CI) as a follow-up action, not an automatic step.

## Phase 2 — Critical journeys

Humans own the coverage model; never invent it silently.

- If `docs/critical-journeys.md` exists, use it. Flag anything in the app that looks like a money path but isn't listed.
- Otherwise, propose a ranked list — the flows that cost revenue, signups, or trust if broken (signup, login, the product's core action, checkout/payment). Confirm/edit with the user in **one round** (AskUserQuestion), then persist the confirmed list to `docs/critical-journeys.md`.

## Phase 3 — Gap report

For each journey, read the specs that claim to cover it and issue one verdict:

| Verdict               | Meaning                                                                                                                                                                      |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **uncovered**         | no spec exercises the journey                                                                                                                                                |
| **covered**           | spec exists and passes the rubric in [conventions.md](./conventions.md)                                                                                                      |
| **nominally covered** | spec exists but is untrustworthy — hollow assertions that would still pass if the feature broke, hard waits, brittle deep-CSS/XPath selectors, or skipped/quarantined status |

Add one **CI status** line: does anything actually run these tests on PRs?

Deliver the report in chat and copy it to the session scratchpad. Never persist it to the repo — verdicts go stale the moment specs change; only the journey list is durable.

## On-request actions

### Write missing tests

1. **Plan gate first.** Per journey, present steps plus the exact outcome assertions ("order appears in /orders with status 'paid'", never "checkout works"). One approval round. No spec code before approval.
2. **Ground it.** Launch the app (`webServer` config or dev server), verify selectors against the live DOM via Playwright MCP, and execute each spec before delivering it.
3. **Can't launch?** Fall back to source-grounded drafts — real roles, labels, and `data-testid`s read from the actual components — and mark each one `test.fixme` with a header naming why it's unverified and what blocks the launch. Never deliver an unexecuted spec as done.
4. Every spec follows [conventions.md](./conventions.md).

### Run the suite

Execute and report honestly: failures with traces, flaky-on-retry flagged as defects to investigate — never counted as passes.

### Scaffold CI

GitHub Actions workflow: install browsers, run the smoke subset on `pull_request`, full suite nightly, upload traces/HTML report on failure. Tell the user to mark the job as a required status check in branch protection — never change repo settings yourself.

## Red flags

- Marking a journey covered because a spec file _mentions_ it — read the assertions.
- Delivering a spec that has never executed without a `fixme` marker.
- Writing an e2e test for an edge case a unit/integration test could catch — push it down and say so.
- Writing tests when the user only asked for gaps.
- A hollow plan entry ("verify page loads") surviving the plan gate.
