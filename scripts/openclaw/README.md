# OpenClaw reference capture

OpenClaw is a capability reference. `backplane_agent_runtime` remains the runtime
contract authority. Captured names and schemas do not register or authorize tools
in Synapsis.

The source is pinned to `488631c18fae7cc541ba8fc8beff6cbb0438787b`. Use a complete,
clean Git checkout and a Node version supported by its `package.json`. The real
capture was checked with Node 24.22.1 and the pinned TypeBox 1.3.37 dependency,
resolved from that checkout. The capture command never installs dependencies.

```sh
node --max-old-space-size=2048 scripts/openclaw/capture-contracts.mjs \
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
python3 -B scripts/openclaw/verify-baseline.py \
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

The Browser recipes additionally capture eight schemas from the original builders:
default (24 actions / 14 act kinds), evaluation disabled (24/13), tab-bound
(17/14), both (17/13), existing-session (17/13 and tab-bound 10/13), and
Lightpanda (14/8 and tab-bound 7/8). Driver capability methods and the viewport
constant use recorded exact source-byte projections; the verifier recomputes
selection and generated-wrapper hashes. These are schema-construction facts.
The actual unchanged `createBrowserTool` factory now has 36 captured cases:
four direct constructors, eight supplied-capability variants, and 24 representative
role/profile/configuration contexts. Each returned metadata object, including
`outputSchema`, matches `createBrowserToolDefinition(...).metadata` in a fresh VM.
Only the SDK `readRuntimeConfig` binding receives a recorded synthetic input; the
real runtime-config implementation is not executed. `normalizeOptionalString`
uses a recorded whole-source-module projection. Supplied engine capabilities do
not establish host configuration/profile resolution. Flags that do not gate this
constructor cannot establish eligibility from a returned descriptor.

A separate `browserRegistrations` array records 35 source-projected lazy callback
cases: 24 representative contexts, five ordinary config precedence cases, four
media contexts and two valid node-tab bindings. Exact bytes of the complete
`api.registerTool` statement and its three helpers are composed with recorded
observation bindings. The callback delegates to the unchanged real definition;
full metadata, including `outputSchema`, matches an independently invoked
definition in a fresh VM. Inputs and getter calls identify whether the callback
selects `getRuntimeConfig()`, `runtimeConfig` or `config`. This runs the projected
statement/callback, rather than the whole `registerBrowserPlugin` function.
Plugin loader, service startup, general scanning, runtime assembly/admission and
Browser actions remain unexecuted or unresolved. Existing static registration
and assembly gaps are retained.

The Python verifier recomputes source selection, generated TypeScript wrapper,
context/config and schema hashes. The dedicated Node suite also recomputes the
transpiled executable hash; Python checks that recorded digest's format.

The dedicated ordinary metadata suite requires a complete pinned source checkout
with its TypeBox dependency available. Set `OPENCLAW_BROWSER_SOURCE` explicitly
when the checkout is not `/tmp/openclaw-488631c`; it does not fetch dependencies.
Use the supported Node version:

```sh
PYTHONDONTWRITEBYTECODE=1 NODE_OPTIONS=--max-old-space-size=2048 \
OPENCLAW_BROWSER_SOURCE=/path/to/pinned/openclaw node \
  --experimental-vm-modules --disable-warning=ExperimentalWarning --test-concurrency=1 \
  --test scripts/openclaw/browser-factory-functional.test.mjs \
  scripts/openclaw/browser-registration-functional.test.mjs
```

The session capture loads the unchanged `createSessionsListTool`,
`createSessionsHistoryTool` and `createSessionStatusTool` factory modules. Each has
24 recorded representative option contexts; seven additional direct cases cover
ordinary link-description and `supportsActiveOnly` variants. Complete metadata,
including `displaySummary` and both schemas, is compared with exact original
schema/metadata regions in a fresh VM. Those regions are not upstream exported
definitions. The real execution-wrapper source is retained, and the status lazy
loader remains deferred; no returned tool or service executes. Constructor
contexts do not establish runtime eligibility, registration or action behavior.

Run the dedicated ordinary metadata suite with the supported Node version:

```sh
PYTHONDONTWRITEBYTECODE=1 NODE_OPTIONS=--max-old-space-size=2048 \
OPENCLAW_SESSION_SOURCE=/path/to/pinned/openclaw node \
  --experimental-vm-modules --disable-warning=ExperimentalWarning \
  --test scripts/openclaw/session-factory-functional.test.mjs
```

The bounded heap lets Node collect the many fresh TypeBox VM graphs promptly;
the VM execution deadline and comparison assertions stay unchanged. The Python
verifier independently reconstructs exact source regions and generated wrappers.
It checks transformed executable digest format; the Node suite recomputes that
digest using the actual TypeScript transformer.

The PDF capture evaluates the complete unchanged `createPdfTool` factory for 26
ordinary constructors: an agent directory, positive configured `pdfMaxMb` and
`pdfMaxPages` defaults, and the same 24 representative contexts extended with
`agentDir: "/reference/agent"`. None configures an explicit `pdfModel` or
`imageModel`, so the upstream constructor defers model readiness. Actual pure
`coercePdfModelConfig`, `coerceImageModelConfig`, `hasToolModelConfig` and their
pure dependencies use exact source-region projections; normalization modules
retain whole pinned source. Other execution imports are explicit audited throwing
bindings. A fresh VM compares exact original schema, description and returned
metadata regions without invoking the factory again or duplicating its schema.
The PDF tool has no output schema or display summary in this pinned source.

```sh
PYTHONDONTWRITEBYTECODE=1 NODE_OPTIONS=--max-old-space-size=2048 \
OPENCLAW_PDF_SOURCE=/path/to/pinned/openclaw node \
  --experimental-vm-modules --disable-warning=ExperimentalWarning \
  --test scripts/openclaw/pdf-factory-functional.test.mjs
```

These cases exclude absent-agent-directory, null-return, throwing-constructor,
explicit model configuration and auth readiness branches. PDF loading, extraction,
native providers, model fallback, resource lifecycle, tool execution, registration
and runtime assembly remain unexecuted. Configured limits are constructor inputs;
metadata equality does not prove those limits during execution. Python reconstructs
the complete 26-case input matrix, source selections, wrappers and import boundary;
Node recomputes transformed executable digests.

The TTS capture evaluates the complete unchanged `createTtsTool` factory for 27
ordinary constructors: no arguments, an empty options object, configured voice
intent with channel/agent/account hints, and the same 24 representative contexts.
A fresh VM evaluates exact original schema and metadata regions, including
`displaySummary`; the pinned tool has no output schema. TypeBox is the real pinned
1.3.37 dependency. Four execution imports use explicit throwing bindings and are
recorded individually. Neither the returned tool, transcript sanitizer, runtime
config reader nor voice provider executes. Constructor equality does not establish
voice readiness, delivery, registration, runtime eligibility or assembly.

```sh
PYTHONDONTWRITEBYTECODE=1 NODE_OPTIONS=--max-old-space-size=2048 \
OPENCLAW_TTS_SOURCE=/path/to/pinned/openclaw node \
  --experimental-vm-modules --disable-warning=ExperimentalWarning \
  --test scripts/openclaw/tts-factory-functional.test.mjs
```

The dedicated Node suite independently reconstructs the 27-case matrix and source
regions, verifies transformed executable digests and checks the frozen capture
against actual factory results. The Python verifier independently reconstructs the
matrix, exact source/generated metadata regions, declared import boundary and
provenance relationships. It validates executable digest format; Node recomputes
those executable digests with the actual TypeScript transformer.

The separate OpenAI speech oracle executes the complete pinned speech provider,
its shared provider-config module, and three normalization modules. Small SDK
facades re-export those original normalization functions. Fourteen successful
callbacks cover raw configuration resolution, file/voice-note formats, Groq
WAV defaults, model/voice/speed/instructions, public extra-body precedence,
provider overrides and telephony PCM at 24 kHz. HTTP, proxy capture, media limits,
secret normalization and voice compatibility are explicit synthetic platform
boundaries. Captured bytes are opaque transport tokens, not decodable audio.

```sh
OPENCLAW_SPEECH_SOURCE=/path/to/pinned/openclaw node \
  --experimental-vm-modules --disable-warning=ExperimentalWarning \
  --test scripts/openclaw/openai-speech-functional.test.mjs
node --experimental-vm-modules --disable-warning=ExperimentalWarning \
  scripts/openclaw/capture-openai-speech.mjs /path/to/pinned/openclaw \
  /tmp/openai-speech.json
```

The standalone fixture is `488631c/openai-speech.json`; it does not alter the
canonical factory inventory or mark full TTS action/assembly evidence complete.
The host `Synapsis.Provider.Speech.OpenAI` adapter compares `build_request/2`
against every oracle request. Its dedicated Gaoxy functional tests separately
exercise binary HTTP collection, a valid tiny WAV and opaque MP3/Opus bytes.
The adapter accepts explicit atom-key request/config maps and returns audio bytes
and format metadata for a future native tool owner. Media persistence/delivery,
provider discovery, runtime selection, channel routing, fallback, full lifecycle
and actual supplier verification remain separate requirements. No real provider
connection is made by these tests.

The separate `schemaCaptures` collection contains two cron metadata observations:
the real `createCronToolSchema()` with no arguments and the complete
`CronToolOutputSchema` export. The input schema exposes nine default actions;
the output retains all 13 discriminator mappings as schema data. Only the input
action enum contributes newly observed action gaps. Output mappings do not prove
that the default input selects those additional actions, or that any action ran.
The 24 generic unresolved `createCronTool` attempts remain unchanged.

The dedicated exporter writes only these rows, their tracked source snapshots,
license scope and dependency provenance to a new directory:

```sh
node --experimental-vm-modules --disable-warning=ExperimentalWarning \
  scripts/openclaw/capture-cron-schemas.mjs \
  /path/to/pinned/openclaw /tmp/openclaw-cron-schemas
OPENCLAW_CRON_SOURCE=/path/to/pinned/openclaw node \
  --experimental-vm-modules --disable-warning=ExperimentalWarning \
  --test scripts/openclaw/cron-schema-functional.test.mjs
```

Use Node 24.22.1 and the existing real TypeBox 1.3.37 package; no dependencies
are installed. Each row records its actual Node version separately from historical
capture runtime metadata. The input builder preserves the complete real schema
cache, `Clone` from the actual `typebox/value` export, normalization and numeric/enum
helpers. Complete output/protocol schema modules retain the full result contract.
Five small declarations/helper regions use original source bytes with recorded
line/byte selections, generated wrappers and executable digests. Two explicitly
named input-validation imports are audited throwing bindings with zero calls.

The dedicated positive suite recaptures complete schemas in fresh VMs, recomputes
original blob/selection/wrapper/transformation and actual package/export-file
hashes, and compares both rows with the canonical fixture. Python independently
reconstructs source boundaries, aliases, projections, full schema JSON/digests,
action indexes and pinned dependency inventories; it checks executable digest
format while Node recomputes the executable bytes. Factory construction,
eligibility, registration, assembly, validation, services and tool actions remain
unexecuted. This schema evidence preserves the incomplete/coverage gates.

The canonical capture contains 181 recipes: the existing 49 recipes plus 79
session, 26 PDF and 27 TTS factory cases, and 35 separate Browser callback captures, plus the two separate cron schema captures.
Its valid-but-incomplete verifier status remains `2`. Generic unresolved factory
attempts and all runtime assembly/action gaps remain recorded.

The standalone `488631c/automation-factory.json` capture invokes the complete
unchanged `createCronTool` and its returned callbacks for 19 successful vectors
across status/list/get/add/update/remove/run/runs/wake. It executes 128 complete
pinned source modules, including the selected normalization, creator and result
helpers, with actual TypeBox 1.3.37 and Zod 4.6.7. Twenty Gateway calls receive
supplied fixture replies; they do not execute the Gateway, job service, storage,
timers or runtime. Model run defaults to `due`, while omitted Gateway mode defaults
to `force`; wake defaults to a session system event on the next heartbeat.

One recorded import-edge facade replaces only
`captureCronStreamPolicyConfigCurrentness`: it records construction and returns
an uninvoked throwing assertion. Policy construction is not executed and assertion
calls remain zero. Other deferred imports also have zero calls. The capture records
source, transformed executable, facade, dependency-file and Node digests and checks
all tracked upstream blobs before and after. Full factory/runtime parity and the
existing canonical coverage gates remain incomplete.

```sh
/path/to/node-24.22.1 --experimental-vm-modules --disable-warning=ExperimentalWarning \
  scripts/openclaw/capture-automation-factory.mjs \
  /path/to/pinned/openclaw /tmp/automation-factory.json
OPENCLAW_AUTOMATION_FACTORY_SOURCE=/path/to/pinned/openclaw \
  /path/to/node-24.22.1 --experimental-vm-modules --disable-warning=ExperimentalWarning \
  --test scripts/openclaw/automation-factory-functional.test.mjs
```

The harness uses the existing temporary capture runtime at
`/tmp/synapsis-openclaw-capture-runtime` for Node and exact pinned dependencies;
it never installs packages. Its positive suite recaptures the callbacks and
compares the entire result with the frozen standalone fixture.

Copied upstream source retains its pinned license in the capture output.
Dependency hashes record provenance; dependency code is not vendored into this
repository by the capture.

The separate PDF automatic-model capture executes the complete unchanged
`src/agents/tools/pdf-tool.model-config.ts` and 48 original helper modules:

```sh
node --experimental-vm-modules scripts/openclaw/capture-pdf-model-config.mjs \
  /tmp/openclaw-488631c /tmp/pdf-model-config.json
node --experimental-vm-modules --test scripts/openclaw/pdf-model-config-functional.test.mjs
```

The checked-in `488631c/pdf-model-config.json` records eighteen ordinary positive
vectors with complete ordered primary/fallback references, source and executable
hashes, import bindings, and the full fixture-port call ledger. All 174 bundled
manifests are parsed as immutable metadata inputs. Twelve explicit ports replace
manifest/runtime-registry access and provider availability; 39 sealed imports
remain uncalled, and `node:path` is the only platform module exposed to evaluated
source. The VM has an empty environment. The actual selector, configuration
coercion, metadata projection, provider priority, document hints and reference
normalization run from unchanged source bodies. Source checkout blob, mode and
symlink checks cover 58,558 entries before and after execution. These checks do
not qualify authentication, external providers or host integration.

The independent literal outputs preserve source quirks, including explicit
fallback duplicates and the additional self-prefixed configured-model fallback.
This receipt is distinct from the earlier PDF construction-only capture and the
native protocol capture below; neither earlier capture executed this resolver.

The separate host qualification is
`apps/synapsis_agent/test/synapsis/agent/tools/pdf_auto_admitted_functional_test.exs`.
Its six successful selected Worker scenarios observe ordinary Worker readiness
before one model switch and use an installed image-capable active model. The two
preceding frozen host fixtures are retained verbatim as
`host-pdf390-unready.frozen.exs` and
`host-pdf390-unknown-active.frozen.exs` in the fixture directory. They are historical
failed qualification artifacts outside test discovery: one omitted the asynchronous
Worker boot precondition; both manually declared image capability for an unknown
active model. Their failed receipts remain in
`/tmp/synapsis-pdf390-evidence/green_all.log` and `ready_before_repair.log`.
The corrected fixture keeps all six lanes, ordered candidate and result/history
assertions. Against the unrepaired product it still fails the main fingerprint
assertion (six tests, one failure); the single product fingerprint repair then
passes the separate 26-test qualification. These later results do not turn the
original failed gates into passing runs.

The separate ordinary native PDF capture executes the complete pinned
`src/agents/tools/pdf-native-providers.ts` module:

```sh
node --experimental-vm-modules scripts/openclaw/capture-pdf-native.mjs \
  /tmp/openclaw-488631c /tmp/pdf-native.json
node --experimental-vm-modules --test scripts/openclaw/pdf-native-functional.test.mjs
```

Its checked-in `488631c/pdf-native.json` records five successful Anthropic/Gemini
callbacks, ordered inline bytes, request bodies, response joining, timeout and
release calls. Eleven imported platform modules are explicit synthetic boundaries;
the capture uses synthetic PDF tokens and performs no external requests. Provider
mapping tests substitute valid local PDFs, including a document larger than
262144 bytes, into those frozen bodies. Gemini `inline_data/mime_type` fields are
compared with the official codec's equivalent `inlineData/mimeType` fields. The
reference uses one-shot JSON HTTP; the host uses the existing streaming adapter.
These observations do not prove full factory/action/assembly parity or live
provider acceptance, and leave the whole-reference coverage gates unchanged.

The independent native contract capture is:

```sh
MIX_ENV=dev devenv shell --no-tui -- mix run --no-start \
  scripts/backplane/capture-contracts.exs --offline --check
