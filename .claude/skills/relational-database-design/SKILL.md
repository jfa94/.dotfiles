---
name: relational-database-design
description: Use when designing or changing a relational database schema — creating/altering tables, choosing primary keys or column types, adding constraints, modelling entities and relationships (many-to-many, hierarchies, inheritance, polymorphism), writing migrations, or reviewing a schema. Symptoms include "uuid or bigint?", "how to store money/dates?", "do I need a junction table?", "should I soft-delete?", "is this normalised?".
---

# Relational Database Design

## Overview

**Core principle: design follows the questions you will ask of the data, and the database is your last line of defence for integrity.** Model the domain, pick the grain, normalise, choose keys deliberately, and declare every constraint the engine can enforce.

Two tiers of discipline. **Iron Laws** are categorical — breaking one corrupts data or is unambiguously wrong. **Decision Gates** are genuine trade-offs — the discipline is to _choose consciously and say why_, never to default by accident.

**Violating the letter of the rules is violating the spirit of the rules.**

## When to use

Designing or changing a schema: creating/altering tables, choosing keys or types, adding constraints, modelling relationships, writing migrations, reviewing a schema.

**Not for** query/EXPLAIN performance tuning — use a query-tuning skill if installed (e.g. `supabase-postgres-best-practices`). Runtime concurrency, sharding, backups, and security-ops are out of scope.

**First, is it even relational?** If the dominant access shape is document, graph, key-value, or time-series, model that part in the fitting store rather than forcing the whole schema flexible (polyglot persistence). Analytical/reporting modelling (star/snowflake) _is_ in scope — see `modelling-and-normalisation.md`.

Principles are engine-agnostic; examples are Postgres-first, with notes where MySQL/SQL Server/Oracle differ materially.

## The Iron Laws

1. **Declare every invariant the database can enforce** — NOT NULL, FOREIGN KEY (with a deliberate ON DELETE action), UNIQUE, CHECK. Test: _"If a rogue script bypassed the app, would breaking this rule corrupt the data?"_ If yes, it is a database constraint — not just application logic. Omitting FKs "for flexibility" is Keyless Entry.
2. **Money is never binary floating point.** Use DECIMAL/NUMERIC(p,s) or integer minor units. Store the ISO-4217 currency alongside the amount when more than one is possible.
3. **Instants in UTC.** An event's time → `timestamptz` (UTC); a calendar date → `DATE`; a future/civil local time → local time + IANA zone name. Never a naive `timestamp` for an event; never a sentinel date.
4. **One value per cell.** No comma-separated lists, no `tag1/tag2/tag3`, no array standing in for a relationship. Use a junction or dependent table (1NF; counters Jaywalking).
5. **State the grain and a primary key before `CREATE TABLE`.** Decide what one row means; keep every row at that grain; give every table an identity.
6. **Schema changes are versioned migrations; live breaking changes use expand–contract.** Add the new shape before the code needs it; drop the old shape only after the old code is gone. Never hand-edit production; never a one-step destructive ALTER. Destructive DDL (`DROP TABLE`, or a `DROP`/retype/rename of a column live code depends on) is schema-changing SQL: run it only when the user has explicitly requested it and confirms in the current turn.
7. **Don't default to EAV or polymorphic FKs.** They forfeit type safety and referential integrity. Model subtypes; use a JSONB tail for genuinely dynamic/sparse data; use exclusive arcs or a shared supertype for polymorphism.
8. **NULL means "unknown," never a sentinel** (`-1`, `'N/A'`, `9999-12-31`). A nullable UNIQUE column still admits many NULL rows (NULLs compare distinct) — it does not cap missing values at one.
9. **Never store plaintext credentials.** Salted hash (bcrypt/scrypt/Argon2) only — never plaintext or reversible encryption.

Rationalizations → reality:

| Excuse                                    | Reality                                                                          |
| ----------------------------------------- | -------------------------------------------------------------------------------- |
| "It's just a prototype, skip constraints" | Prototypes become production. Constraints are the cheapest integrity you'll get. |
| "I'll add the FK later"                   | Later you have orphans. Declare it now.                                          |
| "FLOAT is fine for price"                 | 0.1 + 0.2 ≠ 0.3. DECIMAL or integer minor units.                                 |
| "A CSV column is simpler"                 | Breaks search, joins, validation, FK integrity. Junction table.                  |
| "I'll just store local time"              | Offsets change with DST and politics. UTC for instants.                          |
| "One quick ALTER"                         | Rolling deploys run old + new code at once. Expand–contract.                     |

## The pre-DDL gate

Before writing `CREATE TABLE`, `ALTER TABLE`, or a migration, pass every step. Skipping a step is the violation.

