# Data Model: Duskmoon Web UI Refactor

**Branch**: `001-duskmoon-web-refactor` | **Date**: 2026-03-09

## Overview

This feature is a presentation-layer refactor. No database schema changes are required. The data model described here covers the **component interface contracts** — the props/attributes and slots that each custom component accepts.

## Component Interfaces

### 1. `stat_card`

| Attribute | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `icon` | `string` | yes | — | Material Design Icon name |
| `value` | `string` | yes | — | Statistic value to display |
| `label` | `string` | yes | — | Description of the statistic |
| `color` | `string` | no | `"primary"` | Theme color variant |
| `to` | `string` | no | `nil` | Optional navigation link |
| `class` | `string` | no | `nil` | Additional CSS classes |

### 2. `empty_state`

| Attribute | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `icon` | `string` | yes | — | Material Design Icon name |
| `title` | `string` | yes | — | Main heading text |
| `description` | `string` | no | `nil` | Supporting text |
| `class` | `string` | no | `nil` | Additional CSS classes |

| Slot | Description |
|------|-------------|
| `action` | CTA button or link |

### 3. `chat_bubble`

| Attribute | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `role` | `string` | yes | — | `"user"` or `"assistant"` |
| `class` | `string` | no | `nil` | Additional CSS classes |

| Slot | Description |
|------|-------------|
| `inner_block` | Message content (text, markdown, tool calls) |

### 4. `tool_call_display`

| Attribute | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `name` | `string` | yes | — | Tool name |
| `status` | `string` | yes | — | `"pending"`, `"running"`, `"complete"`, `"error"` |
| `class` | `string` | no | `nil` | Additional CSS classes |

| Slot | Description |
|------|-------------|
| `params` | Tool parameters display |
| `result` | Tool result display |

### 5. `readonly_field`

| Attribute | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `label` | `string` | yes | — | Field label |
| `value` | `string` | yes | — | Display value |
| `monospace` | `boolean` | no | `false` | Use monospace font |
| `class` | `string` | no | `nil` | Additional CSS classes |

### 6. `mode_toggle`

| Attribute | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `current_mode` | `string` | yes | — | Currently active mode |
| `modes` | `list` | yes | — | List of `{value, label}` tuples |
| `on_change` | `string` | yes | — | Phoenix event name |
| `class` | `string` | no | `nil` | Additional CSS classes |

### 7. `settings_sidebar`

| Attribute | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `current_path` | `string` | yes | — | Current route path for active state |
| `class` | `string` | no | `nil` | Additional CSS classes |

## Existing Entities (Unchanged)

No changes to database schemas. The following Ecto schemas remain as-is:
- `Synapsis.Project`
- `Synapsis.Session`
- `Synapsis.Message`
- `Synapsis.Provider`
- `Synapsis.Skill`
- `Synapsis.MCPServer`
- `Synapsis.LSPServer`