```

The active native fixture pins Backplane 1.10.61, including `Approval.decide/2`,
child interaction resolution/cancellation, managed-child `Codex.Session` APIs and
the opt-in `Plugins.Session` public API, plus callbacks such as
`ConversationAdapter.prepare_tool/2`; the 1.10.28, 1.10.30, 1.10.31, 1.10.32,
1.10.34, 1.10.35, 1.10.36, 1.10.37, 1.10.38, 1.10.40, 1.10.42, 1.10.43, 1.10.44, 1.10.45, 1.10.46, 1.10.48, 1.10.49, 1.10.50, 1.10.51, 1.10.52, 1.10.53, 1.10.57 and 1.10.60 fixtures remain historical.
Runtime 1.10.61 adds the explicitly selected revision-2 `Web.ReadableFetch`
adapter, its native extraction controls and lossless portable document result.
The snapshot captures its public API and an inert readable service profile
separately from the unchanged revision-1 raw profile. Ordinary standalone and
native Conversation checks use an explicit host-document fixture; they do not
install the production HTML/charset/JSON extraction pipeline. Only the runtime
lock row changes: JSON Schema/MCP/schema remain 1.10.60, AI/skill/plugin 1.10.57,
and the existing HTTP closure is unchanged. The snapshot records the actual
versions separately. The earlier 1.10.60 `ToolResultContract` API is consumed by
the scoped Skills/read/workshop contracts documented below.
Capturing the API does not install plugin tools or
the host `append_feedback` callback in Synapsis. The active snapshot retains
`direct_model_only` extension exposure and tagged `memories.match_mode` changes;
the unconfigured tool list remains unchanged. Capture does not establish runtime
behavior or optional host integration acceptance.

Official 1.10.57 retains the five packages' 1.10.53 `lib/priv` implementation.
Its MCP dependency requires `http_web_socket ~> 0.21.19`, so the host adopts the
eight-package HTTP 0.21.19 dependency closure. The gateway Responses lifecycle
release does not activate that feature in Synapsis or qualify new runtime behavior.
Issues #151, #152 and #154 remain separate caller requirements. #153 is available
in official runtime 1.10.60; complete host consumers and their own result/persistence
contracts still require implementation and verification.

Official 1.10.53 supplies canonical observed stream models (#149) and explicit Google
thinking configuration (#150). The host retains the latest observation through
the authoritative assistant message and committed native completion; it never
uses the requested alias as observed identity. Positive local Gaoxy tests verify
the child/parent durable chain. Model capabilities and reasoning defaults remain
caller decisions; no real-provider or full-reference acceptance is claimed.

Official 1.10.52 adopts invocation-owned native clock waits (#146). The dedicated
ordinary completion fixture uses actual Conversation and Deno Headless consumers,
original host hooks and real Synapsis Store acknowledgements. It observes the
waiter's normal exit, retention of its registry resource before the result ACK,
and release after that ACK. The passive snapshot alone does not prove those
behaviors. Cancellation and failure branches are source-reviewed only; no such
execution tests are included in this adoption.

Current verification follows the user's instruction to omit all security and
permission tests and mixed suites. The historical 1.10.38 consumption batch used passive
package provenance checks, dev/test compilation, offline snapshot capture/check,
the dedicated ordinary patch/sandbox functional files, and two selected baseline
metadata cases. These checks do not establish PDF host integration or production
image availability. Exact commands and results are recorded in the implementation
plan; the broader historical commands below are not permitted for the current run.
The 1.10.42 cohort retains Responses image results (#112), pinned
provider/preparation catalog snapshots (#113), and CodeMode settled-result error
serialization (#111), and includes direct/nested backend-context parity (#114).
The original Worker catalog-revision functional tests now pass unchanged across
direct and nested file/MCP/clock calls, yield/wait, Concord and new-Worker replay.
The official 1.10.43 cohort adds inline user PDF codecs, optional Linux PTY build
support, and archived-child reconciliation APIs. Package adoption and passive
capture alone do not install the optional PTY broker or prove those host flows.
The official 1.10.44 cohort adds the optional `ConversationAdapter.tool_effect_timeout/2`
selector and runtime-owned `backend_context.effect_deadline/0` callback, caller-owned
MCP resource requests (`Client.start_list_resources`, `start_list_resource_templates`,
`start_read_resource`, `await_resource_request`, `cancel_resource_request` and
`ResourceRequest`), and Web search answer/citation results. It also adds explicit
plugin/connection cleanup reports, an opt-in stdio guardian build task, completed
installation receipts and archive message metadata preservation. The active passive
snapshot retains its 21 runtime API modules; MCP resource APIs and Web result
contracts are separately verified from the official published source. This dependency
adoption does not wire the Browser deadline hook, MCP resource cancellation chain,
Sonar adapter or optional guardian, and does not establish their host behavior.
Static CodeMode host wiring and pinned catalog projection are locally verified;
production dynamic discovery/publication and the MCP eager/deferred choice remain
separate and incomplete. Published APIs and local fixtures do not prove live
provider readiness or complete OpenClaw parity.

The official 1.10.45 cohort adds `Goal.settle_unstarted_admission/4`, the
`Goal.Settlement` contract, and `Codex.Readiness.await/4` while retaining the
existing readiness arities. It preserves startup failure observations through
native environment controls. These additions address #127/#128; package/source
inspection does not establish settlement, failure or recovery behavior in
Synapsis. The passive snapshot keeps its existing 21-module boundary and records
the changed Control source; Goal and native Readiness additions are separately
inspected from the released source. Synapsis has no production callers for these
new APIs. Goal durability remains a separate Concord integration requirement;
The subsequent 1.10.46 release includes fixes for MCP metadata (#130), event
listing (#132) and citation-only search (#129); adoption and each consumer
acceptance remain distinct.

The official 1.10.46 cohort adds public caller-owned modern Events requests and
preserves namespaced request metadata. Original ordinary resource assertions and
new modern HTTP event pages pass after adoption. The existing passive snapshot
retains seven profiles and 21 public API modules; profile/unconfigured values are
unchanged while Session, DynamicRuntime and ToolEffects add lifecycle exports.
Host adapters recognize the new runtime `register_cancellation` context callback
without invoking it or adopting cancellation behavior. Model-facing resource and
event tools, independent explicit resource-source configuration and full recovery
acceptance remain separate work. No security or permission tests are run.

The official 1.10.48 cohort adds public sequential MCP resource scopes (#139),
staged child exports and offline journal loading, native image invocation context,
plugin-wait retirement, and Headless Code Mode. The active passive capture keeps
seven profiles and 21 API modules. It reads declared descriptor revisions when
constructing capture authority: imagegen now has revision 2 and non-retryable,
non-read-only effect semantics; other tools retain their declared contracts.
Three dedicated ordinary scope cases use actual native invocations and two real
resource-only HTTP clients. These qualify the public upstream API. Production
resources now use `MCPResources`, the same native descriptors and a Session-owned
DynamicRuntime, with start-only Synapsis support returning actual caller-owned
handles. Independent `mcp_resource_source_ids` defaults to `[]`; omitted-server
lists visit all selected UUIDs in saved order. Explicit UUID continuation and raw
URI reads retain complete per-source JSON/structured envelopes, without media
adaptation or dereferencing. Dedicated support and Worker/provider/Concord/replay
fixtures are separate from the upstream scope qualification; executed outcomes
and remaining limits live in the implementation plan. Cancellation/recovery
acceptance remains separate. Existing exact host context lists now recognize the
runtime's `cancellation_coordinator` field without invoking it. Native headless
host integration remains separate. The timer/generator race in #140 was not
exercised or bypassed in that 1.10.48 adoption. Official 1.10.49 now includes the
fix, with no public API or descriptor change. Its five-package adoption and
dedicated ordinary Headless/Deno verification are recorded in the plan. Public
ordinary execution does not deterministically force the old internal interleaving;
the upstream scheduling regression is source-reviewed only. Source/package adoption
does not install a production Headless or image-job consumer. No security or
permission tests are run.

Official 1.10.50 adds provider-independent `host_context` (#143) and fixes native
resource retirement and post-hook Code Mode cancellation (#141/#142). The latter
fixes are source-reviewed only. Existing host context lists recognize
`register_code_mode`; SessionAdapter retains the provider-time catalog resolver
and supplies that same resolver through host_context for the original tool hooks.
The dedicated ordinary host-context fixture uses original Profiles/Policy and
native clock/shell/Deno with real Store ACKs, ordered continuation and normal
Session cleanup. It establishes neither a production scheduled-script consumer
nor arbitrary host-descriptor Headless metadata compatibility. The seven-family
passive snapshot, ordinary scoped results and evidence limits are recorded in
the implementation plan. No security, permission or cancellation tests are run.

Official 1.10.51 publishes the native one-page Events bridge (#144). The passive
capture uses an inert `list_events/2` declaration to include the original
`mcp_events` descriptor; it starts no requests and installs no production adapter.
Dedicated ordinary fixtures use the public typed client identity, controlled
wait and single retirement, then the actual `DynamicRuntime.event_request/2`
helper under Conversation and nested Headless Code Mode. Real Store/Concord ACKs
gate dispatch and result consumption; complete raw pages and normal Deno/Session
closure are checked. The helper consumes its retirement receipt internally;
receipt fields are qualified separately by the public raw-client fixture, never
by retiring a native request twice. Events visibility remains an independent
unresolved host choice; resource UUIDs do not select Events. No production Events
adapter, subscription or automation is installed. The separate new
`Goal.settle_host_admission/4` API (#145) has no Synapsis consumer. Failure,
cancellation and recovery branches remain source-reviewed only. Source adoption,
ordinary verification and remaining limits are recorded in the plan.

Historical tooling verification used `node --test scripts/openclaw/capture-contracts.test.mjs` and
`python3 scripts/openclaw/verify-baseline.test.py` for the capture tooling tests.
It also used `MIX_ENV=test devenv shell --no-tui -- mix test
apps/synapsis_agent/test/synapsis/agent/tools/ --exclude upstream_blocker` for native snapshots, capability
assessments, catalog/binding composition, and isolated host policy and approval hooks.
These local checks use trusted host sidecars. Dynamic `:ask` can use native
Conversation interactions when an explicit trusted approval context is supplied;
otherwise it remains denied with an approval-required reason. The current Worker
integration and trusted UI/API operator path have scoped fixture evidence; see the
implementation plan for exact boundaries. The native integration has been restarted in the local development process;
saved version-0 selections remain unmigrated. Local service health does not prove
reliable browser loading, complete reference parity, or installed CLI acceptance. Live credentials and full device/browser
integration remain unverified. Historical child interruption and dynamic catalog
failures are linked to [backplane#99](https://github.com/gsmlg-opt/backplane/issues/99),
[backplane#97](https://github.com/gsmlg-opt/backplane/issues/97), and
[backplane#101](https://github.com/gsmlg-opt/backplane/issues/101). Their fixes were
consumed in 1.10.37; production acceptance and any retained assertions remain
separate from issue closure and this limited 1.10.38 verification. Bounded
revision-fenced permission writes and migration await
[concord#107](https://github.com/gsmlg-dev/concord/issues/107). The excluded
assertions remain in the test sources; their recorded failures were not rerun in
this batch. Exclusion does not complete their acceptance
criteria or prove production dynamic wiring.


### Browser screenshot normalization oracle

Run the complete pinned Browser2000px/5MiB normalizer, annotation scaling, and
independent model-image1200px/5MiB sanitizer with the published Rastermill0.4.0
codec used by the tool host:

```sh
node --experimental-vm-modules scripts/openclaw/capture-browser-images.mjs \
  --source /path/to/pinned/openclaw \
  --output packages/tool-host/test/fixtures/browser-image-normalization.json
```

Every loaded source is checked byte-for-byte against488631c before type stripping.
The fixture records13 fully executed source modules and7 provenance-only files,
explicit process/logging/system resolver facades, and six successful deterministic
PNG vectors with input/saved/inline hashes, byte counts, MIME, dimensions and saved
annotation coordinates. The actual pinned local processor factory and Rastermill
internal Photon codec execute; the worker orchestration facade does not claim the
reference worker pool, native fallback, Browser routes/storage, provider traffic or
full factory/action/assembly. The tool-host functional tests replay these frozen
observations and independently exercise real managed/remote captures. No security,
permission, malformed-image or mixed-suite tests are included.

### Browser AI ARIA YAML body oracle

```sh
node --experimental-vm-modules scripts/openclaw/capture-browser-aria.mjs \
  /path/to/pinned/openclaw \
  packages/tool-host/test/fixtures/browser-aria-yaml.json
```

This executes four complete pinned TypeScript modules after type stripping and
verifies every source against the fixed Git commit. SDK imports redirect to their
complete pinned implementation modules; there are no behavioral facades. Twelve
synthetic successful vectors capture rendered-line depth/interactive/compact
shaping, scalar/key quoting, nested properties and main/frame source refs. The
compact vector explicitly records omission of unnamed structural lines including
inline scalar text. Slash-name vectors cover the pinned lexical parser; they do
not claim ordinary Playwright AI mode emits those names.

The fixture proves body shaping. Browser routes, final output budgets/truncation
markers, URL/delta finalization and full assembly are outside this oracle. Scoped
real Browser tests separately capture exactly one public AI YAML string and
compare ordinary text after mapping formatter-owned source refs to host aliases;
public `getByRef` retains the original exact main/frame Element handles. The
public YAML formatter omits accessible names over900 UTF-16 units; no second JSON
capture restores them. Existing local line/character/byte budgets remain.

### Browser scoped native-role rendering oracle

```sh
node --experimental-vm-modules scripts/openclaw/capture-browser-role.mjs \
  /path/to/pinned/openclaw \
  packages/tool-host/test/fixtures/browser-native-role-format.json
```

This executes the complete pinned `cdp-role-snapshot.ts` through its public
`snapshotRoleViaCdpSession` entrypoint, including private duplicate-ordinal
assignment before tree rendering. Nine complete modules execute after type
stripping; three platform modules have explicit, provenance-only facades for
synthetic caller-owned CDP sessions, disabled DOM enrichment and unused socket
assembly. Every recorded source is checked against the exact reference commit.

Twelve ordinary scoped AX vectors cover input-array versus DFS ordering,
depth/interactive/compact filtering, transparent and ignored roots, iframe leaves,
native states/values, and true-empty markers. Host ref spelling is normalized only
through retained backend identity. `[nth=N]` is informational; actions keep exact
ElementHandles. The ordinal also supplies the existing delta identity. Empty-tree
markers share host budgets; nonempty output truncated to zero stays blank.

The oracle does not execute Chromium, Browser routes, page-wide cursor discovery,
iframe enrichment/recursion, URL discovery or full plugin assembly. Local compact
output preserves leading depth indentation where the pin's final trim removes it;
the compact comparison vector starts with a visible root. Host output budgets,
delta/URL/label finalization and cleanup remain separate functional checks. This
evidence does not establish whole Browser reference equivalence.

### Perplexity Search API and Sonar source observations

The dedicated exporter evaluates unchanged complete Perplexity factory/shared/runtime
modules, their recorded pure config/cache helpers, and the generic search-output
normalizer from the same pinned checkout. Use Node 24.22.1 (the supported runtime
used for this capture) and the checkout's existing TypeBox 1.3.37; do not install
or refresh dependencies as part of capture.

```sh
node --experimental-vm-modules --disable-warning=ExperimentalWarning \
  scripts/openclaw/capture-perplexity-search.mjs \
  /path/to/pinned/openclaw /tmp/perplexity-search.json

OPENCLAW_PERPLEXITY_SOURCE=/path/to/pinned/openclaw \
OPENCLAW_PERPLEXITY_FIXTURE=apps/synapsis_agent/test/fixtures/openclaw/488631c/perplexity-search.json \
  node --experimental-vm-modules --disable-warning=ExperimentalWarning \
  --test scripts/openclaw/perplexity-search-functional.test.mjs
```

The standalone fixture records actual runtime metadata, both dynamic schemas,
raw arguments, successful request bodies, provider results, normalized public
results, cache sequences, and ordinary citation/UTF-16 budget observations.
`publicUnwrappedResult` removes only the existing prose framing; consumers must
explicitly omit the stamp and elapsed-time fields when comparing host output.
Source and executable hashes, complete-tree checks, generated facades, synthetic
bindings and actual TypeBox dependency files remain separate evidence classes.

HTTP, JSON parsing, header policy, deadline, literal credential and logger services
are explicit fixture boundaries. Header policy returns undefined so the unchanged
runtime supplies its own default expression; this does not execute production
policy. No real network, credential discovery, security/permission/auth/TLS,
refusal or mixed suites are involved. Public schemas and successful callbacks do
not prove plugin registration, full runtime assembly, all reference actions,
native Worker persistence or real-provider readiness. This standalone observation
does not promote the canonical capture or any whole-reference capability gate.

The host's explicit `search_api`/`chat_completions` mode and trusted `base_url`
adaptation, public answer projection, and separate verification limits are described
in `docs/designs/2026-10-27-native-web-search.md`.

### Browser action timing arithmetic

`capture-browser-timing.mjs` executes the complete unchanged pinned `act-policy.ts`
and six actual pure dependency modules. It records15 ordinary request-budget
vectors, including serial nested waits, shallow standalone defaults, repeated wait
conditions, phase clamps,75,005,000ms allocation and conservative timer saturation.
These are arithmetic observations; no long-duration Browser operation is run.
Use exact Node24.22.1 and the existing fixed checkout, without installing packages:

```sh
node --experimental-vm-modules --disable-warning=ExperimentalWarning \
  scripts/openclaw/capture-browser-timing.mjs \
  /path/to/pinned/openclaw /tmp/browser-timing.json

OPENCLAW_BROWSER_TIMING_SOURCE=/path/to/pinned/openclaw \
  node --experimental-vm-modules --disable-warning=ExperimentalWarning \
  --test scripts/openclaw/browser-timing-functional.test.mjs

node --test packages/tool-host/test/browser-timing-functional.test.mjs
```

The fixture records raw/prepared input before and after execution. Preparation
pairs explicitly encode the source-reviewed shallow model-local60,000ms default;
the complete `browser-tool-dispatch.ts` is provenance-only and is not claimed as
executed. Batch children retain their8,000/20,000ms phase defaults. SDK imports
redirect to actual complete pure implementation modules; all source bytes match
the fixed pin, and all58,558 tracked blobs are checked before and after capture.
The source10 provenance-only files and7 executed whole modules stay distinct.

The host's top-level `timeout_ms` is an explicit outer-watchdog override, separate
from leaf `request.timeoutMs` phase values (normally under `args.request`). Its helper privately injects the standalone
default once, gives each real Playwright phase an explicit timeout and preserves
the existing operation/cancellation/cleanup owner. Existing host wait durations,
ref waits, selector-fill fields, targeted presses, two-scroll drags and explicit
slow-type delays remain supported; their conservative extra budgets are host
adaptations and are not added to the exact-source arithmetic fixture. Async
evaluate uses the reference-specific inner Promise deadline rather than a timer
around every batch child. See `docs/designs/2026-10-26-browser-native-host.md` for
the native deadline clipping and profile/default contract.

Production driver/navigation policy/rechecks, full tool/plugin/runtime assembly,
human-wait behavior and full Browser equivalence are not executed by this oracle.
The dedicated helper tests execute short ordinary Chromium success paths and
observe actual phase options, separate from source arithmetic and native
Worker/Concord verification. No canonical capture or whole-reference gate is
promoted, and no security/permission/auth/TLS/refusal/mixed/real-provider suite is
run.

### MCP Events factory and one-page Gateway catalog

The standalone exporter executes the complete unchanged pinned
`extensions/mcp-events/index.ts` tool factory/create/execute and
`src/gateway/server-methods/mcp-events.ts` handler, including its private
`projectCatalog`. The actual plugin-entry/lazy helper, capability types and record
normalizers execute as whole modules. Use the existing fixed Node 24.22.1 runtime
and checkout; this capture needs no dependency installation:

```sh
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node \
  --experimental-vm-modules --disable-warning=ExperimentalWarning \
  scripts/openclaw/capture-mcp-events.mjs /tmp/openclaw-488631c \
  apps/synapsis_agent/test/fixtures/openclaw/488631c/mcp-events.json

/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node \
  --experimental-vm-modules --disable-warning=ExperimentalWarning \
  --test scripts/openclaw/mcp-events-functional.test.mjs
