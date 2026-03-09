# Feature Specification: Duskmoon Web UI Refactor

**Feature Branch**: `001-duskmoon-web-refactor`
**Created**: 2026-03-09
**Status**: Draft
**Input**: User description: "please use frontend design and duskmoon skills to refactor apps/synapsis_web"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Consistent Navigation and Layout (Priority: P1)

A user opens the Synapsis web application and sees a polished, cohesive interface with a clear navigation structure. The app bar, sidebar navigation, and page layouts follow a consistent design language using the Duskmoon design system. Navigation between sections (Dashboard, Assistant, Projects, Settings) is intuitive and visually distinct.

**Why this priority**: The navigation and layout form the skeleton of the entire application. Every other page depends on having a well-structured, consistent shell. Without this, individual page improvements lack coherence.

**Independent Test**: Can be tested by navigating through all top-level routes and verifying visual consistency, correct active states, and smooth transitions between sections.

**Acceptance Scenarios**:

1. **Given** the user opens the app, **When** the page loads, **Then** the app bar displays a branded logo, main navigation links, theme switcher, and settings access in a visually cohesive layout.
2. **Given** the user is on any page, **When** they click a navigation item, **Then** the active item is visually highlighted and the page content updates without full page reload.
3. **Given** the user is on a settings sub-page, **When** they view the layout, **Then** a left sidebar shows all settings categories with the current category highlighted, and breadcrumbs indicate the navigation path.

---

### User Story 2 - Polished Dashboard and Content Pages (Priority: P2)

A user visits the Dashboard and sees well-organized summary cards showing project counts, recent sessions, and quick actions. Content pages (Projects, Providers, MCP, LSP, Skills, Memory, Model Tiers) use consistent card layouts, list styles, form patterns, and action button placements derived from the Duskmoon component library.

**Why this priority**: Content pages are where users spend most of their time. Consistent card layouts, proper spacing, and clear visual hierarchy improve usability and reduce cognitive load.

**Independent Test**: Can be tested by visiting each content page and verifying that cards, lists, forms, badges, and action buttons follow the same visual patterns and spacing conventions.

**Acceptance Scenarios**:

1. **Given** the user visits the Dashboard, **When** the page loads, **Then** summary statistics appear in properly styled cards with icons, counts, and descriptive labels.
2. **Given** the user visits any list page (Projects, Providers, Sessions, etc.), **When** viewing items, **Then** each item is presented in a consistent list-row format with status badges, action buttons, and proper hover states.
3. **Given** the user opens a create/edit form on any page, **When** the form renders, **Then** inputs, labels, selects, and buttons follow the Duskmoon form component patterns with proper validation feedback.
4. **Given** the user views a detail/show page, **When** the page renders, **Then** the layout uses cards for content sections, breadcrumbs for context, and consistently placed action buttons.

---

### User Story 3 - Enhanced Chat and Assistant Experience (Priority: P3)

A user engages with the Assistant or a Session chat and experiences a well-designed conversational interface. Messages are clearly distinguished (user vs. assistant), markdown content renders properly, tool invocations display inline with clear status indicators, and the input area is prominently placed with send controls.

**Why this priority**: The chat interface is the core interaction model for an AI coding agent. While the layout and content pages provide the frame, the chat experience is what delivers the primary value of the product.

**Independent Test**: Can be tested by opening the Assistant or a Session, sending messages, and verifying message rendering, markdown display, tool call display, and input area behavior.

**Acceptance Scenarios**:

1. **Given** the user is in a chat view, **When** they send a message, **Then** the message appears right-aligned in a user-styled bubble with a distinct background, and the input clears.
2. **Given** the assistant responds, **When** the response streams in, **Then** text renders with proper markdown formatting including code blocks, lists, and links.
3. **Given** a tool is invoked during a response, **When** the tool call appears, **Then** it displays inline with the tool name, parameters, and a status indicator (pending/running/complete/error).
4. **Given** the user is in a session, **When** they view the sidebar, **Then** they can switch between sessions, see session metadata, and access model/agent mode controls.

---

### User Story 4 - Responsive Design and Theme Support (Priority: P4)

A user accesses Synapsis on different screen sizes and can switch between light (sunshine) and dark (moonlight) themes. The layout adapts gracefully to smaller viewports, and theme changes apply instantly across all components.

**Why this priority**: Theme support is already partially implemented (moonlight default + theme switcher), and responsive design ensures accessibility on various devices. This builds on existing infrastructure.

**Independent Test**: Can be tested by toggling the theme switcher and resizing the browser, verifying all components adapt correctly.

**Acceptance Scenarios**:

1. **Given** the user clicks the theme switcher, **When** the theme changes, **Then** all page elements (backgrounds, text, cards, buttons, badges) update to the selected theme immediately.
2. **Given** the user is on a desktop viewport, **When** they resize to a tablet-width viewport, **Then** the navigation collapses appropriately and content reflows without horizontal scrolling.

