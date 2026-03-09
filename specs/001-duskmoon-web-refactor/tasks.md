# Tasks: Duskmoon Web UI Refactor

**Input**: Design documents from `/specs/001-duskmoon-web-refactor/`
**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/

**Tests**: Not explicitly requested. Test tasks omitted. Validation via `mix compile --warnings-as-errors` and visual smoke testing.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- **Umbrella app**: `apps/synapsis_web/lib/synapsis_web/` for all source files
- Components: `apps/synapsis_web/lib/synapsis_web/components/`
- LiveViews: `apps/synapsis_web/lib/synapsis_web/live/`
- Layouts: `apps/synapsis_web/lib/synapsis_web/components/layouts/`

---

## Phase 1: Setup

**Purpose**: Verify current state compiles and existing functionality works before changes

- [x] T001 Run `mix compile --warnings-as-errors` from umbrella root to establish baseline
- [x] T002 Run `mix test apps/synapsis_web` to verify existing tests pass

**Checkpoint**: Baseline verified — all existing code compiles and tests pass

---

## Phase 2: Foundational (Core Components)

**Purpose**: Build the 7 reusable app-specific components that all user stories depend on

**CRITICAL**: No user story work can begin until this phase is complete

- [x] T003 [P] Implement `stat_card/1` component (attrs: icon, value, label, color, to, class) composing `dm_card` and `dm_mdi` in `apps/synapsis_web/lib/synapsis_web/components/core_components.ex`
- [x] T004 [P] Implement `empty_state/1` component (attrs: icon, title, description, class; slot: action) composing `dm_mdi` in `apps/synapsis_web/lib/synapsis_web/components/core_components.ex`
- [x] T005 [P] Implement `chat_bubble/1` component (attrs: role, class; slot: inner_block) with right-aligned user bubbles and left-aligned assistant bubbles in `apps/synapsis_web/lib/synapsis_web/components/core_components.ex`
- [x] T006 [P] Implement `tool_call_display/1` component (attrs: name, status, class; slots: params, result) with status badge indicator in `apps/synapsis_web/lib/synapsis_web/components/core_components.ex`
- [x] T007 [P] Implement `readonly_field/1` component (attrs: label, value, monospace, class) composing `dm_label` in `apps/synapsis_web/lib/synapsis_web/components/core_components.ex`
- [x] T008 [P] Implement `mode_toggle/1` component (attrs: current_mode, modes, on_change, class) using `dm_btn` group in `apps/synapsis_web/lib/synapsis_web/components/core_components.ex`
- [x] T009 [P] Implement `settings_sidebar/1` component (attrs: current_path, class) using `dm_left_menu` with menu items for Providers, Models, Memory, Skills, MCP, LSP in `apps/synapsis_web/lib/synapsis_web/components/core_components.ex`
- [x] T010 Run `mix compile --warnings-as-errors` to verify all 7 components compile without warnings

**Checkpoint**: Foundation ready — all 7 core components available for use in LiveViews

---

## Phase 3: User Story 1 - Consistent Navigation and Layout (Priority: P1) MVP

**Goal**: Polished, cohesive navigation with appbar, settings sidebar, breadcrumbs, and active states across all pages

**Independent Test**: Navigate through all top-level routes and verify visual consistency, active states, and smooth transitions

### Implementation for User Story 1

- [x] T011 [US1] Update app layout to conditionally render `settings_sidebar` when route matches `/settings/*`, using flex layout with sidebar and main content area in `apps/synapsis_web/lib/synapsis_web/components/layouts/app.html.heex`
- [x] T012 [US1] Verify root layout uses Duskmoon design tokens exclusively (bg-base-100, text-base-content), confirm theme data attribute setup in `apps/synapsis_web/lib/synapsis_web/components/layouts/root.html.heex`
- [x] T013 [US1] Refactor SettingsLive to use `settings_sidebar` component and remove inline navigation cards, keep only content area in `apps/synapsis_web/lib/synapsis_web/live/settings_live.ex`
- [x] T014 [US1] Run `mix compile --warnings-as-errors` and visually verify navigation flow: Dashboard → Projects → Settings → Settings sub-pages

**Checkpoint**: User Story 1 complete — navigation is consistent with sidebar, active states, and breadcrumbs across all routes

---

## Phase 4: User Story 2 - Polished Dashboard and Content Pages (Priority: P2)

**Goal**: Consistent card layouts, list styles, form patterns, and empty states across all content pages

**Independent Test**: Visit each content page and verify cards, lists, forms, badges follow same visual patterns

### Implementation for User Story 2