```

Nine ordinary vectors preserve the public schema, raw callback/context inputs,
Gateway requests/responses, one discovery then one list request per invocation,
exact text JSON and details, empty/ordered/duplicate webhook descriptors,
boolean/object schemas, opaque Unicode pagination, raw server/cursor whitespace,
long descriptions and 1000 valid descriptors. Pagination requires another explicit
tool invocation; an unconsumed nextCursor does not trigger traversal. The source
filters descriptors by delivery containing `webhook` and retains delivery in the
projected result. Its documented page bounds are 1000 entries and 1MiB raw JSON
UTF8 before projection. The 1000-entry success vector does not establish transport
or storage capacity at 1MiB.

Description projection is exactly JS `.slice(0,4096)` in UTF16 units. A valid emoji
crossing the boundary produces a lone high surrogate; the actual tool's
`JSON.stringify` text preserves its escaped representation. The capture does not
silently replace this behavior with scalar-safe truncation.

The fixture separates six executed whole source modules from 17 provenance-only
sources, records source/executable/exporter/harness/runtime hashes and every
generated per-import facade, and checks all 58,558 pinned tracked blobs before and
after capture. SDK record aliases resolve to their actual whole source module;
the VM's `Buffer.byteLength` and `node:util.isDeepStrictEqual` use real Node
builtins. Registration API/context, configured-agent resolution, connection,
request transport and stable caller/runtime bindings are explicit synthetic
facades. Deferred config/error/service imports are recorded and remain uncalled.

This is tool-only registration with a fixture Gateway descriptor. Production
plugin enablement/config parsing, required `callbackOrigin`, full plugin/runtime
activation, actual transport/authority behavior and callback HTTP handling are
not established. The tool does not subscribe or schedule; the subscription
service, shared scheduler and durable ingress do not execute. Official MCP
1.10.46 supplies the public Events API requested by
[backplane#132](https://github.com/gsmlg-opt/backplane/issues/132), with separate
ordinary HTTP adoption evidence. Official 1.10.51 adds the native bridge (#144),
with separate ordinary Conversation/Headless qualification. Production Synapsis
event-tool wiring and source visibility remain unimplemented; no private RPC or local transport workaround
is added here. No security, permission, auth, TLS,
negative, mixed or real-provider tests run. This standalone fixture does not
promote canonical capture/schema recipes or any whole-reference completion gate.

### OpenAI audio transcription request and JSON result

The standalone exporter runs the complete unchanged pinned
`extensions/openai/audio-transcription.ts` direct callback and
`src/media-understanding/openai-compatible-audio.ts` adapter. The complete shared
multipart/transport helpers, buffer-to-Blob helper, pure base URL normalizer and
provider JSON decoder/object wrapper execute with their actual pure dependencies.
Use the existing fixed Node 24.22.1 runtime; no dependency installation is needed:

```sh
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node \
  --experimental-vm-modules --disable-warning=ExperimentalWarning \
  scripts/openclaw/capture-openai-transcription.mjs /tmp/openclaw-488631c \
  apps/synapsis_agent/test/fixtures/openclaw/488631c/openai-transcription.json

/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node \
  --experimental-vm-modules --disable-warning=ExperimentalWarning \
  --test scripts/openclaw/openai-transcription-functional.test.mjs
```

Fifteen successful synthetic observations preserve raw inputs and input bytes,
actual native FormData field order, native File name/type/size/bytes, effective
multipart part MIME, request URL/method/timeout, raw response UTF8 bytes and JSON,
returned text/model, one POST and one release. Cases cover defaults and explicit
models, trimmed language/prompt, omitted blank hints, POSIX basename, AAC filename
mapping, omitted MIME, native MIME case folding, custom base URL, Unicode edge
trimming and interior preservation, successful silence, ignored query options,
a nonzero-offset Buffer view, and an initial raw JSON UTF8 BOM. The latter uses
the actual fatal TextDecoder followed by JSON.parse; it is separate from trimming
FEFF inside the transcript string. Native Blob snapshots bytes without decoding
or converting audio, including when the file name is mapped from AAC to M4A.

The actual generic adapter ignores its typed `query` map: it sends no query
parameters, `response_format`, temperature or timestamps. It reads successful
JSON with a string `text`, trims that string, and returns the resolved request
model, ignoring a response model field. Empty/whitespace-only text is successful
silence. The parser forwards its actual default **16 MiB response-byte bound**
and **30,000 ms chunk timeout**. The generic upload path has no input audio-byte
cap, and no text-character truncation is added. Ingress limits are separate.

The fixture records 19 executed whole modules and 22 provenance-only sources,
source/transformed executable/exporter/shared harness/runtime hashes, and exact
per-importer generated facades. All 58,558 pinned tracked blobs are checked
before and after capture. Native FormData serialization supplies the effective
part MIME; random multipart boundaries and File.lastModified are excluded from
deterministic evidence. Fresh independent captures match the frozen JSON exactly.

The successful policy facade invokes only the actual whole-source pure base
normalizer and supplies explicit empty headers and transport values. Transport
uses a supplied synthetic fetch callback returning a native successful Response;
no real network operation occurs. The lowest response reader is an explicit
Response.arrayBuffer fixture that records parser options: production bounded
streaming, chunking, timeout and overflow behavior remain unexecuted. Actual
credential/context/account resolution, header/transport policy, retry/failure
paths, provider/plugin registration, runtime assembly, ingress and transcription
quality are outside this capture. No security, permission, auth, TLS, negative,
mixed or real-provider tests run. Native Synapsis integration and whole P10
completion require separate evidence.


### Decisions tool factory, generic contract and positive callback

The standalone Decisions tool capture executes the complete unchanged pinned
`src/agents/tools/decision-tool.ts` factory and successful `execute` callback,
`decision-tool-contract.ts`, V1/V2 validation and compatibility, text-result
projection, model-setting resolver and model-reference helpers. Actual TypeBox
1.3.37 constructs the complete input and output schemas. The fixed Node runtime
is reused without installing dependencies:

```sh
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node \
  --experimental-vm-modules scripts/openclaw/capture-decision-tool.mjs \
  /tmp/openclaw-488631c \
  apps/synapsis_agent/test/fixtures/openclaw/488631c/decision-tool.json

/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node \
  --experimental-vm-modules --test scripts/openclaw/decision-tool-functional.test.mjs
```

Twelve positive observations retain complete tool name/label/description,
input/output schemas and network result-content marker, original arguments,
legacy conversion, all six generic result kinds, exact callback batch/options,
current selection, provider outcome/provenance and complete JSON content/details.
Cases include prepared metadata, manifest-snapshot metadata, default-role selection,
structured V2 JSON, runtime configuration reread, supplied text/JSON/image/list,
explicit choice and fractional score, box coordinates, sorted IDs, tag abstention,
scalar boolean zero with categorical metadata, optional confidence, provider metadata,
zero cost, units and raw usage. Actual source capability guidance and rubric hashing
execute; the reference `decision-v1-` prefix remains distinct from the accepted
Synapsis `synapsis-decision-v1-` semantic-map contract.

The runtime `evaluateDecisionV2Operation`/`completeDecisionEvaluation` import is an
explicit synthetic success facade. It records input/options, one evaluation and
completion ordering, and returns the supplied outcome. The actual Decisions
runtime, provider-host, billing and authority bodies are **not executed** here.
Runtime configuration, Agent lookup, metadata snapshot, available manifest list
and plugin registry are separate explicit input facades. The actual model-setting
resolver uses those supplied inputs; this does not validate the real configuration
loader, fleet lookup, plugin eligibility, provider registration or runtime assembly.
The synthetic model capability declarations do not prove any real provider supports
six kinds. OpenAI/OpenRouter provider-source and Synapsis native-worker evidence
remain separate.

The exporter records 13 complete executed modules, eight provenance-only files,
source/transformed executable/exporter/shared-harness/runtime hashes, generated
per-import facades, actual TypeBox package/file hashes, and the generated host
setup bytes. All 58,558 pinned tracked blobs are verified before and after capture.
Fresh capture must equal the complete frozen standalone JSON. No disabled,
invalid, error, cancellation, security, permission, auth, TLS, mixed or real-provider
tests run. This fixture does not promote canonical recipe counts, registration,
assembly, whole-reference or full-P6 completion gates.

## Browser snapshot queries

The independent query oracle executes the complete pinned
`extensions/browser/src/browser-tool.snapshot.ts` module and its
`executeSnapshotAction` export. Actual whole string/numeric normalization,
parameter readers, formatter ref parser/finalizer, role sets, constants,
UTF-16 slicing and text-result helpers execute. The exporter records all
source/transformed executable/exporter/shared-harness/runtime/generated-import
and host-setup hashes and checks all 58,558 tracked blobs before and after.

```sh
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node --experimental-vm-modules scripts/openclaw/capture-browser-query.mjs /tmp/openclaw-488631c packages/tool-host/test/fixtures/browser-query.json
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node --experimental-vm-modules --test scripts/openclaw/browser-query-functional.test.mjs packages/tool-host/test/browser-query-functional.test.mjs
```

Seventeen ordinary vectors cover case/Unicode/whitespace token matching,
preserved source line order and repeated tokens, raw node roles/names/values/
descriptions, successful no-match results, blank-query pass-through, query caps
including explicit zero, truncation markers, already-truncated sources,
filtered delta counts, lexical YAML refs and labeled snapshots. Matching applies
to the entire serialized line: `Sign IN` also matches a `Sign out` node whose
role is `InlineTextBox`, because that role supplies the `in` token. The retained
source/host comparison explicitly covers that case.

Lower Browser transport, configuration and image loading are synthetic success
inputs. The external-text envelope and sanitized prefix are explicit facades;
the latter calls the real surrogate-safe UTF-16 helper on ordinary text. The
actual security wrapper/sanitizer is not executed or tested. Source wrapping
still uses its real 16000 live-text constant and original query budget arithmetic
with a deterministic facade envelope. These inputs establish the original query
algorithm and ref/stat projection, not Browser runtime assembly, filesystem
image loading, registration, network, sanitizer or permission behavior.

The production host retains its existing native JSON result representation,
UTF-8/native-result budgets, monotonic `e`/`ax` aliases and private Element handles;
it adds no reference text envelope. Query text uses positive `maxChars` or 40000
otherwise; capture shaping remains separate, including raw capture ignoring
`maxChars`. Full wrapping/budget byte equivalence is not claimed. Results publish
the bounded matching `snapshot`, separate `summary`, pre-cap `matchCount`, current
`stats` and surviving public `refs`/`refCount`. Queried raw `nodes`/`nodeCount`
contain only surviving formatter refs. Raw stats count informational nodes too;
public `refCount` continues to count actionable handles. Blank query preserves
the ordinary result shape. Full private capture handles and the full-source delta
baseline remain unchanged; query does not define a new delta family. Labeled
images and annotations still describe the full finalized capture, while their
paired text serializes the filtered result. These are explicit host adaptations;
whole Browser/reference gates remain open.

## OpenAI direct image generation and edits

The dedicated image oracle executes the unchanged pinned
`buildOpenAIImageGenerationProvider(...).generateImage(req)`, complete
`image-generation-response.ts`, actual asset parser and sequential URL inlining.
Fifteen complete modules include the real base URL classifier, base64, numeric,
string/record normalization, MIME and Blob byte-range helpers. Three precise,
complete original source regions supply the configured base URL resolver,
closest-size geometry and generated-image download cap. Each projection records
its original byte offsets, source-region hash, exact generated prelude/source,
generated hash and transformed executable hash. It does not substitute a copied
expected sizing algorithm for source execution.

```sh
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node \
  --experimental-vm-modules scripts/openclaw/capture-openai-image-generation.mjs \
  /tmp/openclaw-488631c \
  apps/synapsis_agent/test/fixtures/openclaw/488631c/openai-image-generation.json

/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node \
  --experimental-vm-modules --test scripts/openclaw/openai-image-generation-functional.test.mjs
```

Twenty-two ordinary successful vectors retain original requests, normalized JSON
or ordered native multipart fields/files, complete output bytes as base64, MIME,
filenames, revised prompts, chosen model, usage/geometry metadata, URL download
order and release/read receipts. Cases cover explicit models/count, default and
legacy/native/flexible/auto sizes, 2.5 `xhigh`/`max`, PNG/JPEG/WebP, compression only
for JPEG/WebP, provider background precedence, moderation/user, single/multiple
edit inputs, POSIX basename/default filenames, native Blob MIME semantics,
ordered inline/URL/mixed results, trimmed revised prompts, zero/nested/absent
usage, custom endpoint prefixes and Azure generation/edit deployment endpoints.
Azure uses the pinned default API version or an explicit synthetic per-vector VM
environment value; no real process environment is discovered or changed.

Lower HTTP, key lookup, configuration/account/profile/policy and bounded-reader
bodies are explicit synthetic success facades with source attribution. Native
`Response.json`/`arrayBuffer` records the caller-supplied limits; production reader
bounds, retries, timeout enforcement and network transport are unexecuted. The
actual helper supplies a 64 MiB image download cap and response envelope formula
`ceil(64 MiB * requested count * 4/3) + 1 MiB`. Native FormData/Blob/File supplies
ordered fields, MIME and bytes; random multipart boundaries and File timestamps
are omitted. Image bytes are protocol fixtures, with no codec or image-quality
claim. No `isConfiguredAsync`, OAuth/Codex, credential discovery, registration,
security, permission, TLS, negative, mixed-suite or real-provider checks run.

The source-only `source-only-transparent-reroute` observation has
`hostComparable: false`: pinned public `gpt-image-2` plus transparent background
changes to `gpt-image-1.5`. Synapsis preserves the explicitly selected model and
requires a compatible selection before HTTP. The other 21 rows are ordinary host
comparison inputs; this adaptation is not counted as literal host equivalence.

All 58,558 tracked reference blobs are checked before/after execution, alongside
source/executable/exporter/shared-harness/runtime/generated-import hashes. Fresh
independent capture must equal every frozen JSON field. This is inactive direct
provider groundwork: tool/catalog/config enablement, persisted images/media,
task lifecycle, delivery, real-provider behavior and full P10/reference completion
remain separate work and existing acceptance gates are unchanged.

## Google direct image generation and edits

The dedicated Google oracle executes the unchanged pinned 214-line
`extensions/google/image-generation-provider.ts` and its real metadata, model
aliases, size/string helpers, Google Base64, inline asset parser and URL/HTTP
wrappers. Nineteen whole modules and one exact complete configured-image-cap
source region are recorded with original, generated and executable hashes.
The complete `provider-json-post` module runs its actual `finally` release.

```sh
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node \
  --experimental-vm-modules --disable-warning=ExperimentalWarning \
  scripts/openclaw/capture-google-image-generation.mjs /tmp/openclaw-488631c \
  apps/synapsis_agent/test/fixtures/openclaw/488631c/google-image-generation.json

/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node \
  --experimental-vm-modules --disable-warning=ExperimentalWarning \
  --test scripts/openclaw/google-image-generation-functional.test.mjs
```

Thirty-eight ordinary successful vectors retain original inputs, exact JSON
requests, raw response JSON, ordered image bytes/MIME/filenames, selected model,
source read budgets and one POST/release. They cover all nine model aliases and
a retained Google prefix, five size mappings and size tiers, aspect/resolution
precedence, one/five ordered edit inputs, ignored count and unsupported controls,
candidate flattening, camel/snake inline and MIME precedence, MIME parameters,
PNG fallback, padded/unpadded/URL-safe Base64, ordinary official-root
normalization (including uppercase hostnames) and a larger configured media cap. All returned images survive;
declared maxCount four does not truncate the actual direct provider's response.
Only images/model are returned; text, usage and extra provider fields are not
projected. Small opaque bytes establish protocol preservation, not image quality.

The source-only omitted-model/timeout row retains the real default
`gemini-3.1-flash-image` and 180000 ms. The host adapter requires an explicit
model and finite positive timeout. Its other 37 rows compare full builder plans
at the original official root, then use a separately substituted local Gaoxy root
for actual successful POST/result checks. This transport seam does not claim the
source accepts localhost. Host input admission of at most five images and the
default 64 MiB per-image predecode bound are separate from direct source
enforcement. The source raw JSON cap uses four declared results regardless of
count: `ceil(max(64 MiB, configured image bound) * 4 * 4/3) + 1 MiB`.

Credential/configuration/request-policy/attribution and lower HTTP/status/read
bodies remain explicit successful facades. The native Response JSON reader
records source limits; production bounded streaming, timeouts and failure cleanup
are unexecuted in the oracle. Empty attribution avoids impersonating OpenClaw's
client identity. All 58558 tracked blobs, pin, modes and symlinks are checked
before/after, with exact import/facade/exporter/shared-harness/runtime receipts;
two fresh captures must equal every frozen field. No real account readiness,
`isConfiguredAsync`, security, permission, auth/TLS, negative, mixed, live-provider,
failure/cancel/crash or recovery tests run. The additive host protocol remains
inactive: saved selection, native jobs/tools, media storage/delivery and complete
P10/reference acceptance require separate evidence. Executed host outcomes and
limits are recorded in the implementation plan.

## xAI direct image generation and edits

The dedicated xAI oracle executes the unchanged pinned
`extensions/xai/image-generation-provider.ts`, the shared complete
`src/image-generation/openai-compatible-image-provider.ts` factory, and the
actual image asset parser and ordered URL inliner. Metadata/constants, configured
media caps and operation deadlines retain exact source regions with explicit
preludes and provenance. Generic key/configuration/policy and lower successful
HTTP/status/body-reader facades remain identified service boundaries.

```sh
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node \
  --experimental-vm-modules --disable-warning=ExperimentalWarning \
  scripts/openclaw/capture-xai-image-generation.mjs /tmp/openclaw-488631c \
  --out apps/synapsis_agent/test/fixtures/openclaw/488631c/xai-image-generation.json

/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node \
  --experimental-vm-modules --disable-warning=ExperimentalWarning \
  --test scripts/openclaw/xai-image-generation-functional.test.mjs
```

Forty-one ordered success vectors include 40 complete host-comparable plans and
HTTP/result checks, with one explicit source-only default-model/timeout row.
The oracle executes nine whole modules and four complete original source regions;
all 58558 tracked blobs, modes and symlinks are verified before and after capture.
Two fresh captures must equal every frozen field.

The protocol uses one JSON POST to images/generations or images/edits, requests
b64_json, and clamps outgoing positive count to four. It sends only supported
aspect ratios and trimmed lowercase resolution; size, quality, output format,
background and provider options are ignored. One reference uses image, two or
three use ordered images. A trimmed input URL takes precedence over supplied
bytes; otherwise exact bytes and trimmed MIME (default PNG) form a data URL.
Model and prompt retain the source's distinct trim/exact semantics.

All inline results survive even if there are more than four. Up to four response
URL entries are downloaded sequentially and merged in original result order.
Inline MIME is trimmed or defaults to PNG without sniffing; download MIME is the
lowercase Content-Type base. Asset filenames and optional revised prompts follow
the original parser. Only images/model are returned; outer usage and metadata do
not become result fields. Source default model and 600000 ms timeout remain
source-only; the host requires explicit model/timeout and key/base URL.

The raw JSON budget is calculated from four metadata results and a 64 MiB floor,
independently of outgoing count. Host per-image bounds before inline decoding
are a separate admission boundary. A linked HTTP owner and one finite absolute
deadline cover POST, sequential downloads and bounded bodies, using shared
Req.Finch without retries or polling. Original-root builder comparison precedes
any separate local Gaoxy transport substitution, including response download
URLs; it does not prove real network/account or policy equivalence.

This is an inactive standalone image protocol, distinct from xAI video. It does
not register a model tool, save a provider, create jobs, store media or activate
completion delivery. Opaque fixture bytes prove protocol preservation, not codec
or visual quality. No security, permission, auth/TLS, negative, mixed, live-provider,
failure, cancellation or crash execution tests run. Source capture, exact matrix,
local checks and their limits are recorded in the implementation plan.

### Absolute and interval schedule computation

`capture-schedule-computation.mjs` executes the pinned
`src/cron/schedule.ts:computeNextRunAtMs` with all eight complete source modules
used by its absolute-time and interval paths. Twelve positive vectors make twenty-four
actual helper calls, covering explicit-offset and offsetless UTC timestamps,
epoch-millisecond strings, date-only values, fractional milliseconds, valid 24:00,
future anchors, exact interval boundaries and subsequent
advancement. Each run verifies the complete tracked source tree before and after;
a fresh capture must exactly reproduce the frozen fixture.

```sh
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node \
  --experimental-vm-modules scripts/openclaw/capture-schedule-computation.mjs \
  /tmp/openclaw-488631c \
  apps/synapsis_agent/test/fixtures/openclaw/488631c/schedule-computation.json

