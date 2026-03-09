# Implementation Plan: Duskmoon Web UI Refactor

**Branch**: `001-duskmoon-web-refactor` | **Date**: 2026-03-09 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/001-duskmoon-web-refactor/spec.md`

## Summary

Refactor all 17 LiveView pages in `apps/synapsis_web` to consistently use the `phoenix_duskmoon` v8.0 component library. This eliminates DaisyUI class leakage, raw HTML patterns, and visual inconsistencies. The approach: (1) build 7 reusable app-specific components in `core_components.ex`, (2) update layouts for settings sidebar integration, (3) refactor each LiveView's `render/1` function to use Duskmoon components exclusively. No backend or database changes.

## Technical Context

**Language/Version**: Elixir 1.18+ / OTP 28+
**Primary Dependencies**: Phoenix 1.8+, Phoenix LiveView 1.0+, phoenix_duskmoon 8.0, @duskmoon-dev/core 1.11+, @duskmoon-dev/elements 0.7+
**Storage**: N/A (presentation-layer only, no schema changes)
**Testing**: `mix test apps/synapsis_web` (ExUnit), visual testing via `mix phx.server`
**Target Platform**: Web browser (Phoenix LiveView)
**Project Type**: Umbrella web app (Elixir umbrella)
**Performance Goals**: N/A (no performance-critical changes)
**Constraints**: Must use only phoenix_duskmoon components per UI Constitution. No React, no DaisyUI, no other CSS component libraries.
**Scale/Scope**: 17 LiveView pages, 2 layout files, 1 core_components module, ~2500 lines of HEEx templates

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Functional Core, Imperative Shell | PASS | No core logic changes. Only presentation layer. |
| II. Database as Source of Truth | PASS | No database changes. |
| III. Process-per-Session | PASS | No process changes. |
| IV. Provider-Agnostic Streaming | PASS | No provider changes. |
| V. Permission-Controlled Tool Execution | PASS | No tool changes. |
| VI. Structured Observability | PASS | No logging changes. |
| VII. Strict Umbrella Dependency Direction | PASS | `synapsis_web` has no umbrella deps (build artifact only). Changes stay within `synapsis_web`. |
| UI Constitution: No other CSS libraries | PASS | Removing DaisyUI leakage, using only phoenix_duskmoon. |
| UI Constitution: No React/JS frameworks | PASS | All UI is Phoenix LiveView + HEEx. |
| UI Constitution: phoenix_duskmoon for all components | PASS | This is the goal of the refactor. |

**Post-Design Re-check**: All gates still pass. No new dependencies or architectural changes introduced.

## Project Structure

### Documentation (this feature)

```text
specs/001-duskmoon-web-refactor/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Component audit and research findings
├── data-model.md        # Component interface contracts
├── quickstart.md        # Development setup guide
├── contracts/
│   └── component-contracts.md  # Component function signatures
├── checklists/
│   └── requirements.md  # Spec quality checklist
└── tasks.md             # Phase 2 output (/speckit.tasks command)
```

### Source Code (repository root)

```text
apps/synapsis_web/
├── lib/synapsis_web/
│   ├── synapsis_web.ex                          # No changes needed
│   ├── components/
│   │   ├── core_components.ex                   # ADD 7 app components
│   │   └── layouts/
│   │       ├── root.html.heex                   # Minor updates
│   │       └── app.html.heex                    # Settings sidebar integration
│   └── live/
│       ├── assistant_live/index.ex              # Chat bubble refactor
│       ├── dashboard_live.ex                    # Stat cards, list cleanup
│       ├── project_live/index.ex                # List consistency, empty state
│       ├── project_live/show.ex                 # List consistency, empty state
│       ├── session_live/index.ex                # Empty state, link cleanup
│       ├── session_live/show.ex                 # Chat UI, mode toggle, menu
│       ├── provider_live/index.ex               # Readonly fields, buttons
│       ├── provider_live/show.ex                # Readonly fields, chat, collapse
│       ├── settings_live.ex                     # Settings sidebar
│       ├── memory_live/index.ex                 # Form, button cleanup
│       ├── skill_live/index.ex                  # Form cleanup
│       ├── skill_live/show.ex                   # Already good, minor polish
│       ├── mcp_live/index.ex                    # Labels, readonly fields
│       ├── mcp_live/show.ex                     # Already good, minor polish
│       ├── lsp_live/index.ex                    # Labels, readonly fields
│       ├── lsp_live/show.ex                     # Labels, readonly fields
│       └── model_tier_live/index.ex             # Already good, minor polish
└── assets/
    └── css/app.css                              # No changes expected
