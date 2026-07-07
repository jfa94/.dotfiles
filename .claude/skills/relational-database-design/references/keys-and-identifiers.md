# Keys & Identifiers

Choosing what identifies a row, and what type that identifier should be.

## Vocabulary

| Term              | Meaning                                                                  |
| ----------------- | ------------------------------------------------------------------------ |
| **Candidate key** | Any minimal set of columns that uniquely identifies a row.               |
| **Primary key**   | The candidate key you elect as _the_ identity. NOT NULL, unique, stable. |
| **Alternate key** | A candidate key not chosen as primary — enforce with UNIQUE.             |
| **Composite key** | A key spanning more than one column.                                     |
| **Foreign key**   | A column referencing another table's key; the integrity link.            |
| **Natural key**   | A key drawn from real-world data (email, ISBN, country_code).            |
| **Surrogate key** | A synthetic, meaningless identifier (auto-increment, UUID).              |

## Natural vs surrogate (Gate G1)

The synthesis — you usually want **both**:

> **Surrogate PK for identity + a UNIQUE constraint on the natural key.**

The surrogate gives you a stable, narrow, never-changing join target. The UNIQUE on the natural key preserves the real-world rule the surrogate would otherwise let you violate (two customers with the same email). Dropping the natural UNIQUE "because we have an id" is how duplicates creep in.

**Identity ≠ search key.** The surrogate PK is the join/identity target, not what humans look rows up by — they search by the natural key (email, SKU, order number). Keep that key indexed (its UNIQUE doubles as the search index) even though the surrogate is the PK; conflating "the value I join on" with "the value I search by" is what tempts people to drop the natural key.

**Exception — pure junction/lookup tables:** a join table whose only identity is the pair of FKs should use that **natural composite key** as its PK. Adding a surrogate `id` to it is the **ID Required** anti-pattern — it permits duplicate pairs and buys nothing.

```sql
-- good: composite natural PK, no surrogate
CREATE TABLE post_tag (
    post_id bigint NOT NULL REFERENCES post (id) ON DELETE CASCADE,
    tag_id  bigint NOT NULL REFERENCES tag  (id) ON DELETE CASCADE,
    PRIMARY KEY (post_id, tag_id)
);
```

## Key type (Gate G2)

Default to **BIGINT identity** for a single database. Switch deliberately.

| Type                             | Size | Index locality                                                                        | Pros                                                        | Cons                                                         |
| -------------------------------- | ---- | ------------------------------------------------------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------ |
| **Auto-increment BIGINT**        | 8 B  | Excellent (monotonic append)                                                          | Smallest, fastest joins/indexes, human-readable             | Guessable, leaks row counts, collides when merging databases |
| **UUIDv4 (random)**              | 16 B | Poor (random inserts fragment the B-tree / clustered index, page splits, cache churn) | Unguessable, generate anywhere offline, no coordination     | Larger, write amplification, not sortable by time            |
| **UUIDv7 / ULID (time-ordered)** | 16 B | Good (time prefix appends in order)                                                   | Distributed-safe _and_ index-friendly, sortable by creation | Slightly leaks creation time, newer tooling support          |
| **Snowflake-style**              | 8 B  | Good (time-ordered)                                                                   | Compact + distributed, sortable                             | Needs a generator/coordination scheme                        |

Reasoning that drives the table: a primary/clustered index is a B-tree. **Sequential** keys append to the right edge — one hot page, minimal splits. **Random** v4 keys scatter inserts across the whole tree, causing page splits and poor cache locality. That's why v7/ULID exist: keep UUID's distributability without v4's write penalty. Measured effects are directional but large: InnoDB page fill drops from ~94% (sequential) to ~50% (random v4), and Postgres benchmarks show ~8× the WAL volume once the index outgrows RAM.

Rules of thumb:

- **Single DB, internal IDs** → BIGINT.
- **Distributed generation, public/merged IDs, or offline creation** → UUIDv7/ULID.
- **Unpredictability matters more than ordering** (don't even leak creation time) → UUIDv4.
- **Store UUIDs as 16-byte binary**, never as 36-char text — text triples the size and wrecks index performance.
- **Hybrid:** BIGINT internal PK for joins + an external UUID (`uuid UNIQUE`) for public URLs. Best of both when you can afford the extra column.
- **Migrating off v4:** point new inserts at v7 and let existing v4 rows coexist — never backfill/rewrite keys other rows reference.

Figures here are directional, not universal — measure on your workload.

### Don't expose sequential IDs in public URLs

A bare auto-increment in a URL leaks volume and invites enumeration. Either use a UUIDv7 as the public identifier, or keep BIGINT internal and add a UUID/slug for the outside. (This is the gap baseline models miss — they reach for v4 by reflex; prefer v7 unless you specifically need unpredictability over ordering.)

## FK actions

Every FK needs a _deliberate_ `ON DELETE` (and sometimes `ON UPDATE`) action — picking one is part of L1, not an afterthought.

| Action                   | Use when                                                                                                               |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------- |
| **RESTRICT / NO ACTION** | Safe default — block deletion while children exist.                                                                    |
| **CASCADE**              | True composition — children cannot exist without the parent (order_item under orders). Use sparingly; it deletes data. |
| **SET NULL**             | Optional child outlives the parent (post.author_id when an author is removed). Requires the FK column be nullable.     |
| **SET DEFAULT**          | Rare — child reparents to a default row.                                                                               |

**Contradiction to avoid:** `ON DELETE SET NULL` on a `NOT NULL` FK column is impossible — the engine can't write the NULL it promised. Either make the column nullable or choose a different action.

**FKs cost writes:** each enforced FK makes the engine verify the parent exists on every child insert/update, and check for surviving children on every parent delete/update. That's the price of integrity — pay it by default, and index the FK column (see indexing reference) so the child-side checks don't table-scan. "Drop FKs for write speed" is Keyless Entry (L1); the right lever is indexing the FK, not removing the constraint.

## Examples

```sql
-- surrogate PK + natural UNIQUE (the common case)
CREATE TABLE customer (
    id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email text NOT NULL UNIQUE,            -- natural/alternate key still enforced
    name  text NOT NULL
);

-- public-facing entity using a time-ordered UUID as PK
CREATE TABLE invoice (
    id         uuid PRIMARY KEY DEFAULT uuidv7(),   -- PG 18+; pre-18, or when unpredictability trumps ordering: gen_random_uuid() (v4)
    customer_id bigint NOT NULL REFERENCES customer (id),
    issued_at  timestamptz NOT NULL DEFAULT now()
);
```

**Other engines:**

- **MySQL:** `BIGINT AUTO_INCREMENT`; store UUIDs as `BINARY(16)` (optionally with `UUID_TO_BIN(uuid, true)` to byte-swap v1 for index locality). InnoDB clusters on the PK, so a random UUID PK is especially costly there — prefer a sequential PK or a swapped/ordered UUID.
- **SQL Server:** also clusters on the PK by default; use `NEWSEQUENTIALID()` rather than `NEWID()` if a GUID must be the clustered key.
- **Postgres:** heap-organised (not clustered on PK), so the penalty of a random PK is smaller than in MySQL/SQL Server — but index bloat still argues for v7 over v4.
