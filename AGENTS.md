# Repository Guidelines

## Project Structure And Module Organization

This is an Elixir umbrella project with a Phoenix server/web surface, OTP-backed agent runtime, Ecto persistence, and TypeScript workspace packages.

- `apps/synapsis_data`: Ecto schemas, Repo, migrations, persistence contexts, encrypted fields, and database-facing APIs.
- `apps/synapsis_provider`: provider adapters and streaming transport for Anthropic, OpenAI-compatible, Google, model registry, retry, sanitization, and provider event/message mapping.
- `apps/synapsis_core`: shared domain services, session orchestration helpers, tool registry/executor, permissions, config, PubSub, memory, git/worktree helpers, and file watching.
- `apps/synapsis_agent`: supervised agent/session runtime, agent graphs, query loop, runtime checkpoints, work items, heartbeats, messaging, and session worker implementation.
- `apps/synapsis_server`: Phoenix endpoint, router, channels, REST/SSE controllers, telemetry, and debug store.
- `apps/synapsis_web`: Phoenix LiveView UI, HEEx layouts, DuskMoon-based components, TypeScript hooks, and asset entrypoints.
- `apps/synapsis_plugin`: plugin loader, plugin servers, MCP protocol support, and LSP protocol/manager support.
- `apps/synapsis_workspace`: workspace resource model, local blob store, projections, path resolution, search, permissions, and workspace tools.
- `apps/synapsis_cli`: escript CLI and HTTP/SSE client code.
- `packages/*`: Bun workspaces for TypeScript packages (`@synapsis/channel`, `@synapsis/hooks`, `@synapsis/ui`).
- `docs/`: architecture docs, ADRs, guardrails, PRDs, designs, and implementation plans. Read the relevant docs before changing behavior.

## Architecture Boundaries

- Database is the source of truth for projects, sessions, messages, tool calls, memory, agent events, and workspace records. GenServers may hold transient operational state only.
- `synapsis_data` owns schemas, migrations, Repo access, queries, and transactions. Other apps should go through `synapsis_data` contexts instead of defining schemas or using `Synapsis.Repo` directly.
- `synapsis_provider` owns provider-specific request/response formats. Core and agent code should operate on domain structs/events, not hardcoded provider payload shapes.
- `synapsis_core` owns shared tool, config, PubSub, memory, git, and session-domain services. Keep Phoenix endpoint/router/controller concerns out of core.
- `synapsis_agent` owns the agent runtime and supervised session/agent processes. Tool registration happens there at startup.
- `synapsis_server` and `synapsis_web` are presentation layers. They depend inward on core/agent/provider/plugin/workspace APIs.
- `synapsis_plugin` and `synapsis_workspace` are support layers. Keep plugin/LSP/MCP protocol concerns in plugin modules and virtual workspace concerns in workspace modules.
- Preserve dependency direction shown by `mix.exs` files. Do not introduce cycles or broad cross-app calls just for convenience.

## Guardrails

- Persist before broadcasting. Write to the database first, then publish via `Synapsis.PubSub`.
- Never make synchronous LLM calls in request or worker paths; stream asynchronously and delegate slow work to supervised tasks.
- Use `Port` for shell/tool execution, not `System.cmd`, so output streaming, timeouts, and cancellation remain possible.
- Validate every tool path against the project root and reject path traversal.
- Always run permission checks, even when dev config auto-approves a risk level.
- Give Port, task, HTTP, provider, LSP, and MCP operations explicit timeouts.
- Handle monitored process exits and `:DOWN` messages for stream processes, tool tasks, LSP/MCP processes, and agent work.
- Use structured logging such as `Logger.info("session_started", session_id: id)`. Do not interpolate secrets or API keys into logs.
- Test provider HTTP behavior with `Bypass`; never hit real provider APIs in tests.
- Keep `.opencode.json` compatibility for agents, providers, MCP servers, and LSP config unless a task explicitly changes that contract.

## Build, Test, And Development Commands

Run commands from the repository root unless noted.

- `mix deps.get`: fetch Elixir dependencies.
- `mix ecto.create && mix ecto.migrate`: create and migrate the configured database.
- `mix ecto.setup`: create, migrate, and seed when appropriate.
- `mix phx.server`: start the Phoenix endpoint on the configured dev port (`4657` by default).
- `mix test`: run the full umbrella test suite.
- `mix test apps/synapsis_core/test`: run one app's tests by path.
- `mix test apps/synapsis_web/test/synapsis_web/live/session_live/show_test.exs`: run a focused test file.
- `mix format --check-formatted`: verify Elixir formatting.
- `cd apps/synapsis_web && mix assets.setup`: install Bun and Tailwind CLIs if missing.
- `cd apps/synapsis_web && mix assets.build`: build web assets.
- `cd apps/synapsis_web && mix assets.deploy`: build minified production assets with digest.
- `bun install`: install Bun workspace dependencies for `packages/*` and app packages.

Use scoped tests for scoped changes. For PRD work, modify only files in the stated scope, run only scoped tests unless told otherwise, and stop once the in-scope checklist is complete and tests pass. If unrelated tests fail, report them and stop instead of fixing outside scope.

## Coding Style

