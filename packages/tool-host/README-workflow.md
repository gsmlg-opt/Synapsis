# Workflow compute helper package

The helper consists of byte-copied `src/workflow/schema-stdio.mjs`,
`schema-worker.mjs`, `schema.mjs` and `template.mjs`. The stdio process owns its
worker and transport; the worker performs Ajv schema compilation, response
validation and the complete pure Lobster template formatter. The formatter keeps
its original MIT license and attribution. `Synapsis.Workflow.Schema.PortSession`
owns actual helper calls and normal close. No additional executor or scheduler
is introduced.

`render_template` requests carry a caller-owned `id`, tagged string `template`,
tagged `item` and the existing version 1 heap. Rendering reuses `decodeRoots`
with the template/item in its schema/response slots, preserving references, own
undefined fields, property order and binary64 values. Well-formed strings retain
`{type: "string", value: utf8}`; unpaired UTF16 units use the distinct canonical
`{type: "string", utf16le: base64}` form without a `value` field. Both request
roots and returned strings preserve exact UTF16LE units.

A successful operation returns `result: "ok"`, `outcome: "rendered"` and the
canonical tagged string in `value`, inside the usual `type`/`id`/`cacheEntries`
result envelope. PortSession checks the exact kind/id/result and canonical string
receipt, including the unchanged cache count. Rendering does not populate the
Ajv cache. The existing ready version/profile remains unchanged; its profile
identifies the retained Ajv 8.20.0 Draft-07 schema dialect. Existing deadlines,
transport byte limits, worker ownership and normal-close protocol still apply.
Base64 expansion counts toward the existing transport limits.

Generate its standalone runtime tree from the repository root using the explicitly
provisioned Node runtime:

```sh
"$SYNAPSIS_FILESYSTEM_NODE" scripts/build-workflow-schema.mjs
"$SYNAPSIS_FILESYSTEM_NODE" scripts/build-workflow-schema.mjs --output /absolute/output/path
```

The default output is `apps/synapsis_core/priv/workflow_schema/`. The builder copies
all installed package files pinned by `src/workflow/dependencies.json`, including
licenses, types, source maps and package metadata. Only `.npm-ex-cache-complete`
installation markers are omitted. It checks the complete `package-lock.json`
hash, exact lock entries, installed versions, dependency resolution, file hashes
and byte counts before writing. It never installs dependencies or removes an
output tree; unrelated existing output entries stop generation.

The closure contains Ajv 8.20.0, fast-deep-equal 3.1.3, json-schema-traverse 1.0.0,
require-from-string 2.0.2, and two distinct fast-uri locations. The helper imports
fast-uri 4.2.2 directly; Ajv retains its own nested fast-uri 3.1.9. Both are copied
in their original Node resolution locations. Ajv's whole installed tree includes
that nested package; the nested pin verifies the same bytes independently, and
the output contains each shared path once.

`pinned-dependencies.json` preserves the input manifest verbatim. `provenance.json`
records unchanged host module hashes, package and license inventories, lock hash,
host imports and generated artifact hashes. Paths are relative; timestamps and
absolute build locations are absent. The provenance inventories every generated
file except itself. There is no source transformation or checkout fallback at
runtime. To update the closure, explicitly review the lock and installed package
bytes and regenerate the pins; do not relax checks to accept a mismatch.

The existing Node supply remains `SYNAPSIS_FILESYSTEM_NODE`, including the
version-local release runtime provisioned by `rel/filesystem_runtime.exs` and
`rel/env.sh.eex`. This helper package adds no Node search or configuration default.
The packaged helper path can be resolved from the core application's private
directory as `workflow_schema/schema-stdio.mjs`.

Scoped validation:

```sh
devenv shell --no-tui -- mix test apps/synapsis_core/test/synapsis/workflow/schema_package_functional_test.exs
```

The functional test copies and relocates the complete generated tree outside the
checkout, checks original modules/packages/licenses/provenance, then drives the
protected ordinary same-stage, next-stage and completion cases through the actual
helper. Input checkpoints resume with a fresh helper; successful close observes
the helper's OS exit. This qualifies the relocated schema package. The dedicated template check runs
114 previously frozen formatter literals and 23 previously frozen UTF16 strings
through both source and relocated helpers, including generated lone-surrogate
receipts, re-input, actual Ajv enum validation and normal close:

```sh
devenv shell --no-tui -- mix test apps/synapsis_core/test/synapsis/workflow/template_port_functional_test.exs
```

These are compute/transport checks. They do not qualify an installed release or
Docker image, the template command constructor, filesystem loading, lazy Machine
execution or new-variant Worker persistence.

The source-checkout Worker now exposes the explicitly selected
`synapsis::lobster` tool through the existing native catalog. It resolves this
packaged helper from core priv and uses the configured Node executable; it never
falls back to the checkout source. Supported inline commands are head, pick,
json, ask, sort, dedupe, groupBy, map, where and table. Structured-input checkpoints return a
host locator for an explicit resume call with responseJson. The durable aggregate
retains the full Machine state and heap across fresh Workers and helpers. The
new template compute operation is not in this public command allowlist. Machine
string consumers, escaped-lone JSON input and surrogate object keys still need
explicit integration before template activation.

The native Policy timeout hook selects timeoutMs per invocation (default 20000,
effective minimum 200, maximum 2147483647). The complete ordered pretty JSON text
is both the published content and the UTF-8 maxStdoutBytes input (default 512000,
effective minimum 1024); details is decoded from that same text. No tool is added
to Agent defaults.

The dedicated ordinary Worker test covers the local Gaoxy Responses request,
native result, next request, Parts, Concord and fresh-Worker explicit resume:

```sh
devenv shell --no-tui -- mix test apps/synapsis_agent/test/synapsis/session/native_workflow_functional_test.exs
```

Installed Worker and managed-child workflow integration, native effects, workflow
files, approvals, checkpoint cancellation and external Lobster token compatibility
remain unqualified or unimplemented. Security, permission, authentication,
failure, cancellation, expiry and resource-limit tests were not run.