/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node \
  --experimental-vm-modules --test \
  scripts/openclaw/schedule-computation-functional.test.mjs
```

The Croner imports are uninvoked throwing bindings, with an empty invocation audit.
No cron branch, job service, one-shot lifecycle, tool factory, eligibility or runtime
assembly executes. The pure helper returns a strictly future occurrence; it does
not prove how persisted overdue work, manual runs or terminal outcomes are handled.
In particular, an unfinished past one-shot remains due in the reference service,
and interval terminal scheduling can prefer actual execution start plus its period.
Production integration and its evidence are recorded separately in the P6 plan.


### Independent video tool factory, list and status

`capture-video-tool.mjs` executes the complete pinned video tool factory, action
module and shared dispatcher, with the original catalog/capability/status owners
and actual TypeBox 1.3.37. Two factory cases retain the complete descriptor/schema
with and without audio references; generated-audio `audio` remains in both. Six
ordinary action cases cover empty/static provider lists and idle, queued, running
and running-preferred status. `list` describes providers/models; `status` describes
the current session's active video work, without a task-ID/history API.

```sh
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node \
  --experimental-vm-modules scripts/openclaw/capture-video-tool.mjs \
  /tmp/openclaw-488631c \
  apps/synapsis_agent/test/fixtures/openclaw/488631c/video-tool.json

/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node \
  --experimental-vm-modules --test scripts/openclaw/video-tool-functional.test.mjs
```

The 35 whole source modules, 58,558 tracked blobs before/after, transformed bytes,
import bindings, generated facades, runtime and actual dependency files have
explicit provenance. Ten positive tests independently assert full literal schemas
and action results, then compare complete fresh captures to the frozen fixture.
Tool context, model configuration, provider registry/configured availability and
same-session/same-agent operation arrays are supplied inert success data. The
model-config facade makes no normalization claim. No task registry lifecycle,
generation, completion queue, persistence, network, authentication or permission
implementation executes. The capture is independent groundwork; it does not
satisfy canonical factory/registration/assembly gates or install a native tool.
The inactive xAI provider adapter and future durable video delivery remain
separate implementation boundaries. Full P10 acceptance remains open.


### Independent Firecrawl search callbacks

`capture-firecrawl-search.mjs` executes the whole fixed-488631c plugin registration,
paid/free generic factories, dedicated `firecrawl_search` callback and shared client.
The 56 executed modules, 26 provenance-only modules, actual TypeBox 1.3.37/Node
24.22.1 and all 58,558 tracked blobs before/after have explicit provenance. Its
41 groups contain 47 successful callbacks, 43 with an actual fixture HTTP request.

```sh
/tmp/synapsis-openclaw-capture-runtime/node_modules/.bin/node \
  --experimental-vm-modules scripts/openclaw/capture-firecrawl-search.mjs \
  --source /tmp/openclaw-488631c \
  --output apps/synapsis_agent/test/fixtures/openclaw/488631c/firecrawl-search.json

env OPENCLAW_FIRECRAWL_SEARCH_FIXTURE=apps/synapsis_agent/test/fixtures/openclaw/488631c/firecrawl-search.json \
  /tmp/synapsis-openclaw-capture-runtime/node_modules/.bin/node \
  --experimental-vm-modules --test scripts/openclaw/firecrawl-search-functional.test.mjs
```

Eleven positive checks cover defaults, paid/free and dedicated metadata, all normal
knobs, envelope priority, empty optional field fallbacks/full timestamps, Unicode
budgets and actual shared cache behavior. Original frames/results remain complete;
explicit unframing removes only reference Web Search frames and portable comparison
omits the externalContent stamp. Generic normalization is the actual source helper.
HTTP/Response.json, literal config and clock are documented successful facades;
production network, bounded parser, endpoint policy, timers and secret discovery
are unexecuted. Raw callback numeric-string/camelCase acceptance differs from the
host's integer/snake_case schema. Whole reference assembly/action gates, complete
WHATWG/sanitizer equivalence and real provider acceptance remain unverified.
Actual Provider/Core/native Worker integration is recorded separately in the plan.

### Independent Tavily search callbacks

`capture-tavily-search.mjs` executes fixed-488631c whole plugin registration,
generic provider factory, dedicated `tavily_search` callback, client/readers/cache,
wrappers and the actual public normalizer. The 40 groups record 53 successful
callbacks, 46 fixture HTTP requests and seven cache hits; 41 whole modules execute,
17 are provenance-only. Actual TypeBox 1.3.37/Node 24.22.1 and all 58,558 tracked
source blobs before/after have explicit provenance.

```sh
/tmp/synapsis-openclaw-capture-runtime/node_modules/.bin/node \
  --experimental-vm-modules scripts/openclaw/capture-tavily-search.mjs \
  --source /tmp/openclaw-488631c \
  --output apps/synapsis_agent/test/fixtures/openclaw/488631c/tavily-search.json

env OPENCLAW_TAVILY_SEARCH_FIXTURE=apps/synapsis_agent/test/fixtures/openclaw/488631c/tavily-search.json \
  /tmp/synapsis-openclaw-capture-runtime/node_modules/.bin/node \
  --experimental-vm-modules --test scripts/openclaw/tavily-search-functional.test.mjs
```

Eleven positive checks include a fresh complete capture and exact fixture equality.
Original framed results and dedicated jsonResult remain complete; portable fields
remove only declared exact framing/stamp differences, preserving provider whitespace.
Generic normalization uses the actual source helper. Raw numeric-string readers,
source `max_results` versus host `count`, and source generic schema20 versus host10
are explicit adaptation boundaries. Source-effective typed replay compares all 46
HTTP bodies and complete portable maps in Core; actual native Worker evidence is
separate. HTTP/Response.json/literal config/clock are successful facades, with no
production network/parser/policy/timer/secret-discovery execution. Whole assembly,
complete WHATWG/sanitizer/wrappers and live provider behavior remain unverified.

## Ordinary ElevenLabs speech

`capture-elevenlabs-speech.mjs` executes the complete pinned speech factory and
nine complete helper modules after TypeScript erasure. Thirty-one successful
callbacks cover actual nested raw config resolution, defaults, individual voice
setting overrides, model aliases, seed/latency bounds, language/normalization,
file/note formats and authored Unicode text. Each observation retains the full
source request/result, provider metadata, unchanged inputs and exactly one
synthetic HTTP release. The source advertises models independently of effective
aliases and accepts custom model strings.

```sh
/tmp/synapsis-openclaw-capture-runtime/node_modules/.bin/node --experimental-vm-modules \
  scripts/openclaw/capture-elevenlabs-speech.mjs /tmp/openclaw-488631c \
  apps/synapsis_agent/test/fixtures/openclaw/488631c/elevenlabs-speech.json
/tmp/synapsis-openclaw-capture-runtime/node_modules/.bin/node --experimental-vm-modules \
  --test scripts/openclaw/elevenlabs-speech-functional.test.mjs
```

The harness verifies every tracked source blob before/after and records complete
module, transformed executable, import and wiring provenance. Export facades
only re-export original helpers. Secret/profile/environment resolution, network
policy, HTTP transport and the binary reader are declared synthetic boundaries;
production reader MIME/16MiB checks, deadlines and cleanup are not executed.
The eagerly evaluated profile fallback is counted even with a fixture key.
Streaming, telephony, listVoices, directives, Talk, plugin registration and runtime
assembly remain unexecuted. Fresh capture equality and independent literal
expectations are checked in the nine positive Node tests.

Host positive checks compare all31 complete request maps and all31 actual local
HTTP requests and returned opaque byte/metadata maps. Native TTS publishes only
MP3/Opus/WAV, normalizing their storage family while the adapter retains vendor
format tokens. PCM/ulaw/alaw/unknown formats do not imply native media support.
The source callback evidence neither upgrades canonical whole-reference gates
nor establishes real-provider acceptance.


## Tool search controls and native publication

`capture-tool-search-controls.mjs` executes the fixed-488631c control factories
and actual search runtime, catalog, request, ranking, index, config and text/schema
helpers. It records the original `tool_search`, `tool_describe` and
`dispatch_action` descriptors and successful callbacks. MCP identities,
instructions, target executors and service context are supplied fixtures; their
binding and effect receipts distinguish those inputs from executed source logic.
The target callbacks do not establish a production MCP connection.


```sh
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node --experimental-vm-modules \
  scripts/openclaw/capture-tool-search-controls.mjs /tmp/openclaw-488631c \
  apps/synapsis_agent/test/fixtures/openclaw/488631c/tool-search-controls.json
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node --experimental-vm-modules \
  --test scripts/openclaw/tool-search-controls-functional.test.mjs
```

Twenty-one ordinary vectors cover exact names/IDs (including a stopword name),
scalar defaults/positive overrides, ordered scalar-plus-batch queries, real compact
schema hints, full optional output schema and MCP instructions, and six successful
argument aliases with one target effect and complete image/JSON envelopes. The
harness evaluates 64 whole pinned source modules and 371 original TypeBox modules;
two source-record regions retain complete metadata/control-marker declarations.
Eleven tangential source files are provenance-only. The whole 58,558-blob tree is
checked before/after, including modes and symlinks, and all executable/exporter/
helper/binding identities are recorded. The two fresh captures in the independent
Node suite must each equal the frozen fixture.

Absent runtime config, stable plugin context, absent hooks/swarm scope and terminal
presentation/result-bookkeeping services are explicit successful facades. Actual
MCP metadata binding/classification, Runtime search/describe/call, scheduling and
result processing execute unchanged. MCP target callbacks are supplied effects;
core dispatch is unexecuted because its dynamic schema-validator import is outside
the offline loader. Core full schema/output metadata are observed through assembly
and describe. Only configured tools mode is exercised; directory mode is linked.
Ordinary complete result text includes source framing with recorded deterministic
marker bytes; this does not establish cryptographic, policy or network behavior.

The native host uses the accepted explicit `deferred_tool_names` list (default
empty), original Backplane catalog publication, original descriptors and the
existing direct/nested dispatcher. It does not introduce tools merely to match
reference names. The dedicated ordinary
`native_discovery_schema_functional_test.exs` observes a real Worker and local
Gaoxy Responses requests: full literal nested MCP input schema and Unicode
multiline description, the issued Decisions schema/description and unchanged
exec custom grammar appear after committed publication at revision 2. The
original deferred direct-model-only Decisions backend and MCP backend each
execute once, and positive `ALL_TOOLS` metadata, checkpoint/adoption, model
results, Part JSON and durable Concord projections retain their actual contents.

| Reference control | Existing native mapping and remaining difference |
| --- | --- |
| `tool_search` | Scalar native search stages selected deferred candidates; the next committed request exposes them. Reference searches its effective catalog, promotes exact names/IDs and supports ordered grouped batch searches and compact schema/source hints. The native lexical algorithm and discovered-only lifecycle remain distinct. |
| `tool_describe` | Publication automatically sends complete input schema/description or custom grammar to the next model request. Independent exact describe, optional output schema, source identity and full MCP instructions are not established by that path. Code Mode metadata is a compact directory. |
| `dispatch_action` | Published original identities execute directly or through the existing native nested dispatcher. Reference selector/argument aliases and `{tool,result}` envelope remain an explicit adaptation difference; no extra executor is introduced. |

These are partial evidence and semantic comparisons. Source callback capture,
native successful local HTTP behavior, real-provider acceptance and complete
reference factory/action/assembly gates remain distinct. Optional output schema
is not blindly forwarded as a provider field. No production selection, dependency,
config or policy changes are part of this batch.

The subsequent inspection169 implementation adds explicitly selectable,
default-off `synapsis::tool_describe`. Its one required `tool_name` is an exact
canonical selected name. Before native deferred publication, Profiles freezes
public metadata for all selected issued tools, including deferred tools and the
inspector itself. Only the inspector gets that sidecar and strict re-admission;
original target backends and contexts retain their identity. Inspection neither
publishes nor executes a target, and its invocation uses the existing pinned
catalog and Session binding. MCP source checks compare the frozen snapshot with
the source owner's current snapshot without replacing the captured document.

Results are allowlisted JSON text in `content`, with no structured schema
sidecar: name/revision/description, function schema or exact custom grammar,
optional output schema, known MCP source UUID/raw/configured name and complete
available instructions. Portable validation precedes JSON allocation, followed
by a 65,536-byte encoded document limit; excess is explicit, with no truncation.
Schema property names such as `operation` remain intact. The shared result
projection and its runtime-key guard are unchanged. Source-owned asynchronous
refresh retains optional output schema and public protocol discovery metadata
inside per-tool snapshots; their outer keys stay unchanged. `codex_source`
carries compact identity only, so search results do not duplicate instructions.

Ordinary selected-inventory/native Conversation tests pass, including default-off
and deferred-inspector construction. A separate real managed-legacy Worker test
passes exact next-provider HTTP JSON, inspection effects zero and original target
once, Part/Store/Concord equality, second turn and dormant-new-Worker replay. The
content-only native result follows the existing ProviderMessages legacy branch:
Part.content holds exact JSON text and Part.projection is nil. The native result
is independently asserted before conversion; no structured sidecar is claimed.
Legacy discovery reports
`not_retained_legacy`, since the upstream public client does not retain legacy
initialize instructions. The modern capture code distinguishes `available`
(including empty strings) from `not_advertised`, but managed modern-source
acceptance and the modern Worker deferred/custom/publication-reinspection chain
remain pending: current Transport pins non-SSE sources to legacy `2025-06-18`.
The source-level protocol selection decision is open; no transport default,
saved configuration or dependency was changed. A separate modern client is not
used as proof of managed-source behavior. The capability map adds only a partial
inspection entry, preserving all whole-reference gates. Evidence and original
pre-implementation test archives: `/tmp/synapsis-inspection169-v21pts2x/`.


## Independent DeepInfra image generation and editing

`Synapsis.Provider.ImageGeneration.DeepInfra` adds an inactive explicit protocol;
it does not register a model tool or select a saved provider. Callers supply exact
prompt, model, finite positive timeout, API key and base URL. One exact `deepinfra/`
model prefix is removed after ECMAScript trimming. The base URL loses trailing
slashes without a version rewrite. JSON generation sends model/prompt/n/size and
b64_json; count defaults to one without a raw-callback clamp, and size defaults
to 1024x1024. A single source image selects multipart edits with n=1, ordered
text fields and the singular `image` file field, retaining bytes and source
filename/MIME rules. Source-unused geometry/quality/format controls are ignored.

Responses preserve all ordered inline assets and at most four sequential URL
assets for generation or one for edit. Explicit MIME wins; absent inline MIME
uses the original JPEG/PNG/WebP sniffing rules with JPEG fallback. Filename and
revised prompt follow the shared source helpers. Results contain only images
and model. One linked HTTP owner, shared Req.Finch and one absolute deadline
cover POST/GET, with bounded raw/image reads and no retries or polling. Tight
inline predecode limits remain an explicit host adaptation.

Config `request.headers` accepts an explicit string map. Ordinary custom headers
are trimmed and merged, then JSON forces its content type or multipart removes
it for the generated boundary. Other nonempty request/auth/proxy/TLS/private-
network or direct transport settings are unsupported; no saved request policy
is silently dropped. This is a host API boundary, not full source transport
policy equivalence or credential discovery.

```sh
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node --experimental-vm-modules \
  scripts/openclaw/capture-deepinfra-image-generation.mjs /tmp/openclaw-488631c --out \
  apps/synapsis_agent/test/fixtures/openclaw/488631c/deepinfra-image-generation.json
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node --experimental-vm-modules \
  --test scripts/openclaw/deepinfra-image-generation-functional.test.mjs
```

The oracle executes 11 whole pinned modules, including the complete DeepInfra
provider/media models, shared factory/assets/URL inliner and Blob helper, plus
two complete cap/deadline source regions. Every one of 58,558 tracked blobs,
modes and symlinks is checked before/after; all source/executable/import/generated/
helper/exporter/runtime identities are retained. Real Node FormData/Blob supplies
ordered field and file bytes/name/type observations; random raw multipart boundary
serialization remains outside that abstraction.

Twenty-eight ordinary callbacks include 26 host-comparable rows and two explicit
source-only rows: omitted model/timeout defaults and a configured-header service
fixture. Two further constructor-only observations retain empty/custom model
catalog metadata. Ten independent literal Node checks include two fresh captures
exactly equal to the frozen JSON. All 26 comparable rows are checked against the
host builder and actual local Gaoxy JSON/multipart/GET requests and full results;
local transport URL substitution retains the original source plans and payloads.

Key/config/sanitizer/policy/HTTP/status/read services are named successful facades.
Configured-request helpers and production bounded readers/network do not execute
in the oracle; that configured-header row is source-only. Tiny opaque successful
bytes prove protocol projection, not codec validity or visual quality. Real
supplier acceptance, native jobs/storage/destination delivery, saved readiness,
complete P10 and whole-reference gates remain unverified.

## Independent MiniMax image generation and reference images

`Synapsis.Provider.ImageGeneration.MiniMax` implements the shared `minimax` and
`minimax-portal` image protocol as an inactive explicit API. Callers provide
prompt, model, finite positive timeout, API key and effective image base URL.
The host does not resolve an environment region, saved provider or default model.
Raw model and prompt strings retain their bytes, including model whitespace and
provider prefixes. One JSON POST to `/v1/image_generation` sends model, prompt,
`response_format: base64`, count (default one, without clamping), and an optional
JavaScript-trimmed aspect ratio. Size and resolution do not add wire fields.

The first input image becomes a character subject reference data URL. Its raw
truthy MIME is preserved, with JPEG as the missing/empty fallback; filenames
are ignored. The source advertises one input image. Its direct callback uses
`at(0)`; multiple-input behavior is documented from source review only. Returned
assets retain bytes and ordering with fixed `image/png` MIME and original-index
PNG filenames. Model is the original supplied string; other response metadata
is not added to the result.

One linked HTTP owner uses shared Req.Finch and one absolute deadline for the
bounded JSON POST. No retry, poll or download is performed. Default JSON capacity
is `ceil(max(64 MiB, max_image_bytes) * 9 * 4 / 3) + 1 MiB`; predecode image bounds
and explicit raw-cap overrides are host adaptations. Explicit `request.headers`
string maps follow the existing image adapter convention; other nonempty
transport overrides are unsupported. This does not establish full configured
request policy or credential discovery equivalence.

```sh
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node --experimental-vm-modules \
  scripts/openclaw/capture-minimax-image-generation.mjs /tmp/openclaw-488631c --out \
  apps/synapsis_agent/test/fixtures/openclaw/488631c/minimax-image-generation.json
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node --experimental-vm-modules \
  --test scripts/openclaw/minimax-image-generation-functional.test.mjs
