# Provider, Models, MCP and Skills Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Share provider connections across configured models, live MCP tools and remote skills, and make session model selection durable and effective.

**Architecture:** Keep TOML configuration in synapsis_data, provider/model services in synapsis_provider, MCP and remote skill transport in synapsis_mcp, and session ownership in the existing worker. Add one configured model catalog and explicit MCP selection rules. Preserve Backplane source identity and strict provider-state validation.

**Tech Stack:** Elixir/OTP, embedded Ecto schemas, Config.Store, Concord, Phoenix LiveView, Phoenix DuskMoon, Backplane protocol packages, ExUnit/Bypass.

**Approved design:** `docs/superpowers/specs/2026-10-19-provider-model-mcp-skills-design.md` (user approval: 2026-10-19, LGTM).

**Workspace:** `/home/gao/Workspace/gsmlg-opt/Synapsis/.trees/provider-model-mcp-skills`, branch `codex/provider-model-mcp-skills`.

**Execution:** The user requests parallel work. Independent owners may edit disjoint files concurrently; all Mix/devenv commands serialize through `/tmp/synapsis-provider-model-mcp-skills-run`. No commits or publishing are requested.

## Shared contracts and ownership

- Model owner: data ModelConfig/Models/Store model type, Providers catalog service, provider/model settings UI and tests.
- MCP owner: synapsis_mcp, MCPConfig/MCPConfigs linkage, MCP settings and skill-source UI, related tests. Do not edit Providers or AgentLive.Agents.
- Session/selection owner (parent): core resolver/MCP selection/compaction, agent session/runtime/context/daemon filtering, AgentLive.Agents/Sessions/Toolsets and tests.
- `Providers.configured_models/0` returns runtime-available model rows carrying `id`, `provider_id`, `provider`, `model`, `name`, `context_window`.
- `Providers.model_context_window/2` resolves the configured provider/model context, falling back to existing static metadata for legacy configurations.
- `MCP.refresh_all/0` refreshes enabled sources and returns per-source outcomes. MCP registrations include `:mcp_config_id` and `:mcp_tool_name` so core can resolve selection without depending on the MCP app.
- The MCP app installs a `:synapsis_core, :mcp_refresh` callback for asynchronous turn preparation. Core never owns remote discovery.
- Agent MCP policy persists in `AgentConfig.config["mcp_selection"]`: `%{"default" => "all" | "selected", "sources" => %{source_uuid => %{"mode" => "all" | "selected" | "none", "tools" => [raw_name]}}}`.
- Missing legacy policy preserves existing effective MCP names. New agent forms explicitly initialize the all policy.

## Task 1: Add the configured model data catalog

**Files:** Create `apps/synapsis_data/lib/synapsis/model_config.ex`, `models.ex`, and `apps/synapsis_data/test/synapsis/models_test.exs`; modify `config/store.ex` and test isolation helpers only as needed for `:model`.

- [x] Write catalog tests before implementation. Cover round-trip, positive context, unique provider/model identity, enable/disable, imported metadata preserving user edits, and repeated import.

```elixir
assert {:ok, model} = Models.create(%{provider_id: provider_id, model: "custom-model", context_window: 32_768})
assert model.context_window == 32_768
assert {:error, _} = Models.create(%{provider_id: provider_id, model: "bad-context", context_window: 0})
assert {:ok, edited} = Models.update(model, %{context_window: 65_536, enabled: false})
assert edited.enabled == false
```

- [x] Run the new scoped data test and confirm the missing feature causes failure.
- [x] Implement embedded schema and data-only CRUD/import through Config.Store. Add `:model` to Store types and `models.toml` mapping.
- [x] Run the new data test and existing provider/store isolation contract tests; inspect persisted TOML round-trip.

## Task 2: Expose one model catalog and its settings UI

**Files:** Modify `apps/synapsis_provider/lib/synapsis/providers.ex`, provider configuration/preset fields as required, `apps/synapsis_web/lib/synapsis_web/live/model_tier_live/index.ex`, `provider_live/index.ex`, `provider_live/show.ex`, and corresponding tests.

- [x] Add provider service regressions for manual catalog models, duplicate raw IDs on different providers, consistent eligibility and configured context.

```elixir
assert [%{provider: "catalog-provider", model: "manual-model", context_window: 49_152}] =
         Providers.configured_models()
assert Providers.model_context_window("catalog-provider", "manual-model") == 49_152
refute Providers.model_runtime_available?(provider, "not-configured")
```

