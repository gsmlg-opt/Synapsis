# Quickstart: Duskmoon Web UI Refactor

**Branch**: `001-duskmoon-web-refactor` | **Date**: 2026-03-09

## Prerequisites

- Elixir 1.18+ / OTP 28+
- PostgreSQL 16+ running
- Bun installed (asset bundler)
- Node.js (for Tailwind standalone CLI)

## Setup

```bash
# Clone and checkout branch
git checkout 001-duskmoon-web-refactor

# Install dependencies
mix deps.get
cd apps/synapsis_web && bun install && cd ../..

# Setup database
mix ecto.setup

# Start dev server
mix phx.server
```

## Development Workflow

### Files to modify

All changes are within `apps/synapsis_web/`:

```
apps/synapsis_web/
├── lib/synapsis_web/
│   ├── components/
│   │   ├── core_components.ex        # Add 7 new app components
│   │   └── layouts/
│   │       ├── root.html.heex        # Minor layout updates
│   │       └── app.html.heex         # Settings sidebar integration
│   └── live/
│       ├── assistant_live/index.ex   # Chat bubble refactor
│       ├── dashboard_live.ex         # Stat cards, remove DaisyUI
│       ├── project_live/             # List consistency
│       ├── session_live/             # Chat UI, sidebar, mode toggle
│       ├── provider_live/            # Forms, readonly fields
│       ├── settings_live.ex          # Settings hub
│       ├── memory_live/              # Form consistency
│       ├── skill_live/               # Minor form fix
│       ├── mcp_live/                 # Labels, readonly fields
│       ├── lsp_live/                 # Labels, readonly fields
│       └── model_tier_live/          # Already good, minor polish
└── assets/
    └── css/app.css                   # No changes expected
```

### Verification commands

```bash
# Compile with warnings
mix compile --warnings-as-errors

# Run tests
mix test apps/synapsis_web

# Check formatting
mix format --check-formatted

# Visual testing
mix phx.server
# Visit http://localhost:4000 and check each page
```

### Component reference

All Duskmoon components are available via `use PhoenixDuskmoon.Component` (already configured in `synapsis_web.ex`). Key components:

```elixir
# Buttons
<.dm_btn variant="primary" size="sm">Click</.dm_btn>

# Cards
<.dm_card>
  <:title>Card Title</:title>
  Content here
  <:action><.dm_btn>Action</.dm_btn></:action>
</.dm_card>

# Forms
<.dm_form for={@form} phx-submit="save">
  <.dm_input field={@form[:name]} label="Name" />
  <.dm_select field={@form[:type]} label="Type" options={@options} />
  <:actions>
    <.dm_btn type="submit" variant="primary">Save</.dm_btn>
  </:actions>
</.dm_form>

# Icons
<.dm_mdi name="folder-outline" />

# Badges
<.dm_badge color="success">Active</.dm_badge>

# Navigation
<.dm_breadcrumb>
  <:crumb to={~p"/"}>Home</:crumb>
  <:crumb>Current</:crumb>
</.dm_breadcrumb>
```
