# 04 — Boundaries

## App-Level Boundaries

### Official native dependency baseline

The active native runtime is official Backplane `1.10.61`, with
`backplane_json_schema`, `backplane_mcp` and `backplane_schema` at `1.10.60` and
`ex_json_pointer 0.9.0`. AI, skill and plugin remain `1.10.57`. The HTTP core/fetch
closure is `1.0.0-rc.8`, adopted separately with MCP in batch 351. Historical
caller evidence below retains the versions actually executed.

Backplane #157 supplies the opt-in revision-2 `Web.ReadableFetch` behaviour.
The host selects its adapter before native catalog admission, receives the
validated extraction controls and original invocation/deadline context, and owns
HTTP acquisition, decoding, extraction and cache. Native results retain the
complete portable document map. The existing raw fetch profile remains revision
1 for its standalone callers and legacy history. The selected Agent consumer now
uses revision 2: Core acquires unchanged bounded response bytes, the packaged
pure Node helper runs pinned source decoding/Readability/Markdown/exact JSON,
and Core returns only after normal helper/Port/broker retirement. Agent projection
serializes the complete public document once; existing Worker/Part/Concord history
retains it. A process-local cache partitions successful results by trusted Agent
scope and native run/session binding; both cache lookup and insertion carry the
same absolute live deadline as acquisition and computation. The helper contains
no HTTP or session authority. Ordinary local qualification covers successful
redirects/chunks, full documents, same-run reuse and distinct-Worker reopen;
provider discovery, LLM instruction processing, spill/threshold controls and full
source factory/assembly equivalence remain outside this bounded consumer.

Backplane #153 provides `:tool_result_contract`, a trusted host callback over
the registered descriptor and invocation identity. It chooses finite native
external-size and nested JSON allowances before effect dispatch. The selected
contract is retained in the native intent and used for direct delivery and Code
Mode transport without selecting it again. It does not change provider accounting,
Code Mode program/output limits, or install a global allowance. Production Skills,
workshop and canonical default-resize read consumers now select their scoped
contracts. Skills readers and Agent-private workshop discovery were installed in
batch 348; larger completed-history qualification remains separate.

Passive native snapshots record public APIs and the actual dependency versions
without executing tools. Ordinary direct/native Deno tests qualify the selected
contract's normal intent/completion/reconstruction flow in an EphemeralStore;
this is not a Worker/Part/Concord or full-size Skills acceptance claim. Earlier
caller scenarios retain their recorded versions until actually rerun.

The earlier five-package `1.10.57` cohort retained `1.10.53` library implementation
and introduced the current HTTP closure. Its gateway Responses lifecycle release
did not enable lifecycle routes in Synapsis or authorize migration or deployment.
Backplane #151 (retained command inspection), #152 (stdin EOF) and #154 remain
independent caller requirements; package API availability does not install those
consumers or transfer execution evidence.
The original direct and Code Mode catalog-revision scenarios now select canonical
`synapsis::read` and call `tools.synapsis__read` in the nested program. Only those
two names changed in the fixture. Its original assertions still verify batch 1
pinned to revision 1, public staging of the same members to revision 2, unchanged
construction descriptors, actual host/MCP/clock execution, Deno yield/wait and
normal retirement, complete provider/Part/Concord results and fresh Worker replay
without repeating shell or MCP effects. Production code and dependencies did not
change in this caller migration.

The first 1.10.57 integration's two failures remain archived: the old fixture
selected retired `synapsis::file_read` and stopped before runtime creation. A new
same-version before/after run reproduces both failures and passes both original
cases after the two substitutions; it does not establish a pre-upgrade baseline.
The complete original seventeen-file ordinary integration now passes Provider
8/0, Core 3/0, MCP 4/0 and Agent 30/0, seed 238239. This closes the two-scenario
regression gap from the dependency adoption. Its separate metadata case passes
1/0 with six excluded; compilation, passive capture/check and exact dev/test
package-version observations remain distinct evidence. WebSocket execution,
TLS/HTTP3, excluded paths and full OpenClaw alignment remain unqualified.
Evidence: `/tmp/synapsis-backplane237-xaxr6746/` and
`/tmp/synapsis-catalog238-tugawaf6/`.

### Canonical read image results

Canonical read images use the same distinction as Skills: an exact issued
Filesystem descriptor and trusted native invocation select the transport
allowance before dispatch. The existing Runtime.Store operation retains that
selection. A named `synapsis::read` v2 Part is a finite display/history contract;
it neither proves historical execution origin nor grants execution authority.
Only the unchanged successful source image envelope selects v2: ordered text
then image, with matching image-kind details, text and MIME. Ordinary text,
document advice and existing v1 history keep their current representation.
The provider mapper checks the same image envelope and sends content only.

The current production default resizes images according to the source. Its
4.5 MiB base64 ceiling plus a 1 MiB envelope reserve yields a 5,767,168-byte native
allowance; nested JSON and display reserve 11,010,048 bytes, with a 5,767,168-byte
string allowance. Base64 requires no JSON escaping; the metadata reserve allows
sixfold escaping. Prepared targets supply only an empty prefix or the existing
resolved-basename note. Explicit resize-disabled contexts retain native defaults.
These are scoped finite allowances, not a global limit or new source file cap.
They do not establish full-size native aggregate fit or provider qualification.

Ordinary Responses direct and Deno nested cases retain a fixed complete PNG
through the next fixture request, Parts/JSON, Concord and normal fresh Worker
replay. Source-compatible Anthropic direct image support is independent; its
codec rejects native custom CodeMode inputs, so it is not used for these nested
cases. Larger provider continuations remain stopped for Gaoxy #24; the original
Skills corpus and fixture transport stay unchanged. Full 4.5 MiB, resize-disabled,
accumulated-media, other-provider and whole-reference qualification remain open.

### First-party operator input provenance

`Session.InputContext` owns two portable version-1 input shapes. The existing
messaging shape retains explicit provider/account/conversation/sender bytes.
`capture_operator/2` receives a host-supplied requester and fixed `rest`, `channel`
or `liveview` origin, producing `kind: operator`, `trigger: user`, source session
and a fresh input UUID. Shape validation is not authentication. Core neither
imports agent identity nor invents messaging identities for the local operator.

The REST message action, session channel message event and LiveView shared submit
path capture the accepted `Approval.operator_id()` on each ordinary text/image
submission. Context is a separate trusted argument. REST/channel path images use
the same encoder as the existing Sessions API; LiveView supplies its already
decoded image parts to `send_message/4`. Existing primary response, trim and queue
behavior is retained.

The existing Worker lane carries that map unchanged to native root host context,
PendingInputStore, Message and Concord. The input UUID is the prompt/message ID;
queued promotion retains the same identity. Old internal send arities, child
inputs and system events keep their existing contracts. This producer adds no
native tool or execution owner. Steer/retry/regenerate, personal-instruction
eligibility and standing-intent execution remain separate work. Source-format
SessionDirectory history projection still omits these operator contexts; raw
Message/Concord custody does not imply that projection exposes them.

### synapsis_data → Runtime aggregate commits

`Synapsis.Runtime.Store` persists opaque run aggregates; the agent layer owns
their transitions and effects. Run commits read the decoded value and storage
`mod_revision` together through public `Concord.KV.get` with `engine: :turso`
and `metadata: true`. The legacy `Concord.Turso.get` delegates to `Concord.get`
and does not expose this metadata contract.

The store checks the current aggregate's logical revision and incarnation, then
uses Concord 3.1.10's public `Concord.Turso.compare_and_swap` against the observed
storage revision. An absent initial aggregate uses storage revision zero. Logical
and storage revisions are distinct. Only an acknowledged successful CAS returns
`:ok`; conflicts and errors retain the existing return contract. There is no
retry or alternate writer. Complete new history and outbox values remain one
atomic aggregate, within Concord's 16 MiB logical-value limit, without copying
old and new values into the generic 1 MB transaction envelope. Facts and
projections retain their existing transaction path.

A valid aggregate commit establishes one requested five-second deadline for its
metadata read and subsequent CAS. It recalculates a positive remaining timeout
before each public operation, returning `{:error, :timeout}` before dispatching
another operation if the budget is exhausted. Other store operations retain
their existing per-call timeouts. Concord 3.1.10 carries the caller's point,
metadata and batch-read budget through connection checkout, readiness/migration
and SQL, with checks around decoding and decompression; this consumes the
upstream fix for Concord #111. Already-running synchronous native work is not
forcibly interrupted. The composed requested budget does not establish a hard
wall-clock return bound or prove absence of late writes. A known successful CAS
acknowledgement retains its success contract without a post-CAS timeout check.
This does not give agent-level load/fence sequences or other mutation consumers
a shared deadline; those require separate contracts and verification.

### synapsis_data → Recent turns and context list admission

`Session.Store.list_recent_turns/2` uses Concord 3.1.10's public descending,
key-only list. Each page requests only the remaining number of turns, capped
at 10,000. Descending continuation retains the original inclusive lower bound
and uses the lowest returned key as the exclusive upper bound. Selected keys
are returned to the existing value-read path in ascending order, preserving
chronological results and positive limits greater than one upstream page.
Older inventory is not enumerated or decoded to select a short recent tail.
Each list call explicitly queues within five seconds; the existing API does
not acquire a new whole-call deadline or snapshot-consistency guarantee.

`list_turn_page/2` keeps its ascending cursor, canonical-key filter, 512-seek
limit, byte bound and shared caller deadline. Each one-key seek now opts into
Concord's public finite queue with the remaining timeout. This replaces the
previous immediate list admission during overlapping normal pending-input
reads. No retry, sleep, local lock or pool change is added. Ordinary automation
context and wake acceptance use their original assertions. Query-readiness
and value-read deadline limits remain distinct from queued list admission;
this does not establish an end-to-end hard deadline for those consumers.
Session-directory latest-message and inline-history enrichment still require
their own consumer implementation and acceptance.

`Session.Store.list_recent_turn_page/2` supplies the shared-deadline data
prerequisite for those consumers. It selects canonical newest turn keys with
public descending, queued, key-only one-key seeks and an optional exclusive
older-index cursor. At most 512 seeks include the lookahead and any skipped
noncanonical keys. The selected page is returned chronologically as
`%{index: index, turn: turn}` rows; `next_cursor` is the oldest returned index
only when a further canonical key exists. Index zero and an empty namespace
are valid ends. Defaults are 20 turns / 64 KiB decoded external size, with
limits of 100 turns / 1 MiB. Key selection and selected value reads use the
same caller deadline, capped at five seconds; the lookahead payload is not
read. These are already-read payload limits, not pre-decode allocation or hard
interruption guarantees. Each call independently observes durable state,
without session-existence, liveness or cross-page snapshot guarantees.

Existing recent and forward APIs retain their contracts. The new descending
page does not itself enable model-facing previews or duplicate OpenClaw's
display projection. Reference preview selection also handles hidden and
forwarded messages, assistant display phases, silent replies, media directives
and Markdown; inline history and derived-title rules are distinct. Those
consumer contracts require actual reference execution and production wiring.

### Session directory deadlines and durable snapshot ownership

The native `SessionDirectory` adapter reads Backplane's live `effect_deadline`
getter before removing runtime-only context. Its absolute monotonic deadline
is clipped to the five-second ceiling captured at execute entry, passed to
core `SessionDirectory.list_rendered/3`, and checked after content and native-wrapper
serialization. Ordinary standalone calls without that getter retain the local
five-second ceiling. A supplied inactive or malformed getter never falls back
to a new allowance. Native error values remain native errors. This composes a
requested read/output budget; synchronous storage work is not forcibly interrupted.
The directory schema, result shape, selection and current-durable read contract
remain unchanged.

`Synapsis.Session.ReadSnapshot` provides a data-only capture/page/index/validation
API for later preview/inline/title consumers. `capture/2` binds a canonical
session UUID, the actual historical metadata Record's `create_revision`, one
committed revision R, and the existing local `Concord.Turso.DB` pool PID. It
retains the real key-only Record and the independent same-R metadata value.
Handles are invocation-local opaque BEAM values; their PID is never a persisted
or public JSON token. Existing current-state Store/page APIs remain unchanged.

`read_page/2` uses that same R and original absolute deadline for ascending or
descending exclusive-index pages, returning complete opaque turns in
chronological order. Only canonical twelve-digit turn keys select values;
one extra canonical key establishes continuation without reading its payload.
Each page allows 1..100 selected values and at most 512 queued one-key seeks,
including skipped/lookahead keys. A caller can read a head, a tail of 20, then
widen to 100 at the same R without recapturing current data.

`tail_index/2` counts every canonical turn key at the captured R and returns a
bounded newest suffix of `%{index: physical_index, ordinal: dense_rank}` entries
in chronological order, together with exact `total_turns` and `has_older`.
Ordinals are one-based ranks in that snapshot, independent of sparse physical
indexes and metadata `turn_count`. Retention defaults to 100 and allows
1..10000. Descending public `KV.list` calls use queued, keys-only pages of at
most 100 Records, the original owner and absolute deadline, and validated
range/order/continuation. The scan retains only the requested suffix while
counting older keys, without turn-value reads, a fresh revision or a total-key
ceiling. It never returns a partial count as success.

The index byte limit defaults to 64 KiB and allows up to 1 MiB. Each page is
charged together with retained indexes; the final result is also charged.
Discarded pages do not accumulate against this bound. Exact counting costs
O(total keys) storage traversal and O(retained indexes + one key page) decoded
storage, under the original deadline. This prepares an internal history reader;
it does not expose inline messages, alter public SessionHistory or replace the
existing page's 100-value limit.

`validate_many/1` checks 1..200 distinct captured lifecycles at one later common
committed V, using only exact-key historical metadata Records. It preserves
input order and reports `same_lifecycle` for each target; absence or a changed
creation revision is false, while storage errors remain errors. It neither
reads point payloads nor chooses which public rows to omit. Every call checks
the original pool identity and remaining deadline before/after storage and
before success. Capture clips its caller deadline to five seconds; pages
retain it and multi-target validation uses the earliest original deadline.

Capture and page byte limits default to 64 KiB and allow up to 1 MiB. Capture
counts its complete returned term; a page counts its complete term plus all
returned key-only Record bookkeeping, including lookahead/skipped records.
Validation counts returned Record bookkeeping and its result within 1 MiB.
These are already-decoded term bounds, not pre-decode allocation or native
scan-work bounds, and the deadline cannot forcibly interrupt native work.

This owner fence is qualified for the configured local file-backed pool and
ordinary reconnects to the same file; it is not a database-incarnation API for
external file replacement, in-memory or remote-synced storage. Full consumer
assembly, display projection and final visibility checks remain separate.
OpenClaw's lifecycle generation survives ordinary appends and metadata edits;
neither a global revision change nor `updated_at` equality is its substitute.
The data binding preserves that distinction. Each target has its own R; final
validation shares V without requiring one initial transcript snapshot for all.