- [x] Run these tests and confirm expected failures.
- [x] Implement catalog API, idempotent import of existing available/enabled/manual agent models, runtime eligibility and stable provider references. Discovery is a candidate source and must not reset edited context/enabled choices.
- [x] Replace the static models settings page with provider-linked model CRUD/import and context inputs. Move model selection controls out of provider connection settings.
- [x] Run provider and relevant LiveView tests, including config reload and discovery failures. Resolve only in-scope failures.

## Task 3: Link MCP and Backplane skill sources to providers

**Files:** Modify `apps/synapsis_mcp/lib/synapsis/backplane/{connection,client,snapshot,sync,skill_loader}.ex`, MCP transport/config parsing, `apps/synapsis_data/lib/synapsis/{mcp_config,mcp_configs}.ex`, and focused connection/sync/loader tests.

- [x] Add Bypass contract tests: selected provider credential reaches MCP and skill requests; URL override survives sync; clearing/disabling provider prevents old credential use; source UUID and skill locator remain stable.

```elixir
assert linked.provider_id == provider.id
assert updated.id == connection.id
assert refreshed_mcp.url == override_url
assert {:error, :provider_unavailable} = Providers.runtime_config(provider.name)
```

- [x] Run the affected tests to reproduce missing linkage/override behavior.
- [x] Keep provider credentials authoritative and Backplane source identity/status separate. Reuse existing managed markers for migration, report credential conflicts and avoid name-based merging. Preserve manual MCP configurations.
- [x] Update MCP setup UI to select provider and override URL. Use existing asynchronous discovery paths and existing DuskMoon controls.
- [x] Run scoped data/MCP/LiveView tests. Inspect credential rotation and disable paths end to end.

## Task 4: Make the existing MCP server own live complete discovery

**Files:** Modify `apps/synapsis_mcp/lib/synapsis/{mcp,mcp/server}.ex`, MCP application/supervision, MCP settings views, and `apps/synapsis_mcp/test/synapsis/mcp/server_test.exs`.

- [x] Add tests for repeated live refresh, multi-page catalogs, added/changed/removed tools, repeated cursors, failed later pages, concurrent refresh coalescing and caller cancellation/timeout.
- [x] Verify the new tests fail against startup-only discovery.
- [x] Implement refresh through supervised tasks, explicit bounded pagination, source identity in registrations and complete catalog publication. Remove persisted `backplane_tools` as a discovery allowlist while preserving source availability/trust enforcement.
- [x] Add `MCP.refresh_all/0` and install its callback for turn preparation. Refresh MCP settings/agent-tool UI on connected open and explicit refresh; show loading and error state.
- [x] Run MCP discovery, transport, response, sync and UI tests. Verify failed refreshes do not publish partial catalogs or authorize stale schemas.

## Task 5: Persist dynamic MCP all/selected/none selection

**Files:** Add a pure `apps/synapsis_core/lib/synapsis/mcp_selection.ex` and tests; modify core `agent/resolver.ex`, agent `daemon/toolsets.ex`, web `agent_live/{agents,toolsets}.ex` and corresponding tests.

- [x] Test global default, per-source overrides, future tools in all, raw-name identity, removed tools in selected, none without legacy fallback, daemon exclusion and legacy migration.

```elixir
policy = %{"default" => "all", "sources" => %{source_id => %{"mode" => "none"}}}
assert [] = MCPSelection.names(policy, source_catalog)
assert [new_tool.name] = MCPSelection.names(%{"default" => "all", "sources" => %{}}, [new_tool])
```

- [x] Run the pure tests to confirm missing policy behavior.
- [x] Implement policy resolution against runtime-available registry entries using config UUID/raw names. Preserve built-in toolsets and apply one result to definitions and dispatch authority.
- [x] Add agent group controls for all/selected/none and per-tool checkboxes; initialize all only for new agents, preserving existing agents' choices.
- [x] Integrate asynchronous refresh before per-turn tool admission. Daemon profiles retain existing read-only/trust restrictions and honor explicit exclusions.
- [x] Run resolver, daemon toolset, session admission and related agent/toolset LiveView tests.

## Task 6: Make session model selection authoritative and context effective

**Files:** Modify core `sessions.ex`, `session/compactor.ex`; agent `session/worker.ex`, `session/worker/{config,runtime,boot}.ex`, `agent/context_builder.ex`, provider request-history mapping and `agent/runtime/provider_adapter.ex`; web `agent_live/{agents,sessions}.ex`.

