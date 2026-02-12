# ADR-002: PostgreSQL Storage

## Status: Accepted

## Context

Need to persist sessions and messages. OpenCode uses JSON files on disk. Options considered: JSON files, ETS + DETS, Mnesia, SQLite, PostgreSQL.

## Decision

PostgreSQL via Ecto (`postgrex`). Single database, projects scoped by `project_id` column.

## Rationale

- **Maximum development velocity**: `mix ecto.gen.migration`, `mix phx.gen.schema`, standard Ecto queries — zero custom persistence code
- **JSONB**: native support for the polymorphic parts structure, queryable without deserialization
- **Concurrency**: no write contention during concurrent sessions streaming
- **Ecosystem**: LiveDashboard Ecto stats, Oban compatibility, every Ecto library assumes Postgres
- **AI-assisted development**: all code generation models know Ecto + Postgres patterns, minimizing friction when building with Claude Code

## Alternatives Considered

**JSON files** (like OpenCode): Zero deps, but no query capability. Listing/searching requires reading all files. No transactional guarantees. Custom serialization code.

**ETS + DETS**: OTP-native, but DETS has 2GB limit, corruption risk, no ordering. Would require building a custom persistence layer.

**Mnesia**: No external deps, but schema migrations are manual, large binary transactions spike memory, and weak tooling familiarity across AI code generators.

**SQLite** (`ecto_sqlite3`): Zero infrastructure, but less Ecto tooling support, dynamic per-project Repo adds complexity, concurrent write limitations.

## Consequences

- Requires a running PostgreSQL instance (acceptable — `docker compose up` or system install)
- Standard Ecto migration workflow — no custom persistence code
- Can leverage JSONB operators for future search/filter features
- ETS still used for runtime caches (provider registry, config, tool registry) — not persistent state