- Follow `.editorconfig`: UTF-8, LF endings, 2-space indentation except Makefiles.
- Format Elixir with `mix format`; the root formatter delegates to all umbrella apps.
- Elixir modules use `PascalCase`; functions, variables, and atoms use `snake_case`.
- Keep tests under the owning app's `test/` tree and mirror the module path.
- Match existing patterns and naming before adding abstractions. Avoid speculative configuration or generic layers for one-off behavior.
- Remove only imports, aliases, functions, or variables made unused by your own changes.
- Do not refactor adjacent code, reformat unrelated files, or clean unrelated generated output.

## Data Layer Rules

- Put migrations in `apps/synapsis_data/priv/repo/migrations`.
- Use UUID/binary IDs for persisted records. Do not add auto-increment integer primary keys.
- Encapsulate Ecto queries and transaction boundaries in `synapsis_data`.
- Keep `synapsis_data` free of agent runtime, orchestration, Phoenix, provider streaming, tool execution, and UI logic.
- When a task explicitly targets `synapsis_data`, keep the change data-only. If the requested behavior truly needs cross-package API or architecture changes, explain the required boundary change before broadening the edit.

## Tool, Agent, And Process Rules

- Every tool implements `Synapsis.Tool.Behaviour`; every provider adapter follows the provider behavior/transport patterns already in `synapsis_provider`.
- Tools must include project context, validate inputs, honor permissions, persist auditable calls where required, and broadcast side effects only after persistence.
- Session and agent workers must not block on provider streams, tool execution, database work that can be slow, or external processes.
- Agent graph changes should include focused tests in `apps/synapsis_agent/test`.
- Tool changes should include focused tests in `apps/synapsis_core/test/synapsis/tool`.
- Provider changes should include parser/transport tests in `apps/synapsis_provider/test` with `Bypass` for HTTP.

## Web And UI Rules

- This project uses Phoenix LiveView plus TypeScript hooks and DuskMoon UI. Prefer `phoenix_duskmoon` components and DuskMoon packages for new UI work.
- Do not add DaisyUI or another CSS component library.
- Treat `SynapsisWeb.CoreComponents` as legacy/local glue. Do not expand it when a DuskMoon component fits the job.
- Tailwind CSS is built through the configured Tailwind CLI and `@duskmoon-dev/core` assets/packages.
- Keep UI changes consistent with the existing dashboard/application style: dense, operational, accessible, and responsive.
- For LiveView changes, run the relevant `apps/synapsis_web/test` files. For hook/package changes, also build assets when practical.

## Documentation And Planning

- Architecture source of truth lives in `docs/architecture/*` and `docs/guardrails/GUARDRAILS.md`.
- PRDs and implementation plans live under `docs/prd`, `docs/designs`, and `docs/superpowers/plans`.
- Update docs only when the behavior or public contract changes, or when the task explicitly asks for docs.
- Keep generated planning/checklist content out of `AGENTS.md`; this file should stay concise and operational.

## Agent Skills

### Issue Tracker

Issues are tracked in GitHub Issues for `gsmlg-opt/Synapsis` using `gh`. See `docs/agents/issue-tracker.md`.

### Triage Labels

Use the default five-label triage vocabulary. See `docs/agents/triage-labels.md`.

### Domain Docs

This is a single-context repo. Use repo-wide architecture, decision, guardrail, PRD, and design docs. See `docs/agents/domain.md`.

## Dependency Issue Routing

If a dependency from the `gsmlg*`, `duskmoon-dev`, `Gao-OS`, or related internal GitHub organizations is missing needed behavior or appears buggy, do not silently work around it.

- Identify the upstream repo from `mix.exs`, `package.json`, `Cargo.toml`, `go.mod`, `pubspec.yaml`, `flake.nix`, or lockfiles.
- Open an upstream GitHub issue labeled `internal request` with the proper type (`Bug` or `Feature`) and severity.
- Add `# TODO(upstream): org/repo#issue` at the callsite for blockers.
- For non-blocking temporary workarounds, add `# WORKAROUND(upstream): org/repo#issue`.
- If the upstream issue blocks the requested task, stop that blocked task and move only to unrelated unblocked work.

## Git, Commits, And PRs

- Put repo-local worktrees under `.trees/<branch-name>`.
- Do not revert user changes or unrelated dirty worktree files.
- Use Conventional Commit style such as `feat(scope): add model selector`, `fix(streaming): handle disconnect`, or `test(provider): cover retry`.
- Do not include `Generated with Claude Code` or `Co-Authored-By: Claude` in commit messages.
- PRs should include a concise problem/solution summary, linked issue or task, test evidence, and screenshots or GIFs for UI changes.

## Graphify

This project has a knowledge graph at `graphify-out/` with god nodes, community structure, and cross-file relationships.

- Always read `graphify-out/GRAPH_REPORT.md` before reading source files, running grep/glob searches, or answering codebase questions.
- If `graphify-out/wiki/index.md` exists, navigate it instead of reading raw files.
- For cross-module questions, prefer `graphify query "<question>"`, `graphify path "<A>" "<B>"`, or `graphify explain "<concept>"` over grep.
- After modifying code, run `graphify update .` to keep the graph current.

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **Synapsis** (2662 symbols, 2866 relationships, 18 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/Synapsis/context` | Codebase overview, check index freshness |
| `gitnexus://repo/Synapsis/clusters` | All functional areas |
| `gitnexus://repo/Synapsis/processes` | All execution flows |
| `gitnexus://repo/Synapsis/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