```

The independent oracle executes eight whole pinned modules, including the
complete MiniMax provider/media runtime, shared `postJsonResponse`, image assets
and Base64 helpers, plus a complete configured-cap source region. All 58,558
tracked blobs, modes and symlinks are checked before/after; source, executable,
projection, import, exporter, shared harness and runtime hashes are retained.
Both IDs register in the same MiniMax plugin; registration is provenance only.

Twenty-seven ordinary source callbacks include 25 host-comparable rows and two
source-only rows for omitted model/timeout and literal configured-header outputs.
Configured CN routing runs against a frozen empty environment and records its
effective image root separately; host comparison explicitly supplies that root.
Credential/config/sanitizer/lower HTTP/status/reader services are named successful
facades. The real shared POST wrapper's successful `finally` releases once;
production transport and bounded readers do not execute in the source oracle.
Tiny opaque bytes establish protocol projection, not image quality or codec
validity. Native tool activation, jobs, storage, destination delivery, real-provider
acceptance and complete P10/reference coverage remain separate work.

The independent Node suite passes 11 checks, including two fresh captures exactly
equal to the frozen JSON. The dedicated host file passes six ordinary checks;
all 25 comparable source rows match complete builder plans, actual local Gaoxy
POST bodies/headers and full byte/MIME/filename/model results. Local URL
substitution happens after the original effective source plan is checked. A
successful chunked response also meets explicit raw/decoded byte bounds, and the
linked request owner exits normally after success. Error, cancellation and crash
paths were not executed. That batch brought the image inventory to six implemented
IDs across five inactive protocols; the later LiteLLM protocol is described below.

## Independent LiteLLM image generation and multi-image editing

`Synapsis.Provider.ImageGeneration.LiteLLM` provides explicit `build_request/2`
and `generate/2` without saved selection or model-tool activation. Callers supply
prompt, model, finite positive timeout, API key and base URL. Model is trimmed
without removing its provider prefix. The base loses trailing slashes without
rewriting versions. Generation sends model, prompt, n (default one, unclamped)
and size (nullish default `1024x1024`, otherwise unchanged). No response_format
field is sent. Aspect/resolution/quality/format controls are source-unused.

One to five input images select multipart editing. Ordered model/prompt/n/size
fields precede a singular `image` part or repeated `image[]` parts. Requested
count is retained. Source MIME/filename trimming, PNG upload default, generated
names, path prefixes and Blob ASCII lowercase rules retain the ordered original
bytes. Logical FormData parts are compared; random HTTP boundary bytes are not.

Results preserve ordered image bytes, trimmed explicit MIME, filename extension
and revised prompt. Missing MIME defaults to PNG without signature sniffing.
Both generation and edit support at most four sequential URL downloads using
response Content-Type and original bytes. One linked HTTP owner, shared Req.Finch
and one absolute deadline cover POST/GET with bounded bodies and no retry or poll.
JSON capacity uses four results for both operations; predecode image bounds and
explicit raw-cap overrides remain host adaptations.

Explicit request.headers string maps follow the existing image protocol
convention. Unsupported nonempty transport overrides return errors. The host
does not resolve saved credentials, defaults or LiteLLM private-network policy.

```sh
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node --experimental-vm-modules \
  scripts/openclaw/capture-litellm-image-generation.mjs /tmp/openclaw-488631c --out \
  apps/synapsis_agent/test/fixtures/openclaw/488631c/litellm-image-generation.json
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node --experimental-vm-modules \
  --test scripts/openclaw/litellm-image-generation-functional.test.mjs
```

The independent oracle executes ten whole pinned modules and three complete
source regions for the onboarding base constant, media cap and deadline helpers.
All 58,558 tracked blobs, modes and symlinks are checked before/after; every source,
transform, generated binding, shared harness, exporter and fixed Node runtime has
a receipt. The original Node isIP binding is identified. Every callback receives
an explicit public base, including the source-only default-model/timeout row;
there is no loopback/private-policy test or policy equivalence claim.

Thirty-six source observations include 34 host-comparable rows and two source-only
rows for omitted model/timeout and literal configured-header outputs. Lower
key/config/sanitizer/policy/POST/GET/status/reader services are named successful
facades; production network, configured policy and bounded readers do not execute
in that oracle. Tiny opaque bytes establish protocol projection, without codec
or image quality claims. Native tools, paid jobs, custody, storage, destination
delivery, real-provider acceptance and complete P10/reference remain open.

The dedicated host file passes five ordinary checks, including complete builder
plans and actual Gaoxy JSON/multipart POSTs, ordered GETs and full results for all
34 comparable rows. The independent Node suite passes ten checks with two fresh
captures exactly equal to frozen JSON. Eleven advertised sizes, requested edit
counts, five ordered upload files and success-only owner cleanup are covered.
The source plan is checked before replacing local POST/download transport URLs.
No error, cancellation, crash, overflow, security or permission tests were run.
Six inactive image protocols now cover seven registered IDs; six other image
provider IDs remain unimplemented.

## Independent OpenRouter image generation

`Synapsis.Provider.ImageGeneration.OpenRouter` exposes inactive, explicit
`build_request/2` and `generate/2`. Callers supply prompt, model, finite positive
timeout, API key and base URL. Exact canonical and legacy OpenRouter roots select
canonical `/images`: one concurrent request per requested image, each with `n: 1`,
with results flattened in request order. Other public bases select one
`/chat/completions` request with the requested count and image/text modalities.
Count defaults to one and floors/clamps to 1–4. Models retain their prefixes after
JavaScript trim; only `google/gemini-` models receive aspect/resolution fields.
One to five references retain ordered bytes and trimmed/default PNG MIME as data
URLs. Reference filenames and source-unused controls do not enter the body.

Dedicated responses preserve explicit MIME, the source `media_type` alias rule,
JPEG/PNG/WebP sniffing with PNG fallback, revised prompts and per-request names.
Chat reads message images before string/array content, including both image URL
spellings, base64 and inline-data variants, with contiguous filenames. It performs
no URL downloads. One linked HTTP owner and at most four linked request tasks use
shared Req.Finch, one absolute deadline and bounded raw/predecode reads, without
retry or polling. Chat JSON capacity accounts for twice the requested count;
dedicated capacity accounts for one result per request, with the source 64 MiB
floor. Explicit headers follow the existing image adapter convention.

The original image context disables JSON content type, and original
`postJsonRequest` stringifies without adding it. Despite its source comment,
native `Request` therefore supplies `text/plain;charset=UTF-8` when absent.
Builder headers retain the raw context headers; actual HTTP uses the observed
effective header unless explicitly configured. This is a wire adaptation, not
saved credential or generic transport-policy equivalence.

```sh
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node --experimental-vm-modules \
  scripts/openclaw/capture-openrouter-image-generation.mjs /tmp/openclaw-488631c --out \
  apps/synapsis_agent/test/fixtures/openclaw/488631c/openrouter-image-generation.json
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node --experimental-vm-modules \
  --test scripts/openclaw/openrouter-image-generation-functional.test.mjs
```

The oracle executes ten whole pinned modules and three complete source regions
for base normalization, the media cap and original JSON POST helpers. All 58,558
tracked blobs, modes and symlinks are checked before/after, with source, transform,
import, harness, exporter and fixed runtime receipts. Forty-one observations
include 39 host-comparable rows and two source-only default/header rows. Native
Request records original raw headers, effective wire headers and original
JSON.stringify bodies. Four dedicated requests reach a barrier before successful
reverse completion, retaining original result order and single release receipts.
Lower key/config/sanitizer/policy/HTTP/status/reader services are named successful
facades, without production network, policy or bounded-reader acceptance.

The independent Node suite passes twelve checks, including two fresh captures
equal to frozen JSON. Host checks use local Gaoxy fixtures and temporarily restore
the existing Req default-plugin convention: verify the original official request,
then replace only scheme/host/port while retaining its path. No public transport
override or provider activation is added. Real-provider acceptance, visual quality,
native tools, paid jobs, custody, storage and destination delivery remain open.

The dedicated host file passes five ordinary checks, including complete builder
plans, actual Gaoxy POSTs and full ordered results for all 39 comparable rows.
Original URL/path and raw builder headers are checked before local transport
replacement; effective headers and decoded JSON are checked on actual HTTP.
Four requests reach a barrier together and complete in reverse order while the
owner exits normally. No failure, cancellation, crash, overflow, security or
permission tests were run. Seven inactive image protocols now cover eight
registered IDs; five other image provider IDs remain unimplemented.

## Independent Microsoft Foundry MAI images

`Synapsis.Provider.ImageGeneration.MicrosoftFoundry` supplies inactive explicit
`build_request/2` and `generate/2`. Callers provide prompt, deployment model,
finite positive timeout, API key and endpoint. Optional `models` metadata uses
the source's exact deployment ID lookup and model-name rules. Generation accepts
known MAI names and custom deployment IDs; edits require MAI Image 2.5 or 2.5
Flash, either directly or through matching metadata. Model uses JavaScript trim
and retains its provider prefix. There is no default deployment selection.

Generation posts only model, prompt, width and height. Size defaults to
1024x1024; explicit dimensions have a minimum side of 768 and at most 1,048,576
pixels. One input selects multipart editing: ordered model, prompt and image,
with original bytes, trimmed filename and source upload naming. Upload MIME is
trimmed/lowercased PNG or JPEG; JPG becomes JPEG on the wire. Edit size and other
source-unused controls do not enter the body. Count is absent or one.

The original endpoint helper removes query/fragment, trailing slashes and the
OpenAI/Anthropic suffix while preserving preceding path components. The image
provider appends `/mai/v1/images/generations` or `/mai/v1/images/edits`; an existing
`/mai/v1` path is retained by that helper. JSON forces application/json; multipart
removes configured Content-Type for the generated boundary.

Inline results retain original bytes, explicit MIME or JPEG/PNG/WebP sniffing
with PNG fallback, revised prompts and `microsoft-foundry-image` filenames.
There are no URL downloads. One linked HTTP owner uses shared Req.Finch and one
absolute deadline, bounded raw/predecode reads, no retry and no polling. The raw
JSON budget uses one result and the source 64 MiB floor. Saved credentials,
environment endpoint fallback, Entra refresh and generic transport policy are
outside this explicit adapter; the dynamic credential sentinel is unsupported.
Native tools, paid jobs, custody, storage and destination delivery stay inactive.

```sh
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node --experimental-vm-modules \
  scripts/openclaw/capture-microsoft-foundry-image-generation.mjs /tmp/openclaw-488631c --out \
  apps/synapsis_agent/test/fixtures/openclaw/488631c/microsoft-foundry-image-generation.json
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node --experimental-vm-modules \
  --test scripts/openclaw/microsoft-foundry-image-generation-functional.test.mjs
```

The independent oracle executes the whole 295-line image provider and eight
whole image/blob/expect/normalization/media helpers. Four projected modules retain
seven complete original regions: Foundry constants, MAI model recognition and
endpoint helpers, plus cap, deadline and original JSON/multipart POST helpers.
Exact source spans, generated code, transformations, imports, runtime, exporter
and harness have receipts; all 58,558 tracked blobs, modes and symlinks are
checked before/after. Original POST helpers stringify JSON or pass native
FormData; captures compare ordered logical fields and files, not random multipart
boundary bytes. A deterministic clock records successful POST/read/release costs.

Forty-one successful observations include 39 host-comparable rows and two
source-only default-timeout/header rows. All callbacks use an explicit public
endpoint and deployment. Credential, config, sanitizer, guard, lower HTTP, status
and reader boundaries are named facades. Availability, environment fallback and
Entra runtime auth remain unexecuted provenance; synthetic key context does not
establish credential or policy behavior. Body caps are observed parameters in
the oracle, not proof of the production bounded reader.

The host file passes five ordinary checks, including complete builder plans and
actual Gaoxy JSON/multipart requests and full results for all 39 comparable rows.
The public source plan is compared before substituting a local endpoint for HTTP.
Each response contains one image; MIME variants use separate calls. Initial
literal expectations remain intact. Chunked BOM JSON and normal owner exit are
covered. The independent Node suite passes eleven checks, including two fresh
captures equal to frozen JSON. No security, permission, auth/TLS, overflow, failure,
cancellation, crash or real-provider tests were run. Eight inactive image
protocols now cover nine registered IDs; fal, clawrouter, comfy and vydra remain
unimplemented, and full P10/reference acceptance remains open.

## Independent FAL image generation and reference editing

`Synapsis.Provider.ImageGeneration.Fal` exposes inactive explicit `build_request/2`
and `generate/2`, requiring prompt, model, finite positive timeout, API key and
base URL. It implements the pinned raw callback, with separate routing for exact
GPT Image 2.5 paths, Krea, legacy Nano Banana, generic GPT, Nano Banana 2, Lite,
Grok and Flux/custom fallback. Model prefixes and prompt bytes remain intact;
only model whitespace is trimmed. Reference fields, limits and edit path rules
follow each family, including sixteen GPT 2.5 inputs, ten GPT/Krea inputs,
fourteen Nano 2/Lite inputs, three legacy Nano/Grok inputs and one fallback input.
References retain ordered bytes and trimmed/default PNG MIME as data URLs;
filenames do not enter the request.

Geometry preserves source size precedence, named aspect sizes, computed numeric
dimensions and JavaScript positive rounding. GPT 2.5 adds its grid/area/ratio
validator, exact auto size, quality/background and three formats. Native-ratio
families select explicit or nearest size-derived ratios; Grok lowercases its
allowed resolutions. Krea sends creativity and style references, with neither
count nor output format. Other families retain their count without clamping.
This adapter does not apply the outer runtime geometry normalizer.

The request is one JSON POST to the source-normalized base/model path. Raw string
JSON retains configured header overrides after the default Key and JSON headers.
Every returned URL is trimmed and downloaded sequentially. Downloads receive no
POST headers, and return original bytes, full trimmed response Content-Type
including case/parameters (PNG fallback), stable image-N extensions, and optional
trimmed prompt metadata. There is no MIME sniffing, inline-output parser, upload
multipart, queue or poll. All ordered results are retained without an invented
download-count limit.

One linked HTTP owner and one absolute deadline cover preflight, POST and every
GET through shared Req.Finch, with bounded bodies and no retries. Timeouts use
the source positive-number floor/clamp. JSON defaults to the original 16 MiB
reader budget; each image has the source 64 MiB floor or a larger configured
bound. Saved credentials, environment and generic transport policy remain
outside the explicit adapter. Native tools, jobs, custody, storage and destination
delivery remain inactive.

```sh
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node --experimental-vm-modules \
  scripts/openclaw/capture-fal-image-generation.mjs /tmp/openclaw-488631c --out \
  apps/synapsis_agent/test/fixtures/openclaw/488631c/fal-image-generation.json
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node --experimental-vm-modules \
  --test scripts/openclaw/fal-image-generation-functional.test.mjs