The official Concord/ex_turso/viewstamped_replication 3.1.13 cohort retains the
historical reads introduced in 3.1.12 and supplies
bounded historical prefix/range lists in both orders, including key-only Record
metadata and cursor continuation at the captured revision
([concord#113](https://github.com/gsmlg-dev/concord/issues/113)). Compose those
Records with independent `Concord.KV.get(..., engine: :turso, revision: r)` point
values at the same revision. The legacy `Concord.Turso.get/2` is not equivalent.
Capture revisions after all writers upgrade: earlier discarded versions cannot
be reconstructed, historical retention is not automatically compacted, and TTL
visibility uses current wall-clock time. No lifecycle-bound preview consumer is
enabled by this dependency adoption.

The 3.1.13 documentation clarifies that a non-nil `:revision` takes precedence
over `:metadata`: `KV.get(metadata: true, revision: r)` returns a value.
Historical Record assertions therefore continue to use the public list API
([concord#115](https://github.com/gsmlg-dev/concord/issues/115)). This is a
documentation clarification, not a changed return shape. No synthetic Record
or dependency patch is used.

A storage snapshot also cannot repair intermediate logical publication.
`replace_turns/2` now issues one public `Concord.Turso.replace_prefix/3` command,
including an empty replacement, and leaves session metadata untouched. The
primitive retains 16 MiB per value and a 64 MiB command envelope, unlike generic
transactions (128 operations/1 MB), and retains
creation revision while incrementing retained-key versions
([concord#114](https://github.com/gsmlg-dev/concord/issues/114)). It requests a
five-second operation budget and preserves a known successful acknowledgement;
uncertain errors do not prove rollback and require reconciliation before retry.
The wrapper has no retries or separate-write fallback.

The 3.1.13 public primitive admits 501 total replacement puts, preserving the
existing 500-turn capacity together with one related metadata pair
([concord#116](https://github.com/gsmlg-dev/concord/issues/116)). Generic batch
APIs remain capped at 500; configured lower limits and the existing byte limits
still apply. `Store.replace_turns/3` publishes turns and the full supplied raw
metadata in that one command. It removes only the turns prefix, preserves
unrelated session keys, and overwrites retained metadata without changing its
creation revision. Empty and shrinking rewrites use the same command.

`Message.persist_list/3` retains the existing message encoding and delegates to
that coupled API. Fork and import publish their destination metadata and copied
or converted messages together. Snapshot publishes its raw metadata with the
updated turn count and encoded messages together, including an empty transcript.
Existing turns-only arities remain available with their metadata-untouched
contract; normal runtime append and automation paths keep their existing coupled
APIs.
No 499-turn cap, split write, retry or fallback is introduced.

One destination publication does not make earlier source metadata/transcript
reads atomic or resolve existing read-modify-write races, optional count policy,
or metadata-only struct round-trip behavior. Lifecycle validation and complete
display/inline/title consumer assembly remain separate; this writer migration
does not enable model-facing previews.

### synapsis_core → Public API

The core exposes these context modules as the sole interface:

```elixir
# Session lifecycle
Synapsis.Sessions.create(project_path, opts)        # => {:ok, session}
Synapsis.Sessions.get(session_id)                     # => {:ok, session} | {:error, :not_found}
Synapsis.Sessions.list(project_path, opts)            # => [session]
Synapsis.Sessions.delete(session_id)                  # => :ok

# Messaging (starts the agent loop)
Synapsis.Sessions.send_message(session_id, content)   # => :ok (async, results via PubSub)
Synapsis.Sessions.cancel(session_id)                  # => :ok
Synapsis.Sessions.retry(session_id)                   # => :ok

# Tool permission responses
Synapsis.Sessions.approve_tool(session_id, tool_use_id)  # => :ok
Synapsis.Sessions.deny_tool(session_id, tool_use_id)     # => :ok

# Provider management
Synapsis.Providers.list()                             # => [provider]
Synapsis.Providers.models(provider_name)              # => [model]
Synapsis.Providers.authenticate(provider_name, key)   # => :ok | {:error, reason}

# Config
Synapsis.Config.resolve(project_path)                 # => config_map
Synapsis.Config.update_user(key, value)               # => :ok

# Project management
Synapsis.Projects.list()                              # => [project]
Synapsis.Projects.get(id)                             # => {:ok, project} | {:error, :not_found}
Synapsis.Projects.find_or_create(path)                # => {:ok, project}

# Session extras
Synapsis.Sessions.list_by_project(project_id, opts)   # => [session]
Synapsis.Sessions.recent(opts)                        # => [session]
Synapsis.Sessions.fork(session_id, opts)              # => {:ok, session}
Synapsis.Sessions.export(session_id)                  # => {:ok, export_data}
Synapsis.Sessions.compact(session_id)                 # => :ok | {:error, reason}
```

### synapsis_server → Endpoint, Router, Channels

`synapsis_server` owns all Phoenix infrastructure: the Endpoint, Router, Plug pipelines, Channels, and REST controllers. It defines no OTP application — `SynapsisServer.Supervisor` is started by `SynapsisCore.Application` at runtime.

```
Endpoint:  SynapsisServer.Endpoint
Router:    SynapsisServer.Router
Socket:    SynapsisServer.UserSocket (at /socket)
LiveView:  /live socket (for LiveView connections)
```

### synapsis_web → LiveView Pages

`synapsis_web` owns all LiveView modules, HEEx templates, and function components. It depends on `synapsis_server` and defines no OTP application. LiveView owns pages and server state. Forms and chat use published DuskMoon React islands under [ADR-010](../decisions/ADR-010-react-form-islands.md) and [ADR-011](../decisions/ADR-011-react-chat-islands.md). [ADR-007](../decisions/ADR-007-pure-liveview-ui.md) documents the earlier pure-LiveView decision.

**LiveView pages** (all under `SynapsisWeb.*` namespace, routed from `SynapsisServer.Router`):

```
GET  /                                        DashboardLive        — landing
GET  /agent/agents[/new|/:id/config]          AgentLive.Agents     — agent CRUD + config
GET  /agent/tools[/new|/:id/edit]             AgentLive.Toolsets   — toolset CRUD
GET  /agent/skills[/new|/:id/edit]            AgentLive.Skills     — skill CRUD
GET  /agent/agents/:agent_id/sessions[/:id]   AgentLive.Sessions   — chat view
GET  /workspace                               WorkspaceLive.Explorer
GET  /settings                                SettingsLive         — appearance
GET  /settings/providers[/new|/:id]           ProviderLive.Index/Show
GET  /settings/models                         ModelTierLive.Index
GET  /settings/memory[/new|/:id]              MemoryLive.Index/Show
GET  /settings/skills[/:id]                   SkillLive.Index/Show
GET  /settings/mcp[/new|/:id]                 MCPLive.Index/Show
GET  /settings/lsp[/new|/:id]                 LSPLive.Index/Show
```

The MCP server create/edit forms accept HTTP headers as `Name: Value`, one per
line (for example, `Authorization: Bearer <token>`), not JSON. Config writes reject
invalid HTTP header names, non-string values, and disallowed control characters
before persistence; the forms display a header-format error on rejection.

Appearance at `/settings` owns the Auto, Light, and Dark theme controls; the
appbar only links to Settings. The browser stores the preference in `theme`
localStorage (`auto`, `sunshine`, or `moonlight`). Auto follows system color-scheme
changes on every page; existing Sunshine/Moonlight preferences remain valid.

`AgentLive.Sessions` and Provider Test Chat mount `dm_react_chat`. LiveView projects canonical messages, publishes ordered streaming events, validates scoped requests, and acknowledges admission. React owns Markdown, the editable composer, attachments, and transcript scrolling; the agent runtime remains independent of the browser mount lifecycle.

Agent tool results use `SynapsisWeb.ToolResultView` to read the existing checked
`Part.ToolResult.projection`. Live and historical chat snapshots carry a display
view instead of duplicating the raw projection. The React chat renders ordered
literal text, inline PNG/JPEG/GIF/WebP image representations, expandable public
JSON sidecars, and public error fields. Image bytes are preserved; generic URI-only
media, resources, and audio expose metadata without fetching their references or
printing inline media bodies. Native speech with a durable delivery reference has
the user-controlled audio player described below. Unsupported content is explicitly labeled, and an invalid
projection has an explicit display error. Legacy text parts and older chat
snapshots retain their text fallback. Code-agent tool results correlate with the
original tool-use ID, preserving call order when results arrive out of order.
This presentation layer does not change runtime results, persistence, or provider
media support.

`Synapsis.PDF.Source` owns bounded binary acquisition for PDF analysis; Agent
owns model selection, analysis and final-result persistence. Remote acquisition
follows HTTP 301/302/303/307/308 with at most three redirects, resolving each
Location against the current URL. The same download task and absolute deadline
cover the whole chain, with the existing byte bound and source checks applied
at each hop. Req automatic redirects and retries remain disabled. The initial
resolved input stays in provenance and native document metadata even when the
download URL changes. Completed Worker history reuses the final analysis without
downloading the PDF or invoking an analysis provider again. This does not claim
complete remote-media transport parity or real-provider verification.

PDF automatic selection uses the same Agent analysis and provider execution path.
Data owns optional saved model `input` modalities and `selection_order`; unknown
modalities remain distinct from an explicit list. `Models.ordered/1` preserves
provider-local selection order while `Models.list/1` retains picker ordering.
Non-destructive import records supplied metadata and new-list order without
changing existing model UUIDs, enabled state or user choices. The existing
provider discovery cache retains those optional fields.

Provider owns the immutable pinned OpenClaw document-model metadata and the
read-only saved-provider/model availability snapshot. An explicit
`ProviderConfig.config.media_understanding.profile` precedes an exact known
preset and then an exact canonical provider name. Source-shaped metadata fields
(`capabilities`, `autoPriority`, `defaultModels`, `nativeDocumentInputs`,
`documentModels`) can override that profile; lists replace and nested maps merge,
including literal false document hints. Snake-case field aliases are accepted.
Transport and URL do not establish a media profile. Each saved provider UUID
remains a distinct execution instance. Defaults only participate when an enabled
saved model can execute; selection never imports or enables providers/models.
Configured provider order uses the existing saved-provider name order; legacy
models without an authored order use the existing deterministic model-ID order.
Lost historical configuration-array order is not reconstructed.

Agent PDF.Model preserves explicit PDF/image configuration precedence, then
resolves native, generic-image and text-extraction lanes in the pinned order,
including configured-primary text preference and native-primary preference. The
actual image-capable active model fills only the final empty selection. Automatic
native PDF requires declared document support and an installed Anthropic/Google
codec. Existing explicit native behavior remains compatible. Worker.Config keeps
the saved Agent/project default separate from the session override; SessionAdapter
binds the active identity to the final provider/request pair used by that run.
The admitted fingerprint includes all ordered saved model/provider/profile and
availability inputs, source revision and both identities. Invocation re-reads
saved Agent/model/provider state and retains the trusted in-flight project
snapshot, through existing CatalogBinding/Session validation. No new store,
process, registry or execution path owns this selection.

Explicit host references remain prefixed, trimmed and deduplicated with the
existing ten-candidate limit; source bare-reference expansion, explicit duplicate
fallbacks and timeoutMs behavior remain differences. Arbitrary Unicode/case
collation, excluded lifecycle branches and real-provider behavior remain
unqualified. These boundaries do not establish whole PDF reference parity.

`Synapsis.Workspace.Media` owns immutable local audio objects for speech
capabilities. `put_audio/3` and `read_audio/2` preserve opaque MP3, Opus and WAV
bytes and return a portable descriptor containing a stable
`synapsis-media://audio/<sha256>.<format>` reference, digest, byte count, format
and MIME type. This reference identifies local media; it is not a download URL.
The default root is `media` under `Synapsis.Config.Store.config_dir/0`; trusted
host callers can supply an explicit root. Objects live separately from the
document BlobStore, whose orphan collector only recognizes document/version
references. Session or native resource cleanup must not delete published media.

Publication writes and syncs a unique staging file, then publishes the complete
object with an atomic hard link that does not replace an existing object.
Repeated writes retain the existing object, and reads verify its digest within
the configured byte bound. The descriptor is derived from the immutable object
identity, so it requires no separate mutable metadata record. Operations check
an explicit monotonic deadline between filesystem stages; a native caller must
still run them in its supervised effect task to bound a blocked filesystem call.
File sync and atomic publication do not establish directory power-loss durability
or a transaction with Concord. Interrupted calls can leave staging/orphan files;
this boundary adds no retention or automatic recovery policy. The Agent delivery
service below supplies HTTP/UI consumption; channel delivery is separate.

Native `synapsis::tts` is available only when explicitly selected and the enabled
Agent has `config.tts.provider` naming a saved, available OpenAI-compatible speech
provider (`openai_speech`, `openai`, `openai_compat`, `openai_responses` or `groq`). Optional
`tts.model`, `voice`, `speed`, `instructions`, `response_format`, `extra_body`, `max_bytes` and
`media_root` configure speech and its host-owned output location. Speech models
need no chat-model catalog entry. The tool uses fresh provider runtime settings;
descriptor contexts retain bound identities and fingerprints rather than resolved
credentials. It shares the existing native admission and supervised effect path.
Saved Provider addresses use the application's API-root convention. This host
binding trims whitespace and trailing slashes and appends `/v1` unless the address already ends
in `/v1`, preserving any preceding custom prefix. The speech adapter continues
to accept an explicit API prefix and appends `/audio/speech`. This maps the saved OpenAI and Groq roots
to `/v1/audio/speech` and `/openai/v1/audio/speech` respectively.

The dedicated `openai_speech` type is offered through the explicit OpenAI Speech
preset, with an editable `https://api.openai.com` root and the existing credential
reference. Its type-derived capabilities are `[:tts, :stt]`; `elevenlabs` declares
`[:tts]`. These describe implemented speech operations rather than adding a new
persisted capability policy. Both types are excluded from LLM model operations.
The new preset is not automatically seeded, and existing provider types, saved
references and defaults retain their behavior. Creation, cards and detail show
both OpenAI speech capabilities; the detail retains the saved-name `tts.provider`
instruction and connection editing, with no LLM Models/Test Chat panels or
unimplemented Agent STT configuration instruction.

`Speech.OpenAI.resolve_config/1` is the explicit raw configuration boundary:
`providers.openai` precedes `openai`, then the root record; a selected empty record
masks lower records. It follows ECMAScript trimming and removes raw URL trailing
slashes. `build_request/2` and `synthesize/2` receive resolved configuration, whose
trimmed URL retains trailing slashes. Pure Talk callbacks accept the source's
modelId/voiceId fields and inherit the base extra body. Metadata and voice listing
are static (four models, fourteen voices). Ordinary synthesis supports MP3, Opus
and WAV; a telephony target still uses ordinary format selection. The separate
`build_telephony_request/2` and `synthesize_telephony/2` force PCM at 24 kHz. Public
extra-body values merge last on the wire; result metadata retains the selected
format. These APIs add no Talk, channel, voice-note or phone consumer.

`Providers.openai_speech_config/2` rereads the current saved UUID, name, API root,
referenced credential and advanced settings. It normalizes saved fields before
explicit Agent overlays; connection and credential authority stay with the saved
provider. Saved timeout aliases are ignored. Native tool timeout wins over the
explicit Agent timeout, then the 30-second host default, with one T+5-second
effect allowance. HTTP receives original T and the original effect absolute
deadline; timer normalization occurs at the HTTP boundary. Media publication,
immutable delivery, Parts, Concord and normal completed replay retain their
existing owners. Ordinary completion does not establish crash recovery.

The OpenAI Speech detail exposes static model/voice selectors and custom choices
for custom routes. Route classification uses the same ECMAScript-trimmed raw
resolver as provider preparation, including persisted BOM-surrounded official
roots; it does not rewrite the saved raw connection. Changes remain transient
until explicit save, which rereads
the UUID and updates only model/voice, preserving current advanced settings,
connection and credential. Each field's custom-entry option uses a token distinct
from its saved literal value, frozen at mount through transient changes and
provider refresh, then recomputed after save. This retains legitimate provider
names such as `__custom__` without interpreting them as blank editor values.
Mount, change, save and reopen issue no catalog or synthesis requests. No model seed, preview, ambient credential fallback or new
readiness authority is introduced.

A saved provider of type `elevenlabs` is a speech-only alternative for the same
`config.tts.provider` reference. It reuses provider UUIDs, credential resolution,
TOML persistence and the native TTS effect/publication path. It is excluded from
LLM model migration, discovery, suggestions and request execution; Registry does
not classify it as an LLM adapter. Existing LLM provider behavior is retained.
The native binding passes its base URL unchanged to `Speech.ElevenLabs`, which
owns `/v1/text-to-speech/<voice_id>` and the `output_format` query. The default
endpoint is `https://api.elevenlabs.io`; a custom prefix is retained.

The Providers creation page offers an explicit ElevenLabs preset with an editable
endpoint and the existing credential selector. It is not seeded automatically and
creation does not discover LLM models. Preset, saved-provider cards and the detail
page identify its text-to-speech capability. The detail page retains connection
editing and displays the saved provider name for an explicit `tts.provider`
reference; it omits the LLM Models and Test Chat panels. Existing LLM provider
panels are unchanged. The ElevenLabs detail adds free model/voice inputs with six
advertised models and custom values, optional advanced speech settings, and an
explicit asynchronous voice catalog refresh. Mount, save and reopen do no HTTP.
Drafts are separate from the mounted saved baseline: save rereads the current
UUID and writes only intentionally changed fields, preserving newer untouched
raw settings, unknown fields, connection and credential references. Edited
model/voice aliases are replaced by canonical keys. No automatic Agent
configuration or synthesis tester is added.

ElevenLabs uses `voice_id`, `model_id`, `seed`, `apply_text_normalization`,
`language_code` and nested `voice_settings` (snake-case fields). These options may
be saved in Provider config, with Agent TTS options overriding them. Agent
`tts.output_format` and `latency_tier` become explicit synthesis overrides; they
are not read from provider config. Defaults are voice `pMsXgVXv3BLzUgSXRplE`,
model `eleven_multilingual_v2` and file format `mp3_44100_128`. Native delivery
accepts only MP3, Opus and WAV families and stores their normalized media format;
the provider adapter retains the full vendor format. Unsupported media families
are excluded before synthesis. Its standalone atom-key adapter can return other
opaque format families without publishing them. There is no decoding, transcoding,
automatic channel or telephony consumer in this slice. The standalone service
provides nested-only raw resolution, Talk config/override composition, metadata,
voice catalog, fixed PCM22050 telephony and true incremental HTTP streaming.
The supervised stream task delivers original transport chunks; Finch returns
the connection at normal EOF, while the logical owner remains until explicit
idempotent release joins its task and monitor. Handles are invocation-local.
Current UUID preparation resolves saved camel/snake options before partial Agent
overlays. Host lookup prefers snake string, snake atom, camel string, then camel
atom, including nested voice settings, consistently with the settings UI. The
source raw resolver retains its camel-only contract. Preparation takes the root
from the current provider connection rather than merged speech options, and uses
the current credential. Saved timeout aliases do
not determine T; native execution passes original T and the original absolute
Backplane deadline. Result
`details.provider` identifies `elevenlabs`; existing OpenAI-compatible results
continue to identify `openai`. Ordinary local fixture evidence is separate from
real-provider acceptance and interrupted-call lifecycle verification.

A saved Inworld Speech provider uses the same native TTS, UUID, credential and
media owners. Providers.inworld_speech_config/2 rereads its current UUID/name,
connection root and credential. Saved model, voice and temperature aliases are
selected by presence in snake string, snake atom, camel string, camel atom order,
then normalized before partial Agent overlays. Speech options cannot replace the
current connection root or key; saved timeout aliases do not establish T.

Speech.Inworld owns nested-only source config, Talk composition, ordered model
metadata, buffered synthesis, fixed PCM22050 telephony and explicit voice listing.
The /tts/v1/voice:stream endpoint buffers NDJSON and concatenates decoded audio;
it has no incremental streaming callback. File output is MP3, note output
OGG_OPUS, and phone output PCM22050. Only MP3 has a native publication consumer.
The native effect passes original T and the same absolute Backplane deadline D;
HTTP, body parsing and actual linked task completion share H = min(now + T, D).
The effect joins the HTTP task before using Media and MediaDelivery under D.
Completed transcript/result reconstruction reuses the durable delivery fact
without synthesizing or publishing again.

The Inworld detail card offers four models, free custom model/voice values and
optional temperature. Its explicit asynchronous Refresh voices action rereads
the current UUID inside the task. Catalog order, duplicate IDs and available
name/description/locale/gender survive projection. The catalog remains ephemeral.
Draft and baseline are separate; saves patch only intentional edits into the
newest raw config, keeping untouched aliases, advanced fields and connection
references. Numeric-equivalent temperature text does not rewrite an untouched
saved number. Mount, change, save and reopen perform no provider HTTP.
Ordinary local completion evidence does not qualify real providers or interrupted
effects.

`text` and optional `channel` are trimmed. This slice accepts an absent or empty
channel for ordinary audio-file output; channel-specific delivery is unavailable.
The provider timeout defaults to 30 seconds and `timeoutMs` is bounded to 60
seconds, with another five seconds reserved for media publication. Synthesis has
no automatic retry. Publication checks that deadline between filesystem stages;
a blocked filesystem call remains bounded by the existing native effect timeout
of 600,000 ms, rather than being interrupted at the five-second reserve.
Success publishes audio before native result settlement and
returns `(spoken) ...` text with durable media metadata. `details.audioPath` and
`details.media.mediaUrl` contain the stable media URI, while
`details.mediaDescriptor` contains its portable descriptor. These are local
references, with no automatic download, playback or voice-note delivery. Concord
retains the result metadata and transcript; it does not contain the audio bytes.
Completed history is replayed through the existing result projection, without
calling synthesis or media publication again. Interrupted calls, ambiguous
settlement and recovery require separate lifecycle acceptance.

Native `synapsis::decision_evaluate` is selected separately and requires an enabled
Agent with `config.decision.provider` naming a saved `openai_responses` or `openrouter` provider
and a required `config.decision.model`. This explicit section declares the chosen
native Decisions capability; chat discovery or provider readiness does not prove
remote model support. There is no conversation-model fallback or implicit model.
Profiles/SessionAdapter install the native descriptor and classifier together.
`Agent.Tools.Decisions` pins Agent/provider UUIDs, config/authentication generation
and an opaque per-bundle runtime generation, then revalidates before execution.
`Provider.Decision` owns bounded input and provider-neutral result validation.
`Decision.OpenAI` owns POST `/decisions`; `Decision.OpenRouter` owns POST
`/systemone`, both relative to the effective API prefix. Saved roots use the
existing `/v1` host convention, preserving preceding custom prefixes. OpenRouter
requires the explicit model `typesafe/jev-1.13`, `typesafe/jev-1.14` or
`~typesafe/jev-latest`. Agent `decision.params` overrides saved provider params;
nested `provider` routing preferences merge fieldwise. Only OpenRouter's
`provider` preferences are supported; OpenAI accepts no nonempty params. Effective
private headers are consumed, while nonempty request/proxy/TLS settings are not
supported. This is an explicit host configuration adaptation, not reference
configuration inheritance or account/model discovery.

The generic V2 contract represents boolean/choice/score/tags/box/sort with tagged
text/JSON/image/list evidence. Lists retain at most 120 unique supplied IDs; sort
requires list evidence and box requires image evidence. Legacy text/JSON retains
the original three question kinds. PNG/JPEG/WebP images have a separate 4 MiB
decoded bound; evidence uses the reference finite-JSON accounting and encoded
1 MiB bound, 20,000 nodes/depth 32, at most 256 legacy or 400 V2 questions.
These are evidence limits, not a whole HTTP upload cap. Generic choice has no
255-alternative limit; the executable OpenAI and OpenRouter adapters each do.
OpenAI executes boolean/choice/score over text/JSON/PNG/JPEG/WebP. OpenRouter Jev
executes those three kinds over text/JSON/PNG/JPEG, plus box on 1.14/latest;
JSON null/scalar numbers/booleans, absent instructions and sort/tags/list are
unsupported there. Jev scores require 2–10 nonnull criteria. Generic acceptance
does not establish provider support: valid unsupported combinations return an
explicit unavailable result without HTTP or chat fallback. Sort/tags execution,
other providers, inherited decision-model settings and dynamic capability
discovery remain outside this slice. No ambient history, files or tools accompany
supplied evidence.

Native function arguments are semantic maps. The adapter sorts object keys by
UTF-16 code units recursively for canonical serialization, including OpenAI's
submitted question/choice arrays and JSON evidence/criterion strings; arrays and
literal text retain their order and contents. OpenAI matches response names
against the actual submitted question order. OpenRouter retains JSON evidence
and structured instructions/criteria as JSON values, and preserves image caption
presence, including an explicit empty string.
Original JSON insertion order and ECMAScript number/escaping bytes are not
preserved. This can change inference and usage; equal reference answers are not
claimed. Rubric IDs therefore use the host-versioned `synapsis-decision-v1-`
prefix with 24 SHA-256 hex characters over canonical questions, excluding state.

One native effect owner sets a 30-second absolute budget including preparation,
shortened by the native effect allowance. Its linked HTTP task owns checkout,
request and bounded response consumption, with a 1 MiB raw response cap and no
retry. Task shutdown waits for exit. Transport/deadline ambiguity remains
`unknown_outcome`, without replaying the request. Ordinary success preserves the
returned model, explicit choice/fractional score, finite provider confidence and
distributions without thresholding, argmax or normalization. OpenAI usage retains
only input/output tokens. OpenRouter also preserves returned provider metadata,
optional USD cost (zero differs from absent), complete extended usage in `raw`,
and box coordinates; native Jev confidence is a probability while generic
confidence may be any finite provider metric. Generic results also represent
explicit abstentions, units and per-question errors without manufacturing answers.
OpenAI per-question refusals have an explicit error mapping;
failure/cancellation paths and real-provider behavior have not been tested in
this slice. The complete public outcome and host provenance enter model-visible
JSON text and retained details, using the existing Part/Concord projection and
completed-history replay. No separate decision store or execution chain exists.

`Synapsis.Agent.MediaDelivery` binds published audio to its original host location.
The native TTS effect writes an immutable `audio_delivery` fact through
`Synapsis.Runtime.Store` after `Media.put_audio/3` and before successful result
settlement. Data owns the exact fact read/write API; Agent owns the versioned
fact schema and native publication flow; Workspace owns all audio bytes and
digest verification. Each fact has the five-field descriptor, expanded original
root, original byte bound, and selected native invocation provenance. Fresh
delivery UUIDs distinguish invocations even when a provider reuses a tool call ID.
No new database, executor, queue, metadata process or mutable lookup index is added.

The public `details.mediaDelivery` contains only `version: 1`, `session_id` and
`id`; physical paths remain in the private fact. The portable descriptor and
transcript remain unchanged. Reads use the stored root and bound, then compare
the verified object's complete descriptor with the fact. They do not consult
current Agent configuration or session ownership metadata, so changing the Agent,
media root or byte bound does not relocate an already published delivery.
Audio publication, fact publication and native settlement are separate durable
steps. A failed settlement may leave an orphan object or unreferenced fact; no
automatic retry, deletion, retention or recovery policy is implied.

`GET /api/media/audio/:session_id/:delivery_id` delegates to this service and
returns the verified complete audio body with its MIME type and byte length.
This route is outside the JSON-only accepts pipeline. It serves whole `200`
responses and advertises `Accept-Ranges: none`; partial responses and random
seeking are not implemented. Media's filesystem deadlines remain checks between
stages, not interrupts for blocked syscalls. The controller performs no provider
work. Missing deliveries and unavailable storage remain distinct HTTP outcomes.

`ToolResultView` derives a same-origin audio URL from the checked descriptor and
public delivery reference. The shared chat result renderer supplies native audio
controls with `preload="none"` and a download/fallback link, without autoplay.
The same display is used for live, historical and code-agent results. Neither
the server-side presenter nor the browser guesses a filesystem location. Older
descriptor-only results retain their transcript and metadata with an explicit
"Audio delivery unavailable" display: their original custom root is not
recoverable from the portable descriptor. Any later locator migration requires
authoritative original location evidence and must not rerun synthesis or rewrite
the old transcript. Generic audio blocks remain metadata references; MP3/Opus
byte conservation is separate from browser codec decoding and channel delivery.

Delivered audio can also appear as a standalone `Part.Audio`, with only the
portable `descriptor`, public `delivery` reference and optional display `name`.
Data preserves these values in Part JSON and Message/Concord turn encoding;
REST and channel history retain the rich part. Both provider-history paths use
the same pure `Audio.summary/1`, bounded below 2048 UTF-8 bytes, without fetching
audio bytes or rerunning synthesis. This representation supplies no message
producer, inbound upload, recording, transcription or Agent activation policy.

SessionChat and tool results share `ToolResultView.audio_delivery/2`, preserving
the existing descriptor checks and versioned URL construction. The standalone
part uses its display name, or `audio.<format>` when absent. The React message
and tool-result paths share `AudioContent`: native controls, `preload="none"`,
no autoplay and the same download link. Projection performs no storage reads;
the existing HTTP reader continues to verify the original immutable delivery.
Unavailable display references fall back to the bounded summary. MP3, Opus and
WAV use their existing MIME and complete-body/no-Range delivery contracts.

Generated images use the same immutable media publication mechanism through
`Media.put_image/3` and `read_image/2`. The supported opaque formats are `png`,
`jpeg` and `webp`, with canonical image MIME types and a five-field descriptor
whose URI is `synapsis-media://image/<sha256>.<format>`. The default image byte
bound is 64 MiB; audio retains its 16 MiB default and existing URI/layout. These
functions do not decode images or establish visual quality. Published objects
remain outside document garbage collection and session/resource cleanup.

`MediaDelivery.publish_image/4` writes an immutable `image_delivery` fact with
the original root, byte bound and explicit invocation provenance. Its public
reference has the same version/session/delivery UUID fields as audio, while
`read_image/2` and `image_url/1` select the image namespace explicitly. Image and
audio facts retain separate namespaces without changing historical audio facts.
`GET /api/media/image/:session_id/:delivery_id` returns the verified whole image
body with its canonical MIME type, length and inline filename. Reads do not run
a provider or consult current Agent configuration. This is a storage and HTTP
delivery API, without image tool installation, chat presentation or a completion
queue. Publication and fact creation are separate durable operations; failed or
interrupted generation must not be replayed to reconstruct missing artifacts.

Opaque generated video uses `Media.put_video/3` and `read_video/2`. Its five-field
descriptor retains the exact supplied MIME string, including aliases, casing and
parameters. Only the base MIME selects the storage format, matching the existing
xAI adapter's AVI/M4V/MP4/MKV/WebM/FLV/WMV/MOV mapping. An unknown base keeps its
original MIME and uses the adapter's `mp4` filename label; no conversion or codec
support is implied. The stable URI is `synapsis-media://video/<sha256>.<format>`.
Video retains the 16 MiB default and existing filesystem publication/deadline
semantics. Its reader accepts the complete descriptor: a URI alone cannot recover
the original MIME alias or parameters. The shared pure
`Media.validate_video_descriptor/1` checks this descriptor contract for both
storage and publication without reading bytes or duplicating the MIME mapping.

`MediaDelivery.publish_video/4` retains the descriptor, original root/bound and
invocation provenance in the separate immutable `video_delivery` namespace.
`read_video/2` passes the complete stored descriptor to Workspace;
`video_url/1` builds `GET /api/media/video/:session_id/:delivery_id`. This serves
the verified complete body with its original MIME, size and inline filename,
advertising `Accept-Ranges: none`. It does not consult current Agent settings,
call a provider, add a sidecar/index, decode media or establish browser playback.
Audio and image APIs and historical facts retain their existing shapes.

This video artifact API does not install a native tool or implement submission,
provider task custody, a durable completion queue, original-route completion
turns, cancellation or restart recovery. Fresh delivery UUIDs identify independent
publications; they do not make a repeated completion publication idempotent.
Media publication and fact creation remain separate durable writes. Native video
integration still needs stable task/occurrence receipts and a selected custody
contract; no automatic generation replay follows from the storage API.

Delivered assistant video messages have a dedicated Data `Part.Video` carrying
only `descriptor`, `delivery` and optional `name`. Both Part JSON and Message
turn encoding preserve these public values; Snapshot delegates to Message, so
Concord reload and REST/channel history retain the rich part. Data does not call
Workspace or Agent. This representation adds no completion producer or role policy.
Ordinary model history projects Video through the same pure `Video.summary/1` in
the runtime bridge and direct provider mapper. Its six text fields each retain at
most 320 UTF-8 bytes, keeping the total below 2048 bytes. No video bytes or native
provider video content block enter this projection; the durable part stays rich.

The shared SessionChat projection validates the existing complete descriptor and
builds its URL through `MediaDelivery.video_url/1`. The existing DuskMoon React
chat renderer displays native video controls with `preload="none"`, no autoplay,
and a download link; unavailable display references fall back to the bounded
summary. HTTP retains its complete-body/no-Range contract. A generated local
one-second H.264 MP4 fixture covers this renderer and byte transport; that does not
establish support for every MIME alias, remote generation, background task custody
or original-route completion delivery.

Delivered assistant images have an additive Data `Part.DeliveredImage` with only
`descriptor`, `delivery` and optional `name`, serialized as `delivered_image`.
Part/Message JSON, Concord and explicit REST/channel history preserve these public
values. Existing inline `Part.Image` persistence and provider vision blocks remain
unchanged; no migration or image-generation producer is introduced. Both ordinary
provider-history paths project the same pure bounded text summary (six fields of
at most 320 UTF-8 bytes, total below 2048 bytes), retaining the rich durable Part.

SessionChat builds the existing `MediaDelivery.image_url/1` and a bounded display
name. The distinct React branch displays and downloads that stable URL using the
existing image sizing behavior. It does not derive a path from the descriptor or
read media during projection. The existing HTTP reader verifies the immutable
fact and image bytes. A locally generated 128×96 PNG fixture establishes the
representation path separately from native generation and task completion.

Installed Backplane 1.10.49 retains the published #136/#137 fixes: genuine native
`image_gen::imagegen` revision 2 has image-specific effect metadata and supplies
invocation-local identity, ownership and live deadline to the adapter. The former
upstream blockers are closed and adopted; package support does not install the
host generator. No replacement backend or descriptor override is used.

The native image service still waits for its adapter result. An arbitrary artifact
map is not an asynchronous task receipt. The fixed OpenClaw session flow requires
asynchronous generate/list/status, then persisted completion delivery to the
original conversation before a follow-up model turn. Its provider work is
process-local; durable completion recovery does not establish safe replay of an
interrupted paid provider request. A separate native-backed lifecycle surface,
job lifetime and unavailable-original-destination behavior require explicit product
decisions. The genuine Headless execution composition uses the existing native
Conversation, without a provider loop. The timer/generator yield fix for
`gsmlg-opt/backplane#140` is now published and adopted in official 1.10.49.
Package adoption removes that publication gate; it does not install a production
Headless/image-job consumer or settle the pending lifecycle decisions. No local
workaround or replacement execution loop is introduced.

The dedicated ordinary `headless_code_mode_functional_test.exs` composes native
Headless and the original `:code_mode_only` catalog with a real Session binding,
clocks, Deno and one admitted fixture effect. The effect is held only to observe
the already-committed intent and live worker. An observing adapter delegates all
storage operations and returns the real `Synapsis.Agent.Runtime.Store` ACKs
unchanged. Automatic timer/generator continuation preserves ordered output and
executes the effect once; final result and revision match the stored record,
normal Deno exit is observed and Session close is confirmed. This fixture has no
provider or production job consumer. It does not force #140's precise internal
interleaving; the upstream deterministic scheduling tests are source-reviewed.

`Synapsis.Provider.Transcription.OpenAI` is an explicit bytes-in/text-out
OpenAI-compatible transcription adapter. `build_request/2` prepares ordered
multipart fields (`model`, optional `language` and `prompt`, then `file`);
`transcribe/2` performs one bounded POST to the versioned API prefix plus
`/audio/transcriptions`. The standalone OpenAI wrapper defaults to
`gpt-4o-transcribe`, without selecting an Agent provider or enabling preprocessing.
Request text uses JS-compatible trimming, including BOM; internal whitespace and
case remain. Filename normalization uses the pinned POSIX basename/AAC rules.
Blob MIME normalization and the empty-type multipart fallback remain separate.

The caller supplies audio bytes and a finite positive `timeout_ms`. The adapter
reads neither files nor application configuration, and performs no transcoding.
The streamed JSON response defaults to a 16 MiB raw-byte bound, independently
configurable through `max_response_bytes`; it imposes no audio upload-byte cap.
Success returns trimmed text, including empty silence, and the selected request
model. An initial raw JSON UTF-8 BOM is consumed before parsing; trimming a BOM
inside the transcript remains a separate normalization step. The response's
other metadata does not replace that model.

Call it inside an existing supervised execution task. Its linked HTTP owner and
whole-request deadline bound completion, and requests use the shared Req.Finch
instance without retries. The saved-provider entry point
`Synapsis.Provider.Transcription.transcribe(provider_name, request)` resolves an
explicitly persisted, available `openai_speech` record and its current runtime
credential. It checks both provider UUID and speech type, normalizes the saved
root to a versioned `/v1` prefix, and delegates the request unchanged to the
existing OpenAI adapter with only its API key and endpoint. The returned text and
model retain the adapter contract; no chat model is inherited. The HTTP timeout
does not establish a shared deadline for configuration reads plus HTTP.

This service does not register a model tool, admit attachments, persist
transcripts or change the text/image message contract. Audio upload/recording,
Agent STT configuration, preprocessing, transcript projection and durable input
replay remain separate integration requirements.

`Synapsis.Provider.VideoGeneration.XAI` owns the inactive explicit xAI video
protocol. The fixed OpenClaw 488631c provider supports text or first-frame
generation, ordered reference images, remote video editing and extension. It
submits once, immediately reads status, waits five seconds between subsequent
reads (at most 120), then downloads the completed opaque video. Edit requests
omit duration and generation geometry; supplying a video duration selects the
extension endpoint. The selected model is retained, including the three source
1.5 identifiers that permit single-frame 1080p. Generic 1080p becomes 720p.

Requests supply a prompt, finite positive `timeout_ms`, and optional model,
duration, ratio, resolution and images/videos. Image inputs use the existing
`:data`/`:mime_type` convention or a preferred explicit URL; video inputs use a
remote URL. Config explicitly supplies the API key and optional versioned base
URL, defaulting to `https://api.x.ai/v1`. No provider, environment or Agent
configuration lookup occurs. Results use `videos` with `:data`, `:mime_type` and
`:filename`, the selected model, and request/status/video-URL/mode metadata.

Call generation from an existing supervised execution task. A caller-linked
HTTP owner and one monotonic deadline cover submission, polling waits and reads,
and download through shared Req.Finch. Raw downloaded bytes default to a 16 MiB
bound. A separate configurable 1 MiB raw control-JSON ceiling is a host bound.
Chunk idle waits are at most 30 seconds. No automatic host request retries occur;
the pinned source's generic GET retry service is outside the successful protocol
comparison. An abnormal caller exit terminates the linked task; a normal caller exit does
not guarantee that cleanup. These are source-reviewed boundaries, without an
owner-exit runtime check. Remote job cancellation or refund is not established. Explicit total timeouts are also a host adaptation: with an
omitted timeout the source resets budgets between stages, whereas this adapter
requires a finite caller budget.

The independent xAI capture executes the unchanged pinned provider factory and
callback, whole asset/duration/MIME modules, and complete metadata/cap/deadline
source regions. Synthetic clock, successful HTTP/config/readers and deterministic
UUID boundaries are recorded separately from executed source. Its 34 vectors
include 33 host-comparable cases and one source-only omitted-timeout case.
Source timing is virtual; local HTTP evidence is separate. Neither establishes
real provider compatibility, codec validity, remote cancellation or failure/retry
parity. This provider does not enable a tool, choose a provider, save media,
create durable jobs, deliver attachments or resume a conversation. Those native
and asynchronous lifecycle requirements remain separate. The pinned version has
no OpenAI/Sora video provider; its absence does not justify inventing one.

`Synapsis.Provider.MusicGeneration.OpenRouter` owns an inactive, explicit music
protocol. It posts one streamed `/chat/completions` request with text/audio
modalities, default model `google/lyria-3-pro-preview` and WAV output; explicit
models and MP3 are supported. Prompt composition preserves the pinned order:
JS-trimmed prompt, optional instrumental instruction, trimmed lyrics, rounded
target duration. One reference image uses its trimmed URL before already-read
bytes, with a default `image/png` data URL. Unknown request options are not sent.

The caller provides an API key, optional versioned base URL, prompt and required
positive finite `timeout_ms`. The explicit timeout is a host adaptation of the
source's optional 180-second default. Duration accepts positive safe numbers;
the protocol does not invent a duration clamp. Configurable `max_audio_bytes`
defaults to 16 MiB and independently bounds decoded audio and UTF-8 transcript.
The raw SSE line bound is ceil(cap / 3) * 4 + cap + 64 KiB. A linked HTTP owner
runs inside the caller's existing supervised execution task, through shared
Req.Finch, with the whole HTTP budget and at most 30 seconds between chunks.
There are no automatic retries or application configuration reads.

The parser joins each complete raw line once, preserving UTF-8 across transport
chunks. Only the first choice's `delta.audio` contributes. Audio deltas are slices
of one Base64 stream, with an incomplete quartet retained between events and
flushed on `[DONE]`; the final marker may omit its newline. Decoded bytes are
budgeted before allocation. Empty transcript deltas are ignored; nonempty chunks
retain all whitespace and their original order. The result is one `tracks` entry
with raw `data`, `mime_type` and `filename`, the requested model, optional `lyrics`,
and request metadata.

An independent capture executes the unchanged complete pinned provider/SSE
parser, whole image/Base64/string/number modules and request-context module,
plus the exact configured-cap source region. Context configuration and HTTP are
explicit successful facades; native Response streams exercise real byte chunks.
All 58,558 tracked reference blobs are verified before and after capture. There
are 26 ordinary vectors, of which the 25 with explicit timeouts are compared to
the host builder and actual local Gaoxy HTTP results. The remaining vector records
the source-only omitted-timeout default. Synthetic music bytes establish protocol
preservation, without codec or music-quality evidence. Error, overflow,
interruption and abnormal-owner branches are source-reviewed only. This adapter
does not choose a saved provider, register `music_generate`, store audio, create
durable jobs or deliver results. Those integration/lifecycle requirements and
whole P10/reference acceptance remain open.

**Workspace packages** (npm workspaces built by DuskmoonBundler):
- `@synapsis/hooks` — LiveView hooks, React Form compatibility glue, `SynapsisReactChat` presentation/composer, and `AgentModelPicker` (Preact)

### synapsis_server → Channel Protocol

```elixir
# Client → Server (push)
"session:create"        %{project_path: str}
"session:message"       %{session_id: str, content: str, files: []}
"session:cancel"        %{session_id: str}
"session:tool_approve"  %{session_id: str, tool_use_id: str}
"session:tool_deny"     %{session_id: str, tool_use_id: str}
"session:switch_agent"  %{session_id: str, agent: str}

# Server → Client (broadcast)
"text_delta"            %{session_id: str, content: str}
"tool_use"              %{session_id: str, tool: str, input: map}
"tool_result"           %{session_id: str, tool_use_id: str, result: map}
"permission_request"    %{session_id: str, tool_use_id: str, tool: str, input: map}
"reasoning"             %{session_id: str, content: str}
"session_status"        %{session_id: str, status: str}
"error"                 %{session_id: str, message: str}
"done"                  %{session_id: str}
```

### synapsis_server → REST API

The `:api` pipeline serves JSON endpoints (no session, no CSRF):

```
GET    /api/sessions                 # list sessions for project
POST   /api/sessions                 # create session
GET    /api/sessions/:id             # get session with messages
DELETE /api/sessions/:id             # delete session
POST   /api/sessions/:id/messages    # send message (also via channel)
POST   /api/sessions/:id/fork        # fork session
GET    /api/sessions/:id/export      # export session
POST   /api/sessions/:id/compact     # compact session context
GET    /api/sessions/:id/events      # SSE stream (alternative to channels)
GET    /api/providers                # list providers + models
GET    /api/providers/:id/models     # list models for provider
POST   /api/providers/:id/test       # test provider connection
GET    /api/providers/by-name/:name/models  # models by provider name
PUT    /api/providers/:id            # update provider
POST   /api/auth/:provider           # authenticate provider
GET    /api/config                   # resolved config
```

### synapsis_lsp → Internal API

```elixir
Synapsis.LSP.diagnostics(project_path)                # => [%Diagnostic{}]
Synapsis.LSP.diagnostics_for_file(project_path, file) # => [%Diagnostic{}]
Synapsis.LSP.ensure_server(project_path, language)     # => :ok
Synapsis.LSP.stop_server(project_path, language)       # => :ok
```

### synapsis_sandbox → Invocation-Bound Reverse Calls

`Synapsis.Sandbox.Bridge` owns a JSON-RPC stdio Port. Reverse function calls use a
host-injected unary `nested_dispatch` captured from the executing native backend;
they do not call the legacy Executor. The host also supplies `invocation_binding`
(`session_id`, `run_id`, `incarnation`, `catalog_revision`, `invocation_id`), the
effect-task `owner`, and a unary `abort` callback. The callback carries execution
authority; the IDs describe its scope. Sandbox JSON supplies only method and params.

The host projects native results into `{:ok, json_safe_map}` or
`{:error, %{code: integer, message: string}}`. Successful maps preserve content
order, structured data and `is_error`, including tool-error results. The bridge
does not inspect native error causes or context. Dispatch is single-flight; a
second pending reverse request receives a busy response. Eval completion waits
for pending reverse work. A bound bridge serves one eval, then the host closes it;
callbacks must not be reused across invocations. Unbound host-only eval and
console/PubSub output retain their existing interface.

On owner loss, Port exit, callback/protocol failure or timeout, the bridge stops
its waiter, timers and Port, attempts the supervised native abort callback when
reverse work remains, then returns the eval failure. Abort is bounded to 1–500 ms.
A cancellation acknowledgement is not settlement: the host must observe native
terminal state and resource cleanup, and preserve an `unknown_outcome` result.

This is a support-layer contract. No production model-facing Sandbox descriptor
or caller is installed. A test-only native backend exercises the real nested
dispatcher and verifies intent before effect, committed completion before reply,
and cancellation with live-resource cleanup.

### Retained native run addresses

The latest roster is a presentation projection, not the recovery directory.
Agent-owned `RunInventory` retains immutable `run_locator` facts through the
existing data `Runtime.Store`. Each version-1 locator records the host Session
UUID, exact journal namespace/run ID/admitted incarnation, root or child kind,
name, and actual parent-run/native-agent identity. Root identity has no invented
child or Goal ID. The fact identity is the URL-safe encoding of the Erlang tuple
`{namespace, run_id, incarnation}`. Facts carry no capabilities, credentials,
process handles, execution permits, or inferred Plan/Goal attribution.

Explicit human mode selection now survives independently of the legacy permission
configuration. The existing `Worker.switch_mode` path retains its accepted name
in `session.config["user_mode"]`, preserving other config entries. Metadata and
permission updates remain separate publications with their existing ordering;
this does not introduce cross-store atomicity. At an accepted root prompt,
SessionAdapter captures a version-1 `mode_provenance` from the supplied immutable
Session snapshot: `plan_mode` maps to native `:plan`, other accepted user modes
to `:execution`, with source `:user_mode` and the exact selected name. An absent
choice records `:execution` with source `:default` and a nil selected name. A
present unsupported choice returns an explicit admission error. Agent names,
permission policy and prompt text are not mode sources. The historical Worker
engine `execution_mode` remains independent.

Successful public Agent switching also retains the newly resolved Agent and
Session in the live Worker. Its specific state-machine return keeps the current
state name and existing reply/inactivity timeout actions while replacing the
resident data; the generic unchanged-data helper is not used for that update.
Thus durable selection, live snapshots and preparation of the next provider
catalog use the same selected Agent without a Worker restart.

Each actual root or native MultiAgent child incarnation carries the same captured
value in its prepared context, Conversation `host_context` and acknowledged
immutable locator before startup. A follow-up retains its existing child provider
selection but inherits mode from its actual current caller's run context, matching
native `Goal.delegate` inheritance. Later user selections leave earlier locators
unchanged. The un-attributed direct locator constructors remain available;
historical facts are neither backfilled nor attributed from current settings.
Settled owner recreation reads the durable user choice for a fresh ordinary run.
The Goal lifecycle below consumes this frozen mode for native accounting bindings.
It does not change model planning-intent tools, enable automatic continuation or
qualify workflow/completion attribution, budgeted Plan behavior or exceptional
recovery.

The existing root preparation job acknowledges its locator before creating native
owners or Conversation. Child admission persists its existing intent and locator
in a linked, monitored job; only after their ACK does the Adapter reserve child
resources, construct original options and reply to the native manager. The manager
still owns child startup, follow-up identity and delegation. No alternative
executor, ledger or runtime-aggregate writer is introduced. A retained locator
means an intended address, not proof of startup, dispatch or completed effects.

Adapter initialization now delegates saved-roster/admission-fact and inventory
reads to its existing job mechanism. The first prompt is held until this phase
finishes; native work cannot start against a partially loaded inventory. The
startup `recovery_inventory` captures full aggregates from every exact retained
address; it is not a continuously refreshed runtime projection. `RunInventory.load`
can read current retained facts separately. Existing admission/roster uncertainty
remains; known absent/nonterminal runs keep recovery required. An exactly attributed
terminal Goal outbox can now be delivered and durably acknowledged through the
native recovery path below; incomplete attribution or remaining receipts keep the
barrier. Storage errors keep admission closed. Exceptional branches have source
review only in this ordinary-success qualification.

Coverage is explicitly `retained_only`: old overwritten root addresses are not
reconstructed from the current roster. Enumeration plus individual aggregate
reads is not a cross-record snapshot. New work keeps its own real namespace;
historical aggregates are not copied. Settled empty outboxes are read unchanged;
terminal recovery modifies only the original journal through its real native ACK.
Fresh accounting capabilities do not restore old capabilities or replay provider/
tool effects. No Goal continuation is activated. Each storage API retains its
existing finite timeout; this does not promise one deadline for the entire load.

Ordinary local fixtures qualify two root turns, child spawn/follow-up, exact
immutable facts and full aggregates, acknowledged fact-before-Conversation/provider
ordering, and settled Worker/owned-process recreation into a separate namespace.
They preserve original tool history, admission facts, old aggregates and effect
counts while permitting only the new ordinary provider request. They do not
qualify crash/cancellation recovery, failure/expiry, concurrent inventory snapshots,
real providers, or the complete Goal Host/release/outbox lifecycle below.

### Goal ownership and reference qualification

Backplane 1.10.57 supplies the persistent `Goal` owner, `Goal.Store` and
`Goal.Host` behaviours, the original ExtensionRuntime `get_goal`, `create_goal`
and `update_goal` descriptors, and Conversation `GoalBridge` accounting/outbox.
Concord 3.1.13 supplies the adopted public storage CAS and bounded reads.
SessionAdapter now owns one real Goal at the stable Session thread, using the
real GoalStore and Worker Host boundary. Ordinary root/child execution and
terminal-outbox recovery are connected. Public Goal descriptors remain disabled.

`Synapsis.Goal.Store` in data persists the entire opaque private record at
`coord/goals/threads/<canonical Session UUID>`. The agent-owned
`Synapsis.Agent.Runtime.GoalStore` implements the native behaviour with `:local`
context and returns `Goal.State.new(thread_id, [])` only for actual absence.
Context is deliberately independent of one thread: native `Goal.fork_snapshot`
uses the same store context for its target thread. This does not qualify the
full native fork operation. Persistent thread identity survives run/owner changes;
the random per-run Runtime.Store namespace is not reused. Native Goal IDs remain
opaque binary identities, distinct from Session UUIDs.

CAS reads the decoded complete record and actual storage `mod_revision` together
through public `Concord.KV.get(engine: :turso, metadata: true)`, checks both old
logical revision and old Goal identity, then uses public
`Concord.Turso.compare_and_swap` with that storage fence (zero for initial
absence). It assigns logical revision `expected_revision + 1`; native transitions
supply their current revision. Only a successful committed CAS returns the exact
full proposed record with this one revision change. No retry, alternate writer,
post-CAS read or post-CAS timeout conversion is added. One requested five-second
budget spans metadata read and CAS, with positive remaining time before each
operation; load has its own five-second timeout. This is neither a hard wall-clock
bound nor proof of no late write or power-loss durability.

Clear retains a full tombstone and its increasing revision; there is no delete
API. Receipt/event/usage/invocation/delivery/admission fences and all other private
fields survive persistence unchanged. The public `Goal.get` projection is
insufficient for recovery. Data owns storage and core identity validation, without
Backplane dependencies; the agent/native boundary owns native record validation,
transitions and error translation. Ordinary real-Concord tests qualify exact
snapshots, nonempty native receipt/accounting state, Unicode, storage versus
logical revisions, retained tombstones/replacement, fresh readers and independent
threads. They do not qualify concurrent conflict paths or failure recovery.

The existing startup job loads retained facts/inventory and starts Goal with an
explicit Adapter owner. Adapter adopts the process before readiness. Root
preparation now has two asynchronous phases: existing selection/resources/options,
then acknowledged attribution and original Conversation startup. Adapter itself
calls owner-only `Goal.bind` between them, with the actual selected authority and
frozen mode. The second phase persists a separate `goal_attribution` fact before
starting Conversation with the real Goal, binding and Session UUID thread.
An absent objective remains absent; an ordinary prompt does not create one.
Close defers while either preparation phase is outstanding, so that phase owns
resource cleanup or the live Conversation handoff. Unconfirmed preparation cleanup
retains the recovery barrier and cannot become a confirmed no-runtime cancellation.

Attribution facts use the same namespace/run/incarnation key as the immutable
locator, without changing that locator. Root facts contain a closed projection of
validated public attribution. `Goal.attribution` returns a capability-bearing map,
so the full response is never persisted. Child facts contain the exact supplied
child run/thread/incarnation plus the validated actual parent's closed projection.
They explicitly describe intended delegation: native MultiAgent issues the actual
child binding after the host callback. There is no second ordinary delegation or
private native-state lookup. Conversation retains normal delivery, checkpoint
removal and unbinding; host terminal history does not charge usage again.

`GoalLifecycle` plans only original terminal receipts with exact retained mode,
Goal identity and parent/root lineage. It preserves consecutive group order and
original receipt maps, selecting each source incarnation's fact. Parent chains
stay within the original namespace. Nonusage child receipts, missing or conflicting
attribution, and replaced Goal identity retain the recovery barrier. Existing
structural uncertainty or absent/nonterminal inventory prevents startup delivery;
terminal receipts cannot settle another unresolved run.

Adapter reconstructs fresh recovery bindings through public owner APIs. Its
existing monitored job reloads the original aggregate, delivers through GoalBridge,
stages `goal_outbox_acknowledged`, calls actual Store.acknowledge_commit and reloads.
Receipt incarnation remains original; ACK uses the current aggregate fence.
Each subsequent group reloads that fence, and every fresh recovery capability is
retired after the job. Only a final full inventory reload and existing uncertainty
checks can open readiness. Pure staging or delivery alone is insufficient. No
provider/tool dispatch, Goal.restore loop, alternate ledger or private writer is
involved. Fresh Goal startup already loads its durable record.

`Worker.GoalHost` routes finite callbacks to the actual current Worker, matching
Session/Adapter/epoch and using the existing resident input readiness predicate.
In this stage its policy admits no automatic continuation and acknowledges no
host instruction: set/clear/resume have no approved canonical source yet. This
is not reservation/release qualification. Full activation still requires the
complete generation/token reservation, native ACK, durable intent ACK, atomic
release, canonical terminal commit and input handoff path. Worker never waits
synchronously on an Adapter operation that can callback into Worker. Owner-only
Goal APIs remain synchronous inside Adapter; they are not moved into a job or
described as a continuously nonblocking Adapter mailbox.

The provider bridge now normalizes source-specific cumulative usage at normal
stream completion, as described under Native provider usage. This does not issue
an authoritative-usage binding or qualify failure/cancellation billing. No usage
authority or budgeted operation is activated by this store or bridge. Merely
composing the extension profile does not install accounting, and progress-card
presentation remains separate.

Ordinary positive qualification uses actual Worker/Adapter, GoalStore/Concord,
local Gaoxy provider and native child/follow-up. Two roots and a fresh root after
normal settled owner replacement account nine known provider attempts exactly
once, preserving old histories, aggregates and admission facts. A separate
component fixture builds a valid terminal aggregate through public Kernel/Store
and genuine Goal.bind/GoalBridge.queue receipts, then starts the real production
consumer: delivery, real ACK revision/readback and full inventory load precede
the first new provider request. A further positive component uses real public
Goal delegation for a root-child-grandchild lineage and genuine terminal usage
receipts. Production startup accounts all three retained reports plus one fresh
report exactly once, confirms each original aggregate and retires every fresh
recovery binding before provider dispatch. A successful public fence advances the
completed child's aggregate to incarnation two while its immutable locator, fact
and receipt remain at incarnation one; ACK uses the current aggregate fence and
preserves the exact original receipt. Full final inventory reload includes every
recovered aggregate. This qualifies retained nested attribution and a successful
terminal-store fence, not live nested MultiAgent delegation or crash/lost-ACK
recovery. Heterogeneous receipt-source groups, failure/unknown/cancel, budgeted
operation and real-provider behavior remain source-reviewed or unverified.

Native and pinned OpenClaw Goal tools differ. The pinned create callback requires
clearing any existing goal first, including a completed one; native Goal permits
replacement after completion. The reference model update exposes complete and
blocked plus a note, while the native descriptor also permits paused and does not
expose that note field. The explicit-request/budget and full-objective/three-turn
blocked requirements are descriptions and prompt obligations, not proof that an
arbitrary model call satisfies them. Native owner set/clear invokes the canonical
instruction callback; native model create follows its committed invocation path.
These contracts require an explicit host decision at future integration rather
than a claim of interchangeable schemas or automatic intent verification.

A progress card is a separate replaceable session surface, not Goal state. Its
reference factory normalizes markdown/steps, invokes progressCard.put and formats
a compact receipt; root eligibility, canonical parent/session ownership, storage,
broadcasts and continuation belong to other owners. Installed Backplane has no
progress_card descriptor. The independent pinned source capture now executes the
whole Goal/progress factories, transitions, accounting and input/result helpers:
34 whole modules, 11 provenance-only sources and actual TypeBox 1.3.37, with all
58,558 tracked blobs verified before and after. Thirteen ordinary successful
call vectors and two nonexhausted accounting samples are frozen in
`goal-tools.json`; six dedicated Node checks include fresh repeat equality.
Goal metadata and all four public schemas have independent literal assertions;
progress prose has bounded assertions. Actual generated UUID uniqueness and
intra-vector timestamp relationships are checked before explicit substitution.

Patch/read/event/path/gateway seams are supplied-success boundaries. The actual
reference storage is SQLite/worker; `sessions.json` is a compatibility address,
not a JSON persistence backend. This capture proves original callback payloads,
normalization, transitions and receipts, without executing persistence, Session
ownership, root eligibility, gateway transport, UI or continuation. Source and
functional checks live in `scripts/openclaw/capture-goal-tools.mjs` and
`scripts/openclaw/goal-tools-functional.test.mjs`; production adoption remains
separately gated above.

### Automation identity and lifecycle

`Agent.Routines` identifies stored automations by `{source, id}`, where source is
`"routine"` or `"heartbeat"`. Its list/get projections add `source`; this field is
not persisted or changed by a patch. Get, partial update, trigger and delete accept
the exact tuple. Existing bare UUID callers remain valid when only one collection
contains that UUID; collisions return `:ambiguous`. Kind and mutable names do not
identify a collection. Creation continues to write the routine collection.

`Heartbeat.LocalScheduler` keys production timers, trigger tracking and persistence
queues by source and UUID. Public status and persisted config fields retain the raw
UUID; status adds the known source. Unstamped legacy injected configs retain their
old internal UUID key. Exact trigger lookup does not select a sibling collection;
legacy UUID/name lookup requires a unique match. Persistence continues through
`Config.Store.merge_existing`, preserving unknown fields without recreating deleted
configs. Successful deletion reloads schedules and removes the future timer; it
does not cancel an already submitted Run or remove its durable history. If reload
fails after deletion, the exact runtime target is removed and the reload error is
returned; the deleted config is not restored.

For existing cron strings, `Heartbeat.CronSchedule` resolves wall times with the
explicit `Tzdata.TimeZoneDatabase` and the IANA data bundled in locked tzdata
1.2.2 (2026d). Core declares this application dependency because it starts the
production scheduler; Agent declares it for its direct timezone API use. Automatic
data updates are disabled and the global Calendar database is unchanged. Missing,
blank and UTC timezone aliases retain the project's UTC default. Named zones use
their actual offsets, including quarter-hour offsets and daylight-saving changes.

The helper matches naive wall times through Crontab, resolves each candidate in
the configured zone, and returns a strictly future UTC instant. A repeated wall
time uses its first occurrence only; nonexistent wall times are skipped and the
cron expression is matched again after the gap. Candidate resolution is bounded
and errors propagate without a UTC fallback. Timer reconciliation compares the
cron string and normalized timezone, so a timezone-only update replaces the
corresponding timer. Status adds the normalized timezone; persisted next/last-run
timestamps remain UTC. Legacy string schedules select the next future occurrence
after restart and skip missed occurrences.

The routine collection also accepts normalized typed `cron`, `at` and `every`
schedules. The legacy heartbeat collection retains cron strings; heartbeat-kind
routines may use typed schedules. `RoutineSchedule` owns data normalization and
`Heartbeat.Schedule` owns pure strictly-future computation. Absolute values accept
offset ISO timestamps, offsetless UTC timestamps, dates and positive epoch-ms
strings; fractions truncate to milliseconds and valid `24:00` rolls to the next
day. Typed cron uses its own `tz` when supplied. Interval creation materializes a
missing anchor once from stable `createdAtMs`; an ordinary cadence patch without
an anchor uses that same creation time.

`LocalScheduler` remains the sole timer owner and submits through the existing
Daemon and Sessions/Worker path. Lifecycle handling retains an unfinished overdue
absolute occurrence and an already persisted recurring occurrence across restart.
Typed occurrence keys combine source, UUID, schedule generation and occurrence;
the existing atomic Run creation/idempotency index admits them. An existing
terminal Run reconciles immediately without requiring its old PubSub event.
Successful scheduled one-shots delete only their config by default;
`deleteAfterRun: false` disables and retains it with no next occurrence. Manual
future one-shots and manual recurring runs preserve the scheduled slot; a manual
due one-shot consumes it. Successful intervals prefer actual durable Run start
plus period when still future, otherwise the next anchor-grid occurrence.

Serialized config mutations guard lifecycle writes and deletion by schedule
generation. Private cadence fingerprints detect file edits during reload or cold
load, rotate generation and clear the old next occurrence before exposing the
replacement; creation identity remains stable. Public directory records retain
their eight fields and whitelist typed schedule members. Timer delays retain
millisecond precision and bound long waits with due-time rechecks. The dormant
Routine scheduler stays inactive and `synapsis::automations` remains read-only
revision 2. Retry, interrupted and delivery-dependent scheduling policies remain unfinished;
this normal-success path does not establish complete reference cron parity or a
new bounded durable-admission contract.

The existing producer's `AgentRun.metadata.automation_ref` is the explicit source
identity. Daemon no-overlap admission compares that identity across active, queued
and pending submissions. Missing attribution retains conservative UUID matching.
Lifecycle PubSub payloads and observational events carry the known reference;
routine updated/triggered notifications retain their UUID and add source. After
scheduler replacement, untracked terminal events match the exact reference and
kind. Old events without a reference match only an unambiguous UUID/kind; source
is never inferred from kind. Already tracked runs retain their captured config.

The original native `synapsis::automations` revision 2 remains read-only. The current config must still
exist for `RoutineRuns.page` visibility; after deletion the underlying Run and
critical event history remain stored, but the directory API cannot expose the
deleted config's history. Full cron scheduling/payload/delivery parity and a new
durable admission contract remain separate work.

An independently selected `synapsis::automations_manage` revision 1 exposes only
`run`. A separate name preserves existing saved read-only selections. It uses
the existing configured execution-route visibility for a source-qualified UUID;
this does not establish creator ownership or expose create/update/remove/wake.
`runMode` defaults to `due`: disabled and future configurations return successful
non-enqueued observations. Explicit `force` may run disabled configurations and
preserves a borrowed future scheduled slot. Existing `Routines.trigger/2` behavior
is unchanged.

`LocalScheduler` owns the due decision and reserves source, schedule identity and
occurrence before supervised submission outside its callback. A timer and a due
request share that reservation and the existing atomic Run idempotency index.
Daemon still creates and executes the actual Run through Sessions and Worker.
The adapter returns an actual Run acknowledgement, then may observe terminal
state from its native effect task for up to `timeoutMs` (default and maximum
60 seconds), bounded by the native deadline. A queued Run requested by the active
Daemon session is acknowledged immediately so the session can finish. Public
identity/status/timestamps travel through text and structured tool results;
acknowledgement alone does not prove completion.

This effect is non-read-only, non-retryable and non-parallel. Preflight rejection
and uncertainty after dispatch stay distinct; a timeout after submission does
not establish that no Run was created. Cancellation of observation does not
cancel the scheduler-owned Run. ConfigStore/Concord admission bounds, complete
management and delivery semantics, and full reference parity remain unfinished.

### Automation source context, execution and completion

`Sessions.automation_context/2` observes the exact source Session UUID without
starting a provider turn. The existing Worker captures its runtime generation
and visible streamed text; a supervised reader obtains canonical history through
the existing SessionAdapter and public Conversation status API. Terminal history
is used while its durable commit is pending, avoiding duplicate transcript text.
The pure `Automation.Context` projection retains user/assistant text only, with
the reference's newest ten messages, 220 UTF-16 units per line and 1400 per block.
It considers at most 220 raw messages and 256 KiB of visible text. This implements
ordinary host role/text projection, not every OpenClaw Gateway display convention.

An absent Worker uses bounded durable pages without booting the session. That
reader caps decoded turn payloads at 256 KiB and 220 rows; a longer prefix is
explicitly unavailable until a supported bounded tail read exists. These bounds
do not cap pre-decode allocation. Live native status reads already-resident
history before projection, and is not a bounded history allocation claim.

`Sessions.append_automation_result/3` obtains the existing session owner and
appends one host-owned completed assistant turn without a provider request or
active Conversation mutation. Active preparation, execution and terminal commit
defer delivery in Worker memory; the Worker flushes results before preparing the
next queued prompt. Idle delivery waits for persistence. `:deferred` is an
ephemeral acknowledgement, not a crash-durable delivery receipt.
Completion flushing also runs when an active turn ends with an error. It does
not by itself resume user prompts parked by that error; a newly acknowledged
explicit prompt records intent to resume after all pending results are written.
The Worker carries the original boot/terminal continuation through result writes;
completion acknowledgement alone grants no continuation. Preparation cancellation
therefore preserves parked prompts, while the existing running-cancel terminal
path retains its original continuation. These error/cancel paths are source-reviewed.

`Session.Store.append_automation_turn/4` compares the latest metadata value and
the absent Worker-owned turn offset, then atomically inserts the turn and a
timestamp-only metadata merge. Unrelated title/config fields survive. Transcript
notifications follow acknowledgement. A dispatched transaction error remains
unknown, is not retried, and pauses further prompt preparation in the resident
Worker. This provides no no-late-write or cross-restart exactly-once guarantee.
An idle Worker without a known offset inherits the existing full-prefix
`count_turns` cost in a supervised task.

For integer `automation_contract_version = 1`, routine and heartbeat adapters
capture origin, session target, wake mode and delivery from top-level configuration
into the submitted Run. Ordinary user metadata is retained, while scheduler-owned
source identity and top-level execution fields take precedence; absent scheduler
fields stay absent rather than inheriting old user metadata. Provider/model
overrides also flow through these adapters. Legacy configurations keep their
existing behavior. Later configuration edits and retirement do not change the
submitted execution snapshot.

`Automation.Execution` prepares `current` context from that exact source UUID;
`isolated` omits it. Both execute in a fresh detached Session through the existing
Daemon and Backplane runtime. Context observation is stored when the Run starts,
without copying raw context into Run metadata. Authored prompt bytes are preserved.
For `announce` and `none`, after a newly acknowledged completed transition the daemon attempts `announce`
once through the existing source owner; `none` suppresses it. An already-terminal
reconciliation does not repeat delivery. Failed/cancelled Runs do not announce.
The existing supervised finalizer bounds the attempt; delivery trouble does not
change completed execution into failure. Terminal metadata records pending or
suppressed intent; an `automation.delivery` observational event records the actual
delivered, deferred, suppressed, unavailable or unknown outcome. Neither is a
crash-durable receipt, retry queue or cross-restart exactly-once guarantee.

Primary `webhook` completion instead runs inside the existing outer Daemon task,
after core execution and before finalizing or persisting a terminal Run. Admission
freezes an explicit public `automation_job` projection alongside source identity
and `delivery.to`; later configuration edits cannot retarget that Run. The
recipient receives a `finished` JSON event with that frozen job, actual run
timestamps, execution session and authored final summary. Optional telemetry is
included only when available; creator context remains in `automation_origin`.
The recipient-facing `delivered: true` is the reference event representation,
not a durable acknowledgement before HTTP succeeds.

The Daemon acknowledges stage ownership and each progress fact before the linked,
monitored HTTP child proceeds. Core's `Automation.Webhook` sends exact encoded
JSON using Req's headers-first asynchronous response. A 2xx is acknowledged before
response cancellation; cleanup cannot undo delivery. The HTTP child is bounded by
both ten seconds and the original absolute Run deadline. The Run stays running
while the receiver has not acknowledged. Cancellation stops and observes that
child before terminal persistence, preserving the strongest acknowledged fact.
Finalizer reconciliation and recovery never send another POST.

Successful empty or ECMAScript-whitespace final output intentionally sends
nothing. This decision retains the final current response, including an empty
response after tools, rather than selecting an earlier assistant text or ordinary
display fallback. Terminal `metadata.automation_delivery` records the settled
outcome; `automation_completion_status` records execution plus required delivery
independently of `AgentRun.status`. Empty suppression and accepted delivery count
as successful completion. One-shot retirement uses that combined result without
creating a retry. RoutineRuns and lifecycle events expose bounded completion and
delivery projections, with shortening flags, without the frozen job or transcript.

Generic transport uncertainty remains unknown and is not retried. The pinned
source requires typed proven-not-sent evidence for a retry; plain non-2xx errors
and generic Req transport errors do not supply that evidence. Recovery retains
an acknowledged non-2xx rejection, including its HTTP status and attempt count;
unknown applies when a durable running Run cannot prove delivery, omitting
unsupported attempt facts. There is no new outbox, durable retry receipt or cross-crash
exactly-once guarantee. Detached completion destinations, failure alerts,
script/stream/event/on-exit jobs and channel delivery remain separate work.

Official Backplane 1.10.50 supplies the public provider-independent `host_context`
from #143; the former #138 admission and #140 buffered-yield gaps are also
resolved in the installed runtime. SessionAdapter binds one immutable catalog
resolver, keeps it in `provider_context` for ProviderAdapter's existing
pre-request catalog check, and supplies the same resolver plus operator identity
through `host_context` for the original tool hooks. This preserves the provider
consumer while separating the host hook input from provider configuration.
Existing host descriptor context lists recognize the runtime's
`register_code_mode` callback without invoking it or changing hook policy.

The ordinary `headless_host_context_functional_test.exs` composes the original
Profiles, Policy, NativeLocal and CodeMode catalog through public Headless,
without a provider. Real Deno calls clock, native shell and clock across ordinary
continuations. Its observing Store commits first and returns the original ACK;
bounded gates verify durable intent before the shell effect and durable result
before settlement and the next call. The final aggregate, revision, once-only
shell effect, normal worker/OS exit and confirmed Session close agree. This
qualifies the public host-context composition; it does not install a production
scheduled-script consumer or establish Headless metadata compatibility for
arbitrary Synapsis host descriptors. The #141/#142 retirement/cancellation fixes
are adopted and source-reviewed, with no cancellation or failure execution tests.

The dedicated `headless_filesystem_functional_test.exs` separately qualifies the
existing nine Filesystem descriptors through genuine Headless and real Deno.
Filesystem recognizes native `execution_mode` and `headless_input` enrichment,
then strips only its documented native metadata before validating the original
domain context. CatalogBinding continues to compare the exact pinned descriptor
and context identity. The ordinary read and finite mutation/search flow retain
complete durable native operations/results and acknowledged revisions; normal
worker/OS exit and confirmed Session close are observed. This compatibility fix
does not install workflow routing, an owned workflow-effect driver, semantic
checkpoint/resume or a production workflow tool. Other host families still need
their own Headless compatibility evidence.

`Synapsis.Agent.Tools.Workflows.Effect.run/2` is an internal one-shot consumer
for an exact frozen Filesystem request inside an admitted native effect task.
It checks the actual parent authority and the original Profiles-issued
exec/wait/target descriptors; unrelated parent caller descriptors remain under
native strict admission. The child rebuilds the original Profiles/Policy catalog
with unchanged permission and Freshness evidence, a fresh Session binding and
exactly those three selected names. It uses real Code Mode and provider-free
Headless, with no direct target backend call or alternate dispatcher.

The complete request is retained in a RunInventory locator before child startup.
One parent ResourceRegistry entry owns the linked child Session and Headless
before execution. Success retains the exact committed target intent/result,
absent target presentation and final acknowledged revision, separately from the
Code Mode consumer value. Registry cleanup and the caller independently observe
normal Headless, Session and child Registry retirement; Session close alone is
insufficient. The ordinary tests cover two fresh reads and one actual write,
real final Store acknowledgements, worker/OS exit and unchanged journal reload.

This helper does not commit a pending workflow request, prevent replay between
calls, expose a public workflow command, or implement semantic checkpoint/resume.
Selected deferred tools are refused before retention/startup. Its ordinary runtime
qualification now covers all nine original Filesystem names: the prior read/write
fixtures and a separate actual-Goal edit/multi-edit/move/list/grep/glob/delete
sequence. The latter checks exact full native results, intermediate and final file
bytes, parent Session/Goal continuity, durable receipts and normal child/worker/OS
retirement. It changes no production code; its independent archive precedes the
coverage updates. The seven additional targets have only actual unbudgeted Goal
qualification. Other families, full effect driver/result mapping, Machine-linked
effect consumption and the pending HTTP/native public-route decision remain open.
The separate pure Segment below now provides durable semantic resume without
effects. The internal journal below joins actual CAS
and verified native receipt reopen without implementing those remaining stages.

When the actual operation carries a native Goal and binding, the helper delegates
that binding with the exact child identity and prepared authority. Native Goal
retains the original mode and usage semantics. No host input overrides this pair.
Headless terminal status precedes asynchronous Goal unbinding; the subscriber
task waits for the matching native `run_completed` event before receipt/release.
A private one-shot in-memory ACK marker lets the Registry cleanup task confirm
this ordering before retiring the child. The marker and binding never enter the
public result, registry value, locator or configuration. A pending ACK remains
uncertain and cannot authorize premature process retirement.

The ordinary Goal fixture runs two reads and one write under the same real
unbudgeted Goal, preserves the parent attribution between effects, and joins real
delegation/completion/retirement observations with exact durable child runs and
the root Goal record. Provider-free descendants generate no model usage charge
by native design. This qualifies normal Goal ownership, alongside the unchanged
non-Goal fixtures; excluded startup, cancellation, owner-death and budget branches
remain source-reviewed only. In particular, uncertain startup without a returned
child PID does not prove that a delegated Goal may be revoked or retired.

`Synapsis.Workflow.Journal` owns pure version-one JSON transitions for ordered
pending/settled effect occurrences in one existing Continuations UUID. The
agent-owned `Synapsis.Agent.Tools.Workflows.Journal` composes those transitions
inside the actual admitted effect task. It checks the original persisted Agent
UUID, exact acknowledged record and native context; pending CAS acknowledgement
is the sole branch reaching the unchanged Effect. After native success, Goal
acknowledgement and normal retirement, it verifies the final native aggregate,
retains the complete unchanged success in an immutable Runtime.Store fact, then
acknowledges a settled CAS. The JSON record contains a typed fact reference; full
intents/results and the original scalar inactive resource handle remain in the
existing opaque fact contract. No term capsule, new store or execution owner is
introduced.

`reopen/5` is read-only and requires an exact revision and explicit caller deadline.
It verifies the complete fact, original request/origin, successful retirement shape
and actual final native aggregate before returning settled evidence. Stored handles
are historical observations, never reusable capabilities. Pending remains pending
even if a locator, terminal aggregate or receipt fact exists; no reconciliation,
retry or replay fallback is installed. Unknown writes retain the last acknowledged
record and attempted revision. Known successful CAS acknowledgements remain success.
Existing Runtime.Store reads/writes keep their own fixed timeouts; live deadline
observations do not establish hard cancellation or absence of late writes.

The independent ordinary actual-Goal fixture appends read and write to the same
record (create r1, pending r2/settled r3, pending r4/settled r5). Fresh supervised
readers start after each actual writer normal exit and return the exact full
native evidence without new effects. Traces join CAS/fact/native/Goal ACK ordering
and normal worker/OS retirement; prior settlement and post-close durable values
remain unchanged. This qualifies the internal journal, not a Machine checkpoint:
its version one still contains no Machine state or consumed-result cursor.
The opt-in Segment v2 consumer below is separate from this unchanged v1 format;
effect-command mapping and public effect routing remain unimplemented.
Excluded lifecycle and security/permission branches remain
source-only; no real provider or live model qualification.

`Synapsis.Workflow.Segment` separately aggregates the complete pure Machine state
and Value heap, inline source, acknowledged revision and an empty v1 journal in
one existing Continuations record. It does not alter the standalone Journal
format. Initial input is an empty iterator with rendering disabled. Explicit
resume imports the submitted JSON into the retained heap and uses Machine's
fresh sliced program: ordinary ask re-enters the paused stage; `ask --emit`
continues at the next stage. Earlier completed stages are absent from that program.

The internal `Synapsis.Agent.Tools.Workflows.Segment` driver runs in a genuinely
admitted native task. It checks the original enabled persisted Agent and actual
Session operation, and reads only the native effect-deadline callback. A dormant
Schema.PortSession uses explicit trusted absolute Node/helper paths, the native
worker supervisor and the caller's ResourceRegistry. Registration precedes actual
Ajv fulfillment. Run acknowledges create r1, drives to a boundary and acknowledges
r2. A fresh call loads the exact revision, validates saved metadata/schema and
response before any constructor, acknowledges the validated claim r3, then drives
and acknowledges r4. CAS is never retried; known successful acknowledgements stay
acknowledged even when late. Errors retain the last acknowledged record.

Only a normal helper-close receipt, actual broker termination and confirmed
registry release permit publishing the envelope. State contains no live binding,
PID, callback, deadline or validator cache. The public projection includes only
input-request type, prompt, schema, optional defaults/subject and a host locator;
internal items/commandInput are omitted. The locator encodes workflow UUID and
revision and has no external Lobster-token interoperability.

Independent ordinary literals and tests were frozen before both modules. Real
Concord, admitted Session/Headless callers and Ajv verify same-stage, next-stage
and ordinary empty completion, full retained state/heap, revisions r1 through r4,
fresh caller/helper and normal helper/root retirement. That batch qualifies the
internal pure driver only. Evidence: `/tmp/synapsis-p3228-workflow-segment-batls956/`.

The selected-only `synapsis::lobster` ToolEffects family now exposes this pure
driver through Profiles, Policy, the native Session and SessionAdapter. It keeps
the original persisted Agent UUID/name, Session UUID and catalog binding. Its
descriptor publishes the pinned reference schema while documenting the supported
inline commands: head, pick, json, ask, sort, dedupe, groupBy and table. It uses the
configured absolute Node executable and the core priv schema helper exclusively.
It adds no default selection. Input checkpoints require an explicit new resume
invocation with the host locator and submitted responseJson.

Policy's native tool_effect_timeout hook selects timeoutMs per invocation
(default 20000, effective minimum 200, supported maximum 2147483647). The original
native operation and deadline callback remain authoritative. Core render_envelope
uses the retained ordered Value heap and Workflow.JSON.pretty, then decodes that
same text for details. The full pretty UTF-8 text supplies content and the
maxStdoutBytes count (default 512000, effective minimum 1024); internal heap and
checkpoint fields stay outside the public result. Errors after an acknowledged
transition retain its continuation ID/revision and do not replay it.

Independent ordinary literals and real Worker/local Gaoxy Responses tests verify
the exact public schema/text, normal empty completion and both input checkpoint
modes. The next provider request, Parts and Concord retain the full result; after
normal Worker retirement, a fresh Worker resumes the same durable record through
r3/r4 with a fresh native Session, caller and helper. The fixture observes the
Worker's asynchronous input-lane readiness before switching models. Combined
ordinary checks with the segment and relocated-helper regressions pass 9/0.
That batch qualified the source-checkout root Worker path. The public pure
managed-child qualification is described below. Installed Worker integration,
native effects and their consumed-result cursor, workflow files, approvals,
checkpoint cancellation, external token compatibility and the complete Lobster
contract remain open. Excluded tests and real provider requests were not run.
Evidence: `/tmp/synapsis-p3230-workflow-public-vpudlg85/`.

The selected public pure v1 family also runs through actual managed-child and
explicit followup paths. Two ordinary Worker/local Gaoxy Chat cases cover
same-stage and next-stage checkpoints. The child receives the exact public
schema and its own descriptor/binding, creates checkpoint 2, and returns the real
locator through normal final feedback. The parent model request carries that
locator; the explicit followup message transfers it into the fresh child's user
history and public resume arguments. Actual saved schema/response validation
ACKs precede claim 3; actual reconstructed ask/response validation follows the
claim ACK where the mode requires it. Completion 4 preserves the original
workflow/session/Agent UUID, source, journal and all old heap nodes.

A completed native Conversation detaches its Session to idle with no active run;
it does not close that Session. Followup retains the child Session, registry and
owner identity while creating a new Conversation, run/incarnation, binding token,
catalog descriptor and schema helper. The native manager normally retires the old
Conversation during replacement. Root and child Sessions remain distinct. The
first test attempt incorrectly required closed Sessions; its two failures and
frozen original remain archived. One lifecycle-only correction adopts the actual
Backplane contract without changing production or the other input/result/schema/
CAS/history assertions. Actual helper close/release receipts, broker and OS exit,
child native aggregates/results, prior history in the next model request, and
parent Parts/Concord containing only the parent's own collaboration tool calls
and actual child feedback are checked. No manual child shutdown manufactures
freshness. Combined ordinary checks pass Core 3/0 and Agent 9/0, seed 236236.
This qualifies public pure source-checkout children on Linux with explicit
Node 24.22.1 and Backplane 1.10.53. Public effectful v2, installed packages,
HTTP/external tokens, crash recovery and excluded checks remain unqualified.
Evidence: `/tmp/synapsis-p3236-managed-workflow-dkora4yg/`.

Explicit `Segment.new(pipeline, version: 2)` adds a `consumed_effects` prefix to
the original six-field aggregate. Its nested Journal keeps the v1 format. The
unchanged v1 constructor and standalone Journal continue to serve existing callers.
At most one occurrence may be outstanding; its request ID, semantic segment,
native tool name and arguments must match the actual waiting Machine. A nonempty
fully consumed journal requires a revision after its latest settlement.

The trusted internal `Journal.run_segment/4` accepts the actual acknowledged
record and a separate awaiting snapshot produced by pure progress. Source,
revision, journal and cursor remain pinned to that record; the Machine may have
advanced. The pending CAS freezes that exact waiting Machine and only its ACK
enters the existing Effect. After normal native retirement, the original full
receipt is verified and retained as an immutable fact. The settled CAS still
preserves the waiting Machine. `consume_segment/3` reloads and verifies the exact
settled record, fact and native aggregate, then commits one snapshot that imports
the result, advances the precise Machine continuation and increments the cursor.
The caller receives the acknowledged consumed record before continuing work.

Consumption takes raw JSON explicitly supplied by the trusted caller. Its decoded
value must equal the verified native `consumer_value`; the original JSON then
enters Value's ordered decoder unchanged. Native maps do not promise raw response
property order, so this API neither re-encodes them nor claims to recover HTTP
ordering. The supplied native target must match the pending body tool and args;
action, session attribution, dry-run and transport translation remain the future
public mapper's responsibility. No public command is activated by this API.
`reopen_segment/5` only checks the retained aggregate and full facts. It does not
dispatch, reconcile or retry. Input resume retains the journal and cursor; this
is not a claim of crash recovery or exactly-once execution.

Two independent Core ordinary cases exercise real Machine effects, ordered
result roots and effect→ask→actual schema helper→fresh semantic resume. Their
journal references are pure fixtures. A separate Agent ordinary case uses an
admitted native Session/Headless and production registration for two canonical
reads under one UUID (revisions 1→7), verifies complete native receipts, normal
retirement and pending→fact→settled→consumed acknowledgements, then reopens from a
fresh reader after the writer exits normally. That batch qualified the internal aggregate API; its separate schema/native cases
did not exercise fresh native execution after ask. The driver qualification below
adds that path. Public v2 Worker integration remains open. Those combined ordinary
regressions passed Core 43/0 and Agent 7/0.
Evidence: `/tmp/synapsis-p3233-segment-effects-y1y7skns/`.

The trusted Segment driver now has explicit internal `run_effects/3` and
`resume_effects/5` entry points for v2. The caller supplies exactly two ephemeral
adapters: `request(machine_request, acknowledged_record)` constructs the declared
native request, and `response_json(verified_effect)` returns an explicit raw JSON
encoding. They perform no execution and are never persisted. The driver alone
passes the actual record and pure awaiting snapshot to the existing Journal,
then continues from its acknowledged consumed record. Pure and effectful paths
share the original schema/resource helpers; the v1 entry points retain their
format and public behavior.

Explicit v2 resume first reopens and verifies the retained aggregate and complete
native facts. Actual saved-schema/response validation precedes the claim CAS;
only its acknowledgement permits fresh constructors or effects. Each later
boundary is committed from the latest actual acknowledged record. The v2 locator
uses `workflow-segment.v2`, carrying UUID/revision only. The public parser and
pure-only command allowlist are unchanged, so this internal API does not install
public v2 invocation, choose native/HTTP mapping or translate action/session/dryRun.
Raw response property order remains caller-supplied. Failure branches retain the
last acknowledged record by source review; no automatic replay/reconciliation or
crash-recovery guarantee is introduced.

An independently frozen ordinary test now exercises this driver with genuine
Session/Headless admission, Profiles and production SessionAdapter registration.
A first canonical read is settled and consumed, then actual Ajv reaches the input
checkpoint at revision 5. After the entire native root/caller/helper exits
normally, a fresh run at incarnation 2 uses a new Session, binding, registry,
adapter, registration and helper under the same host session/Agent/workflow UUID
and native Store namespace. Complete old facts and actual saved-schema/response
validation precede claim 6; the second real read reaches consumed 9 and complete
10. Exact native receipts, original fact/aggregate preservation, acknowledgement
ordering, no prefix re-execution and normal BEAM/OS retirement are checked.

Combined ordinary regressions pass Core 13/0 and Agent 8/0. Two initial fixture
failures and exact corrections are retained: helper registration must compare
Session binding owner incarnation rather than run incarnation; observing root
Code Mode startup also requires tracing the existing Conversation task supervisor
before execution. Production code was unchanged during those fixture corrections; all other
assertions stayed unchanged.
Independent quality review then found that wrapping each recursive driver step
retained control-stack frames for ordinary work, including v1. A source-only
repair moved record-aware wrappers to individual primitives and restored tail
calls for pure, schema and effect progress. The same corrected frozen tests pass
Core 13/0 and Agent 8/0 after that repair; no performance or boundary probe was run.
Qualification is Linux with explicit Node 24.22.1 and internal next-stage callers.
Public v2 Worker/mapper, managed-child/installed-package execution, HTTP semantics,
crash recovery and all excluded tests remain unqualified. Evidence:
`/tmp/synapsis-p3234-effect-driver-em4plil_/`.

A follow-up test-only qualification covers same-stage effectful resume with the
same fixture and all prior next-stage assertions. Without `--emit`, the checkpoint
retains exact command-input metadata, signature and ask suspended state. The first
native result stays in the journal and heap. Its replay list is empty: pinned
Lobster invocation returns an async generator, and the original input tracker
retains array replay only; streaming input with suspended state resumes from that
state. This is source-defined behavior, not a missing replay buffer.

After full old-root retirement, the fresh native root reopens complete facts and
validates resume metadata and the saved response before claim 6. Only after its
ACK does the restored ask constructor validate metadata and the request response,
consume that response into history, then permit the second real read. Both effects
remain consumed under the original UUID through complete revision 10, with no
prefix re-execution. Actual helper/native retirement, immutable old facts and
aggregates, heap and raw result order are checked. The frozen tests pass on their
first run: Core 13/0 and Agent 9/0, seed 235235; production code is unchanged.
This extends internal Linux/explicit Node 24.22.1 qualification only. Public v2
Worker/mapper, managed-child/installed-package and HTTP integration remain open;
excluded checks were not run. Source archive provenance and complete read-only
modules are retained separately from execution evidence:
`/tmp/synapsis-p3235-same-stage-nnkdra30/`.

The fixed Lobster package has no filesystem command. Its `openclaw.invoke` and
`clawd.invoke` call `/tools/invoke`: non-each drains input then invokes during
construction; each merges arguments and invokes serially while consuming input,
accumulates results, then returns a stream. A dedicated oracle executes both
complete unchanged invocation and response-reader modules against four ordinary
literal cases. Its fetch is a declared synthetic transport using actual Response
bodies, so it establishes source ordering/JSON semantics only. It does not qualify
HTTP, native effects or a mapping to Synapsis file tools. Host command mapping and
the public effect/consumed-cursor chain remain separate implementation work.
Source evidence: `/tmp/synapsis-p3231-invoke-reference-bzg3u6t1/`.

The pure Machine invocation continuation is a separate prerequisite to that
durable consumer. It retains each constructor's input tracker, accumulated
tagged result roots and exact return position while exposing a stable `invoke`
request with a shared request ordinal, semantic segment, stage index and ordered
JSON body. A matching `response_json` event imports the raw successful response
through Value's ordered JSON decoder, unwraps the source result envelope and
resumes that constructor. Non-each drains first; each waits for one result before
pulling the next item. Both accumulate all results before returning their output
iterator or constructing the next stage. Original transport arguments stay in
the frame; the pure interpreter does not resolve URLs, environment or credentials.
The public Workflows command allowlist remains pure-only. This pure continuation itself does
not dispatch HTTP/native effects; the separate internal v2 APIs above bind its
return position to the journal and consumed CAS. Source command semantics do not
decide the pending host-command mapping.
Eight independently authored ordinary literals cover the four source-oracle
cases, eager downstream-zero behavior, successive calls, response property order,
optional aliases and fresh ask resume. Each transition is compared against its
JSON-restored state; schema ACKs and raw invoke responses in these new tests are
fixtures. Combined existing pure/schema-helper and public Worker regressions pass
Core 41/0 and Agent 4/0. This is interpreter qualification, not live transport or
durable effect consumption. Evidence: `/tmp/synapsis-p3232-machine-invoke-vkh35m0e/`.

Script configuration, durable per-job state, scheduled admission and notification
remain unimplemented. Native Headless exposes JSON via `input`; the reference's
`trigger.state` global is not automatically available. The pinned reference also
prohibits script payloads with condition triggers. Its recognized result fields
are `notify`, `wake`, own-property `state` and `nextCheck`; `quiet` and `summary`
have no result-field semantics. These are source-reviewed boundaries, not
executed production script, failure or permission tests. Source evidence and the
verified issue receipt are in `/tmp/synapsis-automation-script149-0it7vqi_/`.

### Pure workflow ordered collections

The existing `Synapsis.Workflow.Machine` now composes `sort`, `dedupe` and
`groupBy` with head/pick/json/ask through the same version-one JSON task stack
and tagged heap. It creates no runtime owner, persistence route or model tool.
Sort and groupBy drain their input during construction, before later stages
construct; their materialized state still produces generator output. Dedupe
acquires upstream only on demand and skips duplicate pulls without emitting or
marking output started. Existing started/unstarted return and finish rules remain
in force. Group member arrays are retained during construction, while each
ordered key/items/count wrapper is allocated only on output pull.

Collection identity uses ordinary JSON.stringify text, with a separate undefined
sentinel. It preserves object field order, first occurrences and original aliases;
it is neither stable JSON nor heap-reference equality. Sort preserves ties,
compares finite numbers numerically and otherwise uses original JS String
conversion followed by UTF16 lexical comparison. Dot paths skip empty segments;
optional sort/dedupe keys remain untrimmed, whereas groupBy coerces and trims its
required key. Collection property access leaves pick's existing behavior intact.
Unrepresentable lone UTF16 string-index results return an explicit unsupported
error. Own toString overrides also stop at the existing unsupported boundary;
conversion hooks are not silently treated as default object strings.

Independent ordinary tests retain constructor/demand ordering, reference identity,
all intermediate JSON-state continuation, pretty output and an actual synchronous
Schema helper across checkpoint/fresh semantic resume. A separate pinned capture
executes sixteen whole unchanged modules, including the real shared value_path,
and keeps generator/observer/current-segment resume recipes explicit. This does
not qualify public tool finalization, native effects, database reopen or model
entry. For these three new commands, mixed-type/nullish-placement and
missing/undefined paths are source-only. Inherited pick undefined-value success
regressions run in the original suite and do not qualify collection branches;
prototype/function/sparse/nonfinite/loneUTF16 completeness, remaining commands,
Machine/journal/cursor integration and public durable resume remain open. Evidence:
`/tmp/synapsis-workflow197-hfy_843m/`.

### Pure workflow map transforms

The existing Machine task stack now implements Lobster `map`, and the selected
public `synapsis::lobster` pure command list includes it. Construction does not
pull input or allocate output wrappers. Unwrap reads a literal own property of
an object or dense array; assignments are ignored in that branch. Wrap creates a
fresh object retaining the original item reference. Assignments mutate an object
in the same Value heap, wrapping scalar/null/array values under `value` first.
Each assignment renders against the original item and the latest heap, so later
assignments observe earlier mutations only when the original is the assigned
object. Wrapper fields never replace the original template context.

Assignment parsing splits the first equals and trims only the key using existing
ECMAScript whitespace rules. Placeholder expressions use the original dot-path
helper, with `.`/`this` selecting the original item; nullish values render empty,
strings retain their bytes, and other values use ordered compact Workflow.JSON.
The original lazy pull/return bookkeeping and JSON-only state remain intact;
shared aliases survive intermediate state round trips.

All sixteen frozen ordinary core cases failed before implementation. Fifteen
report the unsupported command directly; the real-Schema case instead reports
cleanup of a never-started helper, masking its earlier exception. Source confirms
the missing command, but that case has no direct unsupported-result evidence.
With the implementation, nine-file integration passes Core57/0 and Agent6/0,
seed239239. Two additional real Worker cases resume same-stage/next-stage inputs
through map wrap/unwrap/assignment, preserving actual schema acknowledgements,
normal helper retirement, complete provider results, Parts and Concord. Original
three public cases and their assertions remain intact. The first integration
compiled Core57/0 but the new native case-list module attribute needed parentheses;
that harness-only correction and original failure are retained, with no production
or assertion repair. A separate oracle executes fourteen whole unchanged pinned
modules with actual Ajv, twelve recipes and thirteen pipeline calls; Node5/0 and
fresh/frozen equality pass after correcting one independently written ask preview
literal to its source-defined `{text: ...}` shape. The original literal and failure
remain archived. Oracle transport/resume recipes are explicit; they do not execute
public token finalization or persistence.

This qualifies ordinary finite/dense/own-property behavior, not general JavaScript
prototypes, descriptors, hooks, sparse/nonfinite values or lone UTF16. Remaining
commands, public effectful v2 mapping/HTTP and installed Worker qualification stay
open. No security/permission or other excluded tests ran. Evidence:
`/tmp/synapsis-workflow239-map-hc0cg0f4/`.

### Pure workflow where filtering

The existing Machine implements Lobster `where` in its lazy transform/task stack.
The public pure command allowlist and description now include `where`; execution
uses the existing owner. Construction stores the parsed predicate without pulling
input. Rejected items schedule the next upstream pull without emitting output;
accepted items retain their original Value roots and heap identities. Existing
head, exhaustion, return and JSON-only restoration bookkeeping remains in charge.

The predicate uses its first positional argument, source-defined operator
whitespace and literal parsing, and an exact end anchor. Unlike collection paths,
its dot paths retain empty segments and traverse only objects and dense arrays;
primitive strings do not acquire boxed properties. Equality follows source loose
nullish, boolean, number/string and default object/array primitive conversion.
Relational operators compare two primitive strings in UTF16 order and otherwise
use numeric conversion. Nonfinite comparison sentinels remain internal state and
do not extend the finite Value heap. General prototypes, callable hooks, sparse
values, lone UTF16 and overflow/underflow are outside this execution qualification.

Thirteen independent ordinary core cases were frozen before implementation. The
original baseline ran twelve, all reporting unsupported_workflow_command; the
real-Schema case was excluded from that baseline and its frozen assertions were
retained. Final eleven-file integration passes Core70/0 and Agent10/0, seed240240,
including the actual Schema case, existing map/managed-child regressions and two
additional public Worker same-stage/next-stage resumes. Complete native results,
following provider requests, Parts and Concord remain checked. The separate oracle
passes Node5/0 with fifteen whole unchanged pinned modules, twenty recipes and
twenty-one pipeline calls, including complete fresh/frozen equality. It does not
execute public token persistence. Source review corrected one optional trailing
terminator in the production predicate regex; no dynamic probe or frozen test
repair was used. Original tests and assertions remain unchanged.

These are local ordinary-success results. Remaining commands, public effectful v2
mapping/HTTP, installed Worker and whole-reference qualification stay open.
Security/permission and other excluded tests did not run. Evidence:
`/tmp/synapsis-workflow240-where-z4kcr0gj/`.

### Pure workflow table rendering

`Synapsis.Workflow.Machine` implements the pinned table command in its existing
version-one task stack and tagged heap. The default `render_output: false`
preserves original input roots through a tracked generator, without turning an
array-backed input into downstream array replay identity. Enabling rendering
drains input during construction, before later stages construct. Output is an
empty generator; direct stdout writes mark the pipeline rendered and output
started without adding entries to the JSON renderer's `rendered_items`.

The first twenty items determine whether object-table rendering applies and
which own columns appear. Columns retain first-seen ordinary JavaScript key
order; later rows affect widths but cannot add columns. Table headers and cells
replace LF with spaces while retaining CR. Widths count UTF16 code units, have a
minimum of three, and pad every column including the last. Scalar/array fallback
writes each cell on its own line without flattening embedded LF. Empty input
writes `(no results)` with a trailing newline; zero-column objects retain empty
header, divider and data lines.

Ordinary verification and source provenance are recorded in
`/tmp/synapsis-workflow198-02khct29/`. Missing/undefined cells, heterogeneous rows
and excluded exception paths remain source-only. Prototype/function/descriptor,
sparse/nonfinite/loneUTF16 representation completeness, remaining commands,
Machine/journal/cursor integration, public invocation and durable semantic resume
remain separate open requirements. This command adds no native execution owner,
persistence mechanism or model catalog entry.


### Pure template formatter component

`packages/tool-host/src/workflow/template.mjs` provides only
`renderTemplate(template, item)`, a synchronous pure formatter over already
resolved text and real JavaScript values. It combines the pinned Lobster
2026.9.16 template-expression, filter-chain and value-path algorithms with all
fifteen filters. Number/Date/String operations retain their JavaScript semantics:
binary64 rounding, UTC date formatting, first-only date-token replacement,
ordinary JSON property order, quoted pipes and escaped filter arguments are not
translated into approximate Elixir equivalents. Full source attribution and the
original MIT license are retained in the module.

The return value remains a JavaScript string. Successful operations on ordinary
astral text, including truncate, empty-separator split, empty-search replacement
and string indexing, can produce lone UTF16 surrogate units. The component
preserves these units; it does not encode them through UTF8. The existing
Workflow.Value now has a trusted string-storage prerequisite for these units:
`from_utf16le/1` accepts exact UTF16LE bytes and canonicalizes well-formed strings
to the existing `{type: "string", value: utf8}` tag. Only strings containing
unpaired units use `{type: "string", utf16le: canonical_base64}`. The encoded form
has no `value` field, so it cannot be confused with base64 display text by an old
string-value pattern. `to_utf16le/1` retrieves the exact units from either form.
Both forms remain ordinary JSON-serializable tagged values in the version 1 heap.
This is a trusted constructor/accessor contract, not an imported-snapshot validator.

Workflow.JSON compact, pretty and stable output escape unpaired units as lowercase
ASCII `\udxxx` and preserve valid pairs as Unicode, including pairs next to lone
units. Strict snapshots retain the existing finite/defined/acyclic validation,
then copy each tree occurrence through Value allocation instead of reparsing
public JSON. Every shared-reference occurrence receives an independent copy;
objects use ordinary key enumeration, negative zero becomes positive zero, and
other finite number bits and string units remain exact. Original heap nodes and
roots are preserved. Ordinary tagged snapshots still retain shared references.

UTF8 JSON import and UTF8 object keys retain their existing contract: native JSON
import does not accept escaped lone surrogates, so it cannot yet re-import all
new public string output. The compute helper and existing Machine runtime string
consumers now accept either canonical string form. No public template command
creates the new variant. JSON input, object keys and the Segment decoded-envelope
boundary still need explicit integration before template activation. Replacing
runtime values with U+FFFD or exposing a restricted text-only command would not
complete that contract.

Independent tests were frozen before implementation. The source oracle evaluates
three complete unchanged archive modules and calls the actual template command;
114 formatter literals, nine text/file/positional constructor cases and three
lazy-demand cases produce 126 command calls. Its real Node filesystem binding
reads only self-created temporary fixtures and removes them afterward. File
precedence, captured-before-pull file text and source laziness are reference
observations; the production formatter implements neither file loading nor the
command constructor. Direct component checks preserve exact UTF16 code units,
including generated lone surrogates. The recorded Node/Unicode/ICU version bounds
this execution evidence; it does not qualify all engines or timezones.

The formatter now runs in the existing helper worker through an explicit
`render_template` operation. Request roots are the tagged template string and
item in the same heap; the worker reuses `decodeRoots` and its shared-shell
worklist, mapping those roots to the existing schema/response slots. It imports
the unchanged complete formatter and returns a canonical tagged string, retaining
lone UTF16 units in base64 rather than emitting escapes that Jason cannot parse.
Rendering does not compile schemas or populate the actual Ajv cache. The main
stdio thread retains its watchdog and worker/transport ownership, and the ready
profile still identifies the retained Ajv schema dialect.

PortSession correlates the caller's pending kind/id, checks the exact rendered
receipt and canonical string shape, and requires the retained cache count to
remain unchanged for rendering. Canonical UTF16 receipts decode to even-length
bytes and must reconstruct the same tagged string; well-formed text uses the
old UTF8 shape. Normal operation deadlines, transport byte limits and observed
normal-close completion remain with the existing owner. The Schema facade still
acknowledges only schema requests; it does not consume or discard rendered values.

The generated standalone package includes the formatter's original bytes, MIT
license and provenance as its fourth host module. The six pinned dependency
locations and original lock/package/license checks remain unchanged. Independent
checks send the previously frozen 114 formatter literals and 23 UTF16 string
literals through the real helper and PortSession, including a relocated complete
package outside the checkout. They also cover a lone-containing template root,
returned-string reuse, actual Ajv enum validation, persistent PID/cache and normal
OS exit. Receipts are in `/tmp/synapsis-session248-template-port-a51go6g5/`.

Machine string indexing and length, lexical comparison, array String conversion,
map interpolation, where coercion, table geometry and ask previews use exact
UTF16 code units. Private LE buffers never enter saved state: assembled runtime
strings pass through Value.from_utf16le, so adjacent high/low replacements can
form a valid pair. Comparisons use unsigned unit order; table LF replacement is
unit-aligned. Ask joins and slices the first 2000 units before storing tagged
subject text; metadata, snapshots and ordinary checkpoint resume retain those
units. JSON identity/groupBy/dedupe retain their existing serialization mechanism.
Parsed command text remains UTF8 and pick/unwrap retain their own property rules.

Diagnostic stdout retains its UTF8 API by matching the source's actual Node
Writable sink. Each complete table or JSON write is assembled first; only then
does UTF8 encoding replace isolated surrogates. Runtime values and subject text
never use that conversion. This matches CLI process.stdout, the default tool
Writable and workflow PassThrough; a test double that directly concatenates raw
JS strings observes a different boundary. Independent literal checks execute
unchanged whole archive commands with actual Ajv and a real Writable, and compare
Machine results, per-write units and encoded bytes separately. The source archive
and bounded ordinary evidence are recorded in
`/tmp/synapsis-session249-machine-strings-n7dmy5b9/`.

Machine now implements the complete template constructor and lazy transform.
Only native string text/file flags participate; nonempty text (including
whitespace) wins, empty text can request a file, and successful empty file
content falls back to positional text joined with spaces. A read_template_file
request suspends construction before downstream stages or any input demand,
even for empty input or downstream head0. Its trusted acknowledgement supplies
a canonical tagged string; Machine performs no filesystem read. Each constructed
stage retains its own text without a shared file cache.

A demanded item produces one render_template request with the retained tagged
template, exact live item root and current heap. Template.advance_pending uses
the caller-owned existing PortSession, then forwards its correlated completed
receipt to Machine. Explicit template kind/id checks and canonical string
validation retain the returned units; generic schema acknowledgement handles
only schema requests. Existing stream/frame emission, normal return, request
ordinals and semantic resume remain the owners. A resumed slice validates its
saved response before constructing its remaining template stages; removed prefix
stages are not reconstructed. Ordinary JSON snapshots retain exact pending work.

Independent tests execute all previously frozen 114 formatter and 23 UTF16
literals through Machine and the actual helper, plus source selection, lazy
shared-heap mutation, lone template roots, normal head1 finalization and same/
next-stage semantic resume. File acknowledgements are trusted content inputs;
they are not evidence of production file loading. Whole unchanged archive
commands and runtime independently establish source construction/demand behavior.
Receipts are in /tmp/synapsis-session250-template-machine-2jenejub/.

Checked file capture belongs to Local.read_binary/3. Template.advance_file now
passes relative cwd plus the original raw file components to that owner, captures
complete bytes and requests canonical-base64 decode_template_file on the retained
PortSession. The existing worker uses Buffer UTF8 decoding and returns an exact
correlated canonical string receipt without growing the Ajv cache. A live native
deadline callback is queried before capture and again before helper execution;
the original absolute cap remains in force across both operations. Local's raw
10 MiB/5 s capture limit and the helper's 8 MiB input (including base64 and heap),
64 KiB output and 120 s compute cap remain explicit limits. No truncation or full
10 MiB template support is claimed.

Segment's existing source optionally stores canonical project_root and relative
cwd in file_scope, with shared pure validation for v1/v2 and unchanged old
unscoped shapes. Agent Segment canonicalizes the trusted root and requested scope
through Local.resolve before create. Resume binds the saved root to the current
trusted root and uses only saved cwd; fresh caller cwd does not overwrite it.
Workflows retains its resolved cwd and supplies that scope, while its public
allowlist and output remain unchanged. The original source reads relative to Node
process.cwd and ignores ctx.cwd; checked workflow cwd is an explicit host
adaptation, not source process-cwd equivalence. No native read grant or Journal
mapping is added.

The internal Agent driver explicitly dispatches file/render before schema work
and retains the existing continuation CAS and resource-retirement owners.
Independent ordinary checks cover 15 source byte literals, actual Local capture,
source and relocated helpers on one PID/cache, normal exit, and an admitted
internal native caller's v1/v2 same/next-stage Concord checkpoint/load/fresh-root
resume. These establish the internal driver, not public Worker template execution.
Receipts are in /tmp/synapsis-session251-template-files-88_ktkgy/.

Internal JSON import and own-object names now retain exact UTF-16 units. Value
lexically masks actual surrogate escapes in quoted tokens, records their unit
offsets and restores the native-decoded ordered AST before duplicate replacement.
Native JSON remains the grammar/number authority; no marker-value matching or
second parser is used. Ordinary objects keep their original keys/fields shape.
Lone-bearing keys use canonical string tags plus optional nonempty fields_utf16le,
separate from ordinary names that resemble base64 or metadata. Shared key_string,
key_index and object_fetch! keep lookup, numeric enumeration, JSON quoting/stable
ordering/snapshot copies and Machine table/selection consistent. The existing
shared-shell helper decodes these same keys without changing runtime ownership,
worker operations or Ajv/cache limits.

Independent ordinary checks exercise raw root/nested units, positional collisions,
duplicate insertion order, namespace collisions, aliases, signed zero, exact table
headers, source/relocated helper PID/cache/normal exit, and admitted internal
v1/v2 same/next-stage Concord recovery. The final template JSON projection is
ordinary UTF8 text containing escaped lone units; it proves internal retained
state, not arbitrary decoded public output. Original pinned Ajv itself cannot
compile a properties subschema below a lone name because its fragment encoder
uses encodeURIComponent. The successful original-source required-only lone-key
schema is qualified; no Ajv patch or substitute validator is used. One independent
positive recipe/schema-derived metadata signature was corrected after source
proof; the original baseline and exact correction are retained. Receipts are in
/tmp/synapsis-session252-utf16-keys-4fnh0vwb/.

Actual public template Worker results remain required work.
Segment.render_envelope still decodes public JSON through
Jason and therefore cannot deliver arbitrary lone-containing outputs; Machine's
tagged state qualification does not establish that public boundary. The public
command allowlist does not include template. The
string-storage/JSON-output prerequisite's independent
checks are in `/tmp/synapsis-session247-utf16-4hzmi1pf/`; prior ordinary Worker
checks still cover its existing UTF8 flows. No alternate execution owner, native
invocation mapping or HTTP bridge is introduced. Excluded error/security/permission
paths were not tested. Source and direct component receipts remain in
`/tmp/synapsis-session246-template-porpt_k2/summary.json`.

### Native clock wait ownership

Backplane 1.10.52 owns admitted `clock::sleep` waits within its existing Session
resource registry. The original local backend passes its existing registration
and deadline callbacks to the native clock implementation. A temporary waiter
registers before arming its timer, completes normally and joins its actual process
exit before returning the unchanged `wall_time_seconds` result. Conversation
retains the resource until the real result Store acknowledgement; only then can
the direct provider or nested Code Mode consumer receive the result. There is no
Synapsis clock tracker, new runtime owner, alternate backend or hook allowance.

Public `ResourceRegistry.owner_status/2` exposes this entry as a generic
`:resource`, while `worker_supervisor/1` permits observing the actual waiter
through the existing supervisor inventory. The dedicated ordinary fixture checks
both, forwarding genuine Concord ACKs unchanged. It covers direct Conversation
and provider-free Deno Headless, exact durable intents/results, result ordering
and normal Session/worker closure. Standalone `Codex.call` retains its legacy
synchronous behavior and cannot establish this admitted lifecycle contract.

The upstream #146 cancellation/retirement and reconciliation changes are adopted
and source-reviewed; normal completion evidence does not qualify those branches.
No cancellation, failure, security or permission execution tests are run. This
dependency update does not install scheduled scripts or background media jobs.

### Native automation creation and versioned configuration

`synapsis::automations_create` revision 2 is a separate, explicitly selected
capability. The existing read-only `automations` and run-only `automations_manage`
descriptors retain their meanings. Profiles pins the configured creator Agent UUID
and creation Session UUID into host context. `Routines.create_automation/3` writes
those facts as `automation_origin` with integer contract version 1; `agent_name`
is the separately editable execution route. Later route/name and scheduler writes
preserve that original binding. No saved selection is expanded automatically.

The native create schema uses host configuration fields and supports typed
cron/at/every schedules, authored prompt, current/isolated, local announce/none or
primary webhook with an explicit `delivery.to` HTTP(S) URL,
execution provider/model and route overrides, enabled state at creation and
one-shot retention. The existing Config.Store serial callback applies v1 defaults
through data-only `RoutineAutomation` before cadence normalization. Creation
defaults to enabled, current when a source exists (isolated otherwise), now,
announce and native_agent, with deleteAfterRun for at. A separate inferred name
uses the first nonblank prompt line and a UTF-16-safe 60-unit limit; authored
prompt bytes are unchanged. Name trimming follows ECMAScript whitespace,
including BOM and excluding NEL.

Existing v1 entries do not receive create defaults again. Presence-aware delivery
patches merge against the latest serialized entry, preserving omitted and unknown
fields, false and zero. Explicit null clears optional provider/model and stored
delivery address fields. Stored address preservation does not install channel
delivery. Legacy entries retain their existing normalization. Cold snapshots with
persisted cadence identity also retain omitted fields.

Creation returns a generated UUID and separate acknowledged persistence and
scheduler reload observations. Reload success does not prove model readiness or
execution; a reload failure retains the persisted identity and the existing
fail-closed behavior. If optional display fields exceed the result budget, a
flagged minimum response still retains source, UUID, persistence and reload status.
Create/update receipts retain the full delivery target when the combined content
and structured result fits its 65,536-byte budget. An oversized minimum projection
shortens only the public target, marking `delivery.to_truncated` and
`projection_truncated`; the persisted and admitted target stays complete.
Dispatch uncertainty does not authorize retry or rollback.
Cancellation of the tool does not delete an already committed configuration.
The effect runs through the original Config.Store, sole LocalScheduler and Daemon
owners; there is no second store, receipt or executor.

Existing domain updates preserve v1 origin. Full reference schema/action/assembly
parity is not established by this host create surface.

### Managed automation cancellation requests

`Routines.remove_automation/2` and `disable_automation/2` are distinct managed
domain operations. The existing reentrant Config.Store write lock serializes
exact-source lookup, acknowledged configuration mutation and a bounded
`LocalScheduler.retire/3` acknowledgement. Removal deletes the configuration;
disable requests cancellation only on an enabled-to-disabled transition. Repeating
disable preserves a later explicit force Run. The compatible `Routines.delete/2`
and `update/3` keep their existing contracts; no native write selection is expanded.
After acknowledged persistence the response retains source, UUID and
`persisted: true`, even when cancellation acknowledgement is unknown. The
configuration is not rolled back or blindly retried.

The Scheduler captures compatibility-trigger, due, force and timer producers as
paused supervised tasks. It pins the actual Daemon PID, registers each producer
from its own PID, and the Daemon records and monitors that producer before
releasing it. Its ordinary synchronous submission transfers ownership into the
Daemon's generated-ID submission entry. Registration and retirement messages
originate from the same Scheduler PID, providing an ordered cut through captured
work. The idempotency-hit path also passes through Daemon ownership, retaining the
actual durable Run ID. An injected trigger function must submit from that same
producer to obey this contract.

Retirement removes the exact future timer/reservation, retains a committed disabled
configuration when supplied, and marks captured producers, tracked Runs and
pending schedule effects retired. The callback performs no Store writes, reload,
provider work or synchronous cancellation. Daemon acknowledgement records exact
`{source, id}` cancellation intent across active, queued, submitting and registered
work, and the current recovery/refill backlog chain. Counts describe captured
owner state and may overlap; `cleanup_pending` is an observation, not settlement.
Existing Operations perform cancellation. Same-UUID sibling sources and durable
Run history remain intact; source-unknown historical work is not guessed.

Retirement also transfers exact Run identity to the Scheduler, including work
known only to the Daemon. The acknowledgement includes known retired Run IDs;
captured producers, submissions and recovery/refill work report later resolved
IDs through the same pinned-owner request. Recovery reports scanned identities
before interrupting or publishing terminal events, preserving IDs across the
associated backlog/retry chain. Identity completion means that captured identities
have been accounted for; it does not mean cancellation or external effects settled.
While identity is unresolved, matching terminal schedule effects wait, including
those from a new producer that might resolve to an old idempotency alias. Once
identity completes, retired IDs are suppressed and remaining terminal effects may
continue. New admission remains available. Owner loss or an unknown submission
does not silently release the identity hold.

A captured producer may persist its first known submission once and cancel the
result before runnable admission. Once a retired submission has dispatched with
uncertain outcome, reconciliation only reads its generated ID and tagged
idempotency mapping; it never recreates on not-found. Producer death does not
discard an accepted submission. Matching recovery results are held before queue
admission through the entire existing backlog/retry chain, then the target-wide
association ends. Exact producer/Run obligations remain separate, so later fresh
explicit work is not permanently banned.

Retired results and terminal observations do not rearm a retired timer or apply
old one-shot mutations to a later configuration. Already-dispatched Store writes,
missing acknowledgement, owner restart and started external effects remain
separate limits. Request bookkeeping is process-local; there is no new durable
receipt, retry journal, executor, crash completion guarantee, hard no-late-write
claim or reuse of a cancelled target runtime lifetime.

### Native automation updates and removal

`synapsis::automations_update` revision 2 and `synapsis::automations_remove`
revision 1 are separately selected descriptors. They retain the existing read-only, run-only
and creation descriptor contracts. Profiles constructs only the selected mutation
descriptors and pins the configured Agent UUID and caller session; arguments do
not supply creator identity. Version-one origin matches the creating Agent UUID,
so a later session of the same Agent may mutate the configuration while retaining
the original source session. Truly ownerless legacy entries use their existing
execution-route fallback and remain creator-unknown.

The domain holds the existing Config.Store write lock across latest lookup,
creator matching, serialized mutation and immediate Scheduler observation.
Updates preserve omitted fields and unknown existing data. RoutineAutomation
applies nested delivery merge and optional provider/model clearing against the
latest serialized entry; updates do not apply creation defaults. Routine entries
accept their existing string or typed schedules. Legacy heartbeat updates keep
string schedules and common supported fields; version-one routine fields expose
only implemented current/isolated context, local announce/none, primary webhook
and overrides. A `delivery.to`-only patch retains the stored mode; a mode-only
patch retains its target. Config.Store validates the merged effective webhook
target on writes and cold reload. Explicit null clears an optional target when
the effective mode permits it. Contract version 1 and saved selections remain
unchanged; native descriptor revisions flow through the existing revision map.

An enabled-to-disabled patch commits all fields once, then retires captured work
using the committed configuration. Other patches reload the existing Scheduler;
repeating disabled state does not cancel later explicit force work. Removal uses
the same managed boundary after checking the current creator. Compatible
`Routines.update/3`, `delete/2` and managed `remove_automation/2` remain unchanged.

Receipts retain source, UUID and acknowledged persistence independently of
activation. `reloaded` records a reload acknowledgement; `retired` requires a
retirement acknowledgement, while missing retirement acknowledgement is `unknown`.
Reload failure remains separately observed as `failed`. Cancellation status and
aggregate counts do not promise cleanup settlement. Public output is bounded,
JSON-compatible and excludes owner PIDs, references and raw failure data. If an
optional configuration projection exceeds the output budget, a minimum receipt
retains the acknowledged mutation and marks `projection_truncated`.

### Automation wake input custody

Direct manual wake is a distinct session-event operation in the pinned reference.
With a concrete caller or explicit target session, both `now` and the default
`next-heartbeat` immediately request exclusive follow-up admission. Acceptance,
checkpointed prompt consumption and terminal completion are separate observations.

The data layer provides typed event custody in the existing session
`pending_inputs` value. Events retain an independent occurrence UUID, captured
internal-system provenance, target Agent and Worker-lifetime owner identity.
Identical invocations remain distinct. The event capacity is twenty pending
occurrences; the existing twenty-five ordinary prompt/steer capacity is separate.
Input text uses ECMAScript outer-whitespace trimming and retains its body.

All pending-input mutations use one narrow compare-and-put path through
Session.Store and the public Concord transaction API. Reads capture the decoded value and modification revision together, distinguishing
absent state from storage failure. Transactions compare that revision, preserving
numeric type distinctions that a value-only comparison could miss. Each acknowledged conflict re-reads and recomputes,
with at most three attempts sharing the original five-second budget, checked
between operations. Concord readiness and database calls can exceed their
requested timeout; this is not a hard caller wall-clock bound. A dispatched
transaction failure is unknown and is not automatically retried. This provides
ordinary acknowledged conditional writes, without a hard no-late-write deadline
or a new queue store, lock-based CAS substitute or executor.

Owned event selection, start and terminal projection update the exact occurrence
and preserve unrelated entries. A new owner retains completed history and marks
previous-lifetime nonterminal events `owner_lost`; ordinary prompt/steer recovery
keeps its existing behavior. A durable row does not authorize automatic manual
event replay. Optional Message provenance and internal-turn-source fields survive
the existing durable message codec; ordinary encoded messages retain their shape.

`Sessions.wake/3` admits an event to the exact existing target session, retaining
its configured Agent/provider/model and independently captured source identity.
The receipt includes the occurrence and target session UUIDs. Both modes use the
same exclusive follow-up lane; acceptance acknowledges durable custody and live
owner insertion, rather than prompt consumption or completion.

Worker.PendingInputs serializes affected store operations, including boot
recovery, in one supervised asynchronous task lane with a bounded 64-operation
queue. Event reservations count towards the independent twenty-event capacity.
Fresh idle ordinary prompts retain their existing direct, no-pending-row path;
earlier recovered or accepted inputs retain FIFO. Existing automation completion
appends have priority, and selected input preparation waits for their ACK and
runtime cleanup. Agent switching cannot cross a pending-input busy window.

Typed Runtime input persists the event occurrence UUID as the host user Message
ID with provenance and `internal_turn_source="event"`. A fresh `runtime_started`
binds the runtime epoch/run; only its matching `prompt_consumed` with `mode:new`
adopts the exact occurrence. The runtime message UUID remains distinct. Terminal
projection follows the existing transcript commit/cleanup ACK, and the next
preparation waits for that projection. Deferred barrier reply actions preserve
active and queued caller handles. Unknown persistence outcomes retain an
unresolved barrier without automatic retry, rollback, or replay claims.

Event text parts preserve the already ECMAScript-trimmed body, including a
NEL-only body. Ordinary prompt text-part construction keeps its existing rules.

Eight ordinary local-fixture wake lifecycle cases pass. Concord 3.1.9's public
finite queued list admission is now consumed by context turn-page seeks. The
unchanged automation context and wake checks pass together; the current baseline
had returned timeout after visible streaming completion before this adoption.
This is ordinary integration evidence, without a forced contention or deadline
probe. Historical Concord 3.1.8 immediate-admission observations remain in the
plan and upstream issue #110. No local serialization, retry, pool change or
weakened context assertion is used. The earlier native creation case also passes
unchanged in the current composition, including before this list change; its
historical unavailable cause remains unproven.

The independently selected `synapsis::automations_wake` revision 1 uses the
existing native CatalogBinding and Worker API. Profiles captures the supported
primary-conversation marker and source Session/configured Agent UUIDs. Execution
reads the exact durable source and target, resolves their configured identities
through the healthy bounded Agent directory, and passes the original remaining
effect deadline to `Sessions.wake/3`. Optional `agent_id` asserts the target's own
Agent; omitted `session_id` uses the captured caller. Public content and structured
success contain only `{ok:true}`. Existing descriptors and saved selections retain
their meanings; no migration enables wake.

Two ordinary backend/Profile cases and three actual local-fixture native session
cases cover selected-only assembly, held caller acceptance, distinct duplicate
effects, an explicit second target, native ToolResult/Part/Concord and completed
Worker history replay. These checks do not establish real-provider or full
reference acceptance. Manual-event display projection is described below.
Untargeted service wake requires a separately defined designated conversation and
ordinary in-session scheduled receiver; the existing detached `current` and
`isolated` contracts retain their meaning.


### Manual-event assistant reply display

New manual `system_event` turns stamp only their assistant Messages with optional
`reply_presentation = {version: 1, policy: "manual_event_message", occurrence_id}`.
Raw native messages, host Part.Text, Concord encoding, model replay, exports,
compaction and session-history APIs retain authored bytes. Untagged historical
and ordinary replies retain existing behavior; no historical inference/backfill
or global heartbeat quiet policy is applied.

`Synapsis.Session.EventReply` owns the pure message-mode display policy. It ports
the pinned OpenClaw helper's exact ECMAScript whitespace, ASCII word matching,
UTF16 suffix-unit counting and candidate precedence, including the observed
`**HEARTBEAT_OK**` to `****` result. Token-free formatting remains byte-preserving.
Canonical text parts project independently; reasoning, media, tool use/results
and nested content remain typed and unchanged. Empty text alone hides a row;
media with an empty caption stays visible. Meaningful remainder has no
300-character suppression threshold.

Worker keeps one derived view for the selected occurrence and actual native run.
Raw `text_delta.text` and `in_flight_text` stay raw; event deltas additionally carry
a scoped, revisioned replacement view. Native `response_completed` reconciles
canonical text-part boundaries through standalone `reply_presentation` events.
After the original transcript commit ACK, successful terminal settlement emits
one `phase=committed` envelope per actual stored assistant Message UUID, followed
by a closed fence and existing terminal events. Known cancellation never emits
successful committed presentation; uncertain cleanup/storage retains its existing
unresolved owner. These failure branches have source review only in this slice.
No presentation cache schedules work or decides event adoption/completion.

LiveView uses the existing ChatBridge replacement/snapshot-removal protocol and
the same durable projector on mount/reload. New occurrence envelopes are checked
against the live Worker view; same-scope stale revisions and closed views cannot
reopen display. Partial marker prefixes may appear before the complete marker
clears them. At the next active status, a live Worker snapshot with no event view
clears the prior settled display scope; a new occurrence adopts the current Worker
view. Ordinary and subsequent-event reasoning and tools remain visible before any
text arrives. REST and WebSocket history preserve raw fields and add display
overrides only to tagged messages; live REST/SSE/WS snapshots add the event view.
External subscribers choosing raw fields continue to receive authored text.

CLI stdout delays only tagged event text until acknowledged committed envelopes.
It prints surviving text once per host Message UUID in order and processes
committed summaries from an active initial closed snapshot before ignoring queued
same-scope duplicates. An idle/waiting snapshot does not replay prior event output
or latch its occurrence for the next request. One existing SSE request latches its first event occurrence
and ends on the existing done/idle event; this does not extend subscriptions to
later queued events. Ordinary text remains immediately streamed, and existing
reasoning/tool output remains unchanged. No terminal redraw or frontend package
change is required. Full gateway saved-history quiet suppression, broader channel
transforms and unknown-outcome recovery are separate capabilities.


## PubSub Topics

```
"session:#{session_id}"          # all events for a session
"sessions:#{project_path_hash}"  # session lifecycle events (create/delete)
"config:#{project_path_hash}"    # config change notifications
"tool_effects:#{session_id}"     # tool side effect broadcasts (:file_changed, etc.)
```

## Behaviour Contracts

### Provider Behaviour

```elixir
defmodule Synapsis.Provider.Behaviour do
  @callback stream(request :: map(), config :: map()) :: {:ok, stream_ref} | {:error, term()}
  @callback cancel(stream_ref :: term()) :: :ok
  @callback models(config :: map()) :: {:ok, [Model.t()]} | {:error, term()}
  @callback format_request(messages :: [Message.t()], tools :: [Tool.t()], opts :: map()) :: map()
end
```

### Native provider usage

The provider app preserves `Backplane.AiProtocol.Usage` as the vendor observation
contract. Agent-owned `ProviderUsage`, held by `ProviderEvents`, adapts it to the
native Conversation's cumulative metrics within one provider attempt. Each
ProviderAdapter relay creates fresh state. Provider-supplied attempt IDs are not
accounting identities; Conversation stamps its trusted run/incarnation/attempt.

| Canonical source | Native inclusive input | Native cached | Native inclusive output |
| --- | --- | --- | --- |
| `anthropic` | input + cache read + cache write | cache read | output |
| `openai`, `openai_responses` | input | cache read | output, already including reasoning |
| `google` | native total − (candidates + thoughts) | cache read | candidates + thoughts |

Every arithmetic operand must be explicitly known. Google's total includes
tool-use prompts, so subtracting inclusive output retains that input category
even though the installed codec has no named tool-use counter. Reasoning remains
a separate informational metric and is not added again to OpenAI/Anthropic output.
Missing fields remain nil, including cache details under a `complete` observation.
The completeness enum does not imply zero. An unknown final observation/source
cannot establish known usage.

Partial snapshots merge explicit fields, preserving earlier values when a field
is omitted; explicit zero replaces its field. Identical snapshots replace rather
than add. Each actual delta occurrence adds its explicit numbers, including two
identical occurrences; there is no delta retransmission identity in this API.
An omitted delta component makes its cumulative value unknown until an explicit
snapshot reanchors it. All four installed wire codecs currently emit snapshots;
the delta convention does not qualify an actual delta producer.

Usage observations are buffered until normal transport completion, including
trailing usage after the protocol's content terminal. Text, reasoning and tool
events retain their streaming path. At `:provider_done`, the adapter emits one
normalized `usage_updated`, then the completed response with the identical
snapshot. If no usage was observed, neither event fabricates it. Native report
deduplication owns terminal-repeat accounting. The host buffer stores counters,
not another usage ledger or a list of every observation.

This final-snapshot boundary is deliberate: native Goal accounting charges
component deltas and cannot refund a prior charge when a later cache observation
changes the split. An early unknown charge also permanently marks Goal accounting
uncertain. Buffering avoids both premature decisions, at the cost of deferring
usage delivery until the normal stream completes. It does not provide a token
cutoff during generation. Failure, cancellation and truncated-stream billing are
separate, unqualified paths. The ordinary Goal owner and bindings are installed by
SessionAdapter's lifecycle described above. This bridge grants no
`usage_authoritative` capability, automatic continuation or budget activation.

Counter semantics are grounded in the installed codecs/native contracts and the
official [Claude cache breakdown](https://platform.claude.com/docs/en/build-with-claude/prompt-caching#tracking-cache-performance),
[Claude thinking accounting](https://platform.claude.com/docs/en/build-with-claude/extended-thinking),
[Google UsageMetadata](https://ai.google.dev/api/generate-content#UsageMetadata),
[OpenAI cache metrics](https://developers.openai.com/api/docs/guides/prompt-caching#monitor-cache-performance)
and [OpenAI output/reasoning metrics](https://developers.openai.com/cookbook/examples/agent_optimization/optimizing_agents_for_cost_and_quality#metrics-helpers).
These documents explain protocol fields; local fixtures do not qualify real
provider accounts or every endpoint that accepts a compatible wire format.

### Tool Behaviour

Production host backends implement `Backplane.AgentRuntime.ToolEffects` and its
native `execute/1` operation contract. Their descriptors enter the existing
`ToolCatalog.admit_batch/2` composition; the historical `Synapsis.Tool` declaration
is no longer a production API or runtime module.

Its unchanged declaration lives only at
`apps/synapsis_core/test/support/legacy_tool.ex`, for retained mixed fixtures.
Core already compiles `test/support` only in `MIX_ENV=test`; other environments
compile `lib`. The test-only declaration supplies no registrar or dispatcher and
does not make retired Registry fixtures executable.

### Tool System Public API

```elixir
# Read-only settings metadata
Synapsis.Agent.Tools.DisplayCatalog.list()
Synapsis.MCP.source_catalog()
Synapsis.MCPSelection.display_catalog()

# Shared session configuration
Synapsis.Tool.Permission.config_for_mode(mode)
Synapsis.Tool.Permission.update_config(session_id, attrs)
```

MCP execution uses `Synapsis.MCP.runtime_snapshot/1` and
`Synapsis.MCP.Server.runtime_call/4` with native source generations and
caller-owned Backplane request handles. MCP discovery no longer publishes
process tools into the legacy `Synapsis.Tool.Registry`; `execute_runtime/5`
is removed, and old GenServer execution messages return a retirement error.

`Synapsis.MCP.source_catalog/0` and `MCPSelection.display_catalog/0` expose
read-only source metadata for settings and saved-selection review. They contain
no executable registrations. Legacy executable selection remains separate and
cannot turn display metadata into native access. Source refresh, failure and
stop broadcast `{:mcp_source_catalog_changed, payload}` on `"tool_registry"`;
MCP settings, Agent and Toolset pages reread their current source catalogs.
Empty and unchanged-name discoveries still invalidate displays. Saved choices
and contract versions are not migrated by this notification.

The remaining twenty-five callerless legacy model wrappers are removed, including
task, shell, planning, interaction, skills, memory, messaging and Swarm wrappers.
Their only production registration producer was Builtin. Builtin and the old
ETS Tool.Registry are now removed together with both startup registrations and
the Registry restart self-heal path. No native runtime or source display catalog
uses that old registry. Native tools retain their explicit selections,
descriptors and original domain services. No aliases or replacement grants are
added.

`Synapsis.Agent.SessionBridge` only builds workspace file context through
`build_spawn_context/1,2`. Its unused `spawn_coding_session/2,3` API and exclusive
session-creation, message-send and completion-watcher helpers have been removed.
Callers must use the supported session lifecycle or native collaboration APIs;
the context builder does not create sessions or select a runtime.

The unused `Synapsis.Agent.Runtime.ToolRegistry`, `SessionTools` and `ToolBackend`
modules have been removed. Current session turns assemble native bundles through
`SessionAdapter` and `Profiles`; they do not bridge back through these wrappers.
This retires those public module APIs. The subsequent caller audit also retired
the core Registry and Builtin. Current UI display metadata comes from
`DisplayCatalog` and source-owned MCP snapshots.

The empty `Synapsis.Workspace.Tools` module and its optional startup call are
removed. Its literal empty tool list registered nothing; real workspace file,
memory and permission services keep their existing owners. Agent startup no
longer registers legacy Builtin metadata.

`Daemon.Toolsets.resolve_for_query_loop/1` and its exclusive registration map
and filtering helpers are retired after a production caller audit. `resolve/1`
now declares ordered native profile names without appending Registry MCP tools.
Submission captures separate `native_profile` provenance in the existing Run
snapshot; execution uses its frozen names and an associated native Session.
The retired resolver's fixture and obsolete Registry/profile tests are removed;
its public Elixir API is no longer supported. Valid Run schemas and Execution
option tests remain separate from native runtime acceptance.

The nine callerless model wrappers `Synapsis.Tool.FileRead`, `FileWrite`,
`FileEdit`, `MultiEdit`, `FileDelete`, `FileMove`, `ListDir`, `Grep` and `Glob`
are removed along with their dedicated tests and mixed wrapper-only cases.
Native turns use the canonical `synapsis::read/write/edit/ls` factory and native
`apply_patch`/command tools. No legacy alias or automatic replacement grant is
added. Internal Local/Workspace file CRUD and search, `Tool.VFS` and
`PathValidator` keep their existing domain responsibilities. Standalone native
grep/glob equivalence remains incomplete.

The callerless `Synapsis.Agent.QueryLoop`, `QueryLoop.Executor` and
`Synapsis.Agent.StreamingExecutor` execution modules have also been removed,
together with their exclusive Worker task-completion and event-projection
handlers. The pure `QueryLoop.Context` and `State` helpers remain for historical
fixtures; they cannot run a turn or dispatch tools. The obsolete QueryLoop fork
test file is removed; independent Context/State tests remain. Other historical
executable fixtures are not current runtime acceptance.
The `:query_loop` mode label still routes turns to native `RuntimeSession`, so its
mode/queue/cancel compatibility and shared user-question notifications remain.
The session-specific graph executor is also retired. Worker boot now directly
initializes idle metadata (`engine_node: :receive`, `awaiting_input: true`), and
pre-adapter cancellation resets that metadata without building or stepping a
graph. Post-registration scheduling still drains recovered pending inputs into
native `RuntimeSession`. Boot retains its seven-element return tuple with a
`nil` graph slot; the old `graph_module` construction option is removed.

`CodingLoop.initial_state/1` remains a pure metadata helper. `CodingLoop.build/0`,
Worker's graph-step entrypoint, graph-only provider/tool/auditor callbacks,
`Worker.IOHandler`, `Worker.Auditor`, the session executor nodes and the remaining
`ToolDispatcher` classification module are removed. Native runtime events,
shared user questions, queues, public approval entrypoints, Config, persistence
and `Nodes.ProviderError` remain. Historical direct graph/node fixtures are
preserved; their retired API expectations are not current runtime acceptance.

Generic Engine/Graph/Node/Runner and checkpoint libraries remain behind the
public `Synapsis.Agent.run_graph` / `step_graph` script APIs. They are separate
from live Session execution.

The legacy `Synapsis.Tool.Gateway`, `Executor`, `CapabilityPolicy`,
`Capability.Grant` and `Capability.PolicySnapshot` are removed together. Their
remaining production references were confined to this five-module execution
island. Current sessions, MCP and Sandbox use native runtime dispatch; no local
execution or grant bridge replaces these retired APIs. Historical direct API
fixtures remain unchanged and do not establish current runtime compatibility.

The deprecated `Synapsis.Tool.Behaviour` compatibility declaration and unused
`Synapsis.Tool.Context` struct/helpers are also removed after a production caller
audit. Their public Elixir APIs are retired; historical direct fixtures remain
unchanged and do not establish current runtime compatibility. The separate
`Synapsis.Tool` declaration has moved unchanged into core's test-only support
directory after an exact production caller audit. The development app module
list and BEAM exclude it; the test build retains it with its compile source at
the test-support path. Existing fixture consumers and assertions are unchanged.

The unused Registry-based Permission.check/2,3, tool-level lookup and
override-resolution dispatch chain, plus Tool.Permissions, are removed.
Shared Permission configuration loading, revision-fenced persistence, mode
normalization and override parsing remain byte-for-byte at function level,
along with Permission.SessionConfig and native Tools.PermissionSnapshot.
Sessions, Worker and Daemon still call those configuration APIs; native policy
continues to authorize the admitted descriptors. TaskSupervisor, VFS,
PathValidator and workspace/domain APIs retain their owners.

Thirty-four exclusive legacy-contract test files are retired, with their original
bytes archived in the batch snapshot. Configuration and mixed native/domain
assertions remain separate. Shared native proof helpers keep their provider,
options, schema, prompt and event methods; only the old Gateway backend and its
sole descriptor factory are removed. Other historical mixed fixtures still
reference retired registration APIs and remain unqualified; this batch does not
replace them with another registry or delete their live native/permission cases.
The Tool declaration remains test-only; optional deterministic support and the
mixed fixtures remain for later migration, with no production runtime use.

The same seven-file ordinary before/after run has Agent27/1 and Web12/1 in each:
the existing Responses usage expectation lacks terminal model metadata and the
Routine fixture still uses a preexisting timer-key shape. Both failures occurred
before production edits, remain unchanged and are outside this retirement scope.
Their files/assertions are untouched; the combined run is not reported green.
A missing test partition caused an earlier setup-only failure; the original log
is retained and only the command environment was corrected before implementation.
No security/permission or other excluded tests ran. See
`/tmp/synapsis-retirement241-fi1n54v3/` for the audited removal list, preserved
baseline and bounded verification. Full P14/reference qualification remains open.

The ContextBuilder `<available_skills>` prompt block describes selected tool
metadata. An explicit `resolved_tools` list remains authoritative, including an
empty list. Otherwise an explicit native version-1 selection is projected in its
supplied order from `DisplayCatalog` and the turn's already captured `mcp_sources`;
MCP rows retain `mcp::source-UUID::raw-name`. The heading is `Selected tools:`.
This path does not enumerate the legacy Registry, refresh sources, construct
runtime descriptors, or establish readiness. Missing descriptive metadata does
not alter selection or native admission.

Root and child prompts use the same refreshed selection metadata; the child
retains its existing `memory_context: false` behavior. Provider tool definitions
and input schemas continue to come from native admission, independently of this
descriptive block. Daemon profiles remain a separate migration boundary.

`Agent.Resolver` preserves the effective native selection's names and order plus
the saved UUID-based `mcp_selection` policy. It does not expand that policy through
the legacy Registry. Source discovery, policy expansion and immutable snapshots
belong to `MCPSources.refresh` during supervised turn preparation; native Profiles
then admit the resulting descriptors. Resolving an Agent does not rewrite its
saved Agent or Toolset records. It also carries the explicit deferred-name list;
exposure planning happens after selected source expansion, as described below.

`MCPSelection` now retains only UI compatibility helpers: source-owned display
metadata, asynchronous source refresh, legacy saved-name conversion, and MCP-name
recognition. Its callerless Registry resolver APIs (`names`, `apply`, `catalog`,
`refresh_agent`, `refresh_required?`, `resolve_agent`) are removed. No saved choice
or MCP exposure strategy changes. Historical direct API fixtures are preserved;
they do not establish compatibility for these retired APIs or unknown external
Elixir callers. The actual Resolver and native Worker MCP path remain separate.

Official `backplane_mcp_protocol`1.10.44 supplies the caller-owned resource
start/await/cancel API requested by
[Backplane#123](https://github.com/gsmlg-opt/backplane/issues/123). The current
support layer adds `MCP.runtime_list_resources/3`,
`runtime_list_resource_templates/3` and `runtime_read_resource/3`, delegated to
Server. Each takes an exact trusted source snapshot, a request map and a finite
timeout. Registration reuses the existing source ticket/config-lock and exact
client incarnation; the actual caller owns the opaque official handle and awaits
outside the Server and lock. Raw response order, cursor, URI, MIME, text/blob and
metadata are returned without fetching referenced URIs or producing model content.

Discovery reads the official public ready protocol capabilities before listing
tools. A resource-only service can publish an empty-tools source snapshot without
an unsupported `tools/list` call. Advertised tools still use actual tool discovery.
The support layer retains the existing source generation and owner mechanism;
it does not inspect private pending state, invent request IDs, cancel a shared
client globally, or introduce another request manager.

Official Backplane MCP 1.10.46 fixes the namespaced `_meta` loss tracked by
[Backplane#130](https://github.com/gsmlg-opt/backplane/issues/130). Both original
ordinary resource fixtures now pass unchanged through actual HTTP, including
list/templates/read, opaque pages, resource-only discovery and complete request
metadata. The support layer forwards through the public caller-owned API without
an alternate encoder or dependency patch. This accepts the support-layer candidate;
model-facing resource configuration and execution remain separate work.

Saved `mcp_selection` selects remote tools. Independent resource selection lives
in `Agent.config.mcp_resource_source_ids`: an ordered, unique list of at most 128
source UUIDs, defaulting to `[]`. Resolver exposes it on the resolved Agent and
in process-free `tool_selection_sources.agent` provenance. Remote tool selection
never populates it. The existing generic config API/TOML path preserves this
setting without a storage migration or new UI control.

`MCPSources.refresh` refreshes the distinct union of tool and resource sources
once, then captures separate maps: `mcp_sources` for tools and
`mcp_resource_sources` for resources. Resource-only sources retain their exact
source UUID, Server PID and generation with an empty tools list; preparation
does not list templates/resources or read a resource. Missing configured sources
remain explicit errors rather than becoming an empty successful selection.

Native Daemon submission freezes resource UUIDs in the existing version-one
snapshot's Agent provenance. Overlay restores those frozen IDs after saved-Agent
edits and drops stale live resource snapshots; turn preparation captures fresh
source generations. Historical snapshots missing this field restore `[]`.
PIDs and generation-bound snapshots are not persisted in Daemon provenance.

The user chose to wait for native aggregate lifecycle support: omitted-server
listing must query all explicitly selected sources with native tracking of every
request. Official Backplane 1.10.48 now supplies the public
`DynamicRuntime.resource_request_scope/2` and scoped `resource_request/2`, resolving
the dependency capability requested in
[Backplane#139](https://github.com/gsmlg-opt/backplane/issues/139). Synapsis has adopted
the five official packages. Three ordinary native contract cases exercise real
list/template/read invocations across two resource-only HTTP clients, preserving
ordered raw results, opaque cursors, URI, metadata and caller-owned handles. This
qualifies the upstream scope API; the fixture uses direct public Client starters.

A scope tracks up to 128 sequential requests under one native invocation. Its
starter must return the real official handle and preserve reserved bounded request
options, including tracked retirement and the absolute native deadline. Existing
Synapsis synchronous resource wrappers return completed raw maps. The native path
instead uses `MCP.runtime_start_resource_request/4` through the exact source ticket
and config-lock boundary. It returns the actual caller-owned official handle;
lookup and lock acquisition consume the finite registration/request budgets, and
the absolute retirement deadline is preserved without legacy await/cancel padding.
Upstream source retains the ordered inventory through authoritative result ACK;
interruption, failure and crash-recovery behavior is source-reviewed only.

`MCPResources` builds the original native `list_mcp_resources`,
`list_mcp_resource_templates` and `read_mcp_resource` descriptors through the
dynamic profile, enriches them with immutable per-turn source snapshots, and
strictly re-admits them. Profiles retains native backend/schema contracts and
classifies the pinned descriptor; SessionAdapter installs the selected bundles.
One temporary DynamicRuntime belongs to each native Session owner/incarnation
through ResourceRegistry. Its bounded process-local cache reuses the runtime
across completed turns, preserves newer child records during root preparation,
and removes records only after confirmed Session/resource cleanup. Source
selection stays in descriptors, not mutable runtime state or durable history.

Omitted-server list/template calls visit every selected UUID in saved order;
an explicit `server` is a selected UUID. `cursor` is forwarded unchanged to each
requested source, including omitted-server fanout; no global continuation token
or automatic page draining is created. Read routes an exact URI to one selected
UUID. Each success contains `{"sources": [{"server": UUID, "result": RAW}]}` as
both JSON text content and structured data. RAW retains the complete source map,
including cursor, URI, metadata, extensions, text and blob. Existing result-size
limits reject oversized results instead of clipping them. Empty source selection
produces the ordinary empty envelope. Errors stop aggregation without publishing
a partial success. Resource contents are structured data; they are neither
dereferenced nor converted into provider media blocks.

Dedicated ordinary fixtures cover support starters and the model-facing path;
their executed results and remaining limits are recorded in the implementation
plan. Raw support-layer HTTP alone does not establish model consumption or actual
cancellation cleanup. No legacy aggregate callback, narrower omitted-server
behavior or local request tracker is installed. Dynamic tool exposure,
`mcp_events` and failure/cancellation/crash execution acceptance remain separate.

`mcp_events` is a separate event-descriptor browsing contract. The pinned tool
accepts a configured `serverName` and optional opaque `cursor`; its Gateway fetches
one Events catalog page and projects webhook-capable definitions, argument and
payload schemas. It does not create a subscription or automation. Full plugin
activation and the webhook/ingress service have separate requirements.

Official MCP 1.10.46 provides `Client.start_list_events/2` and
`await_event_request/2`, addressing
[Backplane#132](https://github.com/gsmlg-opt/backplane/issues/132). Two ordinary
HTTP fixtures negotiate modern `2026-07-28` through `server/discover`, await the
actual caller-owned handle, and preserve explicit cursor pages, raw descriptor
order, boolean/object schemas, extra result fields, Unicode and request metadata.
The same client remains usable for ordinary resource and tool requests. Modern
protocol and advertised Events capability are required; the host protocol default
has not changed. Production model-facing event-tool wiring and source visibility
remain unimplemented. Official 1.10.51 closes
[Backplane#144](https://github.com/gsmlg-opt/backplane/issues/144), adding public
`event_request_identity/1`, `event_cancellation_control/0`, controlled
`await_event_request/3`, tracked `retire_event_request/2` and
`DynamicRuntime.event_request/2`. The original `mcp_events` descriptor requires
an explicit server and fetches one page with an optional opaque cursor. The
helper registers before dispatch, owns the real handle, validates confirmed local
retirement and retains responsibility through the real result Store ACK. Its
reserved starter options must win; the helper consumes the retirement receipt,
so callers neither retire again nor inspect private state. Remote completion
remains unknown.

Dedicated ordinary fixtures qualify raw public identity/receipt fields and the
actual native helper under Conversation and nested Headless Code Mode. A
forwarding Store uses real Synapsis Runtime.Store/Concord ACKs to gate dispatch and
result consumption; complete raw pages, durable history, normal Deno exit/Session
closure and shared-client reuse are checked. Code Mode receives the original
page, while the durable tool result also carries `is_error: false`. This is
upstream bridge qualification, not a production Events adapter or subscription.
Event-source selection remains a separate unresolved configuration choice;
resource UUIDs do not implicitly select it. Failure/cancellation/recovery branches
remain source-reviewed only; no excluded execution or transport workaround is
claimed. The separate 1.10.51 `Goal.settle_host_admission/4` addition (#145) likewise
has no Synapsis host consumer yet.

The independent `mcp-events.json` fixture executes six whole pinned source
modules, with 17 other sources retained only for provenance. Nine ordinary
vectors preserve order, opaque cursors and exact JSON/details. Description
projection follows JS `.slice(0,4096)` in UTF16 units, including an escaped lone
surrogate when truncation splits an emoji. Its explicit connection/runtime
facades establish neither real MCP transport nor the plugin's service, account
authority, native Worker or durable automation behavior. The accepted independent
resource-source UUID configuration does not implicitly select event sources;
event-source visibility and dynamic MCP exposure remain separate consumer
contracts.

Backplane 1.10.46 adds the runtime-owned `register_cancellation` callback to
ordinary tool backend contexts. Existing host adapters recognize that exact
native metadata field alongside `nested_dispatch`; their construction contexts,
arguments and domain execution remain unchanged. The compatibility update does
not invoke the callback or adopt the new resource cancellation helper. Actual
cancellation and recovery remain source-reviewed boundaries.

The callerless `Synapsis.MessageBuilder` module and
`Session.Worker.Config.refresh_turn_tools/1` API are removed. Live turns refresh
selected sources through `MCPSources.refresh` in the supervised preparation task;
`SessionAdapter` builds native Profiles and Conversation supplies admitted tool
definitions to `ProviderAdapter`. No legacy Registry request builder or alternate
turn refresh replaces that path. All other Worker.Config resolution, model,
mode and Daemon-selection behavior remains unchanged, including the reachable
`reject_daemon_tools` helper. The obsolete MessageBuilder test file and
`refresh_turn_tools` fixture are removed; the independent optional Session config
storage test remains. No compatibility with these retired public APIs or
external Elixir callers is provided.

`GET /api/health` reports host infrastructure availability. The retired
`tool_registry` field is replaced by `session_registry`,
`session_supervisor_registry`, `session_task_supervisor_registry` and
`tool_task_supervisor`, checking the three Session lifecycle registries and the
supervisor used for native turn preparation. Existing subsystem checks and
health aggregation remain. These process checks do not admit tools or establish
per-run catalog readiness, credentials, or external MCP availability. No display
catalog or synthetic descriptor is built by health requests. Historical tests
and external consumers expecting the retired JSON field require the new contract.

New Agents and missing Agent permission modes default to `yolo`. New session
permission structs and default session configuration use `:autonomous` with
read, write, execute and destructive decisions set to `:allow`. The Agent form
and mode conversion also treat an omitted or empty mode as `yolo`.
Explicit saved `ask`/`restrict` modes and per-tool overrides retain their
meaning; startup seeding preserves saved Agents. This default change does not
migrate stored permissions, tool selections or contract versions. Native runtime
admission still reads the persisted permission snapshot through its existing API.

Native `web::fetch` uses the original Backplane service profile and backend.
It must be explicitly selected, and the enabled Agent must have a nonempty
`config.web_allowed_hosts` list. The Agent Tools tab edits this list as one
hostname per line; selection remains separate. Ordinary unchanged form values
preserve the stored config. Empty configuration makes fetch unavailable.
The builder reads `AgentConfigs` directly and binds the Agent UUID and host-list
fingerprint to the run; classification reloads that configuration before a call.

`Synapsis.Web.Transport` supplies bounded Req GET requests with a 5-second total
deadline and a 262,144-byte response-body ceiling. It uses clean Req defaults,
disables retries and redirect following, and retains native rejection of
redirects and chunked responses. The durable public projection contains
`status`, `url`, `content_type`, `body`, and model-visible `content`; raw response
headers are omitted. Text must satisfy the existing UTF-8 projection limits.
Bodies are returned as fetched: HTML extraction, instruction processing, cache,
search vendors and Browser actions are not implemented by this fetch slice.
HTTP 404 remains a public response with its status and body.


### Explicit deferred tool discovery

`AgentConfig.config["deferred_tool_names"]` is an exact ordered list of already
selected canonical tool names. Omission means an empty list; it does not rewrite
saved defaults or select additional sources. Resolver carries the list alongside
the existing selection; MCP expansion remains owned by supervised turn preparation.
The Tools form offers effective selected native/Toolset/MCP names and retains
unavailable saved entries for explicit removal. Saving unrelated fields preserves
raw selections and unowned configuration.

For a nonempty valid list, the host derives an ephemeral runtime selection with
original native `tool_search`. The generated control does not enter saved tools,
DisplayCatalog, supported_names or legacy migration. The native Session ceiling
contains the effective selection and this generated control. Host Discovery builds
one immutable issued inventory, normalizes deferred members through public native
Contract APIs, and strictly admits the initial subset with deferred members absent.
Candidate backend, complete context, source UUID/raw name, revision, schema,
custom format and original direct/direct-model-only exposure remain intact.

A per-run native DynamicRuntime indexes only those deferred candidates. It runs
under native ResourceRegistry ownership, separately from the cached resource-only
runtime. Native search stages publication; Conversation settles the current pinned
batch and commits the new catalog before the next provider request can see its
new members. Existing provider/invocation resolvers project committed snapshots
against the same issued inventory. The host does not mutate inventory from an
event callback or dispatch around native execution. Empty lists keep the existing
initial catalog and allocate no discovery runtime.

Child preparation uses the actual parent invocation ceiling. A child created before
publication inherits the current initial members; a later child can independently
defer/search newly inherited members. Existing children do not gain later parent
members. Native CodeMode keeps the same Session, pinned catalog and dispatcher;
publication affects later calls/cells, while running continuations keep their
pinned catalog. Generated search does not add exec/wait or change direct-only tools.

The native search result retains its public tools/publication maps in the durable
projection. ResultProjection accepts the official staged receipt and supplies a
JSON text view; a staged receipt is not a committed catalog. Existing static/Daemon
selection-name restrictions remain unchanged; literal punctuation in standalone
Contract representation tests does not establish production admission.

Daemon snapshots retain the explicit list in captured Agent source material;
queued execution restores that list instead of a later live Agent edit. Older
snapshots without it mean empty. Native discovery resources retire through the
existing normal completion ownership path, with cleanup results preserved.
These boundaries do not complete OpenClaw reference action/assembly, source
eligibility, interrupted recovery or real-provider acceptance.

### Selected Tavily extraction

`synapsis::tavily_extract` is a separately selected native ToolEffects descriptor.
The enabled Agent supplies `config.tavily_extract.credential_id`, optional
`base_url` (default `https://api.tavily.com`) and `timeout_ms` (default 60000).
Arguments contain ordered `urls` (1–20), optional `query`, `extract_depth`,
`chunks_per_source` (requires query), and `include_images`. The pinned reference
has no `format` argument. Credentials resolve only inside the existing effect;
Backplane remains the runtime authority.

Provider `WebExtract.Tavily` owns `/extract` HTTP requests and result projection.
Shared transport retains its 16 MiB default; extraction explicitly permits
64 MiB raw responses. Public results preserve exact prose whitespace, optional
empty content/images, ordered rows and a shared 20-image budget. Raw content then
content consume one 20000-UTF16-unit budget across rows, using scalar prefixes.
Core `Web.Extract` owns a separate supervised 100-entry, fixed 15-minute cache;
normalized argument order, options, endpoint and credential identity distinguish
entries. Search cache TTL and capacity are independent. Hits add `cached:true`
and retain the original timing. Timeout does not partition cache entries.

The Agent emits compact JSON plus its structured equivalent through existing
native result limits. Ordinary ToolUse arguments, next-provider history, Part
encoding, Concord snapshots and a new Worker replay retain the result without
another extraction. The fixed-source factory oracle and local Gaoxy HTTP chain
are separate evidence. Host JSON omits reference random external-content frames
and stamps; full WHATWG URL/sanitation equivalence, large native Unicode chains,
long deadlines, cancellation/recovery, UI configuration and external provider
acceptance remain unverified. Cache expiry is source-reviewed in the host and
executed with a synthetic clock only in the reference capture.


### Selected Firecrawl search

The existing generic `synapsis::web_search` configured with `firecrawl` or
`firecrawl-free`, and dedicated `synapsis::firecrawl_search`, continue through the
same native Web adapter and configured host descriptors. The provider-specific
format is isolated in `Synapsis.Provider.WebSearch.Firecrawl`; no tool, executor,
credential policy or production configuration is added.

Dedicated reader adaptation trims query, array items and optional time/location/
country strings, drops empty options and canonicalizes absent/false scraping for
the shared cache. Generic Firecrawl preserves its authored query, as the reference
provider callback does. Request path replacement remains `/v2/search`, with one
HTTP request and explicit caller timeouts. Provider rows preserve envelope priority
(including an empty first array), web/news/images order, nonempty-string fallback
fields, full valid published timestamps, optional scraped content and ordinary
URL serialization. Empty `url`, title, description, markdown or date fields no
longer hide a later valid source/metadata value. Direct valid timestamps already
retained their spelling; the fix restores their fallback path.

An independent fixed-488631c capture executes 56 whole modules, including actual
plugin registration, paid/free provider factories, dedicated callback and the
complete shared search client. Its 41 groups/47 callbacks include 43 actual HTTP
fixture callbacks. Eleven positive Node checks compare fresh full capture data;
a Core fixture compares all 43 source-effective typed requests and complete
portable outputs. Exact framed source results remain in the fixture; portable
comparison removes only explicit reference framing/stamps. Native schemas retain
snake_case and integer inputs; raw reference reader numeric-string/camelCase
acceptance is an explicit adaptation, not a new native argument contract.

Provider text shares the existing 20,000 UTF-16-unit budget; generic output has
its separate URL-first budget and ten-row projection, while dedicated search
retains up to 100 rows. The native Worker fixture exercises 100 rich rows, a
separate generic call and a cached repeat, with subsequent model wire, Part JSON,
Concord readback, normal owner close and completed Worker replay without another
HTTP effect. Full WHATWG/sanitizer/wrapper equivalence, native large Unicode
history, long deadlines, UI configuration and live provider acceptance remain
unverified. Failure/cancellation/crash and security/permission tests are excluded.
Evidence: `/tmp/synapsis-firecrawl-search149-z3zqjbvw/`.

### Selected Firecrawl scrape

`synapsis::firecrawl_scrape` is a separately selected native ToolEffects host
extension. The enabled Agent supplies `config.firecrawl_scrape.credential_id`,
optional `base_url` (default `https://api.firecrawl.dev`), `timeout_ms` (60000),
`only_main_content` (true), `max_age_ms` (172800000) and `max_chars_cap` (50000).
Existing credentials resolve inside the effect. Model fields retain the pinned
camelCase names: `url`, `extractMode`, `maxChars`, `onlyMainContent`, `maxAgeMs`,
`proxy`, `storeInCache`, `timeoutSeconds`. Native model input remains schema typed;
direct reference factory numeric-string parsing is a separate Provider contract.

Provider `WebScrape.Firecrawl` owns POST and result mapping; its Markdown helper
converts text mode. Both modes request `formats:["markdown"]`; the endpoint path
is replaced with `/v2/scrape` and query/fragment/userinfo cleared. The existing
shared transport receives an explicit 64 MiB raw JSON bound; its default remains
16 MiB. The mode and body budget are local postprocessing, absent from HTTP JSON.
The effective timeout is floored/clamped seconds; per-call values override Agent
defaults while the existing outer native effect deadline remains authoritative.

A page uses `data.markdown`, then `data.content`. Text mode preserves literal
fenced code while removing ordinary Markdown formatting; headings and lists
recognize CR/LF/U+2028/U+2029 line boundaries. Ordered-list prefixes match ASCII
digits only; ordinary Arabic/fullwidth numeral prefixes remain literal. Body uses a UTF16 scalar-prefix
budget, default 50000, bounded by the separate configured cap. Raising only that
cap retains the default; raising both argument and cap permits larger content.
Title then warning share an independent 4000-unit budget. Ordered metadata
selection, optional target status, source URL fallback and original text lengths
remain public. The host omits reference random frames and `externalContent`;
its `length` counts unframed text UTF16 units, while `rawLength` counts the full
mode-converted input before truncation. Markdown/title/warning edge whitespace
is preserved; text-mode prose follows the source whitespace conversion.

Core `Web.Scrape` translates domain errors and enforces the result bound. It adds
no local cache: `maxAgeMs`/`storeInCache` control the remote provider's cache, and
identical invocations each perform HTTP. Agent presentation uses existing compact
JSON/structured result limits and Backplane ownership. Ordinary Worker calls,
subsequent-model history, Part/Concord storage and a new Worker replay use this
same result chain. Full WHATWG/sanitizer/wrapper equivalence, native large-value
chains, long deadlines, cancellation/recovery, UI and real-provider acceptance
remain unverified; ordinary completed-history replay is distinct from recovery.

### Selected xAI X search

`synapsis::x_search` is a separately selected ToolEffects host extension for the
pinned xAI X-search contract. It uses the existing native catalog, binding,
Session and result path. Backplane's generic query-only `web::x_search` remains
an independent service contract; the initial capability map's target is not
proof of installation or of support for the reference filter schema.

The enabled Agent supplies `config.x_search.credential_id` with optional
`base_url` (default `https://api.x.ai/v1`), `model` (`grok-4.7`), `timeout_ms`
(30000), `inline_citations` (false), `max_turns` (omitted), and `cache_ttl_ms`
(900000; zero disables caching). These are typed host settings. Credential
resolution occurs inside the native effect, with no production config migration.
The host schema explicitly rejects additional properties; the reference TypeBox
factory leaves that setting unspecified. Model arguments use `query`, either `allowed_x_handles` or `excluded_x_handles`
(up to 20), optional `from_date`/`to_date`, and image/video understanding flags.

Provider `XSearch` builds a real xAI Responses POST: the endpoint appends
`/responses` to the trimmed base, input contains one user instruction, the remote
tool is `x_search`, and `store` is false. Model aliases and the pinned model
reasoning compatibility determine optional reasoning effort; default `grok-4.7`
sends `low`, while `grok-4.3` sends `none`. No local execution substitutes for the
provider. The shared bounded HTTP transport runs in the native effect's linked
caller tree; the existing outer effect deadline still applies.

Adjacent output text blocks concatenate without a separator, with top-level
`output_text` as fallback. Content retains whitespace and uses a contiguous
20000-UTF16-unit scalar prefix. Top-level ordered unique citations take
precedence over block annotations, up to 20; annotations are considered only for
retained blocks. Optional inline citations retain UTF16 offsets within retained
text. Public results echo normalized filters and keep timing and model identity.
Portable host JSON omits reference random frames and `externalContent`; full
WHATWG URL and external-content sanitizer equivalence remain unverified.

Core `Web.XSearch` translates domain errors and owns an independent supervised
100-entry cache. Keys distinguish effective model, endpoint, credential identity,
query, filters, understanding flags, inline-citation setting and max turns.
Timeout and TTL do not partition keys. Cached results retain initial timing and
add `cached:true`; TTL is checked against both the original expiry and caller
limit. Existing general-search and extraction cache capacity is independent.

The Agent uses the existing compact JSON/structured result limits. Ordinary
completed-history replay, failure/cancellation/crash recovery, real-provider
acceptance and complete reference equivalence require distinct evidence; a
healthy service or a source capture does not establish them.

### Selected xAI remote code analysis

`synapsis::code_execution` is an explicitly selected native ToolEffects host
extension. It sends the complete `task` and supplied data to xAI's Responses
`code_interpreter` tool, with one user input and `store:false`. It installs no
local Python/Deno executor and is independent of local Code Mode and the pending
headless Code Mode API. The enabled Agent supplies `config.code_execution` with
`credential_id`, optional `model` (default `grok-4.7`), `timeout_ms` (30000) and
`max_turns`. A separate host `base_url` setting defaults to `https://api.x.ai/v1`
and appends `/responses`; this explicit transport adaptation supports configured
hosts and local fixtures, whereas the pinned source fixes its endpoint.

The Agent captures trimmed URL/model configuration through the existing binding
and Session path and resolves credentials inside the effect. The model schema
contains only `task` and explicitly rejects extra fields; the reference TypeBox
factory leaves additional properties unspecified. The descriptor declares a
non-retryable remote execution effect. Existing native execution, ownership,
compact JSON/structured results, per-string and aggregate limits remain in force.

Provider `CodeExecution` owns the protocol and output observation. Shared
`XAI.Responses` helpers retain model aliases and per-tool preferred reasoning:
code analysis prefers `low` (including `grok-4.3`), while X search retains its
separate `none` preference and bounded answer contract. Remote analysis preserves
adjacent message/direct output text without a separator and uses top-level text
only as fallback. Its source parser has no 20000-unit search cap, sanitizer,
wrapper or inline-citation projection. The shared transport still bounds raw JSON
at 16 MiB; Core enforces the existing result budget without clipping content.
Full native large-value acceptance is a separate storage/result boundary.

Top-level ordered unique citations take precedence over block annotations, up to
20 with a 1000-entry scan and 2048-UTF16-unit URL limit. `outputTypes` preserves
first-seen output-type order, and `usedCodeExecution` records whether the provider
returned a `code_interpreter_call`; it does not certify external execution.
Core `CodeExecution` translates domain errors and checks the result bound. It has
no result cache: each completed invocation sends its own remote request. Ordinary
completed-history replay uses the existing Worker/Part/Concord chain. Remote
cancellation, refunds, failure/crash recovery, long deadlines, full WHATWG URL
parity, UI and real-provider acceptance require separate evidence.

### Tavily search source fidelity

The existing selected `synapsis::tavily_search` and configured Tavily
`synapsis::web_search` keep the same native Web/Worker/Concord owner. Agent schemas
and credential/configuration references are unchanged. Provider.WebSearch.Tavily
owns the request/result format; common Provider budgeting, Core cache and generic
projection remain in their existing layers. Generic Tavily retains the authored
query; the dedicated private copy trims query and optional strings/domain lists.
Dedicated omitted/false `include_answer` share the actual callback's false cache
identity, while HTTP sends that field only when true. Raw ToolUse remains intact.

Tavily appends `/search` after removing one base-path trailing slash and retains
query/fragment. Ordered rows slice before interpretation, retain score and returned
answer, and charge the existing 20000 UTF16 budget title→snippet per row, then
answer. Existing full ISO and exact RFC-GMT date behavior is regression evidence;
it is not newly implemented timestamp precision. Ordinary URL serialization now
normalizes host/default port/space/non-ASCII encoding and retains bare-origin
spelling with a 2048 UTF16 URL bound. Full WHATWG/sanitizer/wrapper
equivalence remains unverified.

Independent pin488631c capture executes whole registration/factories/client/cache/
normalizer, with 41 executed modules, 17 provenance-only modules, real TypeBox and
58558 unchanged source blobs. Forty groups contain 53 successful callbacks and
46 actual fixture HTTP requests. Core compares all 46 exact bodies and complete
portable maps, with declared source-effective typed inputs: source `max_results`
and raw scientific numeric strings become native integer `count`. Source generic
schema20 and host generic schema10 remain an explicit compatibility difference.
The portable comparison omits only the declared reference framing/stamp and timing.
HTTP/parser/config/clock use explicit successful facades; production network,
bounded parser, policy, timers and secret discovery are unexecuted.

A real local-fixture native Worker verifies 20 rich results, two generic results,
cached repeat, raw calls/schema/backend, every subsequent provider wire, Part JSON,
Concord list/get, normal owner close and completed replacement Worker replay with
no additional search HTTP. New Provider6/Core4/Agent1 pass; final fourteen-file
ordinary integration is 65/0 (seed284206), with source Node11/0 including fresh
capture equality. This does not include the unchanged blocked Concord109 native
Unicode scenario, unknown Core matrix/automation_context failures, long deadlines,
UI/live-provider or failure/cancellation/crash recovery. The two partial map rows
do not change any of the 170 whole-reference gates. Full P8/P0–P15 remain open.


### Canonical observed model and explicit Google thinking configuration

Backplane AI protocol 1.10.53 owns `StreamEvent.resolved_model` observation and
Google `Request.settings.thinking_config` encoding. Synapsis EventMapper passes
observations through the existing ordered provider event stream, including
terminal/trailing events. Adapter expands event batches before dispatching each
event, and model observations preserve any held text buffer. ProviderEvents
retains the latest observation in the
authoritative assistant `message.model`; native Conversation commits the complete
message through Runtime.Store. LLMTask.Completion reads observed metadata only
from that committed assistant after terminal cleanup, and callers may supply it
to Result.present. Requested model aliases and provider configuration never
supply observed identity. Without observation the message omits model.

MessageMapper forwards an explicitly resolved Google thinking_config to the
canonical encoder; Completion preserves that explicit option. This does not
interpret reasoning_effort, choose model capability/default/level/budget policy,
or activate the llm-task catalog. Ordinary local Gaoxy fixtures verify the latest
observed model in durable child history, last_provider_result and parent results.
Real-provider behavior and full reference acceptance remain unverified.


### Durable session directory titles, last-message previews and inline history

The selected native `synapsis::sessions_list` descriptor uses revision 3. Optional
`include_derived_titles` and `include_last_message` default to false and add only
`derived_title` and `last_message_preview`. The saved host `title` remains intact;
it does not stand in for OpenClaw label/displayName/subject. Default and explicit
false calls with omitted/zero `message_limit` retain metadata-only behavior,
without transcript snapshots or Node. Optional `message_limit` is a nonnegative
integer, default 0, with no schema maximum; execution caps positive values at 20
as the pinned source does. Positive values add `messages` to every selected row,
including rows beyond the first 100 eligible for title/preview projection.
Agent passes the existing provisioned filesystem Node executable as a trusted
option only when enrichment is requested; Core does not read Agent configuration.

Core SessionDirectory first scans and selects the ordinary metadata page. With
title/preview or history enabled it captures every selected lifecycle once, materializes rows
from captured metadata, reapplies filters without backfill/reorder, and keeps the
original pagination offsets. Only the first 100 originally selected rows receive
transcript probes; a page can retain 200 rows. ReadSnapshot owns fixed-revision
reads: title head 20 and preview tail 20 widen in the needed direction once to
100, on the same handle/revision and original absolute deadline of at most five
seconds. Scan metadata has a 1 MiB aggregate decoded external-size bound;
individual captures and transcript pages each have their own 1 MiB bound. These
bounds do not limit pre-decode allocations or interrupt native work in progress.

An invocation-owned PortSession runs one reusable Node worker for at most two
title/preview projection waves, followed by requested histories on the same
updated broker. History receives rows after title/preview updates. Standalone
`Projection.enrich/4` and `History.read/3` lifetimes are not nested. Empty captured
input skips the helper and validation. The packaged helper contains 178 pinned pure OpenClaw modules
at 488631c18fae7cc541ba8fc8beff6cbb0438787b, exact ipaddr.js 2.5.0 and the reached
47-package Markdown/mdast/GFM/Zod dependency closure plus 13 exact fs-safe declarations. Vendored original sources,
complete npm package trees, licenses, pnpm snapshot identities and file hashes
support offline reproducible builds. Runtime uses static ESM and standard package
resolution, without a reference checkout, TypeScript loader or VM oracle. Helper
title/preview limits are 8 MiB aggregate input and 1 MiB aggregate output;
history transfers have the separate admissions below. The worker heap is 128 MiB.

The pure source adapter applies actual user/display/title selection, Markdown and
UTF-16 rules. Existing EventReply stamps affect only display copies; raw durable
text stays unchanged. DTOs retain authored text and relevant nontext kinds while
omitting ToolResult bodies, tool inputs and image base64. Current provider text
is legitimately unphased; the adapter does not manufacture final-answer, display,
forwarding or delivery-mirror facts, or convert host UUIDs to sourceSessionKey.
Fork/import presentation and provenance omission policies remain unchanged.

Normal success requires a worker-closed receipt and actual Node exit 0 before a
single final ReadSnapshot.validate_many at common revision V for every retained
selected handle, including rows beyond the enrichment limit. Changed lifecycles
are omitted without backfill. No transcript/helper operation follows V. Pure
synchronous fitting then enforces the source-style 65536-byte pretty JSON budget:
strip enrichment from all rows if the first enriched row cannot fit, report
`enrichment_omitted` when fields were removed, otherwise retain the longest prefix
and original first omitted offset with `truncation_reason: "byte-limit"`. If no
metadata row fits, return output_limit. The native content and structured fields
carry the same result; their duplicate transport envelope has a separate 262144
byte bound. Global result limits are unchanged.

`SessionDirectory.list_rendered/3` returns paired exact text and public page;
the map-only `list/3` delegates to that one invocation. Without history, legacy
Jason pretty bytes remain unchanged. Rich fitting assembles only the scalar
outer envelope around the original JavaScript row fragments, retaining number
spellings and nested property order. It never re-encodes rich message trees to
decide the 64 KiB fit or emit model content. Global metadata downgrade removes
messages, derived titles and previews together. The chosen fragments are decoded
only for the structured result, normalizing known host row keys to atoms while
retaining nested message string keys. Native execution consumes the paired text
directly, so content and structured use the same variant and prefix after V.

Local ordinary fixtures cover fixed-revision widening, common validation after
helper exit, independent/default flags, Unicode, raw EventReply preservation,
100-of-120 enrichment, native wrapper accounting and real Worker/model HTTP,
Part/Concord persistence and completed-history projection. Offline rebuilt and
relocated helper execution is also verified. Full Gateway routing/envelope parity, missing
producer phase/display facts, live-provider behavior and failure/cancellation/
crash/security/permission acceptance remain separate and unverified.


### Internal fixed-snapshot full-history candidates

`SessionDirectory.History.read/3` remains an internal standalone boundary;
native directory `message_limit` composes `History.project/4` instead and does
not change public `SessionHistory`.
Selected entries retain their original row, pagination offset and ReadSnapshot
handle. `History.project/4` accepts the existing invocation broker so native
integration composes title/preview and history within one helper
lifetime and one final validation. Standalone nonempty reads close that helper,
observe actual Node exit 0, then validate every original handle once at common V;
changed lifecycles are omitted without backfill. Empty input skips helper and V.
The caller supplies the trusted absolute Node executable explicitly.

The private Reader uses the original owner/R/absolute D. Exact `tail_index`
counts canonical turns and retains `20*N+20+8000+1` newest sparse indexes for
N=1..20; dense one-based ordinals describe rank in this host snapshot. Requested
logical windows resolve those ranks to physical indexes and read chronological
pages of at most 100 values, checking the actual returned indexes. One persisted
host turn remains one source record. DTOs preserve actual roles, UUIDs,
timestamps, tool arguments and version-1 public tool results; a real top-level
tool role maps to `toolResult`, while legacy result-only user turns stay user.
Unsupported projection versions retain legacy content rather than claiming
version-independent public-result equivalence.

The packaged execution calls the complete pinned history page kernel,
response preparation, exact `stripToolMessages` and newest suffix N without
backfill. Its independent limits are source 6 MiB scan, 512 KiB response and
8,000 display characters. Reader logical pages contain at most 401 raw records;
each physical Data page has a 1 MiB external-term bound, and the complete logical
messages must separately fit actual JavaScript `JSON.stringify` at the source
reader's 1 MiB allowance. Otherwise the adapter reports
`history_reader_admission`; source byte-limited prefix/oversized-first reader
parity remains open. No trimmed page, false empty result or synthetic source
placeholder substitutes for reader admission.

Two named host bindings are explicit. Logging uses an invocation-owned
pinned-default/no-mapped-override view with the complete original redaction
algorithms and fresh source registry; it does not discover source disk configs,
includes or JSON5. Genuine EventReply stamps travel as private ordinal sidecars.
Only a projection copy receives the source `openclawDisplayContent` field and,
for real hidden decisions, `display:false`; the complete source projector then
runs before fullness and response budgeting. Raw content, tool activity,
window accounting and stored records retain their actual facts. Source path
algorithms use the actual child environment/cwd/home. The truthy kernel
`storePath` is explicitly `synapsis:history-view:<viewId>`, checked by injected
readers against this target; it is a virtual reader scope, not a filesystem
path, source SessionEntry/key or lifecycle incarnation.

History adds `historyProtocol:1` while preserving outer protocol 1 and legacy
ready/project/result/closed. One target and reader request are active at a time.
History traffic has independent 8 MiB per-logical-transfer admission, 65,536-byte
wire lines including LF, and 32,768-byte raw chunks with acknowledgments and
backpressure. It does not consume legacy title/preview counters or waves. All
work and normal close use original D; the worker heap remains 128 MiB.
Candidates preserve the original entry and add `history_candidate`; they do not
mutate `row.messages` before final validation and fitting. Exact JS pretty row fragments have four-space line
prefixes, no trailing comma/newline and separate enriched/metadata retention
ceilings of 65,536 bytes. Larger fragments return truthful oversize facts after
full computation, with no fake `messages:[]`. Each fragment set's conservative
200-target bound is 12.5 MiB, separately from the other set, parsed terms and
protocol overhead. It is not a whole-process memory bound. Native final fitting
uses the retained fragments as described above; it does no helper/storage work
after common V.

The reproducible Node-only builder retains exact originals, complete package
licenses and hashes. Official Node TypeScript stripping is used except for the
complete upstream constructor with parameter properties, which uses official
transform mode; this compiler lowering is explicit per source. Executable-token
scanning records literal runtime edges while excluding comments/JSDoc and
string/regex/template text, including executable template substitutions. It is
a build-time check of this packaged graph, not a runtime loader or general
JavaScript-parser qualification. Canonical edge ordering makes source/archive
and vendored-original offline builds byte-identical. One obsolete generated
type-only module was removed from both mirrors after the graph stopped using it.

Batch 273 ordinary verification passed five frozen Node cases and six frozen
Core cases, plus eight existing Node and seven existing Core title/preview
regressions. The four early Reader/empty-input cases are included in those six,
not additional coverage. All 1,784 package files matched source/archive and
offline builds; the actual relocated helper performed history between both
legacy waves and closed with observed worker exit and Node exit 0. These tests
do not execute every declaration merely because its bytes were packaged.
Independent SPEC and fresh QUALITY reviews passed. Managed stop/start replaced
the actual BEAM PID after a restart request returned success without replacing
it; old-process exit, root cwd, manager readiness and two health 200/ok responses
were confirmed. Command success alone was not treated as replacement evidence.
Receipts are under
`/tmp/synapsis-session273-history-internal-xpv4hwi_/`. Security/permission and
other explicitly excluded scenarios have not run. The prior unexplained
ordinary 120-row timeout remains unresolved.


Batch 274 native integration has passed 31 distinct ordinary cases: 19 combined
Core history/title/preview/fitting cases, four metadata cases selected by exact
locations, and eight native/Worker/deadline cases. The expired-deadline case in
the metadata file was excluded. The new real Worker test checks revision 3,
combined flags/history, exact next Gaoxy request, Part/Concord round trips, a
second same-Worker turn and normal stop/reopen without repeated execution. The
pure fitter retains an exactly 65,536-byte JS page containing 2,000 finite
fractions and a large numeric argument, plus ordinary prefix and metadata
downgrade cases. Original frozen tests and their two source-grounded observation
corrections are archived: explicit frozen outer-field order in the JS oracle and
source-sanitized tool-result details, with original raw details still asserted
durable. Production required no repair. Independent SPEC and fresh QUALITY
reviews passed without actionable findings; scoped formatting and development
compilation passed. The managed restart replaced BEAM 3866566 with 3873078,
confirmed old-process exit, root cwd, manager readiness and two health 200/ok
responses. The 12 allowed paths contain the complete batch diff; 6,813 protected
paths, HEAD, index, branch, package and strict capability map stayed unchanged.
This closes the bounded integration, not the full alignment Goal. Evidence is under
`/tmp/synapsis-session274-native-history-sbyf38os/`. Full source reader byte-prefix/
oversized-first parity and missing producer facts remain open; excluded checks
have not run.


### Native standalone history windows and pending context

Selected `synapsis::sessions_history` revision 2 calls only
`SessionHistory.read_rendered/3`; legacy Core `read/3` retains its forward cursor
contract and is not a native fallback. The UUID target defaults to the trusted
current session. Default200/max1000, backward dense `offset`, exact durable
`message_id` and independent `pending_before` replace the old native cursor.
The existing MCPSources revision producer delegates this exact native name to
SessionHistory.revision/0, matching its descriptor without a policy bypass.

Data owns `ReadSnapshot.ordinal_window/2` and `read_pending/2` at the original
owner/R/absolute D. Canonical sparse key scans retain bounded selected indexes
and an exact count; the Reader can find an older anchor beyond a retained tail
without building a full transcript or index. Each host turn remains one record.
One existing invocation-owned PortSession runs the pinned source kernel,
preparation, filtering, sanitization, budgets, pagination and JSON output.
Standalone helper candidate text is exact JS pretty JSON; its decoded map must
match the structured page. Worker closed and actual Node exit0 precede exactly
one original-handle validate_many at common V. After V publication is pure.

Pending reads preserve the actual original stored append order. Consumed items
and system events with a genuine event.run_id adoption witness are omitted;
position+1 is assigned before filtering. Eligible newest min(limit,20) items
retain UUID, state, kind and ISO acceptedAt. nextBefore is emitted only when more
remain. Genuine Part.Image fields use the existing portable DTO conversion and
source display projector. Source boundPendingInputs runs before the host kind
extension, followed by actual byte recount. No new producer, custody, event
identity, runtime or persistent service is introduced.

The expanded static package has181 compiled source modules,189 original source
records and882 regions; source/archive and offline1788 files are byte equal.
Independent source factory services/readers are explicitly supplied qualification
boundaries. Normal local tests cover dense/sparse windows, old anchors, pending
adoption and images, EventReply display, actual close/exit-before-V, native
ACK/effect/resultACK, next fixture provider wire, Parts/Concord and fresh Worker
history without repeated effects. Legacy Core and inline directory positives
remain green. One unrelated unchanged display catalog test still expects51
names where the existing baseline has72; it is recorded without modifying the
assertion. Receipts are under `/tmp/synapsis-history291-evidence/`.

Source reader projected-JSON admission is still distinct from raw event bytes.
Data1MiB decoded terms, source logical-reader1MiB/scan6MiB/response512KiB,
source display8000 and sanitize4000 UTF16 units, transcript+pending80KiB,
Port wire65536/chunk32768/logical8MiB, public text262144 and native envelope1MiB
remain independent limits. These do not bound pre-decode allocation or prove
failure/cancellation/security/permission behavior. Existing Backplane/AiProtocol
policies remain enforced. Full Gateway identity/factory/assembly, source producer,
raw event/tree/archive and live-provider qualification remain open.


### Raw event byte windows remain distinct from projected-message bytes

The pinned active-reader selector charges the UTF-8 length of each original
`eventJson` plus one newline. `resolveSessionActorMemoryHistoryStart` walks
backward, retaining the newest contiguous suffix in ascending order and stopping
at the first older row that cannot fit. Its first indivisible event may exceed
the request's soft byte limit when allowed, while the independent source page
hard limit is 8 MiB. Recent reads allow that first event implicitly; later tail
pages request it explicitly. Fewer rows than `maxMessages` is a valid byte-window
result. This differs from the current host's full-window admission measured by
`JSON.stringify(mappedMessages)`. That admission remains unchanged.

The original producer preserves caller `messageJson` spelling and the complete
event envelope, including its real parent/lineage. Current Concord turns and the
host DTO do not supply that original event JSON or source tree. In particular,
projection-added `__openclaw.seq` must not be charged as original raw-event data.
Re-serializing a guessed envelope cannot prove original stored-byte parity. A
new write/import representation contract is pending a user decision; no default
parent or historical source event is invented. Data external-term bytes, raw
event JSON plus LF, projected message-array JSON and protocol wire bytes remain
four separate units.

Independent reference qualification now executes the complete pinned navigation
and source-pages modules through official Node 24.21.0 TypeScript stripping. Six
explicit unused import facades throw if invoked; all eight successful authored
raw-event vectors leave their call log empty. Five frozen positive tests verify
the original modules, precise JSON spelling/UTF-8-plus-LF costs, inclusive byte
boundaries, contiguous suffixes, message bounds, eligible subwindows and the
indivisible first event above the soft request. The 8 MiB source constant comes
from the evaluated source-pages module; the 1 MiB caller constant has exact
declaration-byte proof without executing the tail caller. The fixture retains
full LICENSE, source Git blobs, whole-module transforms and runtime provenance.
Two independent captures produced identical 38,314-byte fixture bytes. See
`scripts/openclaw/capture-session-reader-window.mjs`, its functional test and
`apps/synapsis_agent/test/fixtures/openclaw/488631c/session-reader-window.json`.
These authored events do not qualify the producer, actor, SQL, reset-archive,
recent/page normalizers, full caller or native reader. Production behavior is
unchanged. Source and scope receipts are in
`/tmp/synapsis-session275-reader-contract-aknz0asm/`.


### Public Diffs delivery boundary (batch359)

The optional, explicitly selected native `synapsis::diffs` tool is direct-model-only.
`Synapsis.Diffs.Config` resolves the singleton `diffs.toml`; SessionAdapter freezes
its resolved fingerprint for native admission. One registered PortSession serves
an invocation. In `both`, acknowledged viewer publication precedes file reservation
and rendering, using the same normalized input, options and deadline. The existing
renderer/capsule is reused without dependency changes.

Data owns durable artifact registrations, expiry and cleanup state; Workspace owns
bounded hash-checked gzip HTML/PNG/PDF bytes. Agent DiffsDelivery joins the owners,
records immutable file-delivery facts and original roots, and DiffsCleanup removes
expired registered artifacts and later orphans. Live registrations govern current
availability independently of historical facts. Server owns viewer/assets/download
GET and HEAD routes; Web projects viewer/download links into the existing React
chat renderer. Endpoint origin composition stays in runtime config, outside Agent.
Native invocation IDs retain their actual prefixed string form; session/agent and
public delivery IDs remain UUIDs. Timeouts/uncertain fact writes remain unknown
outcomes; only a known quota rejection permits cleanup then the same metadata
completion retry, with no rendering or byte/fact replay.

Ordinary local acceptance and exact evidence are documented in the alignment plan
and `/tmp/synapsis-diffs359-evidence/summary.json`. This implements public delivery,
not full source-factory equivalence. Pinned OpenClaw488631c partial patches with
`expandUnchanged=true` remain blocked by Pierre1.5.2's missing `loadDiffFiles` path;
explicit false and before/after inputs are separate accepted paths. Security,
permissions and the established excluded failure/budget/lifecycle families remain
unqualified; no dependency workaround or automatic tool grant is introduced.

### Suggested-task local launch boundary (batch360)

`Synapsis.TaskSuggestions` retains process-local proposals and launch receipts.
Model-facing suggest/dismiss still only change the proposal registry. The trusted
operator's `Start in this folder` action allocates a destination and claim before
one registry-owned supervised task uses `Sessions.create_suggested_session` and
`Worker.start_suggested_turn`. There is no second executor, Goal activation,
automatic worktree creation or copied source transcript/configuration.

Sessions captures the source's saved provider/model identity once at acceptance,
uses the proposal Agent/title/cwd, and initializes fresh metadata plus the ordinary
permission value in one public conditional Concord transaction. Data owns those
keys. Version-one `creation_context` retains task/source/cwd, and normal Worker
configuration reapplies its cwd across refresh and reopening. The existing Boot
normalization also governs the fresh-launch handshake's cwd comparison.

The first input is a user message containing the documented local-folder
instruction and proposal prompt. Worker waits for normal boot and reserves the
existing idle boundary. `runtime_started` only associates the run: acceptance
requires the actual epoch/run-matched native `prompt_consumed` emitted after its
checkpoint. The retained receipt contains native run/turn/message IDs and the
separate host input ID. Existing Runtime, SessionAdapter and Conversation still
own preparation, provider execution and durable turn projection.

Accepting/accepted/unknown rows retain their reserved destination. Successful
accepted replay returns its receipt without resubmission; browser remount reads
host lifecycle rows. Only accepted shows `Open session`, and the source stays
mounted until explicit navigation. Unknown never grants automatic retry or broad
rollback. A known pre-effect rejection may return the proposal to pending;
dispatched ambiguity preserves its association. Registry restart loses proposals
and receipts, while normally persisted session turns remain.

Concord3.1.13 supplies the public finite transaction API used here; historical107
no longer blocks this local slice. A finite timeout does not prove hard rollback
or absence of late effects. Cloud/worktree/current-source launch, full recovery
and complete pinned factory/assembly equivalence remain unfinished. Ordinary
native/Concord/reopen and real Chromium fixture evidence lives in the alignment
plan and `/tmp/synapsis-suggestions360-evidence/summary.json`. Security/permission
and the established excluded test families remain unqualified.