- [x] Replace the old agent-overwrites-session expectation with regressions: switch to configured model, next prompt, queued prompt and worker reboot preserve it; cross-provider uses correct credentials; agent default remains unchanged; busy states reject switching.
- [x] Add request projection tests for compatible signed state, changed affinity, portable tool/result pairs and unchanged durable original messages. Add configured-context assertions for compactor/skill/memory/turn paths.
- [x] Run each focused test to confirm its expected failure before implementing.
- [x] Resolve the existing session pair before agent defaults. Update worker provider/model/config/engine fields coherently and propagate persistence errors.
- [x] Add provider-owned request projection retaining compatible state and removing only nonportable opaque state for changed affinity. Preserve original stored messages and tool pairs; continue strict codec validation. Return errors on incompatible history rather than inventing signatures/results.
- [x] Use configured context in budgeting and add a DuskMoon session model selector listing `Providers.configured_models/0`, with error/busy state and broadcast updates. Agent picker uses the same catalog.
- [x] Run the scoped worker/config/boot/runtime, mapper, compactor/context and session/agent LiveView tests.

## Task 7: Expose provider-linked remote skill sources

**Files:** Modify web `skill_live/{index,show}.ex`, `agent_live/skills.ex`, Backplane source facade as needed, and associated skill/source tests. Parent updates agent skill assignment grouping in `agent_live/agents.ex`.

- [x] Add LiveView/provider-source tests for Backplane source selection, source grouping, error/disabled state and retained assignment identities.
- [x] Confirm the missing UI/association produces expected failures.
- [x] Reuse Connection/Sync/SkillCatalog/SkillLoader. Expose only metadata in the catalog and keep exact revision/digest checks in lazy reads.
- [x] Run focused skill UI/catalog/loader/resolver tests, including same-name skills from independent sources.

## Task 8: Complete scoped integration and record delivery

- [x] Check every approved design requirement against implementation and test evidence; fix only in-scope gaps.
- [x] Run format on changed Elixir files and `git diff --check`.
- [x] Run the combined scoped suite for modified modules through the serial runner. If unrelated baseline tests fail, report and stop instead of repairing outside scope.
- [x] Build web assets through DuskmoonBundler and exercise changed pages using an isolated local server when practical; inspect browser errors and rendered controls.
- [x] Perform spec compliance review, then code-quality review; fix actionable issues and rerun affected checks.
- [x] Write an Agent Note with `project: synapsis`, implementation details, migration semantics, test evidence and any unresolved limitations.
- [x] Report changed behavior, exact verification evidence and the feature worktree location. Leave commit/push/release actions to the user's delivery request.

## Completed verification — 2026-10-19

The final combined scoped run covered 71 test files at seed `835205`, exited 0,
and passed **1,033 tests** with no failures:

| App | Tests |
|---|---:|
| synapsis_data | 47 |
| synapsis_provider | 295 |
| synapsis_core | 109 |
| synapsis_mcp | 166 |
| synapsis_agent | 160 |
| synapsis_web | 256 |

The scoped manifest and final log are `/tmp/synapsis-provider-model-scoped-tests`
and `/tmp/synapsis-provider-model-final-verified-tests.log`. This is scoped
verification, not a full umbrella or CI run. Model-picker fixtures explicitly
seed configured catalogs so durable legacy sessions from worker tests cannot
change their expected model choices.

Hook tests passed 4/4, hook TypeScript checking passed, and the DuskMoon asset
build passed. All 82 changed Elixir files passed `mix format --check-formatted`;
`git diff --check` passed. Independent spec and code reviews have no remaining
actionable findings.

An isolated server on loopback port 14657 used temporary config, Concord and
workspace directories. Browser checks saved the model context from 32768 to
49152 tokens and confirmed it in session selection, saved a Backplane MCP URL
override, verified agent default/group controls and inherited policy after an
ordinary save, and opened remote skill provider selection. LiveView stayed
connected with no console errors/warnings or horizontal overflow. Served assets
matched the built `app-13761a8e.css` and `app-3bfb92a5.js`. The owned server and
page were stopped after verification; user services were not restarted.

HTTP behavior is covered with Bypass/local protocol fixtures; no real provider
service was contacted. Strict codec tests of converted signed histories do not
prove acceptance by every remote model, especially Google signed content.

Agent Note: `eb24f8ad-e712-47d0-9967-6b4f60fe3c14`, revision 2,
label `project: synapsis`. This verification was completed on
`codex/provider-model-mcp-skills` before commit and merge. The user subsequently
authorized merging into `main` and publishing the next version through the
GitHub release workflow; final delivery evidence is recorded in the Agent Note.