**Stage 1 — before any DDL**

1. Conceptual model: entities, relationships, cardinality, optionality named? Sketch it (Mermaid `erDiagram` or a plain entity list).
2. Grain of each table stated explicitly?
3. Normalised to 3NF/BCNF — or a denormalisation deliberately chosen and recorded (G3)?
4. Keys chosen deliberately (G1, G2): surrogate PK + UNIQUE natural key where one exists?
5. Every enforceable invariant declared (L1)?

**Stage 2 — physical**

6. Types correct (L2, L3, G7): money, time, lookup-vs-enum, JSONB only for dynamic/sparse?
7. Cross-cutting decisions where relevant: delete strategy (G4), tenancy model in a multi-tenant app (G9), created/updated/audit baseline, optimistic-lock version column where needed (see constraints-types-and-null)?
8. Naming consistent (snake_case; FK named after referenced table; reserved words avoided)?

## Decision Gates

Choose consciously; state the reason. Defaults shown; read the reference for the trade-off.

| Gate                            | Default                                       | Switch when…                                                                                                                                                  | Read                          |
| ------------------------------- | --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------- |
| G1 Key strategy                 | Surrogate PK + UNIQUE natural key             | pure junction/lookup table → natural composite key, no `id`                                                                                                   | keys-and-identifiers          |
| G2 Key type                     | BIGINT (single DB)                            | distributed/public/merged IDs → UUIDv7; unpredictability > ordering → UUIDv4; store UUIDs as 16-byte binary                                                   | keys-and-identifiers          |
| G3 Normalise/denormalise        | 3NF/BCNF                                      | measured read bottleneck → denormalise (mat. view > generated col > trigger > app); analytical workload → dimensional star/snowflake, kept separate from OLTP | modelling-and-normalisation   |
| G4 Delete strategy (per entity) | Hard delete + archive, or lifecycle status    | legal/undo need → soft delete + partial unique index on live rows                                                                                             | constraints-types-and-null    |
| G5 Tree model                   | Adjacency list + recursive CTE                | both-way + frequent change → closure table; read-only stable → nested sets; breadcrumbs → materialised path                                                   | relationships-and-hierarchies |
| G6 Inheritance                  | (decide per hierarchy)                        | shallow/shared → STI; deep/type-specific → CTI; independent → concrete; may mix                                                                               | relationships-and-hierarchies |
| G7 Dynamic attributes           | Real columns                                  | evolvable set → lookup table; sparse tail → JSONB+GIN; EAV only extreme sparse + high write concurrency                                                       | constraints-types-and-null    |
| G8 Where a rule lives           | Invariant → DB constraint                     | changeable/workflow → app; UX validation → app + DB backstop                                                                                                  | constraints-types-and-null    |
| G9 Tenancy                      | Shared schema + mandatory `tenant_id` (+ RLS) | compliance/residency/isolation contracts → schema- or DB-per-tenant                                                                                           | modelling-and-normalisation   |

## Red flags — STOP

- About to write `CREATE TABLE` without stating the grain → STOP (L5).
- A `type` + `id` pair pointing at several tables → polymorphic FK (L7).
- Adding `id` to a pure join table → ID Required (G1).
- A column holding a list, or `LIKE '%term%'` as the search plan → 1NF / Poor Man's Search Engine.
- `FLOAT`/`DOUBLE`/`REAL`/`MONEY` near a price → Rounding Errors (L2).
- `deleted_at` added to every table by reflex → soft-delete-everything anti-pattern (G4).
- Multi-tenant app, tables without `tenant_id` and no tenancy decision recorded → G9.
- Tuning a slow query with `EXPLAIN` → wrong skill; query tuning is out of scope.

## Reference map

| Topic                                                                                                        | File                                        |
| ------------------------------------------------------------------------------------------------------------ | ------------------------------------------- |
| Conceptual/logical/physical, ER, grain, normal forms, denormalisation, multi-tenancy                         | references/modelling-and-normalisation.md   |
| Natural vs surrogate, key types, FK actions                                                                  | references/keys-and-identifiers.md          |
| Constraints, NULL/3VL, money, time, strings, enums/lookup, JSONB, delete strategy, audit, optimistic locking | references/constraints-types-and-null.md    |
| M:N, self-ref, trees, polymorphism, inheritance                                                              | references/relationships-and-hierarchies.md |
| Anti-pattern catalogue + fixes                                                                               | references/anti-patterns.md                 |
| Design-level indexing principles                                                                             | references/indexing-for-design.md           |
| Migrations, expand–contract, naming                                                                          | references/schema-evolution-and-naming.md   |
