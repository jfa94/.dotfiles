# Indexing for Design

**Design-time indexing only** — the indexes that fall out of how the schema will be queried and the constraints it must enforce.

> **For EXPLAIN-driven query tuning, statistics, bloat, and engine-specific index families (GIN/GiST/BRIN, partial-vs-expression tuning), use a query-tuning skill (`supabase-postgres-best-practices` if installed). This file is design-time only.**

## Indexing is query-driven

You cannot derive the right indexes from the schema alone — they follow the **access patterns** (the queries you'll run). At design time you know many of them: how rows are looked up, joined, filtered, and ordered. Index those; defer the rest until real queries exist.

Every index is a **read/write trade-off:** it speeds matching reads but slows every INSERT/UPDATE/DELETE and costs storage. More indexes ≠ better.

## What to index at design time

- **Primary keys** — indexed automatically.
- **Foreign-key columns** — index them by default: joins and FK existence checks use them, and an unindexed FK makes every parent delete/update scan the child table. Two exceptions: when the FK is already the leftmost prefix of another index (a junction PK `(post_id, tag_id)` already covers `post_id`), a separate index is redundant; and a FK you never join or filter on, whose parent is never deleted/updated, may not earn its write cost. Index by default; skip only with a reason.
- **Frequent WHERE equality** columns — the bread and butter.
- **Columns in UNIQUE business rules** — the unique index _is_ the constraint.
- **ORDER BY / GROUP BY** columns on hot paths — an index can supply sorted order.

## Composite index column order

For a multi-column index, order matters:

1. **Leftmost-prefix rule** — an index on `(a, b, c)` serves predicates on `a`, `a,b`, and `a,b,c` — but **not** `b` alone or `c` alone. Order columns so the common queries hit the prefix.
2. **Equality before range** — put `=` columns first, then the one range/sort column. An index on `(status_id, placed_at)` serves `WHERE status_id = ? AND placed_at > ?` and can return rows already ordered by `placed_at`; reversing it can't use the equality efficiently.
3. **Bust the "most selective column first" myth** — selectivity is secondary to _matching the query's predicate shape_. The right lead column is the one queries filter on by equality, not merely the one with the most distinct values.

## Sargability — match the index to the predicate

A predicate that wraps the indexed column in a function or arithmetic can't use a plain index on it: `WHERE lower(email) = ?` ignores an index on `email`, and `WHERE date(created_at) = ?` ignores one on `created_at`. Decide the fix when you design the access pattern, not after EXPLAIN shows a seq scan:

- Build the index to match the predicate — an **expression index** on `lower(email)` for case-insensitive lookup.
- Or store the value already normalised (e.g. keep `email` lower-cased) so queries can filter the bare column.

(Deeper sargability/EXPLAIN analysis → query tuning, out of scope.)

## Covering / index-only scans

An index that contains every column a query needs lets the engine answer it **without touching the table** (index-only scan). Add payload columns with `INCLUDE`:

```sql
CREATE INDEX order_lookup
    ON orders (customer_id)
    INCLUDE (status_id, placed_at);   -- read these without a heap fetch
```

`INCLUDE`d columns are payload, not key: they ride along at the leaf level for covering reads but take no part in ordering or uniqueness. A `UNIQUE INDEX foo (a) INCLUDE (b)` still constrains only `a` — moving a column into `INCLUDE` never makes it part of the enforced key.

**Postgres caveat:** index-only scans still consult the visibility map; on a table with many dead/un-vacuumed rows the heap is visited anyway, so keep autovacuum healthy. (Details → query tuning, out of scope.)

## Selectivity & cardinality

- **Low-cardinality columns** (boolean, a 3-value status) make **poor lead columns** of a plain B-tree — too many rows per value. They're useful as _later_ columns in a composite, or as the filter of a **partial index** (`WHERE is_active`).
- High-cardinality columns (user_id, email) are good lead columns.

## When not to index

- Small tables — a full scan is cheaper than an index lookup.
- Columns rarely used in predicates.
- Redundant indexes — `(a)` is already covered by the prefix of `(a, b)`; don't create both.
- Write-heavy tables where an index's write cost outweighs its read benefit.

**Index Shotgun anti-pattern:** indexing everything (or nothing) by guesswork. Use a deliberate loop (Karwin's **MENTOR**: Measure, Explain, Nominate, Test, Optimize, Rebuild) — but the measure/explain steps belong to query tuning, not design.

## Unique & partial-unique indexes as constraints

A unique index is the enforcement mechanism for a uniqueness rule. For "unique among live rows only" (soft delete), use a **partial unique index** (G4):

```sql
CREATE UNIQUE INDEX customer_email_live
    ON customer (lower(email))
    WHERE deleted_at IS NULL;
```

## Example

```sql
-- orders are listed newest-first within a status → equality (status_id) then range/sort (placed_at)
CREATE INDEX orders_status_recent
    ON orders (status_id, placed_at DESC);
-- serves: WHERE status_id = ? ORDER BY placed_at DESC  (equality before range)
```

**Other engines:** MySQL/InnoDB clusters the table on the PK, so secondary indexes carry the PK as the row pointer — keep the PK narrow. SQL Server distinguishes clustered vs nonclustered indexes and uses `INCLUDE` similarly. The leftmost-prefix and equality-before-range rules are universal.