- [x] T015 [US2] Refactor DashboardLive: replace DaisyUI `stats`/`stat`/`stat-figure`/`stat-title`/`stat-value` classes with `stat_card` component, replace `list`/`list-row` with consistent Duskmoon pattern, add `empty_state` for empty sections in `apps/synapsis_web/lib/synapsis_web/live/dashboard_live.ex`
- [x] T016 [P] [US2] Refactor ProjectLive.Index: replace DaisyUI `list`/`list-row` with Duskmoon list pattern, replace `btn btn-primary btn-sm` on links with `dm_btn`, add `empty_state` when no projects exist in `apps/synapsis_web/lib/synapsis_web/live/project_live/index.ex`
- [x] T017 [P] [US2] Refactor ProjectLive.Show: replace DaisyUI `list`/`list-row` with Duskmoon list pattern, add `empty_state` for empty sessions list in `apps/synapsis_web/lib/synapsis_web/live/project_live/show.ex`
- [x] T018 [P] [US2] Refactor SessionLive.Index: replace raw `<.link>` with `dm_link`, add `empty_state` when no sessions exist in `apps/synapsis_web/lib/synapsis_web/live/session_live/index.ex`
- [x] T019 [P] [US2] Refactor ProviderLive.Index: replace raw readonly field divs with `readonly_field` component, replace raw preset `<button>` tags with `dm_btn` in `apps/synapsis_web/lib/synapsis_web/live/provider_live/index.ex`
- [x] T020 [P] [US2] Refactor ProviderLive.Show: replace raw readonly field divs with `readonly_field`, replace DaisyUI `collapse`/`collapse-bordered` with `dm_tab` component, replace raw status indicator dots with `dm_badge`, replace raw chat message divs with `chat_bubble` in `apps/synapsis_web/lib/synapsis_web/live/provider_live/show.ex`
- [x] T021 [P] [US2] Refactor MemoryLive.Index: replace raw `<form>` with `dm_form`, replace DaisyUI `btn btn-primary btn-sm` with `dm_btn`, add `empty_state` for empty memory in `apps/synapsis_web/lib/synapsis_web/live/memory_live/index.ex`
- [x] T022 [P] [US2] Refactor SkillLive.Index: replace raw `<form phx-submit>` with `dm_form` component in `apps/synapsis_web/lib/synapsis_web/live/skill_live/index.ex`
- [x] T023 [P] [US2] Refactor MCPLive.Index: replace raw `<label>` tags with `dm_label`, replace raw readonly field divs with `readonly_field`, replace raw `<button>` tags with `dm_btn`, fix disabled state to use Duskmoon styling in `apps/synapsis_web/lib/synapsis_web/live/mcp_live/index.ex`
- [x] T024 [P] [US2] Refactor LSPLive.Index: replace raw `<label>` tags with `dm_label`, replace raw readonly field divs with `readonly_field`, replace raw `<button>` tags with `dm_btn`, fix disabled state styling in `apps/synapsis_web/lib/synapsis_web/live/lsp_live/index.ex`
- [x] T025 [P] [US2] Refactor LSPLive.Show: replace raw `<label>` tags with `dm_label`, replace raw readonly field divs with `readonly_field` in `apps/synapsis_web/lib/synapsis_web/live/lsp_live/show.ex`
- [x] T026 [US2] Run `mix compile --warnings-as-errors` and visually verify all content pages: Dashboard stats, project lists, provider forms, MCP/LSP settings

**Checkpoint**: User Story 2 complete — all content pages use consistent Duskmoon components with proper empty states

---

## Phase 5: User Story 3 - Enhanced Chat and Assistant Experience (Priority: P3)

**Goal**: Well-designed conversational interface with chat bubbles, markdown rendering, tool call display, and mode toggle

**Independent Test**: Open Assistant or Session, send messages, verify bubble alignment, markdown, tool calls, and mode switching

### Implementation for User Story 3

- [x] T027 [US3] Refactor AssistantLive.Index: replace raw message styling (`rounded-md bg-base-300/60 border`) with `chat_bubble` component, add `tool_call_display` for tool invocations, add `empty_state` for initial empty chat in `apps/synapsis_web/lib/synapsis_web/live/assistant_live/index.ex`
- [x] T028 [US3] Refactor SessionLive.Show chat area: replace raw chat message divs with `chat_bubble` component, replace raw SVG chevron icon with `dm_mdi name="chevron-down"`, replace raw mode toggle button group (`flex gap-0 bg-base-300 rounded-lg`) with `mode_toggle` component in `apps/synapsis_web/lib/synapsis_web/live/session_live/show.ex`
- [x] T029 [US3] Refactor SessionLive.Show sidebar: replace raw `<li class="menu-title">` and `<li class="menu-active">` with `dm_left_menu` slot-based menu items in `apps/synapsis_web/lib/synapsis_web/live/session_live/show.ex`
- [x] T030 [US3] Run `mix compile --warnings-as-errors` and visually verify: send message in Assistant, verify user bubble right-aligned, assistant bubble left-aligned, markdown renders, mode toggle works

**Checkpoint**: User Story 3 complete — chat interfaces use chat bubbles with proper alignment and tool call display

---

## Phase 6: User Story 4 - Responsive Design and Theme Support (Priority: P4)

**Goal**: Theme switching works flawlessly across all pages, layout adapts to smaller viewports

**Independent Test**: Toggle theme switcher, resize browser, verify all components adapt correctly

### Implementation for User Story 4

