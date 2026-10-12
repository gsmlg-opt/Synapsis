# React Forms Implementation Plan

> **For agentic workers:** Use subagent-driven-development for the independent page groups. Do not change chat transcript/composer code. Do not run simultaneous Mix commands or commit changes.

**Goal:** Migrate application forms to Phoenix DuskMoon React Form while preserving existing editing and persistence behavior.

**Architecture:** Use the published mixed HEEx/React form API. A small presentation-layer form component and event bridge preserve existing nested handler payloads; a tested native-control adapter covers known upstream gaps. LiveView retains page and business-state ownership.

**Tech Stack:** Phoenix LiveView, phoenix_duskmoon 9.16.14, React 19, Components 0.5.0, TypeScript, DuskmoonBundler.

## Shared integration (parent)
- [x] Add `SynapsisWeb.ReactForms` in `apps/synapsis_web/lib/synapsis_web/components/react_forms.ex`, with `react_form` (for/as/values/draft/structure/actions/rest), `react_form_draft(assigns, id)`, and `reset_react_form(socket, id, values)`.
- [x] Add opt-in `SynapsisWeb.ReactFormEvents` (use in the 13 form LiveViews), initializing draft state with on_mount and accepting JSON payloads before existing callback clauses. Delegate to existing handlers and return JSON acknowledgments/errors; retain HTML-compatible values for existing parsers.
- [x] Add a native-control adapter in `packages/hooks/src/react-form.ts` that extends `DuskmoonReactForm`, snapshots current native fields at submission, restores grouped checkboxes and assigns an inner native form ID. Test actual checkbox/number/model-hidden/reset behavior in `packages/hooks/test/react-form.test.ts`.
- [x] Import the helper component in `apps/synapsis_web/lib/synapsis_web.ex`; register the hook in assets/js/app.ts, add direct JS dependencies and the Components stylesheet.

## Agent and MCP forms (worker one)
- [x] Migrate `agent_live/{agents,toolsets,daemon,skills}.ex` and `mcp_live/{index,show}.ex` with explicit form IDs and JSON event support. Seed React field values explicitly; preserve disabled/required/placeholder native inputs until upstream #191 is fixed.
- [x] Pass `draft={react_form_draft(assigns, id)}`; use `structure` for MCP transport/tab/tool-source changes. Preserve draft through remount and reset server-owned selection changes explicitly. Keep complete selected-tool lists when rendering a subset.
- [x] Adjust owning tests to real JSON payloads/React mount selectors and add focused persistence/error/dynamic-switch checks.

## Provider, memory, skill and workspace forms (worker two)
- [x] Migrate `provider_live/{index,show}.ex`, `memory_live/{index,show}.ex`, `skill_live/{index,show}.ex`, `workspace_live/explorer.ex`; exclude Provider Test Chat send form/composer for phase two.
- [x] Preserve preset/model-dependent options, draft initialization/reset and external memory Save form association. Use `dm_react_field` where supported and native controls with #191 references for missing attribute support.
- [x] Adjust owning tests to JSON payloads, preserve server validation and reset/error cases.

## Verification and documentation (parent)
- [x] Run only the 13 owning LiveView test files plus new form integration tests; run the relevant hook tests and TypeScript checks.
- [x] Format touched Elixir files and build web assets using `mix npm.install` / `mix assets.build` under devenv.
- [x] Exercise real form typing, dynamic switch, save rejection and reset in an isolated server/browser.
- [x] Add ADR-010 for React Form islands, update ADR-007 and architecture boundaries with the precise exception. Keep chat migration deferred.
- [x] Review the complete diff, resolve in-scope issues, update this checklist, and save a verified project-scoped Agent Note.

## Verified result

Implemented 20 forms in 13 LiveViews on uncommitted main, based on `0545d4ce`. Chat transcript/composer migration remains phase two.

- Scoped suite after the keyed-remount fix: 233 tests, zero failures. Subsequent Agent external Save regression and owning file: 23 tests, zero failures.
- Native hook tests: four passed; both TypeScript workspace checks passed.
- DuskmoonBundler asset build passed; all 13 referenced JavaScript files and one CSS file exist. The entry contains native validation and reset fixes.
- Isolated browser/server verification covered native required/range rejection, zero values, memory external Save/cancel/reset, toolset checkbox-array persistence, MCP transport switches preserving drafts and complete controls, Agent model-picker values across tabs and external Save after remount, and Provider token clear preserving pending fields. Desktop page has no horizontal overflow and no console errors after reload.
- Browser findings fixed: structural mounts now use keyed LiveView entries to avoid empty optimized descendants; Agent external Save targets the current native form ID. No existing service was restarted.
- Agent Note saved and read back with project=synapsis: `5e0881f5-cf12-4364-87a0-08b716903972`.

## MCP modal and layout follow-up

- MCP list Import JSON and Add MCP Server now open native DuskMoon modal dialogs. `/settings/mcp/new` patches into the create dialog; successful save or cancellation returns to the list. Errors appear inside the dialog. Close, Escape and backdrop clicks synchronize LiveView state; cancelled drafts are reset.
- Form layout classes now reach the inner native form. Labels, field spacing and control heights match across native and React controls. Select caret/clear styling tracks upstream issues #195 and duskmoon-react#84.
- Verification: 195 scoped LiveView/form tests and 14 hook tests passed; TypeScript checks and DuskmoonBundler build passed, with all 13 JS and one CSS manifest files present.
- Actual development service on port 4657 verified both modal entry points, autofocus, native required validation, invalid JSON feedback with retained text, reset on reopen, Cancel/header/Escape/backdrop close, transport remount with retained drafts, desktop moonlight and mobile sunshine layout without horizontal overflow. Provider vertical spacing and Workspace flex sizing also verified; no existing configuration was changed.
- A one-time loss of native modality while recompiling the open dialog template did not recur after fresh loading, repeated typing or transport remounts. Browser verification ran against the final template after reload.
