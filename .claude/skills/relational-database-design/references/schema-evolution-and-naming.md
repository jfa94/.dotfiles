# Schema Evolution & Naming

Changing a live schema safely, and naming things consistently.

## Schema is code

Every schema change is a **versioned, reviewed, tested migration** checked into the repo — never a hand-edit against production. Editing prod directly with no migration history is the **Diplomatic Immunity** anti-pattern (the schema exempting itself from the engineering discipline applied to all other code). Use a migration tool (Flyway, Liquibase, Alembic, Rails/Django migrations, Sqitch, etc.); each migration is forward-only and ordered.

## Expand–contract (Iron Law L6)

Rolling deploys run **old and new code simultaneously**, so a schema can never be in a state that breaks either. Make every breaking change in four phases — additive first, destructive last:

1. **Expand** — add the new shape (new column/table/constraint as nullable or `NOT VALID`). Old code ignores it; new code can use it. No reads switched yet.
2. **Migrate / backfill** — populate the new shape from the old in batches; deploy code that writes **both**.
3. **Switch reads** — point readers at the new shape; verify. Old shape now write-only.
4. **Contract** — once no code references the old shape, drop it.

Rules:

- **Additive before the code that needs it; destructive only after the old code is gone.**
- Never a single-step destructive `ALTER` (rename/drop/retype) on a table live code depends on.
- **Destructive DDL requires explicit confirmation** — dropping a table, or the `DROP`/retype/rename step on a column live code depends on, runs only when the user has explicitly requested it and confirms in the current turn (the global safety rule). It is the contract phase: never a reflex, never collapsed into an earlier step.

## Safe DDL notes

The online/concurrent techniques below exist to avoid long locks on **large, live** tables. On a small table, or within a planned maintenance window, a plain blocking `ALTER` is fine — match the effort to the table's size and availability requirement.

- **Postgres:**
  - `CREATE INDEX CONCURRENTLY` — build an index without an exclusive lock (can't run in a txn block).
  - Add a constraint `NOT VALID`, then `VALIDATE CONSTRAINT` separately — avoids a long blocking full-table scan under lock.
  - Adding a column with a non-volatile default is metadata-only (fast) on modern Postgres; a volatile default rewrites the table.
- **MySQL:** prefer `ALGORITHM=INSTANT` (metadata-only, where supported) or `INPLACE` over `COPY`; for large tables use online schema-change tools (**gh-ost**, **pt-online-schema-change**) to avoid long locks.
- **SQL Server:** online index builds (Enterprise); watch for lock escalation on big ALTERs.

## Designing for evolvability

- **Model the domain, not today's UI** — a schema that mirrors the current screen layout has to migrate every time the UI shifts; one that captures the underlying entities and rules absorbs UI change without DDL.
- **Additive over repurposing** — add a new column/table rather than overloading an existing column's meaning.
- **Enumerations as data** — a lookup table grows with a normal `INSERT`; a native enum needs a migration (31 Flavors).
- **Avoid premature denormalisation** — every denormalised copy is one more thing a future migration must keep consistent.
- Leave key headroom (BIGINT) so you never have to migrate a key type under load.
- **Partition early if a table will be huge** — for time- or tenant-keyed access at scale, declare native partitioning up front: retrofitting is a full-table migration, and in Postgres the partition key must be part of the PK and every unique constraint, so it shapes key design. Partition before you shard; hand-rolled splits (`orders_2024`, `orders_2025`) are Metadata Tribbles.

## Naming conventions

Consistency matters more than which convention you pick — choose once, apply everywhere.

- **snake_case** for all identifiers (portable across engines; avoids quoting).
- **Singular vs plural table names** — pick one (`customer` or `customers`) and never mix.
- **Primary key** — pick `id` everywhere _or_ `customer_id` everywhere; be consistent.
- **Foreign key** — name after the referenced table + `_id`: `customer_id REFERENCES customer (id)`.
- **Booleans** — `is_`/`has_` prefix (`is_active`, `has_shipped`).
- **Timestamps/dates** — `_at` for instants (`created_at`), `_on` for dates (`shipped_on`).
- **Avoid reserved words** (`order`, `user`, `group`, `value`) as identifiers — they force quoting and cause subtle bugs. `orders`, `app_user`, etc.
- **Constraints/indexes** — use a predictable prefix scheme (`pk_`, `fk_`, `uq_`, `ix_`, `ck_`) so names are greppable and collisions are obvious.

## Example — renaming a column via expand–contract

Renaming `orders.total` → `orders.total_amount` with zero downtime:

```sql
-- Phase 1 — EXPAND: add the new column (nullable, no rewrite)
ALTER TABLE orders ADD COLUMN total_amount numeric(12,2);

-- Phase 2 — BACKFILL + dual-write
--   App now writes BOTH total and total_amount.
UPDATE orders SET total_amount = total WHERE total_amount IS NULL;  -- batch in chunks for big tables

-- Phase 3 — SWITCH READS
--   Deploy code that reads total_amount. Optionally enforce now:
ALTER TABLE orders ALTER COLUMN total_amount SET NOT NULL;

-- Phase 4 — CONTRACT: once no code references `total`
ALTER TABLE orders DROP COLUMN total;
```

Each phase ships as its own migration and its own deploy — never collapse them into one step.