- [x] T031 [P] [US4] Audit all 17 LiveView render functions for hardcoded color values (e.g., `bg-gray-*`, `text-blue-*`) and replace with Duskmoon design tokens (`bg-base-*`, `text-base-content`, `bg-primary`, etc.) across all files in `apps/synapsis_web/lib/synapsis_web/live/`
- [x] T032 [P] [US4] Add responsive breakpoint classes to app layout for settings sidebar (collapse sidebar on mobile/tablet) and appbar navigation in `apps/synapsis_web/lib/synapsis_web/components/layouts/app.html.heex`
- [x] T033 [US4] Visually verify theme switching: toggle between sunshine and moonlight on all pages, confirm no unstyled elements or visual artifacts

**Checkpoint**: User Story 4 complete — themes switch cleanly, layout adapts to viewports

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Final validation and cleanup across all user stories

- [x] T034 Run `mix compile --warnings-as-errors` from umbrella root
- [x] T035 Run `mix test apps/synapsis_web` to verify no regressions
- [x] T036 Run `mix format --check-formatted` and fix any formatting issues
- [x] T037 Visual smoke test: visit all 17 pages, verify SC-001 (Duskmoon components exclusively), SC-002 (2-click navigation), SC-003 (theme switching), SC-004 (empty states), SC-005 (markdown in chat), SC-007 (7 core components)
- [x] T038 Verify `core_components.ex` contains all 7 components: stat_card, empty_state, chat_bubble, tool_call_display, readonly_field, mode_toggle, settings_sidebar

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS all user stories
- **User Stories (Phase 3-6)**: All depend on Foundational phase completion
  - US1 (Navigation) and US2 (Content Pages) can proceed in parallel
  - US3 (Chat) can proceed in parallel with US1/US2
  - US4 (Theme/Responsive) should run after US1-3 to audit final state
- **Polish (Phase 7)**: Depends on all user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Depends on Phase 2 (settings_sidebar component). No other story dependencies.
- **User Story 2 (P2)**: Depends on Phase 2 (empty_state, readonly_field, chat_bubble). No dependency on US1.
- **User Story 3 (P3)**: Depends on Phase 2 (chat_bubble, tool_call_display, mode_toggle). No dependency on US1/US2.
- **User Story 4 (P4)**: Depends on US1-3 completion (audits final rendered pages). Sequential after others.

### Within Each User Story

- LiveView refactors within a story marked [P] can run in parallel (different files)
- Compilation check runs after all parallel tasks in the story complete
- Visual verification runs after compilation passes

### Parallel Opportunities

- Phase 2: All 7 component tasks (T003-T009) can run in parallel — they're all additions to the same file but independent functions
- Phase 4 (US2): Tasks T016-T025 can all run in parallel — each modifies a different LiveView file
- Phase 5 (US3): T027 and T028/T029 can run in parallel — different LiveView files
- Phase 6 (US4): T031 and T032 can run in parallel — different file sets

---

## Parallel Example: Phase 2 (Foundational)

```bash
# Launch all 7 component implementations together:
Task: "Implement stat_card/1 in core_components.ex"
Task: "Implement empty_state/1 in core_components.ex"
Task: "Implement chat_bubble/1 in core_components.ex"
Task: "Implement tool_call_display/1 in core_components.ex"
Task: "Implement readonly_field/1 in core_components.ex"
Task: "Implement mode_toggle/1 in core_components.ex"
Task: "Implement settings_sidebar/1 in core_components.ex"
```

## Parallel Example: Phase 4 (User Story 2)

```bash
# Launch all content page refactors together:
Task: "Refactor ProjectLive.Index"
Task: "Refactor ProjectLive.Show"
Task: "Refactor SessionLive.Index"
Task: "Refactor ProviderLive.Index"
Task: "Refactor ProviderLive.Show"
Task: "Refactor MemoryLive.Index"
Task: "Refactor SkillLive.Index"
Task: "Refactor MCPLive.Index"
Task: "Refactor LSPLive.Index"
Task: "Refactor LSPLive.Show"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (verify baseline)
2. Complete Phase 2: Foundational (build 7 core components)
3. Complete Phase 3: User Story 1 (navigation & layout)
4. **STOP and VALIDATE**: Navigate all routes, verify sidebar, active states
5. Deploy/demo if ready

### Incremental Delivery

1. Setup + Foundational → Core components ready
2. Add US1 (Navigation) → Test independently → Demo (MVP!)
3. Add US2 (Content Pages) → Test independently → Demo
4. Add US3 (Chat Experience) → Test independently → Demo
5. Add US4 (Theme/Responsive) → Test independently → Demo
6. Polish → Final validation → Done

### Parallel Execution Strategy

With multiple agents:
1. All agents complete Setup + Foundational together
2. Once Phase 2 is done:
   - Agent A: User Story 1 (Navigation)
   - Agent B: User Story 2 (Content Pages)
   - Agent C: User Story 3 (Chat Experience)
3. After US1-3 complete: Agent A handles US4 (Theme audit)
4. All agents contribute to Polish phase

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- All changes are within `apps/synapsis_web/` — no backend modifications
- Phase 2 tasks all modify `core_components.ex` but add independent functions — safe to implement sequentially in one pass
- Visual verification is critical — no automated visual regression tests exist
- Commit after each phase or logical group of tasks
