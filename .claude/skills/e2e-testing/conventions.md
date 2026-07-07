# E2E spec conventions

The rubric for judging existing specs (Phase 3 verdicts) and the rules for writing new ones. Distilled from research on e2e testing for consumer web apps (Playwright docs, Google Testing Blog, Fowler, Luo et al. FSE 2014, Kent C. Dodds).

## The one question that matters

For every assertion, generated or reviewed: **would this test fail if the feature broke?**

Hollow patterns that answer "no" — reject or flag as untrustworthy:

- `expect(x).toBeDefined()` / `toBeVisible()` as the _only_ assertion
- "verify the page loads" with no outcome check
- asserting current behaviour read from possibly-buggy code instead of the requirement

A real outcome assertion names the state change: the order row exists with status "paid", the email lands in the outbox, the redirect hits `/dashboard` with the user's name rendered.

The operational check for new specs: sabotage the assertion, watch it fail, revert (see SKILL.md).

## Scope — what earns an e2e test

- Only critical journeys (the confirmed `docs/critical-journeys.md` list). Heuristic: catastrophic-if-broken → e2e; cosmetic → lower layer.
- Edge cases, field validation, business-rule combinations → unit/integration. If a boundary integration test can catch it, don't write the browser test.
- No redundancy across layers; each layer tests what the others can't.
- Keep the e2e suite a small fraction of total tests (~10% heuristic). Tag a **smoke subset** (login + core action) with `@smoke` (`{ tag: '@smoke' }`), run via `--grep @smoke` for the PR gate — tags survive file moves; the rest runs nightly.

## Locators

Priority order: `getByRole` → `getByLabel`/`getByPlaceholder` → `getByTestId` → nothing else.
Deep CSS chains and XPath tied to DOM structure are defects. If no semantic hook exists, add a `data-testid` to the component as part of the change.

## Waiting

- Never `waitForTimeout` / sleep. Wait for a condition: element state, URL change, network response.
- Wait for the event that _causes_ the state change, not the state change itself — register `waitForResponse` on the API call before the click, then assert the UI.
- Lean on auto-waiting and web-first assertions; don't hand-roll polling.

## Isolation & data

- Every test sets up its own state; no ordering dependencies, no shared mutable accounts.
- Arrange preconditions via API/fixture/seed, not by clicking through the UI. Unique per-test identifiers (UUID/timestamp prefixes).
- Fresh browser context per test (Playwright default — don't defeat it).
- Auth via `storageState`: capture the session once in a setup project, reuse everywhere. Interactive login never belongs in CI.
- Deterministic environment: disable animations, freeze or avoid asserting wall-clock time.

## Third-party boundaries

- Real backend and first-party services by default. Mock only third parties not under test (analytics, email delivery) via route interception — assert the outbound request or a test outbox, and keep ≥1 real-backend smoke journey.
- Payments: provider test mode (e.g. Stripe test cards). Never fully mock the payment step on a money path; never real charges.
- Third-party OAuth (Google/Apple login) is not automatable in CI: `storageState` presumes a headless-capable login. Needs a test-credential path or test-only session-injection hook — absence is a testability finding for the gap report.

## Retries & flakiness

- 1–2 CI retries are fine as a _detector_, never a cure. A test that passes only on retry is a defect to investigate.
- Quarantine known-flaky tests out of the merge gate with an owner and an expiry; flaky coverage is worse than none.

## Structure

- No page-object architecture until the suite proves it needs it — simple helper functions and domain actions first.
- No BDD/Gherkin layer unless non-engineers genuinely read the scenarios; behavioural test _names_ in plain language are enough.
- Treat traces/artifacts as sensitive — they capture auth tokens and cookies.
