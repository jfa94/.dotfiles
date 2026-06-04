# Anti-Patterns Catalogue

A quick-reference of common relational-design mistakes (largely Karwin's _SQL Antipatterns_, plus a few more), each with the smell that reveals it, the fix, and the Iron Law or Decision Gate that prevents it.

**Legitimate uses exist for several of these — they're _usually_ wrong, not _always_.** The discipline is to recognise the pattern and justify it consciously, not stumble into it.

## Logical / structural

| Anti-pattern                     | Smell                                                                   | Fix                                                                | Prevented by          |
| -------------------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------ | --------------------- |
| **Jaywalking**                   | Comma-separated list of FKs in a column (`tags = 'a,b,c'`)              | Junction table, one row per association                            | L4                    |
| **Multicolumn Attributes**       | `tag1, tag2, tag3` repeating columns                                    | Dependent/junction table                                           | L4                    |
| **Naive Trees**                  | Adjacency list assumed the only option, can't query subtree efficiently | Pick a tree model deliberately (closure table, path, nested sets)  | G5                    |
| **ID Required**                  | Surrogate `id` bolted onto a pure junction/lookup table                 | Use the natural composite key as PK                                | G1                    |
| **Keyless Entry**                | No foreign keys "for flexibility/speed"                                 | Declare FKs with deliberate ON DELETE actions                      | L1                    |
| **Entity-Attribute-Value (EAV)** | Generic `(entity, attribute, value)` rows for everything                | Typed columns; JSONB for sparse tail; EAV only at extreme sparsity | L7, G7                |
| **Polymorphic Associations**     | `(thing_type, thing_id)` FK pointing at several tables                  | Exclusive arcs / per-type junctions / shared supertype             | L7                    |
| **Metadata Tribbles**            | Tables/columns split by value (`orders_2024`, `orders_2025`) by hand    | Native partitioning; one logical table                             | (design/partitioning) |
| **God Table**                    | One enormous table mixing many grains/entities                          | Split by grain and entity; normalise                               | L5                    |
| **Over-normalisation**           | Joins through 6 tables to read one screen                               | Stop at 3NF/BCNF; denormalise _measured_ hot paths                 | G3                    |
| **Under-normalisation**          | Same fact duplicated across rows, drifts                                | Normalise to remove the redundant FD                               | (normal forms)        |

## Physical / type

| Anti-pattern            | Smell                                                   | Fix                                                  | Prevented by   |
| ----------------------- | ------------------------------------------------------- | ---------------------------------------------------- | -------------- |
| **Rounding Errors**     | `FLOAT`/`DOUBLE`/`REAL`/`MONEY` for money               | DECIMAL(p,s) or integer minor units + currency       | L2             |
| **31 Flavors**          | Native `enum` for a set that keeps changing             | Lookup table + FK                                    | G7             |
| **Fear of the Unknown** | Sentinels (`-1`, `'N/A'`, `9999-12-31`) instead of NULL | Use NULL; design queries for 3VL                     | L8             |
| **Index Shotgun**       | Indexing every column / none; guessing                  | Index from real query patterns (MENTOR)              | (indexing ref) |
| **Naive time**          | Naive `timestamp` / fixed offset for events             | `timestamptz` UTC; local+IANA for future civil times | L3             |

## Query / application (still design-relevant)

| Anti-pattern                 | Smell                                                 | Fix                                                | Prevented by        |
| ---------------------------- | ----------------------------------------------------- | -------------------------------------------------- | ------------------- |
| **Poor Man's Search Engine** | `LIKE '%term%'` as the search strategy                | Full-text index / `tsvector` / external search     | (design for search) |
| **Implicit Columns**         | `SELECT *`, `INSERT` without column list              | Name columns explicitly                            | (convention)        |
| **Readable Passwords**       | Plaintext or reversibly-encrypted credentials         | Salted hash (bcrypt/scrypt/Argon2)                 | L8                  |
| **SQL Injection**            | String-concatenated queries                           | Parameterised queries / prepared statements always | (security)          |
| **Diplomatic Immunity**      | Schema/DDL exempt from version control, review, tests | Migrations are code: versioned, reviewed, tested   | L6                  |

## Scale

| Anti-pattern        | Smell                                                                     | Fix                                                                  |
| ------------------- | ------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| **Premature scale** | Sharding/partitioning/denormalising before any measurement                | Normalise; measure; scale the proven bottleneck                      |
| **Ignored scale**   | Design that can't grow at all (no key headroom, unindexable access paths) | Leave room (BIGINT keys, sane access paths) without over-engineering |
