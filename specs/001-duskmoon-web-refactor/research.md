# Research: Duskmoon Web UI Refactor

**Branch**: `001-duskmoon-web-refactor` | **Date**: 2026-03-09

## R1: Available Duskmoon Components

**Decision**: Use the full phoenix_duskmoon v8.0 component library without additional UI libraries.

**Rationale**: The library provides comprehensive coverage of all UI primitives needed:

| Category | Components |
|----------|-----------|
| Layout | `dm_appbar`, `dm_simple_appbar`, `dm_navbar`, `dm_breadcrumb`, `dm_divider` |
| Cards | `dm_card`, `dm_async_card`, `dm_badge`, `dm_avatar` |
| Forms | `dm_form`, `dm_input`, `dm_select`, `dm_textarea`, `dm_checkbox`, `dm_label`, `dm_error`, `dm_alert` |
| Tables | `dm_table` (with streaming support) |
| Navigation | `dm_tab`, `dm_dropdown`, `dm_pagination`, `dm_left_menu`, `dm_left_menu_group` |
| Buttons | `dm_btn` (variants: primary/secondary/accent/info/success/warning/error/ghost/link/outline), `dm_link` |
| Modals | `dm_modal`, `dm_tooltip` |
| Loading | `dm_progress`, `dm_loading_spinner`, `dm_loading_ex` |
| Skeletons | `dm_skeleton`, `dm_skeleton_text`, `dm_skeleton_card`, `dm_skeleton_table`, `dm_skeleton_list`, `dm_skeleton_form` |
| Flash | `dm_flash`, `dm_flash_group` |
| Icons | `dm_mdi` (7000+ Material Design Icons), `dm_bsi` (Bootstrap Icons) |

**Alternatives considered**: None — constitution mandates phoenix_duskmoon exclusively.

## R2: Current Component Usage Audit

**Decision**: Refactor focuses on eliminating DaisyUI leakage, raw HTML patterns, and inconsistencies.

**Findings** (per-page audit):

### DaisyUI Classes That Must Be Replaced

| DaisyUI Pattern | Where Used | Duskmoon Replacement |
|----------------|-----------|---------------------|
| `stats`, `stat`, `stat-figure`, `stat-title`, `stat-value` | DashboardLive | Custom `stat_card` component using `dm_card` |
| `list`, `list-row` | Dashboard, ProjectLive.Index/Show, SessionLive.Index | `dm_table` or custom list component |
| `btn btn-primary btn-sm` | MemoryLive, ProjectLive.Index | `dm_btn variant="primary" size="sm"` |
| `menu-title`, `menu-active` | SessionLive.Show | `dm_left_menu` with `:menu` slots |
| `collapse`, `collapse-bordered` | ProviderLive.Show | `dm_tab` or custom accordion |

### Raw HTML Patterns That Need Components

| Pattern | Occurrences | Solution |
|---------|------------|---------|
| Raw `<label>` tags | LSPLive.Index/Show, MCPLive.Index | Use `dm_label` |
| Raw `<form>` tags | SkillLive.Index, MemoryLive.Index | Use `dm_form` |
| Raw `<.link>` navigation | SessionLive.Index | Use `dm_link` |
| Raw SVG icons | SessionLive.Show | Use `dm_mdi` |
| Raw chat message divs | ProviderLive.Show, AssistantLive.Index | Custom `chat_bubble` component |
| Raw readonly display fields | Provider/LSP/MCP Live pages | Custom `readonly_field` component |
| Raw status indicator dots | ProviderLive.Show | `dm_badge` with appropriate color |
| Raw mode toggle buttons | SessionLive.Show | Custom `mode_toggle` component |

### Pages Rated by Quality

| Rating | Pages |
|--------|-------|
| Good | ModelTierLive.Index, SkillLive.Show, SettingsLive, MCPLive.Show |
| Needs Work | ProjectLive.Index/Show, SessionLive.Index, LSPLive.Show, SkillLive.Index, MemoryLive.Index |
| Significant Refactor | DashboardLive, SessionLive.Show, ProviderLive.Index/Show, AssistantLive.Index, LSPLive.Index, MCPLive.Index |

## R3: Custom App Components Needed

**Decision**: Create 7 reusable components in `core_components.ex` to eliminate duplication.

**Rationale**: Multiple pages repeat the same patterns. Extracting these reduces code and ensures consistency.

| Component | Purpose | Used By |
|-----------|---------|---------|
| `stat_card` | Dashboard statistic display with icon, value, label | DashboardLive |
| `empty_state` | Placeholder for pages with no data, with icon and CTA | All list pages |
| `chat_bubble` | Chat message container (user right-aligned, assistant left-aligned) | AssistantLive, SessionLive.Show, ProviderLive.Show |
| `tool_call_display` | Inline tool invocation with status indicator | AssistantLive, SessionLive.Show |
| `readonly_field` | Display-only form field with label | ProviderLive, LSPLive, MCPLive |
| `mode_toggle` | Agent mode selector (build/plan toggle) | SessionLive.Show |
| `settings_sidebar` | Shared settings navigation sidebar | All /settings/* pages |

**Alternatives considered**: Using `dm_alert` for empty states — rejected because it lacks CTA button slot and icon customization for this use case.

## R4: Theme and Design Token Strategy

**Decision**: Use Duskmoon design tokens (`base-100/200/300`, `base-content`, color variants) exclusively. Remove arbitrary Tailwind color values.

**Rationale**: The `@duskmoon-dev/core` plugin already provides a complete token system via the sunshine/moonlight themes. Using raw Tailwind values bypasses the theme system and breaks theme switching.

**Allowed patterns**:
- `bg-base-100`, `bg-base-200`, `bg-base-300` (theme backgrounds)
- `text-base-content`, `text-base-content/50` (opacity variants are acceptable)
- `bg-primary`, `bg-secondary`, etc. (semantic colors)
- Tailwind utilities for layout: `flex`, `grid`, `gap-*`, `p-*`, `m-*`, `rounded-*`

**Disallowed patterns**:
- Raw color values: `bg-gray-800`, `text-blue-500`
- Hardcoded dark/light specific colors
- DaisyUI utility classes that have Duskmoon equivalents

## R5: Settings Sidebar Pattern

**Decision**: Extract a shared settings sidebar using `dm_left_menu` that is rendered in all `/settings/*` routes.

**Rationale**: Currently each settings page renders its own breadcrumb and content. A shared sidebar eliminates navigation inconsistency and provides persistent context about where the user is within settings.

**Structure**:
- Settings sidebar items: Providers, Models, Memory, Skills, MCP Servers, LSP Servers
- Active item determined by current route via `@current_path` assign
- Sidebar rendered alongside content in a flex layout