---

### Edge Cases

- What happens when a page has no data (empty states for projects, sessions, providers)?
- How does the UI handle very long session lists or project names (text truncation)?
- What happens when a form submission fails (validation errors displayed inline)?
- How does the chat handle extremely long messages or large code blocks?
- What happens when the WebSocket connection drops (reconnection indicator)?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The application layout MUST use the Duskmoon appbar component with branded navigation, theme switcher, and settings access.
- **FR-002**: All settings pages MUST use a shared left sidebar navigation with active state highlighting and breadcrumb context.
- **FR-003**: All list views MUST present items using consistent card or list-row patterns with status badges, action buttons, and hover effects. Lists render all items with natural page scrolling (no pagination or virtual scroll).
- **FR-004**: All forms MUST use Duskmoon form components with consistent label placement and validation feedback.
- **FR-005**: The Dashboard MUST display summary statistics in styled cards with Material Design icons and descriptive labels.
- **FR-006**: The chat interface (Assistant and Session) MUST display messages using a chat bubble layout — user messages right-aligned with a distinct background, assistant messages left-aligned — with markdown rendering and inline tool call display.
- **FR-007**: The application MUST support both sunshine (light) and moonlight (dark) themes via the Duskmoon theme switcher, with all components correctly themed.
- **FR-008**: Empty states MUST display helpful placeholder content with icons and call-to-action buttons, guiding users to create their first item.
- **FR-009**: All data tables MUST use the Duskmoon table component with consistent column alignment and row styling.
- **FR-010**: The core_components module MUST define reusable, app-specific components (e.g., stat cards, status indicators, empty states) that compose Duskmoon primitives.
- **FR-011**: All pages MUST use Duskmoon design tokens for colors, spacing, and typography instead of arbitrary Tailwind values.
- **FR-012**: Navigation between pages MUST preserve the user's position context through breadcrumbs and active menu states.

### Key Entities

- **Page Layout**: The visual structure of each page including header, sidebar, main content area, and footer placement.
- **Component Library**: The set of reusable UI components built on top of Duskmoon primitives for app-specific patterns (stat cards, chat bubbles, tool call displays, empty states).
- **Theme Configuration**: The mapping between Duskmoon design tokens and application-wide visual properties (colors, typography, spacing).
- **Navigation Structure**: The hierarchy of routes and how they map to visual navigation elements (appbar links, sidebar items, breadcrumbs).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: All 17 LiveView pages render using Duskmoon components exclusively for UI primitives (buttons, cards, forms, badges, icons, tables), with zero use of custom/ad-hoc styled equivalents.
- **SC-002**: Users can navigate between any two sections of the application within 2 clicks from any starting page.
- **SC-003**: Theme switching between sunshine and moonlight applies correctly across all pages with no visual artifacts or unstyled elements.
- **SC-004**: Every list page displays a meaningful empty state when no data exists, with a clear call-to-action to create the first item.
- **SC-005**: The chat interface renders streamed messages with proper markdown formatting, including code blocks with syntax-appropriate styling.
- **SC-006**: All pages compile and render without warnings, and existing tests continue to pass after the refactor.
- **SC-007**: The core_components module contains at least 5 reusable app-specific components that reduce code duplication across LiveView modules.

## Assumptions

- The existing route structure and LiveView module organization will be preserved; this refactor focuses on the presentation layer only.
- The `phoenix_duskmoon` v8.0 library provides all necessary primitive components; no additional UI libraries will be introduced.
- The existing Duskmoon CSS setup (app.css with `@duskmoon-dev/core` plugin, sunshine/moonlight themes) is correct and will be retained.
- The existing JavaScript/TypeScript setup (Duskmoon hooks, element registration) is correct and will be retained.
- Data fetching logic and event handlers in LiveView modules will remain unchanged; only the `render/1` functions and layout templates will be modified.
- The refactor scope is limited to `apps/synapsis_web` files only (LiveViews, components, layouts, CSS).

## Scope Boundaries

### In Scope

- Refactoring all 17 LiveView `render/1` functions to use Duskmoon components consistently
- Enhancing `core_components.ex` with reusable app-specific components
- Updating layout files (`root.html.heex`, `app.html.heex`) for improved structure
- Adding empty state components for list views
- Ensuring consistent use of Duskmoon design tokens throughout
- Improving chat message rendering in Assistant and Session views

## Clarifications

### Session 2026-03-09

- Q: What chat message layout style should be used? → A: Chat bubbles — user messages right-aligned, assistant messages left-aligned with distinct backgrounds.
- Q: How should long lists be handled? → A: Scrollable lists — all items render, page content area scrolls naturally (no pagination or virtual scroll).

### Out of Scope

- Backend logic changes (contexts, schemas, database)
- Route structure changes
- New features or pages
- API endpoint changes
- Build tooling or deployment configuration
- Performance optimization
- Accessibility audit (beyond what Duskmoon provides by default)