```

**Structure Decision**: Existing umbrella structure is preserved. All changes are within `apps/synapsis_web/lib/synapsis_web/`. No new files except component additions to the existing `core_components.ex`.

## Implementation Phases

### Phase A: Core Components Foundation

Build the 7 reusable components in `core_components.ex`. These are prerequisites for all page refactors.

**Components to create** (see [contracts/component-contracts.md](contracts/component-contracts.md) for full signatures):
1. `stat_card` — Dashboard statistic display
2. `empty_state` — Placeholder for empty lists with CTA
3. `chat_bubble` — Right-aligned user / left-aligned assistant messages
4. `tool_call_display` — Inline tool invocation with status
5. `readonly_field` — Display-only form field with label
6. `mode_toggle` — Agent mode selector button group
7. `settings_sidebar` — Shared settings navigation using `dm_left_menu`

**Depends on**: Nothing
**Validates**: `mix compile --warnings-as-errors`

### Phase B: Layout Updates

Update the shared layout files to integrate the settings sidebar.

1. **app.html.heex**: Add conditional settings sidebar rendering when route matches `/settings/*`
2. **root.html.heex**: Minor cleanup if needed (currently well-structured)

**Depends on**: Phase A (settings_sidebar component)
**Validates**: Visual check — all pages still render, settings pages show sidebar

### Phase C: Dashboard and Navigation Pages

Refactor the main entry points.

1. **DashboardLive**: Replace DaisyUI `stats`/`stat` classes with `stat_card` component. Replace `list`/`list-row` with `dm_table` or consistent list pattern. Add `empty_state` for empty sections.
2. **SettingsLive**: Integrate `settings_sidebar`, verify card grid layout.

**Depends on**: Phase A
**Validates**: Dashboard renders with stat cards, settings shows sidebar

### Phase D: Project and Session Pages

Refactor the project/session workflow pages.

1. **ProjectLive.Index**: Replace `list`/`list-row` with consistent pattern. Replace DaisyUI `btn` classes with `dm_btn`. Add `empty_state`.
2. **ProjectLive.Show**: Same list cleanup. Add `empty_state` for empty sessions.
3. **SessionLive.Index**: Replace raw `<.link>` with `dm_link`. Add `empty_state`.
4. **SessionLive.Show**: Major refactor — replace raw chat divs with `chat_bubble`, replace SVG icons with `dm_mdi`, replace raw mode toggle with `mode_toggle` component, replace raw menu items with `dm_left_menu` slots.

**Depends on**: Phase A
**Validates**: Full session workflow — create project, create session, chat, switch modes

### Phase E: Settings Sub-Pages

Refactor all settings detail pages.

1. **ProviderLive.Index**: Replace raw readonly fields with `readonly_field` component, fix preset buttons.
2. **ProviderLive.Show**: Replace raw readonly fields, replace DaisyUI collapse with `dm_tab`, replace raw chat messages with `chat_bubble`, replace raw status dots with `dm_badge`.
3. **ModelTierLive.Index**: Already good — minor polish only.
4. **MemoryLive.Index**: Replace raw `<form>` with `dm_form`, replace DaisyUI `btn` with `dm_btn`. Add `empty_state`.
5. **SkillLive.Index**: Replace raw `<form>` with `dm_form`.
6. **SkillLive.Show**: Already good — no changes needed.
7. **MCPLive.Index**: Replace raw labels with `dm_label`, raw readonly fields with `readonly_field`, fix disabled state styling.
8. **MCPLive.Show**: Already good — minor polish only.
9. **LSPLive.Index**: Replace raw labels with `dm_label`, raw readonly fields with `readonly_field`.
10. **LSPLive.Show**: Replace raw labels with `dm_label`, raw readonly fields with `readonly_field`.

**Depends on**: Phase A, Phase B (settings sidebar)
**Validates**: All settings pages render correctly with sidebar, forms submit properly

### Phase F: Chat and Assistant Experience

Refactor the conversational interfaces.

1. **AssistantLive.Index**: Replace raw message styling with `chat_bubble`. Add `tool_call_display` for tool invocations. Add `empty_state` for initial state.

**Depends on**: Phase A
**Validates**: Send message, see response, verify bubble alignment, markdown rendering

### Phase G: Final Validation

1. Compile with warnings-as-errors: `mix compile --warnings-as-errors`
2. Run all tests: `mix test apps/synapsis_web`
3. Check formatting: `mix format --check-formatted`
4. Visual smoke test: Visit all 17 pages, verify theme switching
5. Verify SC-001 through SC-007 from spec

**Depends on**: All previous phases
**Validates**: All success criteria met

## Complexity Tracking

No constitution violations. All changes stay within the presentation layer of `synapsis_web`.
