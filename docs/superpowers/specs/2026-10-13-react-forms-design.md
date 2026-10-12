# React Form migration, phase one

Approved by the user on 2026-10-13: migrate all application forms first, then handle chat in a separate phase. Agent chat and Provider Test Chat transcript/composer are outside this phase; the Provider chat model selector remains a settings form.

LiveView owns pages, validation, permissions and persistence. Phoenix DuskMoon 9.16.14 owns the React Form integration and supported React fields. Keep existing HEEx layout and controls that require native attributes, using the documented mixed native/React form API. Mark temporary native attribute retention with duskmoon-dev/phoenix-duskmoon-ui#191 and grouped-checkbox compatibility with #192.

Each form has an explicit mount ID. Form JSON events carry id, values and revision; a scoped LiveView bridge delegates values to existing business handlers and replies with status and errors. Keep nested payload names and empty-checkbox semantics. Changes to conditional layouts/options remount only on structural changes and preserve the latest draft; never remount on ordinary typing. Save/reset flows explicitly reset retained drafts. External submit buttons must reference the inner native form.

Register the upstream React Form hook, install React/Components dependencies, and import the Components stylesheet through the existing DuskmoonBundler build. A narrow hook extension reconciles native controls at submit/change, including native grouped selections and model-picker hidden inputs (#193), and checks native required/min/max constraints (#194), without modifying dependency source.

Verification covers the scoped LiveView tests, typed JSON submissions/rejections, native checkbox arrays and reset, dynamic form switches, hook tests, TypeScript, asset build and browser interaction. Record the architecture exception in a new ADR and capture verified reuse guidance in Agent Note with project synapsis. Develop directly on main as requested by the user; do not create worktrees. Do not commit, push, merge or restart existing services without separate authorization.
