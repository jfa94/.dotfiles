# Constraints, Types & NULL

The database is the last line of defence for integrity. Declare what it can enforce; pick types that can't represent wrong values.

## Constraint toolkit

| Constraint               | Enforces                                                                                                                                                         |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **NOT NULL**             | Value is required.                                                                                                                                               |
| **UNIQUE**               | No duplicate values (alternate keys, natural keys). A single-column UNIQUE counts NULLs as distinct, so it still permits many NULL rows.                         |
| **CHECK**                | A row-level predicate (`quantity > 0`, `start <= end`, enum membership).                                                                                         |
| **DEFAULT**              | A value when none supplied (pair with NOT NULL for required-with-default).                                                                                       |
| **PRIMARY KEY**          | Identity = NOT NULL + UNIQUE.                                                                                                                                    |
| **FOREIGN KEY**          | Referential integrity + a deliberate ON DELETE action.                                                                                                           |
| **EXCLUSION** (Postgres) | No two rows conflict under an operator — e.g. no overlapping bookings via `EXCLUDE USING gist (room WITH =, during WITH &&)`. The cross-row complement of CHECK. |

**Declarative over application:** a declared constraint is enforced for _every_ writer — the app, a migration, a psql session, a rogue script — and is documented in the schema itself. Application-only validation is enforced for exactly one code path and silently bypassed by all others.

## Where a rule lives (Gate G8)

The **rogue-script test:** _"If a script bypassed the app and broke this rule, would the data be corrupt?"_

| Rule kind                                                                      | Lives in                                           |
| ------------------------------------------------------------------------------ | -------------------------------------------------- |
| **Invariant** (always true regardless of workflow)                             | DB constraint. Non-negotiable.                     |
| **Workflow / changeable policy** (max 3 active subscriptions, depends on plan) | Application (or DB, if truly invariant).           |
| **UX validation** (friendly messages, format hints)                            | Application **+ a DB backstop** for the hard rule. |

App validation and DB constraints aren't either/or for invariants — the app gives good UX, the DB guarantees correctness.

## NULL & three-valued logic

NULL means a value is **unknown / not-yet-known** — never a sentinel.

