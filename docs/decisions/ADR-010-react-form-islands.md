# ADR-010: DuskMoon React Form islands

## Status: Accepted

Partially supersedes [ADR-007](ADR-007-pure-liveview-ui.md). Approved by the user on 2026-10-13; the first implementation phase covers application forms. Chat migration is a separate phase.

## Context

Phoenix DuskMoon now publishes React Form controls and a LiveView JSON bridge. Synapsis needs these components for existing forms while retaining its operational layout, conditional settings, server validation and file-backed persistence.

## Decision

LiveView continues to own routes, page composition, authorization, validation and persistence. Forms use the published `dm_react_form` integration from `phoenix_duskmoon`; supported fields use `dm_react_field`. Native controls remain within its documented mixed HEEx API when the React wrapper does not support their required attributes.

`SynapsisWeb.ReactForms` supplies stable logical form IDs, initial values, retained drafts, structural mount IDs, explicit reset events and actions. `SynapsisWeb.ReactFormEvents` unwraps JSON `{id, values, revision}` submissions and preserves the existing business handlers' HTML scalar conversion contract. Errors remain server-authoritative and return JSON acknowledgments as well as the existing visible flash feedback.

React owns the ignored form subtree. Conditional fields, option sets and server-driven button state replace a form mount using a structural descriptor, preserving its latest draft. Structural mounts use a keyed LiveView comprehension so unchanged nested components are sent in full for each replacement; changing only the DOM ID can leave optimized descendants empty. Plain typing never remounts the form. Server resets explicitly replace its draft; external Save buttons target the current mount ID plus `-native`, matching the inner native form.

A small extension of the public upstream hook snapshots current native controls before submission and restores typed values and checkbox groups on resets/remounts. It checks native constraints before submission, preserving required fields and numeric bounds. Temporary compatibility code is tracked by upstream issues [#191](https://github.com/duskmoon-dev/phoenix-duskmoon-ui/issues/191), [#192](https://github.com/duskmoon-dev/phoenix-duskmoon-ui/issues/192) [#193](https://github.com/duskmoon-dev/phoenix-duskmoon-ui/issues/193) and [#194](https://github.com/duskmoon-dev/phoenix-duskmoon-ui/issues/194). Dependency source is not patched.

Layout classes apply to the inner native form; its ignored bridge wrapper uses `display: contents` so row and column layouts retain their parent sizing. This temporary adapter is tracked by [#195](https://github.com/duskmoon-dev/phoenix-duskmoon-ui/issues/195). Scoped styles align native and React controls and correct duplicate Select icons pending [duskmoon-react#84](https://github.com/duskmoon-dev/duskmoon-react/issues/84).

## Consequences

React and DuskMoon Components are deliberate application dependencies, built by DuskmoonBundler. No separate SPA, channel client or duplicate persistence layer is introduced. The existing Agent chat and Provider Test Chat message input remain unchanged until the second phase. Future upstream updates should remove these compatibility extensions only after the native/group/draft integration tests pass against the published dependency.
