<!--
Sync Impact Report
==================
Version change: 0.0.0 → 1.0.0 (initial ratification)
Modified principles: N/A (first version)
Added sections:
  - Core Principles (7 principles)
  - Technology Stack & Constraints
  - Development Workflow & Quality Gates
  - Governance
Removed sections: N/A
Templates requiring updates:
  - .specify/templates/plan-template.md ✅ reviewed — no changes needed
  - .specify/templates/spec-template.md ✅ reviewed — no changes needed
  - .specify/templates/tasks-template.md ✅ reviewed — no changes needed
Follow-up TODOs: None
-->

# Synapsis.ex Constitution

## Core Principles

### I. Functional Core, Imperative Shell

- All domain logic MUST reside in `synapsis_core` with zero dependencies
  on other umbrella apps (`synapsis_server`, `synapsis_cli`, `synapsis_lsp`,
  `synapsis_web`).
- Pure functions (message building, context window management, config
  merging, permission checks, provider response parsing) MUST have no
  side effects.
- Side effects (DB writes, HTTP calls, PubSub broadcasts, Port I/O) MUST
  occur only at process boundaries (GenServers, Tasks, Channels).
- `synapsis_core` MUST NOT depend on Phoenix. Communication with the
  server layer uses `Phoenix.PubSub`, which is a stdlib-level abstraction
  with no Phoenix coupling.

### II. Database as Source of Truth

- PostgreSQL via Ecto is the sole persistent store for sessions, messages,
  and configuration state.
- GenServers MUST NOT hold persistent state. They hold only transient
  operational state: current streaming connection, accumulated chunks,
  pending tool permissions.
- On crash/restart, `Session.Worker` MUST rehydrate fully from the
  database.
- All writes MUST be persisted to the database before broadcasting via
  PubSub. The sequence is: write to DB, then broadcast. Never reverse.
- All IDs MUST be UUIDs (Postgres-native). Auto-increment is prohibited.

### III. Process-per-Session (Let It Crash)

- Each coding session MUST be a supervision subtree under
  `DynamicSupervisor` with `:one_for_all` strategy:
  `Session.Worker` + `Session.Stream` + `Session.Context`.
- Sessions are crash-isolated: one session's provider timeout MUST NOT
  affect other sessions.
- `Session.Worker` is the single point of coordination for its session
  and MUST serialize all operations within that session.
- `Session.Worker` MUST NOT be blocked by slow operations. Tool
  execution, LLM streaming, and potentially slow DB writes MUST be
  delegated to `Task.Supervisor`.
- All GenServers that hold resources (Ports, HTTP streams) MUST
  implement `terminate/2` to release them.

### IV. Provider-Agnostic Streaming

- Each LLM provider MUST implement `Synapsis.Provider.Behaviour` with
  `stream/2`, `cancel/1`, and `format_request/3` callbacks.
- LLM calls MUST always be asynchronous and streaming. Synchronous LLM
  calls are prohibited.
- Core logic MUST NOT hardcode provider-specific message formats.
  Providers implement `format_request/3` to translate domain structs
  into their wire format.
- Provider response parsing MUST always pattern match with a fallback
  clause. Providers change SSE formats without warning.
- `Provider.Registry` (ETS-backed) is a cache, not a source of truth.
  It MUST rebuild from config on restart.

### V. Permission-Controlled Tool Execution

- All tools MUST implement `Synapsis.Tool.Behaviour` with
  `call/2` returning `{:ok, result} | {:error, reason}`.
- Tool execution MUST always be async via `Task.Supervisor`.
- The permission check function MUST be called before every tool
  execution, even in "auto-approve" mode. The policy decides, not the
  caller.
- The Bash tool MUST use `Port` (not `System.cmd`) for streaming
  output, timeout control, and kill capability.
- All file path arguments MUST be validated against the project root
  to prevent `../` directory traversal escapes.
- All Port and Task operations MUST have a configured timeout. No
  unbounded waits.