- `NULL = NULL` evaluates to **UNKNOWN**, not true. Use `IS NULL` / `IS NOT NULL`.
- `NULL` propagates: `5 + NULL` → NULL, `WHERE x = NULL` → matches nothing.
- Aggregates skip NULLs (`COUNT(col)` ignores them; `COUNT(*)` doesn't).
- **Fear of the Unknown anti-pattern:** using `-1`, `0`, `''`, `'N/A'`, or `9999-12-31` instead of NULL. These corrupt aggregates and comparisons and hide missing data. If a value is unknown, store NULL (L8).
- **UNIQUE + NULL:** most engines treat NULLs as distinct, so a nullable UNIQUE column admits many NULL rows. For _at most one_ empty value use a partial index / `CHECK`, or Postgres 15+ `UNIQUE NULLS NOT DISTINCT`. Outer joins also manufacture NULLs — account for them in predicates.
- **Inapplicable ≠ unknown:** a column that is _inapplicable_ to a whole class of rows (especially several such columns) is a modelling smell — a missing subtype table, not a reason for more NULL columns. Model the subtype (Gate G6); don't widen the table.

## Numbers & precision

The column type _is_ a constraint — pick the narrowest type that fits the domain, and out-of-range values become unrepresentable.

- **Integers by range:** `INT` to ~2.1 billion; `BIGINT` beyond. Default to `BIGINT` for any high-volume identity or counter — an `INT` PK that overflows in production is a painful migration.
- **Exact fractions** (money, rates, precise quantities) → `DECIMAL/NUMERIC(p, s)`.
- **Approximate / scientific** values where rounding is acceptable → `FLOAT/DOUBLE/REAL`. Only here — never for money (see below).

## Money (Iron Law L2)

- **DECIMAL/NUMERIC(p, s)** — exact base-10; choose precision/scale for the currency (most are 2 dp; some 0 or 3). Default for accounting.
- **Integer minor units** — store cents/pence as BIGINT; fast, exact, no scale ambiguity; common in high-volume/ledger systems.
- **Never** `FLOAT`/`DOUBLE`/`REAL` — binary floating point can't represent 0.10 exactly (`0.1 + 0.2 ≠ 0.3`), so money drifts.
- **Avoid vendor `MONEY` types** (Postgres/SQL Server) — locale-dependent, fixed scale, awkward arithmetic.
- **Store the currency** (ISO 4217 `char(3)`) next to any amount when more than one currency is possible. An amount without a currency is meaningless.

## Dates & times (Iron Law L3)

Decide _event vs schedule_ first:

| Meaning                                                                                                  | Type                                                                          |
| -------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| **An instant that happened** (created_at, logged_at)                                                     | `timestamptz`, stored UTC.                                                    |
| **A calendar date** with no time (birth_date, invoice_date)                                              | `DATE`.                                                                       |
| **A future civil/local time** (a 09:00 appointment that must stay 09:00 even if the zone's rules change) | local `timestamp` **+ IANA zone name** (`Europe/Madrid`), not a fixed offset. |

- Never a naive `timestamp` for an event — it has no zone, so it's ambiguous.
- Never a fixed UTC offset (`+02:00`) for a future local time — DST and political changes move it.
- Avoid `timetz` — a time-of-day with an offset is almost always wrong.

## Strings

- **TEXT vs VARCHAR(n):** in Postgres they're the same speed; use `VARCHAR(n)`/`CHECK (length(...) <= n)` only when the limit is a real domain rule, not a guess. (Other engines may store/limit differently — VARCHAR length can matter for MySQL row format / SQL Server.)
- **Collation & case:** decide case sensitivity explicitly. For case-insensitive uniqueness, use a `UNIQUE (lower(email))` index or a case-insensitive collation (`citext` in Postgres) — don't rely on accidental collation defaults.
- **Localisable text** → a **translation table** keyed by `(entity_id, locale)`, never per-language columns (`name_en`, `name_fr` — the Multicolumn Attributes smell). Keep canonical, locale-independent data (codes, UTC instants, amounts) separate from locale-dependent presentation; format at the edge.
- **Credentials** are never stored as readable strings — salted hash (bcrypt/scrypt/Argon2) only, never plaintext or reversible encryption (Iron Law L9).

## Booleans, enums & lookup tables (part of G7)

| Need                                                                  | Use                                         |
| --------------------------------------------------------------------- | ------------------------------------------- |
| Two states                                                            | `boolean` (`is_active`).                    |
| Tiny, truly fixed set, no metadata                                    | native `enum` or `CHECK (status IN (...))`. |
| Set that may grow, or needs metadata (label, sort order, active flag) | **lookup table** + FK.                      |

Native enums hit the **31 Flavors** anti-pattern: adding/removing a value is a schema migration, you can't attach metadata, and ordering is awkward. Prefer a lookup table once the set evolves:

```sql
CREATE TABLE order_status (
    id        smallint PRIMARY KEY,
    code      text NOT NULL UNIQUE,     -- 'pending', 'shipped'
    label     text NOT NULL,            -- display string
    is_active boolean NOT NULL DEFAULT true,
    sort_order int NOT NULL
);
-- orders.status_id REFERENCES order_status (id)
```

## Dynamic attributes ladder (Gate G7)

Climb only as far as the data forces you:

1. **Real columns** — typed, constrained, indexable. Default; use whenever the attribute set is known.
2. **Lookup table** — for an evolvable set of categorical values.
3. **JSONB + GIN index** — for a genuinely sparse/dynamic _tail_ of attributes that varies per row. Promote any attribute you frequently filter on into a real column.
4. **EAV (entity-attribute-value)** — only for extreme sparsity with high write concurrency over an open-ended attribute space. It forfeits type safety, FK integrity, and simple queries — treat as a last resort (see L7 and the anti-patterns reference). EAV's one edge over JSONB is write concurrency: updating one EAV row locks a narrow row, whereas changing one JSONB key rewrites the whole document.

```sql
-- typed columns for the known attributes, JSONB for the sparse tail
CREATE TABLE product (
    id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku   text NOT NULL UNIQUE,
    price numeric(12,2) NOT NULL CHECK (price >= 0),
    attrs jsonb NOT NULL DEFAULT '{}'      -- specs that vary by category
);
CREATE INDEX product_attrs_gin ON product USING gin (attrs);
```

## Delete strategy (Gate G4)

Soft delete (a `deleted_at`/`is_deleted` flag) is **not** a free default. Its costs:

- **Query bleed** — every query must remember `WHERE deleted_at IS NULL`; one forgotten filter leaks "deleted" rows.
- **Broken uniqueness** — a deleted `email` still occupies the UNIQUE constraint, blocking re-use.
- **Broken FKs** — children can still point at a "deleted" parent.
- **Dead-row bloat** and slower scans.
- **GDPR/"right to erasure"** — a soft-deleted row is still present; legal deletion needs real removal or anonymisation.

Choose per entity:

| Default                                                                                                                         | When to switch to soft delete                        |
| ------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------- |
| **Hard delete** (optionally copy to an `*_archive` table first), or a **lifecycle status** column for entities that have states | A real legal/audit/undo requirement to keep the row. |

If you do soft-delete, restore uniqueness with a **partial unique index on live rows only:**

```sql
-- only one LIVE row per email; deleted rows don't block reuse
CREATE UNIQUE INDEX customer_email_live
    ON customer (lower(email))
    WHERE deleted_at IS NULL;
```

**MySQL** has no partial indexes — emulate with a generated column that is NULL for deleted rows and unique otherwise:

```sql
ALTER TABLE customer
  ADD email_live varchar(320)
  AS (IF(deleted_at IS NULL, LOWER(email), NULL)) STORED,
  ADD UNIQUE (email_live);
```

## Audit baseline

- **`created_at` / `updated_at`** (`timestamptz`) on most tables; maintain `updated_at` with a trigger or app code.
- **History / shadow table** when you need _who changed what when_ — append-only row versions.
- **Effective-dated / valid-time rows** (`valid_from` / `valid_to`, often with a partial unique index enforcing one _current_ row) when the business meaning is temporal — price/rate history, address-as-of-date. This is application-modelled **valid time**, distinct from **transaction time** below. In a dimensional model it is **SCD Type 2**: a new row per version keyed by a surrogate distinct from the business key, so facts reference a specific version. Postgres has no native system-versioning, so effective-dating is the portable choice there.
- **System-versioned temporal tables** (SQL Server, MariaDB, DB2; not native in Postgres) automate full row history if the engine supports it.