```

The oracle executes the complete 698-line callback and 48-line HTTP context,
plus six whole image/normalization/media helpers. Four projected modules retain
six original regions for cap/deadline/base normalization and the JSON reader's
16 MiB selection, fatal UTF-8 decoder and JSON.parse. All 58,558 tracked blobs,
modes and symlinks are checked before/after. Source, transform, generated/import,
exporter, harness and fixed runtime receipts reconstruct independently.

Its 180 ordinary observations include 178 host-comparable rows and two
source-only default/header rows. The deterministic clock charges preflight and
records decreasing POST/download budgets and download-before-POST release order.
Lower credential/config/sanitizer/guard/HTTP/status/body-reader services are named
successful facades, without production policy or bounded-reader equivalence.
The independent Node suite passes seven checks with two fresh captures equal to
frozen JSON, full literal requests/results and all receipts.

Descriptor provenance retains known static contradictions: Krea inherits count
and format declarations its callback rejects; GPT 2.5 inherits four extreme
ratios its validator rejects; Flux edits declare aspect support their callback
rejects. Successful vectors stay within both descriptor and callback bounds.
They do not establish exhaustive advertised-option acceptance. No security,
permission, auth/TLS, overflow, failure, cancellation, crash or real-provider
tests were run. Outer runtime normalization and full P10/reference remain open.

The final host file passes five ordinary checks, comparing all 178 comparable
public builder plans before local transport substitution, actual JSON POSTs,
every ordered GET, full results and optional metadata. Source remaining-time
receipts are checked separately from the builder's total timeout. Four downloads
in the literal success test run sequentially, and the linked HTTP owner exits
normally. Static source review aligned whole-array validation before downloads;
the same five ordinary checks passed again after that adjustment. Nine inactive
image protocols now cover ten registered IDs; clawrouter, comfy and vydra remain
unimplemented. No native image-tool activation or real-provider acceptance is
implied by these checks.

### ClawRouter image catalog and generation callback

`capture-clawrouter-image-generation.mjs` executes the complete pinned
ClawRouter provider, live catalog parser and base normalizer, together with
the original image asset parser, URL inliner and pure helpers. It uses the fixed
Node 24.22.1 runtime and records whole-source, projected-region, transformed
code, import, shared harness and runtime receipts. All tracked source blobs,
modes and symlinks are checked before and after each capture.

ClawRouter uses a fresh `/v1/catalog` GET before each `/v1/images/generations`
POST. The same request context supplies both calls. Four exact qualified
flare/sunburst model IDs are supported; live catalog rows provide current
prompt, count and geometry limits. The static descriptor has an empty model
list and no default model, and its maximum count of ten can be lowered by the
live row. Generation preserves the exact model and prompt, validates size
without geometry normalization, and sends optional top-level controls and the
OpenAI background/moderation/outputCompression/user fields. The outer image
runtime's enum filtering remains a separate contract.

The independent capture includes explicit model, public base and finite
positive timeout in every host-comparable row. Default timeout and configured
header examples remain source-only. It reuses one source provider instance
while fetching a fresh catalog for every invocation. Ordinary vectors cover
all four models, counts one through ten within live limits, lower positive
limits, valid sizes and `auto`, controls, Unicode prompts, homogeneous inline
PNG/JPEG/WebP assets and ordered all-URL results. Output count may be lower
than requested; signatures and MIME must agree. Returned images preserve bytes,
positional filenames and optional revised prompts, without service metadata.

Original deadline, JSON POST, cap, fatal UTF-8 JSON and binary reader regions
execute over named successful credential/config/HTTP/status/lower-reader
facades. These facades do not establish production credential resolution,
network policy or bounded-stream enforcement. Catalog JSON has a 1 MiB cap;
generation JSON uses `ceil(imageCap * count * 4 / 3) + 1 MiB`, and each image has
a 64 MiB floor. A synthetic clock records decreasing operation budgets and
catalog release before POST, sequential download releases, then generation
release. The original timer ceiling is 2,147,000,000 ms.

The inactive host module
`Synapsis.Provider.ImageGeneration.ClawRouter` provides explicit
`build_request/2` and `generate/2` with one linked HTTP owner and shared
Req.Finch. It requires the caller's key, base, model, prompt and timeout;
fetches a fresh catalog; and performs one POST followed by sequential clean
downloads. It does not register models or tools or activate jobs, media custody,
storage or destination delivery. Ordinary local HTTP checks and independent
source capture do not establish real-provider acceptance or image codec quality.
No security, permission, auth/TLS, negative, mixed, overflow, real-provider,
failure, cancellation or crash execution tests belong to this batch.

The final host file passes six ordinary checks. Its full-source comparison
checks all 50 comparable public builder plans before local transport
substitution, then actual catalog GETs, JSON POSTs, every ordered URL download
and full results. Source remaining budgets are asserted separately from the
host builder's total timeout. A literal case observes the linked HTTP owner's
normal exit, and two calls to the same endpoint each query a fresh catalog.
The five independent Node checks include two fresh captures equal to the frozen
fixture. Ten inactive image protocols now cover eleven registered IDs;
At that batch boundary Comfy and Vydra remained unimplemented; complete
P10/reference acceptance remains open.

### Comfy explicit image workflow callback

`capture-comfy-image-generation.mjs` executes the pinned complete Comfy image
registration closure, workflow runtime and HTTP helper, with thirteen whole
modules and three source projections. The four independent Node checks verify
39 literal observations, provenance and two fresh captures against frozen JSON.
All 58,558 tracked source blobs, modes and symlinks are checked before/after.
Thirty-two rows are host-comparable; seven source-only rows retain original RNG,
default model/timeout, config/header and image-overlay behavior. Named successful
credential/config/HTTP/status/lower-reader facades bound the evidence.

The inactive `Synapsis.Provider.ImageGeneration.Comfy` module exposes
`build_request/2` and `generate/2`. Callers explicitly provide prompt, model label,
timeout, local/cloud mode, base URL, inline workflow and prompt-node binding;
cloud mode also needs its key. Model is a trimmed result label. Count, geometry
and quality controls do not rewrite the graph. Optional seed binding uses actual
randomness, with no public deterministic override. Each call prepares a fresh
graph and leaves the caller's graph unchanged.

An optional reference uploads actual multipart image/type/overwrite fields and
binds the returned filename before submission. Local mode polls history; cloud
mode polls job status and fetches history once completed. Downloads run in
JavaScript node-key order and then image-array order, retaining history filenames,
exact bytes and full trimmed HTTP MIME (octet-stream if absent). Host prompt/node
metadata uses atom snake_case. Raw descriptor maxCount=1 and the callback's
all-selected-output behavior remain separate facts; ordinary multiple-output
examples omit count and use small homogeneous images.

One linked HTTP owner and shared Req.Finch perform sequential requests under a
monotonic deadline starting after graph preparation. JSON uses a 16 MiB cap and
30-second idle bound; each image has a 64 MiB minimum cap and remaining-time idle
bound. Original source request-signal handling is absent; this batch adds no
cancellation feature. The source clock records remaining budgets and releases;
the pre-network graph is independently observed from the original clone before
the first fetch, separately from the actual submitted graph after upload.

Reproduce the ordinary source checks with the fixed capture runtime:

```sh
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node \
  --experimental-vm-modules scripts/openclaw/capture-comfy-image-generation.mjs \
  /tmp/openclaw-488631c --out /tmp/comfy-image-generation.json
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node \
  --experimental-vm-modules --test scripts/openclaw/comfy-image-generation-functional.test.mjs
```

These checks establish ordinary callback behavior with local fixtures. Native
registration, jobs, custody, storage, delivery, real providers and image codec
quality remain separate. No security, permission, auth/TLS, negative, mixed,
overflow, failure, cancellation or crash execution tests belong to this batch.

The host file passes seven ordinary checks. It first compares all 32 complete
public builder maps, then substitutes local transport and checks multipart bytes,
JSON, every poll/raw ordered-history response/download, global request order and
full results. The original six literal cases remain intact except the corrected
Plug multipart-reader API arity. At that batch boundary eleven inactive image
protocols covered twelve registered IDs and Vydra remained unimplemented;
full P10/reference stays open.

### Vydra image submission, polling and first result

`capture-vydra-image-generation.mjs` executes the complete pinned Vydra image
registration, shared workflow, defaults, speech-only capability catalog and JSON
POST wrapper, plus pure helpers. Nine whole modules and four projections retain
ten complete original regions for deadlines, polling, transport, readers, caps
and the MIME map. All 58,558 tracked blobs, modes and symlinks are checked before
and after capture. Four independent Node checks cover 46 literal observations,
complete receipts and two fresh captures equal to the frozen fixture. Forty-one
rows are host-comparable; five preserve omitted model/timeout/base, canonical
base and configured-header facade behavior as source-only facts.

The inactive `Synapsis.Provider.ImageGeneration.Vydra` module requires explicit
prompt, model, timeout, base and key. It trims the model for the route and result,
preserves prompt bytes, and posts only `{prompt, model: "text-to-image"}`. The
source base normalizer maps vydra.ai to www.vydra.ai and supplies /api/v1 for a
root path. The callback accepts one image request with no reference; ordinary
geometry/output options leave this fixed body unchanged. Native registration
advertises grok-imagine. The separate static capability catalog contains only
speech, despite the manifest and registration declaring image/video contracts.

Submission may provide a result URL immediately or a job ID. The first poll is
immediate; pending successful reads wait 2500 ms, with a maximum of 120 reads.
Completion uses normalized completed status or a discovered URL. Ordered URL
field names, recursive containers, arrays and first-seen deduplication determine
the first result, and only that result is fetched. Final job ID takes precedence
over the submitted ID; absent IDs remain absent. Host metadata uses atom
snake_case. Download bytes and the full trimmed MIME survive unchanged, with
image/png when absent and a MIME-derived image-1 filename. These are byte
transport checks and do not establish decoded image or visual quality.

Vydra image uses separate submission, polling and download budgets. Its video
callback's aggregate deadline does not apply. Poll calls cap each read at 120
seconds and remaining poll time; the download shares its fresh deadline between
headers and body, with source binary chunk-idle timeout disabled. JSON uses a
16 MiB cap and 30-second idle bound; each image has a 64 MiB floor. The host
uses one linked HTTP owner/shared Req.Finch, finite stage reads and a segmented
three-budget owner watchdog. Its submission total bound and outer watchdog are
explicit host ownership limits, not exact source failure/retry/cleanup parity.
The fractional POST receipt records the raw substituted-guard argument, while
the source download deadline uses the original integer timer normalization.

The oracle's lower credential/config/policy/guard/status/reader/wait/retry
facades are named successful boundaries. Only ordinary same-origin results
execute. These do not establish production authentication, policy, native
bounded-reader enforcement or retry behavior. Source polling retry logic remains
a separate static fact; the first successful operation is the only executed
retry-facade path.

```sh
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node \
  --experimental-vm-modules scripts/openclaw/capture-vydra-image-generation.mjs \
  /tmp/openclaw-488631c --out /tmp/vydra-image-generation.json
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node \
  --experimental-vm-modules --test scripts/openclaw/vydra-image-generation-functional.test.mjs
```

No native image tool, jobs, custody, storage or delivery is activated. Full
P10/reference remains open. No security, permission, auth/TLS, negative, mixed,
overflow, failure, cancellation, crash or real-provider execution tests belong
to this batch. The final host file passes eight checks: all 41 complete public
builder maps are compared first, followed by actual POST/poll/download wire,
global request order and full results. A restored private Req defaults plugin
changes only scheme/host/port for local fixtures, preserving original paths,
queries and result URLs. It uses the standard Req constructor and serialized
tests; the seven original literal tests retain their assertions. Source stage
budgets remain separate from host elapsed-time and ownership limits. Twelve
inactive image protocols cover thirteen registered IDs; native assembly and
full P10/reference remain open.

### Image generation factory, provider lists and active status

`capture-image-generate-tool.mjs` executes the unchanged pinned
`createImageGenerateTool`, image actions and shared dispatcher with actual
TypeBox 1.3.37. It records two available factory contexts, two nonempty provider
lists and four same-session/agent status snapshots: idle, queued, running and
plural active. The full enumerable nonfunction metadata, JSON schema, action
results and ordered callback ledgers are retained. Plural status puts running
before queued; lists preserve generate/edit modes, model catalogs, geometry and
output capabilities. These are original list/status projections over supplied
successful data, not evidence that provider generation or task custody runs.

The report contains 70 source records, including 39 whole executed modules,
complete transformed import bindings, generated facade code and runtime hashes.
Both exporter and independent checks verify all 58,558 tracked blobs, modes and
symlinks. Eight independent checks pass, including two fresh captures equal to
the complete frozen JSON. Context/configuration, provider metadata, configured
callbacks and task snapshots are named inert facades. The directly imported
model-config helper is replaced at that boundary; its transitive model-auth
module is never linked. No credentials are read or authenticated.

```sh
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node \
  --experimental-vm-modules scripts/openclaw/capture-image-generate-tool.mjs \
  /tmp/openclaw-488631c --out /tmp/image-generate-tool.json
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node \
  --experimental-vm-modules --test scripts/openclaw/image-generate-tool-functional.test.mjs
```

No generate branch, duplicate guard, provider request, job registry, completion,
network or storage executes. This independent oracle does not fill canonical
factory/runtime assembly evidence or activate a native tool. The capability map
adds only `image_generate.partialImplementation.independentSourceOracle`;
implementation/local/live gates and `pending-factory-capture` remain unchanged.
No security, permission, auth/TLS, negative, mixed, overflow, failure,
cancellation, crash or real-provider execution tests belong to this batch.


## llm-task ordinary callback reference

`capture-llm-task.mjs` invokes the complete unchanged pinned factory and public
`execute` callback in twelve fresh VMs. It executes the actual model-selection
alias/default and provider/model normalization helpers, parameter/string/number
and thinking helpers, JSON Schema validator and textResult, using actual
TypeBox 1.3.37. The capture records full source/executable hashes and import
facades; 42 whole modules execute and 26 additional modules are provenance only.
All 58,558 tracked source blobs, executable modes and symlinks are checked against
Git before and after. The four metadata fields also match the existing unchanged
schema/factory recipes in capture.json.

```sh
node --disable-warning=ExperimentalWarning --experimental-vm-modules   scripts/openclaw/capture-llm-task.mjs --source /tmp/openclaw-488631c --write
node --disable-warning=ExperimentalWarning --experimental-vm-modules   --test scripts/openclaw/llm-task-functional.test.mjs
```

The frozen file is
`apps/synapsis_agent/test/fixtures/openclaw/488631c/llm-task.json`.
This capture used Node 24.19.0 and TypeBox 1.3.37 (536 hashed package files).
The independent tests specify full literal completion requests and parsed results:
primary string/object defaults, configured/request overrides, cross-provider
aliases, explicit nested model IDs, timeout/token/temperature-zero/thinking,
Unicode content, JSON values and fences, and successful object/local-ref schemas.
Output schema defaults are not injected. Repeated captures compare the complete
artifact; test totals do not count repeated callbacks as new scenarios.

`runtime.llm.complete` is an explicitly recorded successful fixture, returning
text/provider/model. Empty manifest/workspace/plugin/runtime inventories are
explicit inert facts (60 audited calls); unrelated imports throw if invoked
(zero such calls). TypeBox uses its own interpreter fallback with VM string
code generation disabled. This proves source callback behavior; execution.mode
is a recorded request field, not proof of an isolated runtime. Production model
selection, credential overrides, timeout/cancellation, plugin activation and
host/native runtime assembly remain unimplemented or unverified. No real
provider or security/permission/authTLS/negative/mixed/failure/cancel/crash tests
run. Full llm-task/P13/reference gates remain incomplete.


## Lobster complete wrapper callback oracle

`488631c/lobster.json` executes the complete unchanged `createLobsterTool`, its
public callback and `lobster-runner.ts`, with real numeric readers, `jsonResult`,
`raceWithTimeout` and TypeBox 1.3.37. Eleven ordinary vectors cover inline/file
routing, file arguments, arbitrary JSON input responses, exact public metadata
and the input checkpoint envelope. One actual runner is reused, proving one
cached dynamic import of the explicit successful external-core facade.

```sh
node --experimental-vm-modules scripts/openclaw/capture-lobster.mjs \
  --source /path/to/pinned/openclaw --output /tmp/lobster-reference.json
node --experimental-vm-modules --test scripts/openclaw/lobster-functional.test.mjs
```

The test file uses `/tmp/openclaw-488631c`, as do the neighboring source oracles.
It compares literal expectations and a fresh capture against the frozen fixture.
All 58,558 tracked blobs, modes and symlinks are checked before and after capture.
The four independent tests were archived before capture implementation.

The external core is an inert success facade. It does not parse or execute
pipelines, persist checkpoints, validate input responses or resume real work.
Two regular-file stat observations and one contained cwd are also explicit success
fixtures; the external fs-safe implementation is not executed. Normal timers and
Node streams run, but timeout/overflow/cancellation/approval/security/permission
behavior is not tested. This capture installs no Synapsis tool or runtime.

The fixed plugin depends on `@clawdbot/lobster@2026.9.16`, whose public npm tarball
is pinned in the reference pnpm lock by
`sha512-F7Izhqs6tdaSOp5l2vocqa+HXvqiPw3ny8o81kIguqUPL/jJ+72tpib2A5twxTPM2ruK23cdG1B8kO6joHUlVw==`.
Source investigation downloaded and verified that exact package without installing
or executing it. It is a separate workflow executor with filesystem resume state;
its registry override does not intercept workflow-file direct shell execution.
Tokens locate saved records. Command-level input may re-enter its suspended
command, and file resume reloads the workflow file. These are source findings,
not native execution or restart qualification. Host execution must retain native
Conversation/Execution authority and data-owned durable semantic checkpoints;
a live Code Mode handle or saved native interaction is not such a checkpoint.


## Lobster inline pipeline parser

`capture-lobster-pipeline.mjs` verifies the fixed OpenClaw package manifest and
lock bytes against Git, checks the npm archive SHA512, then reads and executes
both complete unchanged `parser.js` and `command_tokens.js` directly from it.
No package installation or workflow runtime is needed. The fixture records both
source hashes, package metadata, archive license and harness hash. Unlike the
wrapper oracle, this executes the real pure parser without a core facade.

```sh
node --experimental-vm-modules scripts/openclaw/capture-lobster-pipeline.mjs \
  /tmp/openclaw-488631c /path/to/lobster-2026.9.16.tgz /tmp/lobster-pipeline.json
node --experimental-vm-modules --test scripts/openclaw/lobster-pipeline-functional.test.mjs
```

The independent literal expectations cover 24 ordinary UTF-8 inputs: pipes,
quoted text and empty tokens, single/double quote escapes and line continuation,
ASCII token separators, ECMAScript edge whitespace (including BOM, excluding
NEL), Unicode, flags, repeated values and exec's boolean JSON switch. Both Node
and Elixir expectations were archived before capture/parser implementation.
The Elixir `Synapsis.Workflow.Pipeline.parse/1` returns string-keyed stage maps
with original trimmed raw text. It performs no resolution, execution or storage.
SDK token dialect, JavaScript prototype mutation/lone surrogates, workflow files,
checkpoints and native execution remain outside this component's qualification.
Full Lobster/reference gates remain incomplete.


## Lobster lazy runtime and input-resume oracle

`capture-lobster-runtime.mjs` executes twelve complete unchanged modules from the
verified Lobster archive, including `runPipeline`, its actual input tracker and
requestInput implementation, parser, ask/head/pick/json, renderer and validation.
It executes Ajv 8.20.0's actual compiler with string code generation enabled;
this is trusted fixed-source qualification, without a plugin sandbox claim.
Sixty-six CommonJS files and two JSON data files execute/load from independently
SHA512-verified package archives. `require-from-string` is recorded package
provenance only. No npm package is installed.

The dependency manifest is a JSON array with `name`, `version`, `integrity` and
absolute local `archive` path for each package: ajv 8.20.0, fast-uri 4.2.2,
fast-deep-equal 3.1.3, json-schema-traverse 1.0.0 and require-from-string 2.0.2.
Download the ordinary registry tarballs for those exact versions; the capture
checks each archive against its integrity entry in the fixed OpenClaw pnpm lock.
It also checks Ajv's exact locked dependency cohort and the fixed workspace's
fast-uri override. The downloaded archives and manifest used here are under
`/tmp/synapsis-workflow186-fydsjreq/npm/`; licenses and package/source hashes are
embedded in the reproducible fixture, independent of those temporary paths.

```sh
node --experimental-vm-modules scripts/openclaw/capture-lobster-runtime.mjs \
  /tmp/openclaw-488631c /path/to/lobster-2026.9.16.tgz \
  /path/to/dependency-manifest.json /tmp/lobster-runtime.json
node --experimental-vm-modules --test scripts/openclaw/lobster-runtime-functional.test.mjs
```

Seven independently authored cases cover lazy head-one/head-zero constructor and
pull order, real pick/json projection, same-stage ask with streamed and known-array
inputs, forced emit next-stage input, and exact JSON rendering. Ten pipeline calls
produce actual source requests/results; four tests compare literal expectations,
all twelve source hashes, dependency identities and complete fresh/frozen equality.
The tests were archived before capture implementation and remain byte-identical.

The source generator and run-order observation wrappers are explicit fixtures.
Resume slicing and state/response injection are declared harness recipes following
`tool_runtime` source. The tool runtime/finalizer, filesystem checkpoint writes,
tokens, native effects and workflow files do not run. Imported fs/atomic-file
module definitions are source execution, not storage qualification. This is an
actual pure engine oracle, separate from the earlier successful core facade, and
it installs no production workflow tool or reducer.

The observed constructor/pull distinction and array/lazy replay identity constrain
the next reducer: buffered output cannot automatically become array semantics.
A faithful machine also needs explicit iterator-return frames and a lossless
internal value representation before public JSON conversion. The architecture
assessment is a design proposal; no native streaming/parallel/shell or full workflow
compatibility follows from these ordinary cases. No excluded checks run.

## Lobster values and typed heap foundation

`capture-lobster-values.mjs` executes the complete unchanged `pick`, `map` and
`value_path` modules from the same lock-verified Lobster archive. Four actual
command calls cover missing-versus-null projection, shared-object mutation and
wrap/unwrap identity. Three separately labeled native-JavaScript observations
cover property order, finite binary64 import and nested values. Source, package,
license and harness hashes are recorded; no package install or full runtime runs.

```sh
node --experimental-vm-modules scripts/openclaw/capture-lobster-values.mjs \
  /tmp/openclaw-488631c /path/to/lobster-2026.9.16.tgz /tmp/lobster-values.json