### VI. Structured Observability

- All log calls MUST use structured logging:
  `Logger.info("event_name", key: val)`. String interpolation in log
  messages is prohibited.
- API keys and secrets MUST NOT appear in log output.
- Provider integration tests MUST use `Bypass` to mock HTTP endpoints.
  Tests MUST NOT hit real provider APIs.
- In tests: always use `start_supervised!/1` for process cleanup; use
  `Process.monitor/1` + `assert_receive {:DOWN, ...}` instead of
  `Process.sleep/1`; use `:sys.get_state/1` to synchronize before
  assertions.

### VII. Strict Umbrella Dependency Direction

- The dependency graph is:
  `synapsis_server` → `synapsis_core`, `synapsis_lsp`;
  `synapsis_lsp` → `synapsis_core`;
  `synapsis_cli` → (no umbrella deps);
  `synapsis_web` → (no umbrella deps, build artifact only).
- `synapsis_core` MUST import nothing from any other umbrella app.
- Each app maps to a deployment boundary. `synapsis_cli` MUST be
  packageable as a standalone escript.
- Never nest multiple modules in the same file (causes cyclic
  dependency and compilation errors in Elixir).

## Technology Stack & Constraints

- **Language**: Elixir 1.18+ / OTP 28+ (BEAM 27)
- **Web framework**: Phoenix 1.8+ with Bandit HTTP server (API-only,
  no HTML/LiveView)
- **Database**: PostgreSQL 16+ via Ecto, Unix socket in development
- **HTTP client**: `Req` + `Finch` for provider streaming. The use of
  `:httpoison`, `:tesla`, or `:httpc` is prohibited.
- **Frontend**: React + Tailwind CSS 4, built with Bun (served as
  Phoenix static assets)
- **Config compatibility**: `.opencode.json` format MUST remain
  backward-compatible with OpenCode. Merge order:
  defaults < user (`~/.config/synapsis/config.json`) < project < env.
- **Performance targets**: session startup <50ms, message persistence
  <10ms, first token to client <200ms after provider responds, 100+
  concurrent sessions per node, <1MB memory per idle session.

## Development Workflow & Quality Gates

- Use `mix format --check-formatted` to verify formatting before
  commit. Use `mix format` to auto-fix.
- Use `mix test` to run all umbrella tests. Single-app:
  `mix test apps/synapsis_core`. Single-file:
  `mix test apps/synapsis_core/test/path_test.exs:42`.
- The `mix precommit` alias (in `synapsis_server`) compiles with
  warnings-as-errors, formats, and tests.
- Elixir lists do not support index-based access (`list[i]`). Use
  `Enum.at/2` or pattern matching.
- Never use map access syntax (`changeset[:field]`) on structs. Use
  `my_struct.field` or `Ecto.Changeset.get_field/2`.
- Do not use `String.to_atom/1` on user input (atom table memory leak).
- Predicate functions end with `?`. Reserve `is_` prefix for guards
  only.
- OTP primitives (`DynamicSupervisor`, `Registry`) require names in
  child spec: `{DynamicSupervisor, name: MyApp.MySup}`.
- Phoenix router `scope` blocks prefix the alias automatically. Do not
  duplicate.

## Governance

- This constitution supersedes all other development practices when
  conflicts arise.
- Amendments require: (1) documented rationale, (2) review of all
  dependent artifacts (CLAUDE.md, templates, design docs), and
  (3) a migration plan for any code that violates the new rule.
- Version follows semantic versioning: MAJOR for principle
  removals/redefinitions, MINOR for new principles or material
  expansions, PATCH for clarifications and wording.
- All PRs and code reviews MUST verify compliance with these
  principles. Violations MUST be justified in a Complexity Tracking
  table (see plan template).
- Use `CLAUDE.md` for runtime development guidance complementary to
  this constitution.

**Version**: 1.0.0 | **Ratified**: 2026-02-12 | **Last Amended**: 2026-02-12
