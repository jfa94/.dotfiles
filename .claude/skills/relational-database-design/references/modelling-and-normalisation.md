# Modelling & Normalisation

How to get from a domain to a sound logical schema, and when to bend it.

## Three models — don't jump to CREATE TABLE

| Model          | Question it answers                                                        | Artefact                                                 |
| -------------- | -------------------------------------------------------------------------- | -------------------------------------------------------- |
| **Conceptual** | What things exist and how do they relate, in the language of the business? | Entities, relationships, cardinality — no types, no keys |
| **Logical**    | What is the precise structure: tables, columns, keys, FDs?                 | Normalised relations, engine-independent                 |
| **Physical**   | How is it stored and accessed in _this_ engine?                            | DDL, types, indexes, partitions                          |

Most schema mistakes are conceptual errors expressed in DDL. Do the first two models — even informally, in a comment or a sketch — before writing `CREATE TABLE` (Iron Law L5).

## ER essentials

- **Entity** — a thing with independent existence (Customer, Order). Becomes a table.
- **Attribute** — a property of an entity (email, placed_at). Becomes a column.
- **Relationship** — an association between entities (Customer _places_ Order).
- **Cardinality:**
  - **1:1** — rare; usually a sign the two tables should be one. Legitimate when you deliberately split columns off a wide row: optional/rarely-used detail, hot-vs-cold columns (vertical partitioning — keep the hot row narrow for cache density), or isolating sensitive columns. Justify it.
  - **1:N** — the workhorse; an FK on the N side.
  - **M:N** — never a column; always resolves to a **junction table**.
- **Optionality** → nullability: a mandatory relationship is a `NOT NULL` FK; an optional one is a nullable FK. Get this wrong and the schema either forbids legitimate data (over-strict NOT NULL) or admits orphans (a missing NOT NULL).

## Nouns → entities heuristic

1. Underline the nouns in the domain description; candidate entities and attributes.
2. **Entity-vs-attribute test:** does it have its own attributes or its own lifecycle? → entity. Otherwise → attribute. ("Address" is an attribute until it needs its own history, validation, or sharing — then it's an entity.)
3. Resolve **every** M:N to a junction table.
4. Ask whether the relationship itself has attributes (e.g. _enrolled_on_, _grade_ on a student↔course link) — if so, the junction is a first-class entity.

## Grain

**The grain is what one row means.** State it in one sentence before creating the table ("one row = one order line"). Rules:

- One grain per table. Keep every row at that grain.
- Mixed grain (order header fields repeated on every line row) causes update, insertion, and deletion anomalies — the same fact stored many times drifts out of sync.
- The fix is almost always to split by grain.

## Functional dependencies

A **functional dependency** X → Y means X determines Y (given a customer_id, there is exactly one customer_email). Normalisation is the disciplined removal of FDs that don't hang off the key.

- **Partial dependency** — a non-key attribute depends on only _part_ of a composite key (violates 2NF).
- **Transitive dependency** — a non-key attribute depends on another non-key attribute (violates 3NF): `order_id → customer_id → customer_city` means `customer_city` doesn't belong on `order`.
- **Multi-valued dependency** — independent multi-valued facts crammed together (violates 4NF).

## Normal forms

Target **3NF / BCNF**. Recognise 4NF/5NF, don't chase them.

| Form     | One-line intuition                                                                                                                        |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| **1NF**  | Atomic cells; no repeating groups, no lists in a column; a key exists.                                                                    |
| **2NF**  | 1NF + no non-key attribute depends on only part of a composite key.                                                                       |
| **3NF**  | 2NF + no transitive dependencies (non-key → non-key). **The practical target.**                                                           |
| **BCNF** | Stricter 3NF: every determinant is a candidate key. Most 3NF is already BCNF; they differ only with overlapping composite candidate keys. |
| **4NF**  | No independent multi-valued facts in one table.                                                                                           |
| **5NF**  | No join dependency that isn't implied by candidate keys. Rarely a concern.                                                                |

Slogan: _every non-key attribute depends on the key, the whole key, and nothing but the key._

## Denormalisation ladder (Gate G3)

Normalise first. Denormalise **only** for a measured read bottleneck (expensive repeated aggregates/counts, or read-heavy reporting paths), and record the decision. Costs: write amplification, drift (the copy diverges from the source), extra storage, more invalidation logic.

Climb in this order — stop at the first rung that solves it, because each later rung adds more ways to get drift:

1. **Materialised view** — engine owns the derived data; you control refresh; source stays normalised.
2. **Generated/computed column** — `GENERATED ALWAYS AS (...) STORED`; engine keeps it consistent.
3. **Trigger-maintained column** — you own the logic; correct but easy to get subtly wrong.
4. **Application-maintained copy** — last resort; every writer must remember to update it.

## OLTP vs analytical (star / snowflake)

Normalisation targets **transactional** workloads — many small reads/writes, integrity first. **Analytical / reporting** workloads (few huge aggregating scans) are modelled the opposite way, **dimensionally**:

- **Star schema** — a central **fact** table at a declared grain (one row = one measured event, e.g. one sale line) holding FKs + numeric measures, surrounded by denormalised **dimension** tables (date, product, customer).
- **Snowflake schema** — the same, but dimensions are themselves normalised into sub-tables: fewer copies, more joins.

Keep the two models **separate**: don't force a star shape onto a write-heavy transactional backend, and don't run heavy OLAP scans on your normalised OLTP tables. The anti-pattern is one giant denormalised "reporting" table acting as the operational source of truth. Feed an analytical store (materialised views, or a warehouse) from the OLTP system unless the workload is genuinely hybrid and small. Deep query/EXPLAIN tuning of either is out of scope — see `supabase-postgres-best-practices`.

## Example — splitting mixed grain

A single `orders` table that repeats the header on every line item violates grain and 3NF. Split by grain: header facts in `orders`, line facts in `order_item`.

```sql
-- header grain: one row per order
CREATE TABLE orders (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id   bigint NOT NULL REFERENCES customer (id),
    placed_at     timestamptz NOT NULL DEFAULT now(),
    currency      char(3) NOT NULL,                 -- ISO 4217
    status        text NOT NULL DEFAULT 'pending'
);

-- line grain: one row per product on an order
CREATE TABLE order_item (
    order_id      bigint NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
    line_no       int    NOT NULL,
    product_id    bigint NOT NULL REFERENCES product (id),
    quantity      int    NOT NULL CHECK (quantity > 0),
    unit_price    numeric(12,2) NOT NULL CHECK (unit_price >= 0),
    PRIMARY KEY (order_id, line_no)               -- natural composite key, no surrogate (G1)
);
```

`order_item` deliberately carries `unit_price` (the price _at time of sale_), which is **not** a denormalisation of `product.price` — it's a distinct fact (historical price), so it correctly lives here.

**Other engines:** the modelling and normal-form theory is engine-independent. `GENERATED ALWAYS AS IDENTITY` is standard SQL; MySQL uses `AUTO_INCREMENT`, SQL Server `IDENTITY`. Materialised views are native in Postgres/Oracle; MySQL has no native materialised view (emulate with a table + triggers/scheduled refresh).