node --experimental-vm-modules --test scripts/openclaw/lobster-values-functional.test.mjs
```

The core `Synapsis.Workflow.Value` component imports JSON through Elixir's decoder
callbacks, retaining ordered properties and finite numeric values as binary64
bits. The installed decoder discards the sign of integer-mantissa negative zero.
After validating the original complete JSON, a narrow lexical adapter preserves
that sign by changing scalar-start `-0` to `-0.0` outside quoted strings; exponent
suffixes such as `1e-0` stay unchanged. Changed input is decoded again through the
same grammar authority. Original numeric spelling is not preserved.
Every value is tagged; object/array references point into
a JSON-compatible heap. Object replacement preserves insertion position, index
keys enumerate numerically, and shared references survive a typed heap snapshot.
The host snapshot check uses Value plus Jason; the JavaScript alias observation
does not claim that plain JSON can preserve ordinary JavaScript object identity.

This foundation provides dense arrays and own object fields. It does not execute
commands, implement nonfinite import, prototypes,
sparse arrays, or lone UTF-16 surrogates. Full command coverage, native effects and actual checkpoint/resume
integration still need implementation and qualification. Independent tests were
archived before capture/product code; full Lobster/reference gates stay incomplete.
Public JSON conversion is a separate component described below.

## Workflow JSON output and input snapshots

`capture-lobster-json.mjs` executes the complete unchanged JSON renderer and
stable-signature function from the same lock-verified Lobster archive. The
imported `atomic_file.js` definitions run, but no state/file function is called.
Native OS/path/filesystem/crypto bindings are recorded separately. The renderer
uses an explicit stdout-write recorder; compact number/string and successful
clone observations use native JavaScript JSON operations. The private strict
snapshot validator and full workflow runtime are not executed by this oracle.

```sh
node --experimental-vm-modules scripts/openclaw/capture-lobster-json.mjs \
  /tmp/openclaw-488631c /path/to/lobster-2026.9.16.tgz /tmp/lobster-json.json
node --experimental-vm-modules --test scripts/openclaw/lobster-json-functional.test.mjs
```

The core `Synapsis.Workflow.JSON` boundary consumes the existing typed heap:

| Function | Meaning |
| --- | --- |
| `stringify/2` | Compact public JSON; omit object undefined, use null for array undefined, return `:undefined` for an undefined root. |
| `pretty/2` | Public JSON with two-space indentation; no renderer newline. |
| `stable_stringify/2` | Recursively sort ordinary keys by UTF-16 code units, preserving numeric index enumeration and array order. |
| `snapshot/2` | Require finite complete JSON values, then allocate independent clones and normalize signed zero. |

Internal root-plus-heap persistence keeps aliases. Strict input snapshots instead
make independent copies of shared objects; public stringify has different rules
for undefined. Apply these conversions only at their actual workflow boundaries.

Finite numeric output selects minimum decimal digits using exact binary64
rational rounding intervals, with closest/even candidate selection following
ECMAScript's stronger recommended guideline. It applies JavaScript's decimal and
exponent spelling rules without assuming BEAM shortest output selects the same
candidate. String quoting uses lowercase generated control escapes while keeping
literal escape-looking text and accepted UTF-8 unchanged. Existing native/Jason
JSON encoders use different control-escape casing.

Independent literal tests precede product/capture code: 23 ordinary finite number
vectors and eight source/native-JS cases, including a decimal tie, format
thresholds, Unicode stable order, pretty output and alias cloning. This is local
boundary qualification, not an exhaustive binary64 or full JavaScript-domain
proof. Nonfinite/error paths remain source-only; lone UTF-16/prototype/sparse-array
semantics, remaining command families, native execution and actual checkpoint/resume stay open.


## Workflow pure machine and input checkpoints

`Synapsis.Workflow.Machine` uses the parser's stage maps and the existing tagged
Value heap. `new/4`, `advance/1,2` and `resume/2` operate on JSON data. Explicit
construction, pull, post-yield, normal return and finish tasks retain iterator
progress without closures. Array input has replay identity; buffered iterators
and tool-mode `json` remain lazy. No vector is inserted between every stage.

The current command families are `head`, `pick`, `json` and tool-mode `ask`.
`pick` retains missing own fields as undefined and reads dense-array indices and
length. Head's fractional limit is compared after each yield; head zero starts no
upstream iterator. Rendering JSON drains during construction and records original
items plus pretty output. A checkpoint candidate contains the full internal
input_request and tagged pending/history state. Ordinary ask resumes at itself,
restoring its subject without draining the old prefix; `--emit` resumes after it.
A new semantic segment retains the schema-request sequence, not old iterator stacks.
A new ordinary request checks prior pipeline/owner output before history/replay;
forced emit and accepted response replay keep their distinct source paths.

Schema compilation and response validation are explicit pending requests. A
matching trusted-driver acknowledgement advances the machine; the machine does
not validate a schema or generate its own acknowledgement. The host validator
and exact Ajv profile remain unimplemented. Source replay item/byte and history
limits are retained in production source; excluded limit/error paths are not
qualified by ordinary tests. A UTF-16 preview cut producing an unsupported lone
surrogate is an explicit domain error, never silently replaced or sliced differently.

```sh
node --experimental-vm-modules scripts/openclaw/capture-lobster-machine.mjs \
  /tmp/openclaw-488631c /path/to/lobster-2026.9.16.tgz \
  /path/to/dependency-manifest.json /tmp/lobster-machine.json
node --experimental-vm-modules --test scripts/openclaw/lobster-machine-functional.test.mjs
```

This new oracle copies the bounded provenance harness from the runtime capture;
the earlier script and fixture remain unchanged. Twelve complete unchanged
source modules and actual pinned Ajv dependencies execute in 17 ordinary cases,
23 pipeline calls. Initial async-generator input open/yield/finally counters and
command-run wrappers are explicit harness observations. Resume slicing and the
pre-entry call to the exported input_request validator are harness recipes;
public tool_runtime, finalizer, state storage and native effects are not executed.
Own-field observations occur before public JSON drops undefined fields. The
initial Node comparison exposed a VM-array prototype at observation transport;
plain values already matched every independent literal. Converting the complete
observation to host JSON fixed transport, with no case/test expectation changes.

The host checks use explicit schema acknowledgements and prove reducer sequencing,
normal lifecycle, replay/subject semantics and intermediate state JSON roundtrip.
They do not prove actual schema validation, native tool execution, Concord
checkpoint commit, process/database reopen or durable model-facing resume. The
remaining stdlib/file/shell/resource/parallel families and native driver stay open;
whole-reference gates remain incomplete.


The standalone filesystem constructor capture invokes complete pinned
`createReadTool`, `createWriteTool` and `createEditTool` modules with their actual
`(cwd, options)` signature. Seven ordinary cases cover default/empty options and
a prepared read configuration. The real `wrapToolDefinition`, private replay
identity, Code Mode identity copy and internal hook helpers remain original
modules. Only two constants use exact source-byte projections. Explicit
importer-specific throwing bindings defer execution, rendering and argument
preparation; none is called. The fixture retains complete original source text,
source/transform/generated-module hashes, actual TypeBox files and applicable
licenses so the graph is reviewable.

```sh
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node \
  --experimental-vm-modules --disable-warning=ExperimentalWarning \
  scripts/openclaw/capture-filesystem-factories.mjs /tmp/openclaw-488631c \
  /tmp/openclaw-filesystem-factories.json
OPENCLAW_FILESYSTEM_SOURCE=/tmp/openclaw-488631c \
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node \
  --experimental-vm-modules --disable-warning=ExperimentalWarning \
  --test scripts/openclaw/filesystem-factory-functional.test.mjs
```

Use the existing supported Node 24.22.1 and TypeBox 1.3.37; no dependency installation
is performed. The frozen standalone fixture is `488631c/filesystem-factories.json`.
Its metadata is checked against independent source-derived literals and repeated
fresh captures. This file is not yet merged into the canonical `capture.json`;
the generic scanner still needs correct signatures and a separate plural assembly
path. Full `ls`/patch/exec/process/shared-terminal construction, real async
role/profile assembly, filesystem effects, image reads, continuation and production
Worker equivalence remain separate requirements. No whole-tool/action/admission
verification flag or strict gap is closed by this constructor-only evidence.


### Read text page source owner

`capture-read-pages.mjs` executes the unchanged complete `read-page.ts` helper
and its eight complete source dependencies at the pinned commit. The retained
report includes full original bytes for those nine modules, root MIT LICENSE and
original tsconfig, complete type-erased executables/hashes, exact source aliases,
real Node Buffer/AsyncLocalStorage bindings, source singleton/cache identity and
the harness hash. No algorithm projection, handwritten service or source rewrite
participates. All selected-page inputs are explicit literals.

```sh
node --experimental-vm-modules scripts/openclaw/capture-read-pages.mjs \
  --reference-root /path/to/pinned/openclaw \
  --output /tmp/read-pages.json
OPENCLAW_REFERENCE_ROOT=/path/to/pinned/openclaw node \
  --experimental-vm-modules --test scripts/openclaw/read-pages-functional.test.mjs
```

Use the supported Node version above. The eight ordinary cases cover complete
selected text and explicit line-slice continuation; they do not execute read.ts
normalization, UTF-16 selection, a file factory, queues, images or runtime assembly.
The dedicated core `text_read_functional_test.exs` independently checks actual
UTF-8 file snapshots through `Local.read_text/4` and the new `TextRead.page/3` owner.
It retains separate raw details/display text and preserves internal zero-based
`Local.perform(:file_read)`/`page_content` consumers. This is a prerequisite for the
accepted replacement, not an optional parallel model tool or completed cutover.
Image/document handling, Windows decoding, model-context preparation, edit/write
receipts, Workspace/model/config migration and actual Worker/persistence/replay
remain separate integration work. Cap/budget/error branches are source-reviewed
only; excluded scenarios and real providers have not been tested. The canonical
factory/assembly and full tool gates remain open.


### Original-snapshot edit and write-diff planner

`capture-edit-plans.mjs` invokes the actual complete `prepareFileEdit` and
`prepareFileWriteDiff` exports at the pinned commit. Provide a separate exact
`diff@9.0.0` package directory and its original sibling `diff-9.0.0.tgz` archive.
The harness checks the archive SHA-512 against the original pnpm lock, verifies
all 136 extracted files against the archive, and retains their complete bytes and
BSD-3-Clause license separately from the OpenClaw MIT license. It never installs
packages or modifies the reference checkout.

```sh
node --experimental-vm-modules scripts/openclaw/capture-edit-plans.mjs \
  --reference-root /path/to/pinned/openclaw \
  --diff-root /path/to/verified/package \
  --output /tmp/edit-plans.json
OPENCLAW_REFERENCE_ROOT=/path/to/pinned/openclaw \
OPENCLAW_DIFF_ROOT=/path/to/verified/package node --experimental-vm-modules \
  --test scripts/openclaw/edit-plans-functional.test.mjs
```

Use the supported Node version above. This capture records Node24.22.1,
Unicode17.0 and ICU78.3. Its complete graph has 23 original TypeScript modules,
including the actual normalization root barrel and Levenshtein dependency; it
retains source/executable bytes, original aliases, manifest/lock/license and the
harness hash. The real diff ESM entry evaluates its 19-module transitive graph;
all 21 ESM modules and all 136 package files remain in provenance, with actual
module statuses distinguishing loaded from retained bytes.

Eight ordinary edit plans cover original-snapshot matching, reversed request
order, Unicode/UTF16, exact and normalized no-ops, BOM/CRLF, per-span line endings
and successful fuzzy lookup that preserves untouched text. Two write cases call
the actual diff planner for create/overwrite. Full changed diff/patch receipts are
frozen from this genuine execution before production planner implementation.
The harness does not fabricate tool envelopes or execute edit/write factories,
WorkerTaskPool, ordering queues, file writes or persisted-byte verification.
A write-tool no-op is a separate effect-owner contract; this pure capture does
not claim to execute it. No excluded scenarios or real provider is exercised.
Production helper/runtime, filesystem/Workspace effects and model/config/caller
retirement remain pending; pure plans close no full tool or assembly gate.

## Workflow tool invocation source

`capture-lobster-invoke.mjs` executes the complete unchanged `openclaw_invoke.js`
and `read_response_text.js` from the lock-integrity-verified Lobster 2026.9.16
archive. Both `openclaw.invoke` and `clawd.invoke` retain their complete metadata
and help. Four independent ordinary cases retain raw request JSON, input/effect/
output order, per-item argument merging, arrays/scalars and Unicode.

```sh
node --experimental-vm-modules scripts/openclaw/capture-lobster-invoke.mjs \
  /tmp/openclaw-488631c /path/to/lobster-2026.9.16.tgz /tmp/lobster-invoke.json
