import assert from "node:assert/strict";
import test from "node:test";

import {
  VALID_DISPOSITION,
  isActiveDisposition,
  normalizeClaim,
} from "./disposition-ledger.mjs";

test("normalizeClaim ignores case, punctuation and spacing", () => {
  assert.equal(normalizeClaim("  Foo,  BAR!! baz "), "foo bar baz");
});

test("non-gated statuses are active regardless of decidedBy", () => {
  for (const status of ["wont-fix", "refuted"]) {
    assert.equal(isActiveDisposition({ status, decidedBy: "report" }), true);
  }
});

test("user-gated statuses are active only when decided by the user", () => {
  for (const status of ["accepted-risk", "by-design", "intent-confirmed"]) {
    assert.equal(isActiveDisposition({ status, decidedBy: "user" }), true);
    assert.equal(isActiveDisposition({ status, decidedBy: "report" }), false);
    assert.equal(isActiveDisposition({ status }), false);
  }
});

test("overturned and unknown statuses are inactive", () => {
  assert.equal(isActiveDisposition({ status: "overturned", decidedBy: "user" }), false);
  assert.equal(isActiveDisposition({ status: "refuted-ish", decidedBy: "user" }), false);
  assert.equal(isActiveDisposition({}), false);
  assert.equal(isActiveDisposition(null), false);
});

test("every valid status other than overturned can be active", () => {
  for (const status of VALID_DISPOSITION) {
    assert.equal(
      isActiveDisposition({ status, decidedBy: "user" }),
      status !== "overturned",
    );
  }
});
