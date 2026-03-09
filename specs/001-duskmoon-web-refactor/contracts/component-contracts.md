# Component Contracts: Duskmoon Web UI Refactor

**Branch**: `001-duskmoon-web-refactor` | **Date**: 2026-03-09

## Overview

This refactor has no API endpoint changes. All contracts are internal component interfaces defined in `core_components.ex`. See [data-model.md](../data-model.md) for detailed attribute/slot specifications.

## Component Function Signatures

```elixir
# core_components.ex

@doc "Dashboard statistic card with icon, value, and label"
attr :icon, :string, required: true
attr :value, :string, required: true
attr :label, :string, required: true
attr :color, :string, default: "primary"
attr :to, :string, default: nil
attr :class, :string, default: nil
def stat_card(assigns)

@doc "Empty state placeholder with icon, message, and optional CTA"
attr :icon, :string, required: true
attr :title, :string, required: true
attr :description, :string, default: nil
attr :class, :string, default: nil
slot :action
def empty_state(assigns)

@doc "Chat message bubble — right-aligned for user, left-aligned for assistant"
attr :role, :string, required: true, values: ~w(user assistant)
attr :class, :string, default: nil
slot :inner_block, required: true
def chat_bubble(assigns)

@doc "Tool invocation display with status indicator"
attr :name, :string, required: true
attr :status, :string, required: true, values: ~w(pending running complete error)
attr :class, :string, default: nil
slot :params
slot :result
def tool_call_display(assigns)

@doc "Read-only form field with label and value display"
attr :label, :string, required: true
attr :value, :string, required: true
attr :monospace, :boolean, default: false
attr :class, :string, default: nil
def readonly_field(assigns)

@doc "Toggle button group for mode selection"
attr :current_mode, :string, required: true
attr :modes, :list, required: true
attr :on_change, :string, required: true
attr :class, :string, default: nil
def mode_toggle(assigns)

@doc "Settings navigation sidebar with active state"
attr :current_path, :string, required: true
attr :class, :string, default: nil
def settings_sidebar(assigns)
```

## Page-to-Component Mapping

| Page | Components Used |
|------|----------------|
| DashboardLive | `stat_card`, `empty_state` |
| AssistantLive.Index | `chat_bubble`, `tool_call_display`, `empty_state` |
| SessionLive.Show | `chat_bubble`, `tool_call_display`, `mode_toggle` |
| SessionLive.Index | `empty_state` |
| ProjectLive.Index | `empty_state` |
| ProjectLive.Show | `empty_state` |
| ProviderLive.Index | `readonly_field`, `empty_state` |
| ProviderLive.Show | `readonly_field`, `chat_bubble` |
| SettingsLive | `settings_sidebar` |
| All /settings/* pages | `settings_sidebar`, `readonly_field` |
