# OpenClaw reference capture

OpenClaw is a capability reference. `backplane_agent_runtime` remains the runtime
contract authority. Captured names and schemas do not register or authorize tools
in Synapsis.

The source is pinned to `488631c18fae7cc541ba8fc8beff6cbb0438787b`. Use a complete,
clean Git checkout and a Node version supported by its `package.json`. The real
capture was checked with Node 24.22.1 and the pinned TypeBox 1.3.37 dependency,
resolved from that checkout. The capture command never installs dependencies.

```sh
node scripts/openclaw/capture-contracts.mjs \
  --source /path/to/pinned/openclaw \
  --pin 488631c18fae7cc541ba8fc8beff6cbb0438787b \
  --out /tmp/openclaw-reference-capture \
  --offline
```

The output directory must be new and outside the upstream checkout. The command
verifies the commit and tracked blob contents before and after capture. It never
calls a captured tool's `execute` function. Reviewed recipes evaluate unchanged
schema and factory bodies with pure helpers and throwing execution bindings.
Unknown imports, attempted service calls, and dynamic imports remain unresolved.
This is a bounded harness for trusted pinned source, not isolation for hostile
plugins. A factory returning a tool proves metadata construction, not credentials,
runtime eligibility, permission, or successful execution.

```sh
python3 scripts/openclaw/verify-baseline.py \
  --manifest docs/superpowers/specs/2026-10-23-openclaw-tool-alignment-baseline.json \
  --fixtures /tmp/openclaw-reference-capture
```

Exit statuses are deliberate:

- `0`: all required capture evidence is complete.
- `1`: invalid source, provenance, input, or fixture.
- `2`: the inventory is verified but factory, registration, assembly, or coverage
  evidence is incomplete. The current real capture returns this status.

The eventual `--require-coverage` gate also requires the adjacent
`capability-map.json` and implemented action evidence. The current mapping is an
assessment and must fail that gate.

Copied upstream source retains its pinned license in the capture output.
Dependency hashes record provenance; dependency code is not vendored into this
repository by the capture.

The independent native contract capture is:

```sh
MIX_ENV=test devenv shell --no-tui -- mix run --no-start \
  scripts/backplane/capture-contracts.exs --offline --check
```

The active native fixture pins Backplane 1.10.31, including public callbacks such
as `ConversationAdapter.prepare_tool/2`; the 1.10.28 and 1.10.30 fixtures remain historical.
The four Backplane packages are upgraded together. Native profile descriptors
remain unchanged across these fixtures; this does not imply all runtime behavior
or optional host integrations are identical.

Run `node --test scripts/openclaw/capture-contracts.test.mjs` and
`python3 scripts/openclaw/verify-baseline.test.py` for the capture tooling tests.
Run `MIX_ENV=test devenv shell --no-tui -- mix test
apps/synapsis_agent/test/synapsis/agent/tools/` for native snapshots, capability
assessments, catalog/binding composition, and isolated host policy and approval hooks.
These local checks use trusted host sidecars. Dynamic `:ask` can use native
Conversation interactions when an explicit trusted approval context is supplied;
otherwise it remains denied with an approval-required reason. Production wiring,
authenticated UI endpoints, static approval integration, remote credential
authorization, and device/browser integration remain unverified.
