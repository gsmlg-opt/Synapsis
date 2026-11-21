# ADR-010: DuskMoon React Form islands

## Status: Accepted

Partially supersedes [ADR-007](ADR-007-pure-liveview-ui.md). Approved by the user on 2026-10-13; the first implementation phase covers application forms. Chat migration is a separate phase.

## Context

Phoenix DuskMoon now publishes React Form controls and a LiveView JSON bridge. Synapsis needs these components for existing forms while retaining its operational layout, conditional settings, server validation and file-backed persistence.

## Decision

LiveView continues to own routes, page composition, authorization, validation and persistence. Forms use the published `dm_react_form` integration from `duskmoon_phoenix`; supported fields use `dm_react_field`. Native controls remain within its documented mixed HEEx API when the React wrapper does not support their required attributes.

`SynapsisWeb.ReactForms` supplies stable logical form IDs, initial values, retained drafts, structural mount IDs, explicit reset events and actions. `SynapsisWeb.ReactFormEvents` unwraps JSON `{id, values, revision}` submissions and preserves the existing business handlers' HTML scalar conversion contract. Errors remain server-authoritative and return JSON acknowledgments as well as the existing visible flash feedback.

React owns the ignored form subtree. Conditional fields, option sets and server-driven button state replace a form mount using a structural descriptor, preserving its latest draft. Structural mounts use a keyed LiveView comprehension so unchanged nested components are sent in full for each replacement; changing only the DOM ID can leave optimized descendants empty. Plain typing never remounts the form. Server resets explicitly replace its draft; external Save buttons target the current mount ID plus `-controls`, matching the inner native form.

The Synapsis hook snapshots native controls for submission and restores typed values on resets and remounts. Selected tools from other sources remain checked, hidden members of the same checkbox group, so the bridge includes them when reading or resetting the group. The Phoenix component enables browser validation through `novalidate={false}` and passes the submitter to the hook.

The component applies `form_class` to the native form. Its outer wrapper uses `display: contents` so row and column layouts retain their parent sizing. Scoped styles align native and React controls.

## Consequences

React and DuskMoon Components are deliberate application dependencies, built by DuskmoonBundler. No separate SPA, channel client or duplicate persistence layer is introduced. The existing Agent chat and Provider Test Chat message input remain unchanged until the second phase. Future upstream updates should remove these compatibility extensions only after the native/group/draft integration tests pass against the published dependency.
