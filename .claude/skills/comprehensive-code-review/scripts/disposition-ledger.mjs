// Shared by review-run.mjs and verify-citations.mjs: both must agree on what
// "same title" means and on which ledger entries are active.

export const collapseWs = (s) => String(s).replace(/\s+/g, " ").trim();

// Lowercase, strip punctuation, collapse whitespace: resilient to rewording,
// blind to line numbers.
export const normalizeClaim = (s) =>
  collapseWs(String(s).toLowerCase().replace(/[^a-z0-9 ]+/g, " "));

export const VALID_DISPOSITION = new Set([
  "accepted-risk",
  "wont-fix",
  "refuted",
  "overturned",
  "by-design",
  "intent-confirmed",
]);

// Intent and risk rulings suppress or promote actionable work, so only an
// explicit user decision may activate them.
export const USER_GATED_DISPOSITION = new Set([
  "accepted-risk",
  "by-design",
  "intent-confirmed",
]);

// An unknown status is inactive: a typo must never suppress findings.
export const isActiveDisposition = (entry) =>
  VALID_DISPOSITION.has(entry?.status) &&
  entry.status !== "overturned" &&
  (!USER_GATED_DISPOSITION.has(entry.status) || entry.decidedBy === "user");
