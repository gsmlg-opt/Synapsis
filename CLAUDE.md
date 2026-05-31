# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository. Keep it aligned with `AGENTS.md`; this file is intentionally concise and current-state focused.

## Common Commands

Run commands from the umbrella root unless noted.

```bash
# Setup
mix deps.get
mix ecto.setup
cd apps/synapsis_web && bun install && cd ../..

# Run server
mix phx.server

# Tests
mix test
mix test apps/synapsis_core/test
mix test apps/synapsis_web/test/synapsis_web/live/session_live/show_test.exs
mix test path/to/test_file.exs:42

# Code quality
mix compile --warnings-as-errors
mix format --check-formatted
mix format

# Database
mix ecto.create && mix ecto.migrate
mix ecto.reset

# Assets
cd apps/synapsis_web && mix assets.build
cd apps/synapsis_web && mix assets.deploy
```

## App Structure

The umbrella has 9 apps:

```text
synapsis_data        - Ecto schemas, Repo, migrations, persistence contexts
synapsis_provider    - Anthropic/OpenAI/Google transports, model registry, retry, sanitization
synapsis_core        - shared tools, config, PubSub, memory, git/worktree helpers, file watching
synapsis_agent       - agent graph runtime, session workers, supervisors, heartbeats
synapsis_plugin      - plugin loader, MCP protocol, LSP protocol and managers
synapsis_workspace   - workspace resources, blob store, projections, path resolution, search
synapsis_server      - Phoenix endpoint, channels, REST/SSE controllers, telemetry
synapsis_web         - Phoenix LiveView UI, HEEx, DuskMoon components, TypeScript hooks
synapsis_cli         - escript CLI and HTTP/SSE client code
```

Dependency direction is strict:

```text
synapsis_data
  <- synapsis_provider
  <- synapsis_core
  <- synapsis_workspace
  <- synapsis_agent
  <- synapsis_plugin
  <- synapsis_server
  <- synapsis_web
```

Do not introduce cycles or direct higher-layer dependencies for convenience.

## Key Systems

- Agent graph execution lives under `apps/synapsis_agent/lib/synapsis/agent/`. `coding_loop` handles build-mode tool use; `conversational_loop` handles chat mode.
- Session workers live under `apps/synapsis_agent/lib/synapsis/session/worker/` and are supervised per session.
- Provider transports live under `apps/synapsis_provider/lib/synapsis/provider/transport/` and normalize streaming provider events into domain messages.
- Tool registration and execution live under `apps/synapsis_core/lib/synapsis/tool/` and must enforce path validation, permissions, persistence, and timeouts.
- Memory, PubSub, config, git/worktree helpers, and shared domain services belong in `synapsis_core`.
- Workspace-specific path, blob, projection, permission, and search behavior belongs in `synapsis_workspace`.
- Phoenix controllers, routes, channels, and LiveViews stay in `synapsis_server` and `synapsis_web`.

## Web UI

The web interface is Phoenix LiveView, not React. It uses `phoenix_duskmoon` and DuskMoon packages.

- Prefer `phoenix_duskmoon` components for new UI.
- Do not add DaisyUI or another CSS component library.
- Treat `SynapsisWeb.CoreComponents` as legacy/local glue; do not expand it when DuskMoon has a suitable component.
- Keep UI dense, operational, accessible, and responsive.
- For LiveView changes, run the focused `apps/synapsis_web/test` files. For hook or asset changes, also run `cd apps/synapsis_web && mix assets.build` when practical.

## Guardrails

- Database is the source of truth. Persist before broadcasting via `Synapsis.PubSub`.
- Never make synchronous LLM calls in request or worker paths.
- Use `Port` for shell/tool execution, not `System.cmd`.
- Validate every tool path against the project root and reject traversal.
- Run permission checks even when dev config auto-approves a risk level.
- Give Port, task, HTTP, provider, LSP, and MCP operations explicit timeouts.
- Handle monitored process exits and `:DOWN` messages for long-running processes.
- Use structured logging and never log secrets or API keys.
- Test provider HTTP behavior with `Bypass`; never hit real provider APIs in tests.
- Keep `.opencode.json` compatibility unless a task explicitly changes that contract.

## Data Layer

- `synapsis_data` owns schemas, migrations, Repo access, Ecto queries, and transaction boundaries.
- Other apps should use `synapsis_data` contexts instead of defining schemas or calling `Synapsis.Repo` directly.
- Use UUID/binary IDs for persisted records.
- Keep agent runtime, orchestration, Phoenix, provider streaming, and tool execution logic out of `synapsis_data`.

## Docs To Read

- `docs/architecture/*`: system overview, domain model, data layer, tools, providers, boundaries.
- `docs/guardrails/GUARDRAILS.md`: invariants for runtime, persistence, tools, and providers.
- `docs/agents/domain.md`: repo-specific context lookup rules.
- `docs/agents/issue-tracker.md`: GitHub issue workflow.
- `docs/agents/triage-labels.md`: default triage labels.

Do not restore obsolete bootstrap phase plans or React frontend instructions into this file. Current implementation guidance belongs here; long-form plans belong under `docs/`.

## Dependency Issue Routing

If a dependency from `gsmlg*`, `duskmoon-dev`, `Gao-OS`, or related internal GitHub organizations is missing needed behavior or appears buggy:

- Identify the upstream repo from dependency metadata.
- Open a GitHub issue labeled `internal request` with type `Bug` or `Feature`.
- Add a `# TODO(upstream): org/repo#issue` comment for blockers.
- For non-blocking temporary workarounds, add `# WORKAROUND(upstream): org/repo#issue`.
- If the upstream issue blocks the task, stop the blocked task and report the dependency.

## Graphify And GitNexus

- Read `graphify-out/GRAPH_REPORT.md` before source exploration.
- Prefer `graphify query`, `graphify path`, or `graphify explain` for cross-module questions.
- Run `graphify update .` after modifying code.
- Before editing a function, class, or method, run GitNexus impact analysis and report the blast radius.
- Run GitNexus change detection before committing.

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