node --experimental-vm-modules --test scripts/openclaw/lobster-invoke-functional.test.mjs
```

The non-each source command drains its input before invoking during construction.
Each mode invokes serially while consuming input, merges the item into the base
arguments and accumulates returned items. It returns the output stream only after
all calls finish. Array results become output items; scalar results become one
item. These semantics matter when persisting a future Machine effect continuation.

`fetch` is a declared synthetic success transport. Actual native `Response` and
the whole source reader decode its body. The harness verifies the reference
manifest/lock against pinned Git bytes and the full archive integrity, then
records both unchanged modules and its own hash. It installs no package and calls
no real HTTP endpoint. The observed `effect` trace is the source notification,
not a Backplane execution receipt.

This qualifies these source-command cases only. It adds no host command, tool
mapping, native effect, durable consumed cursor, HTTP bridge or lifecycle proof.
The existing public Synapsis workflow still supports its documented pure subset.
No token/authentication, permission, failure, cancellation, expiry, limit or real
provider tests are run by this dedicated test file.


## Lobster state command source qualification

The dedicated state suite executes unchanged `state.get`, `state.set` and
`diff.last`, their real file store/lock/atomic-write/accounting helpers, and the
original core runtime/checkpoint functions from `@clawdbot/lobster@2026.9.16`.
It checks the complete archive's 156 file hashes and 593 existing dependency
files, including the actual Ajv 8.20.0 used by input validation. These are file
closure checks; they do not mean every archived module executes.

```sh
SYNAPSIS_LOBSTER_ARCHIVE=/path/to/lobster-2026.9.16.tgz \
node --test scripts/openclaw/lobster-state-functional.test.mjs
```

Run from the repository root. The default archive path matches the earlier
reference captures. `SYNAPSIS_LOBSTER_NODE_MODULES` can select the same pinned
existing dependency tree; no package is installed. `SYNAPSIS_STATE_ORACLE_ROOT`
selects a task-owned temporary parent. Each run extracts a new subtree, writes
only fixture state, and removes its owned files after ordinary completion. Pure
home-directory resolution is checked without writing to the home state directory.

Seventeen independent literal cases cover eager drain/read and lazy returned
streams, original references versus fresh parsed aliases, exact two-space JSON
and newline, UTF16 keys/strings, numeric conversion, stable diff and unchanged
writes, real lock ownership, and private LLM provenance restored as replay only
when the remembered decoded text matches. Exactly 64 successful remembered
writes and an existing-key rewrite run; a 65th-entry eviction is source-reviewed
only. Fresh processes execute original same/next checkpoint functions and retire
their checkpoint files. No provider or LLM completion is called.

These are original-source results, not a Synapsis state-command implementation.
The whole default registry/embedded wrapper is not executed because its `yaml`
dependency is unavailable. The pinned OpenClaw runner caches its imported runtime;
that process-lifetime behavior is source evidence, not established by the fresh
process tests. Production integration still requires an explicitly resolved state
scope, write-always atomic file transitions, correct process-lifetime provenance,
the shared numeric prerequisite described below and durable native effect acknowledgement. Public
state-directory and lossless-output decisions remain independent. No security,
permission, authentication, malformed/error, cancellation/crash, TLS, mixed-suite,
budget-overflow or real-provider tests are run.


## Lobster shared binary64 prerequisite

`Workflow.Number` imports validated decimal tokens with exact integer-rational
nearest/ties-even rounding. The existing Value importer retains the native JSON
grammar and UTF16/order adapters. Overflow becomes signed Infinity, underflow
retains signed zero, and trusted number tags retain NaN payload/sign bits without
constructing nonfinite BEAM floats. Current Machine numeric comparisons, where
coercion, native head arguments and String/table consumers share this domain.
JSON still renders nonfinite numbers as null; strict snapshots remain finite.

Numeric NaN comparisons are nontransitive, so a stable comparator alone does not
reproduce JavaScript sorting. A real source witness is `[3,1,0,NaN,2]`: ascending
reference output is `[0,1,2,3,NaN]`, whereas the former Enum.sort candidate differed.
When any selected key is numeric NaN, Machine allocates one key-array root and
borrows its existing PortSession for `sort_items`. The unchanged decoder rebuilds
keys, the worker calls native decorated-array sort once with the original
comparator, and returns occurrence indices. PortSession and Machine independently
validate the correlated complete permutation; Machine reorders its original roots.
Non-NaN numeric keys retain the pure stable path. No new execution or state owner,
validator cache, journal effect, dependency or fallback is introduced.

```sh
node --test scripts/openclaw/lobster-number-functional.test.mjs
SYNAPSIS_WORKFLOW_SORT_HELPER_ROOT=/path/to/staged-workflow-package \
SYNAPSIS_WORKFLOW_SORT_NODE=/path/to/configured/node \
node --test packages/tool-host/test/workflow-number-sort-functional.test.mjs
```

The independent numeric source suite executes 40 actual original command calls
in one Node test. Its initial final counter expected40 but observed39 after all
semantic assertions passed; the retained baseline and a separately grounded NaN
witness explain the correction. Original semantic expectations are preserved.
Eleven core tests cover actual Machine/helper transitions, JSON state roundtrips,
and safe textual projection before same/next checkpoints and a fresh Machine.
The independent helper suite performs 28 sorts per session across 13 homogeneous
numeric datasets, ascending/descending, through source and physically relocated
599-file helpers on each selected engine. Four tests execute112 helper requests;
52 original sort oracle calls are shared across source/relocated tests. The same
actual helper PID handles schema cache growth0→1→2, sorting leaves it unchanged,
and normal close/exit is observed. Node24.19.0/V8 node.51 and configured
Node24.21.0/V8 node.53 are qualified against the source on that same executable.
This is not a claim of identical inconsistent-comparator permutations on all V8s.

The owning-core integration passes196 tests, with seven existing ordinary public
Worker/native/Concord finite regressions separately. The current public Segment
starts with input[] and ordinary JSON cannot produce NaN; the new admitted sort
dispatch is source-reviewed, not a genuine public NaN execution. No producer or
prepared-state seed is invented. Mixed/non-numeric inconsistent comparators,
full state commands/IO/provenance/operation receipts and public state-directory
and lossless-output choices remain incomplete. See the batch254 evidence at
`/tmp/synapsis-session254-number-0zr7l32y/summary.json`. Security/permission/auth,
negative/failure/cancel/crash/TLS/mixed/budget/real-provider tests are not run.


## Lobster state command semantic requests

The existing pure Machine now represents `state.get`, `state.set` and `diff.last`.
Get requests at construction without pulling input. Set/diff drain first, retain
one original root or allocate a zero/many array, and request exact ordinary pretty
JSON plus LF; root undefined remains literal `undefined\n`. No strict snapshot
or JSON roundtrip replaces the original returned roots. Keys remain original
parsed arguments; filename and directory selection belong to the future driver.

Requests use the existing counter/phase with prefix `state:`. A trusted get ACK
supplies captured decoded text for fresh shared Value import. Set ACK consumption
yields the original value. Diff ACK supplies observed before text and changed;
Machine independently checks stable JSON agreement, then creates ordered
`kind,key,changed,before,after`, preserving the original after root and fresh
before graph. The pure State helper has no IO, cache, provenance or executor.

The independent `machine_state_functional_test.exs` contains22 ordinary tests.
The frozen baseline failed22/22 at unsupported commands; unchanged assertions
pass22/0 after implementation, with218 owning-core integration tests and seven
existing finite public native regressions. Source expectations came from pinned
whole state/diff/store reads and the previous17 original source tests; those source
tests were not rerun or added to this batch's count. Test state ACKs are declared
literal semantic fixtures. Only schema checkpoint requests use real PortSession
and Schema; same/next fresh Machine slices do not reissue consumed state requests.

These results do not prove Local publication/locking/fsync, private provenance,
state journal/CAS/Concord or actual admitted/public state execution. The public
command allowlist is unchanged. Source-only missing/corrupt fallbacks, pending
state-directory/source-scope and public lossless-output choices remain open. No
security/permission/auth, negative/failure/cancel/crash/TLS/mixed/budget/real-provider
tests run. Evidence: `/tmp/synapsis-session255-state-machine-smymai0_/summary.json`.


## Lobster Local state byte operations

Local now offers a dormant single-operation guardian for locked capture,
write-always and a locked byte transition. The caller registers its actual native
ResourceRegistry handle before run; Local remains an internal host API. Workflow
code retains JSON, stable comparison, provenance and durable operation receipts.
The existing trusted root, Access lease, five-second operation and ten-MiB limits
remain. Native state driver/public activation are still absent.

Actual publication uses an exclusive sibling temporary, full write, file fsync,
descriptor close, atomic rename and containing-directory fsync. Created ancestor
links are synced. Same bytes still replace the inode. Explicit IO start/ACK and
monitored non-raw descriptors prevent worker DOWN being treated as proof that a
file-server rename cannot still publish; unknown cleanup retains ownership.
The settled guardian stays alive until exact close ACK plus actual normal DOWN.

Five independently frozen positive tests pass unchanged from a missing-interface
5/5 baseline. A separate frozen public-call trace test passes1/0 and correlates
actual descriptor/sync/close/rename acknowledgements, ancestor syncing, dormant
zero file calls and identical-write inode replacement. The real native registry
fixture confirms register-before-run and ordinary cleanup; it is not Agent state
execution. Integration is43 Core with2 failures plus2 native factory tests with0
failures. The two unchanged helper exact-envelope cases also fail with beforeLocal
loaded in a fresh VM: fixtures expect Node24.22.1 while configured runtime is24.21.0.
Those failures and the initial unsupported diagnostic CLI option are retained;
no unrelated tests/fixtures or runtime configuration were changed.

Original Node crossprocess lock interoperability is unrun. Exact creation-mode
parity and subsecond reclaim without process start identity remain unqualified;
a possibly live owner without usable start identity is conservatively retained.
Excluded branches remain source-reviewed only. Private provenance/cache, versioned
state journal/Concord, actual admitted/public workflow state and pending public
directory/envelope choices remain incomplete. Security/permission/auth and other
excluded tests are unrun. Evidence: `/tmp/synapsis-session256-state-io-9ebntqc9/summary.json`.


## Lobster live private provenance graph

Private provenance now has one application-lifetime bookkeeping owner under the existing core supervisor. Public Value v1 heaps and Machine snapshots retain their existing JSON shapes. Volatile bindings identify the owner incarnation, active graph and writer lease outside durable state. Heap deltas preserve local object identity and synchronize both object mutation and direct group-array append.

The pure Machine observed APIs return the unchanged ordinary transition plus explicit shallow-spread, accepted state.set and accepted state.get observations. Live publishes the node delta and private actions together before returning. The remembered cache stores lexical paths, exact captured decoded text and live graph roots. It follows post-write nested mutation and shared call replay; it does not freeze a write-time provenance tree. Fresh gets allocate new replay identities per marked object. Normal lease release keeps cache-reachable nodes and removes unrelated graphs/calls; JSON reopening starts an independent unmarked graph.

Independent source execution passed8/0 on configured Node24.21.0 with unchanged156-package/593-dependency pins. Independent core assertions were frozen before implementation; their21/21 baseline failures were exclusively the absent Owner interface. After one independently diagnosed helper-path-only correction, unchanged expectations pass21/0; combined Workflow checks pass239 Core/0 plus7 existing native workflow/0. The new21 are already included in239. Product repairs0. Original frozen tests, failing log and exact AST-checked harness transform are retained. Source state/invoke ACKs and private mark actions in core tests are semantic/model fixtures, not actual file, native provider or state-driver receipts. Only the genuine schema checkpoint uses the existing PortSession.

This batch adds no production Agent driver, state Journal/Concord receipt, trusted LLM producer or public state activation. Source lock-held carry still requires a later read-only Local callback; capacity eviction, abnormal cleanup, trusted charge restoration and other excluded domains remain source-only or unqualified. Pending public state-directory/source-scope and lossless envelope choices remain open. Full P13/OpenClaw alignment is incomplete. Evidence: `/tmp/synapsis-session257-provenance-j8rca20o/summary.json`.

## Lobster lock-held read callback

Local now accepts the internal `{:read_locked, callback/1}` operation. StateFile captures actual bytes under the existing physical-path and external file locks, invokes the existing monitored callback and returns its exact domain term in `value`. Normal callback exit is confirmed before lock release. The existing deadline check and created-directory evidence remain; reads introduce no target publication or file fsync. Plain `:read_locked` keeps its byte-only summary with `value:nil`.

Three independently frozen ordinary tests failed before implementation solely because this request was unsupported, then passed unchanged. They cover exact binary capture, unchanged bytes/inode, lock-held actual Machine/Live decode and provenance carry, driver-owned binding after callback retirement, and an actual same-path writer queued until carry finishes. An identical-byte publication then updates remembered provenance for a later read while the earlier fresh root retains its identity. Integrated checks pass29 Core/0 plus2 native filesystem factory/0; the new3 are already included in29. Product repairs0.

This closes the Local callback prerequisite described above. Marks and state ACKs remain internal semantic/model fixtures around real Local file IO, not production Agent state or durable Journal/provider receipts. Agent/Journal/Segment/Concord/helper/public producers are unchanged. The state Journal/CAS, admitted driver, trusted LLM/charge restoration and pending public directory/source-scope/lossless choices remain open. Prior256's two unrelated helper Node-metadata failures are unresolved and unrerun. Security/permission/auth and other excluded tests are unrun. Full P13/OpenClaw alignment remains incomplete. Evidence: `/tmp/synapsis-session258-read-callback-ogwjc5mz/summary.json`.

## Lobster state path and text computation

The existing owned compute helper now accepts `state_key_path` and `decode_state_text`. The former uses the original JS `String(key).toLowerCase()` and ASCII/underscore filters followed by `node:path.join`, including dotted-I and Kelvin-sign behavior. Its explicit directory retains source spelling and relative lexical identity. The latter shares the existing `decode_template_file` Buffer UTF-8 decoder; it does not parse semantic state JSON. PortSession validates the correlated six-field success receipt and unchanged validator-cache count. There is no filesystem IO, path admission, directory default or new process owner in these operations.

Independent literals cover17 successful paths and7 valid UTF-8 texts. The oracle imports the whole unchanged pinned original store module and uses actual filesystem UTF-8 reads; it does not invent an original raw-text public API. Archive identity,156 regular files,74 original JS files and the27175-byte/751-line store are checked. Baselines fail only the unsupported new operations:4 Node helper cases and4 Core cases, with all helpers closing normally. Frozen tests then pass5 Node/0 and4 Core/0 on source and physically relocated complete packages. Each runtime family completes48 new compute requests,14 legacy decodes and92 total requests with the same PID/cache and normal exit. The package retains599 artifacts; only worker/provenance change, with all other597 files byte-for-byte unchanged and the existing package assertion changed only to the new worker hash.

Qualification covers the supported primitive/string key domain and ordinary valid UTF-8; general object-key coercion and malformed-byte cases are unqualified. Production Agent state, IO Journal/CAS/Concord, trusted LLM/charge restoration, and public directory/source-scope/lossless choices remain open. Prior256's unrelated Node metadata failures are unresolved and unrerun. Security/permission/auth and other excluded checks are unrun; full P13/OpenClaw alignment remains incomplete. Evidence: `/tmp/synapsis-session259-state-compute-ws9np7nh/summary.json`.


## Lobster internal admitted state driver

The existing Agent driver now offers opt-in Segment v3 / Journal v2 for an ordered
`native_effect` / `state_operation` union and one consumed cursor. Existing v1/v2
contracts remain. Explicit internal scope captures admitted root, source directory
spelling and absolute cwd; public workflows/catalog and directory defaults remain
unchanged. Actual get/set/diff use registered Local guardians and the owned helper.
Pending CAS gates IO; immutable state fact ACK precedes waiting-settled CAS, then
consumed CAS. Get decodes, parses and publishes carry exactly once inside the
locked callback. Set remembers after write; diff writes even unchanged and emits
no cache action. Every actual Machine/helper/resume transition publishes through
Live once. Fresh resume starts from an unmarked loaded pre-import heap and claims
before constructors, without repeating writes or warming durable provenance.
Private retirement closes the original lease identity after quiescence regardless
of the sequence advanced inside a callback. No new store or process owner exists.

Independent new tests pass4 Core/0 and4 Agent/0. Actual integration is39 Core/0
and9 Agent/1, including the new8; four separately selected Template regressions
pass. The old journal fixture still selects retired file_read/file_write and fails
unsupported_capability. A fresh VM loading the exact nine before-source modules
reproduces that same1/1 failure; it is left unchanged. Two post-freeze trace-only
fixture corrections include the existing cleanup supervisor and distinguish nil
construct events from request-phase schema ACKs; all expected results and nonempty
claim-order assertions remain. Originals and exact transformations are retained.
An initial mixed file:line command selected only four Template tests and excluded
the other files; corrected integration actually ran the counts above. Format and
dev compile pass. Core baseline4/4 lacked the constructor; Agent baseline4/4 stopped
at trace setup for the absent run_state/3 interface, before admission/IO.

This qualifies internal admitted state execution, real IO facts/CAS and ordinary
same/next ask resume. Public directory/source-scope and lossless-envelope choices,
public activation, trusted LLM/charge restoration and full state/P13 alignment
remain open. Native v3 representation is source-reviewed; mixed execution is
unrun. Prior256 Node metadata failures remain unresolved/unrerun. No security/
permission/auth, negative/failure/cancel/crash/TLS/mixed/budget/eviction/real-provider
tests run. Evidence: `/tmp/synapsis-session260-state-driver-nh2hln3p/summary.json`.


## Canonical native Effect and Goal Journal regression fixtures

The two original provider-free Effect cases and the Goal-backed Journal case now
select `synapsis::read`/`synapsis::write` and assert the exact content-block and
diff/patch result contract. The genuine issued root starts with an empty target
ledger and delegates registration/preparation to production SessionAdapter.
Repeated reads retain distinct native children; exact file bytes, immutable
facts, pending/fact/settled ACK order, Goal delegation/unbind, normal resource/OS
retirement and fresh readers after writer exit remain covered. Production code
is unchanged.

The original Effect baseline fails2/2 at retired-name selection before IO; the
unchanged Journal baseline is retained from batch260's exact-before-module1/1
reproduction. The first updated fixtures fail3/3 at an invalid whole-snapshot
comparison. Build-time classifiers capture no catalog, while projected ones
capture the admitted catalog. One independent trace-only correction observes the
actual production projection's exact inputs/return and public field relation,
without changing file/result/revision/dispatch/Goal/CAS/reopen expectations.
Initial files, logs and exact patch remain. Updated cases pass3/0; integration
passes39 Core/0 plus13 Agent/0, with those3 already included in13.

Filesystem fixtures use the existing capture-runtime Node24.22.1; managed Node
and other selected helper checks retain24.21.0. No cross-version parity or
configuration change is claimed. Other legacy Goal/seven-target fixtures and
prior256 Node metadata failures remain outside this run. Public state policies,
activation and trusted LLM/charge restoration remain incomplete. No security/
permission/auth or other excluded checks run. Evidence:
`/tmp/synapsis-session261-native-journal-81j9drvf/summary.json`.


### Diffs request preparation (internal only)

The pinned `diffs` tool distinguishes before/after text, unified patches and the
identical-content result. `capture-diffs-request.mjs` executes exact original
source projections through the render-target selection. It records source-byte
ranges, wrapper/executable hashes and the precise helper bindings. It does not
execute the complete factory/callback, renderer, viewer store or browser.

`Synapsis.Diffs.Request.prepare/2` accepts schema-admitted typed arguments and an
explicit resolved defaults map. It preserves source text, normalizes display
metadata, prepares layout/theme/export options and TTL, or returns the unchanged
content result. Its JSON plans are compared with ordinary pinned-source vectors
and independent literal expectations. Raw callback numeric strings and aliases,
saved configuration, URL construction, rendering, artifact publication, tool
admission and delivery are outside this stage. No project file is read or edited.

```sh
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node \
  --experimental-vm-modules --disable-warning=ExperimentalWarning \
  --test scripts/openclaw/diffs-request-functional.test.mjs
devenv shell --no-tui -- env MIX_TEST_PARTITION=session262 mix test \
  apps/synapsis_core/test/synapsis/diffs/request_functional_test.exs
```

Capture regeneration takes the pinned checkout and an explicit output filename;
it installs no dependencies. The frozen receipt is `diffs-request.json` next to
the capability map. This adds internal preparation evidence only; `diffs` remains
unimplemented at the public catalog/render/delivery boundary.


## Ordinary readable web-fetch reference (batch361)

`capture-web-fetch.mjs` executes 32 complete unchanged modules from OpenClaw
`488631c18fae7cc541ba8fc8beff6cbb0438787b`, including the actual public factory,
response decoder, JSON branch, cache, Markdown helpers and Readability extractor.
It uses actual TypeBox1.3.37, Readability0.6.0, Linkedom0.18.13 and entities8.1.0;
source transformations, import edges, generated facades, package-file hashes,
license and every returned result are recorded in `web-fetch.json`.

Use the existing Node24.22.1 capture runtime. The separate reference dependency
root must contain those three extraction packages at their exact versions. It is
a temporary oracle environment, not a Synapsis production dependency or bundle.
The default root is `/tmp/synapsis-webfetch361-evidence/reference-runtime`; set
`OPENCLAW_WEB_FETCH_DEPENDENCIES` to another prepared root for tests, or pass it
as the fourth positional argument after checkout and output to regenerate.
The scripts do not install dependencies.

```sh
/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node \
  --experimental-vm-modules --disable-warning=ExperimentalWarning \
  --test scripts/openclaw/web-fetch-functional.test.mjs
```

Ten ordinary tests cover 13 source scenarios: plain/Markdown/text, readable HTML
and XHTML with title, declared/BOM/document charset decoding, JSON/+json numeric
source tokens, complete result metadata, a guard-reported final URL, successful
repeat cache reuse and an explicit successful provider callback. Fixed clock and
wrapper-marker bytes make the complete capture reproducible without rewriting
results. These are independent literal expectations plus exact fixture comparison.

Acquisition is a synthetic successful Response, with explicit finalUrl and normal
release. There is no real HTTP, redirect traversal, network-guard qualification,
plugin/provider discovery, late-bound config or Firecrawl implementation test.
Errors, cancellation, spill/truncation/eviction, security/permission and production
consumer execution remain outside this reference qualification. Backplane#157
was resolved by official Backplane1.10.61 (batch391). The separate batch392
production direct-document consumer below does not promote whole-reference
factory/assembly gates.


## Production readable document consumer (batch392)

`packages/tool-host/src/web-fetch` and `scripts/build-web-fetch.mjs` package23
unchanged original/reference files and21 complete dependency locations with
licenses, exact lock records, per-file hashes and enumerated source import edges.
The helper receives acquired bytes, performs pure source computation and has no
network or session state. Its actual qualified executable is the existing trusted
`SYNAPSIS_FILESYSTEM_NODE` Node24.21.0. Build with that executable; `--output`
produces a byte-identical relocated artifact. Readability0.6.0,
Linkedom0.18.13 and entities8.1.0 are exact direct pins.

Core owns actual successful HTTP acquisition, relative/absolute redirects,
chunked multibyte reconstruction, one live five-second ceiling and normal helper
retirement. Native revision2 is derived from the original configured Services
metadata before authority/admission. Full document JSON is projected once into
provider continuation and Part/Concord. Same-run cache hits preserve original
markers/timing; normal new-Worker history replay repeats no acquisition/helper.

Frozen ordinary suites: `packages/tool-host/test/web-fetch-functional.test.mjs`
(14), `apps/synapsis_core/test/synapsis/web/fetch_functional_test.exs` (15), and
`apps/synapsis_agent/test/synapsis/session/native_readable_web_fetch_functional_test.exs`
(3). Run Mix only with a checked fresh `MIX_TEST_PARTITION`. These use real local
Gaoxy HTTP, the production packaged helper and original native Backend/Worker.
The legacy mixed fetch suite is preserved and unrun. Provider/plugin discovery,
LLM instruction processing, spill/threshold/full-factory equivalence and all
security/permission/auth plus established excluded suites remain unqualified.
Evidence: `/tmp/synapsis-web392-evidence/summary.json`; final review and managed
activation are recorded there separately from functional success.
