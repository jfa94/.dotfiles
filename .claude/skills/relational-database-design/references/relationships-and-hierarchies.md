# Relationships & Hierarchies

Modelling many-to-many, self-references, trees, polymorphism, and inheritance — keeping referential integrity intact.

## Many-to-many → junction table

An M:N relationship never lives in a column. Create a **junction (join/associative) table** whose PK is the composite of the two FKs:

```sql
CREATE TABLE enrolment (
    student_id  bigint NOT NULL REFERENCES student (id) ON DELETE CASCADE,
    course_id   bigint NOT NULL REFERENCES course  (id) ON DELETE CASCADE,
    enrolled_on date   NOT NULL DEFAULT current_date,  -- relationship attribute
    grade       text,                                  -- relationship attribute
    PRIMARY KEY (student_id, course_id)
);
```

- The composite PK enforces "a student enrols in a course at most once" and prevents the **Jaywalking** anti-pattern (comma-separated FK lists).
- **Relationship attributes** (enrolled_on, grade) belong _on the junction_, not on either entity.
- Index the second column too if you query both directions (`(course_id, student_id)`), since the PK only covers the leftmost-prefix.
- Don't add a surrogate `id` (G1 / ID Required) — the composite key is the identity.

## Self-referencing FK

A hierarchy within one entity uses an FK back to the same table:

```sql
CREATE TABLE employee (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       text NOT NULL,
    manager_id bigint REFERENCES employee (id)   -- nullable: the top has no manager
);
```

This is the **adjacency list** tree model (below).

## Trees & hierarchies (Gate G5)

| Model                                         | Read subtree                | Insert / move node                        | Notes                                                                     |
| --------------------------------------------- | --------------------------- | ----------------------------------------- | ------------------------------------------------------------------------- |
| **Adjacency list** (`parent_id`)              | Recursive CTE               | Trivial (one row)                         | Simplest; default. Reads need `WITH RECURSIVE`.                           |
| **Materialised path** (`/1/4/9/`)             | Prefix `LIKE` / range       | Cheap insert; move rewrites subtree paths | Great for breadcrumbs; path length limits depth.                          |
| **Nested sets** (left/right bounds)           | Single range query (fast)   | Expensive — most rows shift on write      | Read-only / rarely-changing trees.                                        |
| **Closure table** (ancestor, descendant rows) | Simple join, fast both ways | Insert/move touches many closure rows     | Best when you query _and_ mutate in both directions often; costs storage. |

**Guidance:** start with an **adjacency list + recursive CTE**. Move to a closure table when both-direction queries and frequent moves make CTEs too slow; nested sets only for stable, read-heavy trees; materialised path when you mainly need ancestor breadcrumbs.

```sql
-- adjacency list: fetch a subtree with a recursive CTE
WITH RECURSIVE org AS (
    SELECT id, manager_id, name FROM employee WHERE id = :root
  UNION ALL
    SELECT e.id, e.manager_id, e.name
    FROM employee e JOIN org ON e.manager_id = org.id
)
SELECT * FROM org;
```

## Polymorphic associations (Iron Law L7)

A "comment that attaches to a post **or** a video" tempts a polymorphic FK: `commentable_type text, commentable_id bigint`. **Don't** — `commentable_id` references no actual table, so the engine **cannot enforce** the FK. You get orphans and no cascade. Three integrity-preserving alternatives:

**1. Exclusive arcs** — one real, nullable FK per target type + a CHECK that exactly one is set. Best when the target set is small and stable:

```sql
CREATE TABLE comment (
    id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    body     text NOT NULL,
    post_id  bigint REFERENCES post  (id) ON DELETE CASCADE,
    video_id bigint REFERENCES video (id) ON DELETE CASCADE,
    CHECK (num_nonnulls(post_id, video_id) = 1)   -- exactly one parent
);
```

**2. Per-type junction tables** — `post_comment(post_id, comment_id)`, `video_comment(...)`. Each FK is real; scales to more types without widening `comment`.

**3. Shared supertype** — a `commentable` parent table that `post` and `video` both reference; `comment` FKs to `commentable`. Cleanest when many types share the behaviour (see inheritance below).

Trade-off: exclusive arcs add a column per new type; per-type junctions add a table per type. Both keep real FKs — that's the point.

## Inheritance / subtypes (Gate G6)

When entities share a core but have type-specific attributes (Vehicle → Car, Truck):

| Strategy               | Shape                                               | Pros                                          | Cons                                                                                     |
| ---------------------- | --------------------------------------------------- | --------------------------------------------- | ---------------------------------------------------------------------------------------- |
| **Single Table (STI)** | One table, all columns, a `type` discriminator      | Simple, no joins, polymorphic queries trivial | Type-specific columns must be nullable; CHECK constraints get complex; wide sparse table |
| **Class Table (CTI)**  | Supertype table + one table per subtype, shared PK  | Properly typed/NOT NULL per subtype; clean    | Joins to assemble a full object; insert touches 2 tables                                 |
| **Concrete Table**     | One independent table per subtype, no shared parent | No joins, fully typed                         | No easy "all vehicles" query; duplicated common columns; shared FK target impossible     |

**Guidance:** shallow hierarchy with mostly shared attributes → **STI**. Deep hierarchy with substantial type-specific data and a need for NOT NULL guarantees → **CTI**. Subtypes that are barely related and never queried together → **concrete**. You may mix strategies across different hierarchies in the same schema.
