# Repository Guidelines

## Project Structure & Module Organization
This repository is an Elixir umbrella app. Core backend code lives in `apps/*/lib`, with tests in `apps/*/test`.

- `apps/synapsis_core`: domain logic (sessions, tools, orchestration)
- `apps/synapsis_server`: API/channels layer
- `apps/synapsis_data`: Ecto/repository and migrations
- `apps/synapsis_provider`: provider adapters
- `apps/synapsis_plugin`: MCP/LSP integration points
- `apps/synapsis_cli`: CLI entrypoint
- `apps/synapsis_web`: Phoenix web + frontend assets (`assets/`)
- `packages/*`: TypeScript workspace packages (`@synapsis/ui`, `@synapsis/hooks`, `@synapsis/channel`)
- `docs/`: architecture decisions and handoff docs

## Build, Test, and Development Commands
Run commands from repository root unless noted.

- `mix deps.get`: fetch Elixir dependencies
- `mix ecto.setup`: create and migrate DB
- `mix phx.server`: start Phoenix server
- `mix test`: run all umbrella tests
- `mix test apps/synapsis_core`: run one app’s tests
- `mix format --check-formatted`: verify formatting
- `cd apps/synapsis_web && bun install`: install frontend deps
- `mix assets.build` / `mix assets.deploy`: build/minify frontend assets

## Coding Style & Naming Conventions
Use `.editorconfig`: UTF-8, LF endings, 2-space indentation (except `Makefile` tabs).

Elixir:
- format with `mix format`
- modules in `PascalCase` (e.g., `SynapsisCore.Session`)
- functions/variables in `snake_case`

TypeScript/React:
- components in `PascalCase` (`MessageList.tsx`)
- utility modules/hooks in lowercase or kebab-style file names (`scroll-bottom.ts`)

## Testing Guidelines
Primary framework is ExUnit (`*_test.exs`). Keep tests near the owning umbrella app and mirror module paths.

- Name files like `apps/synapsis_core/test/.../session_test.exs`
- Prefer focused unit tests plus channel/live integration tests where behavior crosses boundaries
- Run `mix test` before opening a PR

No coverage gate is configured; add tests for all behavior changes and regressions.

## Commit & Pull Request Guidelines
Recent history follows Conventional Commit style:

- `feat(scope): add model selector`
- `fix(streaming): remove duplicate subscription`
- `test(provider): strengthen edge-case assertions`

PRs should include:
- concise problem/solution summary
- linked issue/task (if available)
- test evidence (`mix test` output summary)
- screenshots or GIFs for UI/LiveView changes
