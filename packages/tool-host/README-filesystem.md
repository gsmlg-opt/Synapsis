# Filesystem preparation packages

## Connected native factory

The Session Worker and its managed children now construct exactly four
revision-one tools: `synapsis::read`, `synapsis::write`, `synapsis::edit`, and
`synapsis::ls`, with pinned OpenClaw `488631c` input schemas/descriptions and
source `{content, details}` results. Read uses one-based lines and UTF16 cursors;
edit targets one original snapshot; ls uses filename cursors. Source output
schemas describe details, not the complete native envelope. The old nine model
descriptors and Builtin registrations are retired; internal Local/ToolFiles
actions retain their existing domain contracts below. No aliases or
historical-data conversion are needed.

Set `SYNAPSIS_FILESYSTEM_NODE` to an absolute executable before startup;
`config/runtime.exs` supplies `:synapsis_agent, :filesystem_node`. There is no
PATH/temp fallback or reuse of Browser/PDF settings. Only canonical selection
triggers SessionAdapter capture of project cwd, OS home/platform, one canonical
absolute WorkspaceDocuments root, the existing ledger fetch closure and trusted
execution options. Profiles passes these unchanged. All preparation callbacks
remain in host context; only fetch also supplies the descriptor's target reader.
These authorities never come from model arguments or provider parameters.
Original model arguments remain in history; prepared arguments enter committed
execution intents. Existing Policy/Freshness/permission and domain owners remain.

Known selected models use ModelRegistry `supports_images`; unknown models omit
vision. Resizing retains source true. Positive finite
`context.agent.model_context_window` supplies source budgets:
`maxChars = min(floor(context * 0.3) * 4, hardCap)`, with hard caps 16000, 32000
from 100000 floored tokens and 64000 from 200000;
`maxContextChars = max(1024, floor(max(1, floor(context)) * 2 * 0.5))`.
Absent context leaves the budget unspecified. Global limits are unchanged.

The frozen ordinary reference receipts were captured on Node24.22.1/Linux x64.
The locked devenv separately supplies Node24.21.0 through the absolute
`SYNAPSIS_FILESYSTEM_NODE` store path, leaving asset-build Node22 unchanged.
Its ten source plans and actual Worker local/Workspace text read/write/edit/ls
checks pass against the existing artifacts. This qualifies that concrete runtime
for those ordinary cases; an absolute setting or the `>=22` engine floor alone
does not qualify another runtime. OTP packaging now copies an explicit official
Node distribution into each release version, and Docker uses the same step with
a fixed Node24.22.1 source stage. Execution evidence for each resulting artifact
is recorded separately in the alignment plan. Default/Daemon/Swarm and Workflow Effect/Journal evidence is scoped
separately in the alignment plan. Full-image
allowance and Code Mode full nested transport remain blocked by
`gsmlg-opt/backplane#153`; this activation adds no allocation increase or
image-dropping workaround. Ordinary factory/Worker text checks require separate
execution evidence and do not establish full-family/platform/release acceptance.

The byte-read prerequisite uses a separate self-contained artifact alongside the
existing edit/write planner. Build it with the qualified Node after installing
the workspace's frozen dependencies:

```sh
/absolute/path/to/qualified/node scripts/build-filesystem-read.mjs
/absolute/path/to/qualified/node scripts/build-filesystem-read.mjs --output /absolute/path/to/artifact
```

The default output is `apps/synapsis_core/priv/filesystem_read`. The builder
verifies the seven unchanged OpenClaw originals and license listed in
`src/filesystem/read_vendor/provenance.json`, strips the complete TypeScript
modules, and rewrites only the explicit source import graph. The image-ops alias
points to the narrow host codec adapter. The full original detector, attachment
classifier/MIME utilities and processImage algorithm remain the source owners.
`read_vendor/dependencies.json` freezes 12 packages and 108 package files,
including Rastermill 0.4.0, Photon 0.3.4 and file-type 22.1.1 with its selected
closure. The builder checks the original package-lock hash, exact lock rows,
manifests, package file lists, individual file hashes and byte counts. Generated
provenance records those pins, original/generated source hashes, host hashes and
aliases. Builds retain original package manifests, licenses and Photon WASM in
artifact-local `node_modules`; they do not need the root npm tree at runtime.
`--output` builds the same artifact bytes outside the checkout. Existing unrelated
output entries block the build; the builder never removes an output directory.

The new artifact copies the existing filesystem stdio controller byte for byte,
using `read_worker.mjs` as its worker. Its parsing, classification and real WASM
processing run off the controller thread, with the same live stdin ownership
channel, 5000ms bound, frame limits, worker-exit check and normal stdout/process
retirement. The original planner sources, build script and generated artifact
remain separate. No second execution broker, target-path opener, persistent
worker, network request or provider call is introduced.

`read_content.mjs` exports async `prepareReadContent(request)`. A request has
exactly `protocol: 1`, a string `id`, `operation: "read_content"`, and `input` with
canonical base64 `bytes`, boolean `autoResizeImages`, `decodeMode: "local" | "utf8"`,
and optional boolean `modelHasVision`/trusted string `windowsEncoding`. Its
envelope carries the ID, source commit, exact `codecVersions`, actual runtime
identity and either `{kind:"text",text}` or `{kind:"result",result:{content,details}}`.
The helper receives no filename hint. Byte-detected PDF/Office documents produce
the source advisory text; other non-image classes use the read decoder. On Linux,
local decoding recognizes UTF16LE/BE BOMs first, otherwise uses Buffer UTF8
replacement decoding. Explicit utf8 mode uses Buffer UTF8 directly. The helper
leaves UTF8 BOM and CRLF normalization to TextRead.

Supported image bytes pass through the full source processImage. Small probed
JPEG/PNG/GIF/WebP retain exact bytes; BMP converts to PNG even when resize is
disabled. Default resize uses the source 2000px displayed axes, 4.5MiB **base64**
ceiling and quality/compression search. Internal Rastermill has explicit 25M input
and output pixel caps. The explicit header-gated BMP fallback uses Photon WASM,
copies returned PNG bytes and frees its image in `finally`. Only exact-false
vision omits the successfully prepared image, after processing, and yields source
text details. Image blocks retain `type/data/mimeType`; details contain the final
first text and image MIME only when an image is attached.

`Synapsis.Filesystem.ReadContent.prepare/3` accepts immutable bytes, TextRead page
arguments and trusted options: required absolute `:node_executable`, optional
absolute `:helper_path`, `:observer_pid`, original absolute `:deadline`, TextRead's
`:prefix/:max_bytes/:model_budget`, `:model_has_vision`, `:auto_resize_images`,
`:decode_mode` and `:windows_encoding`. Planner.PortSession admits this operation
with its own exact codec envelope/result validators, preserving the existing
edit/write diff envelope. ReadContent requires actual helper exit0, released Port
and normal broker DOWN before rendering. Decoded text goes to TextRead exactly
once. The new trusted `:source_bytes` TextRead option preserves original captured
length only for its empty/no-readable-text notice; other paging arithmetic is
unchanged. Caller prefixes are already complete and are added verbatim. Rich
image/document details include that final prefixed text; normal text page details
retain only selected file content.

`Local.read_file(root,path,args,opts)` captures bytes with standalone guarded
read_binary, waits for its capture worker/guardian retirement, then prepares those
bytes with the same upfront deadline. It accepts no outer lease. Optional present
files have unchanged success details; only source acquisition absence has the
source optional-missing result. FileDocuments.read_file strips the logical leading
slash and calls this owner directly. WorkspaceDocuments.read_file and
Workspace.read_file pass a single trusted pinned root, without sidecar reads,
metadata writes or publication. ToolFiles.read_file pins that root before existing
read authorization, prefers immutable domain projections, and pages projection
text directly instead of classifying a colliding physical file.

`Local.prepare_target(root, source_path, operation, path_environment, opts)` is
the metadata-only target selector for the native preparation hook. It accepts
`:read/:write/:edit/:ls`, captured `:cwd/:os_home/:platform`, and an optional
original selection `:deadline`. The caller supplies a path after lexical XML and
Office repair; `Arguments.prepare_edit/1` and `normalize_path/1` remain separate
pure operations. Local preserves existing literal relative `@` names, consumes
one reference prefix, interprets file URLs and captured home/cwd, and keeps source
display spelling separate from requested and selected absolute paths. Reads
prefer the exact file, then check the source's finite basename-only space, quote,
NFC/NFD and screenshot variants. A sole variant carries the exact resolved-name
prefix for the later read renderer; mutations and directory selection do not
perform this fallback.

Selection reuses the existing bounded guardian and Access owner. After reserving
and checking the root, it acquires one finite lexical superset for possible
literal/reference interpretations, the literal top ancestor and read variants.
Unused lock-only names are not resolved or probed; every actual probe is guarded
and checked against held keys. The ancestor key can conservatively serialize its
descendants during selection. The API captures no bytes, lists no directory,
starts no helper and returns no lease, descriptor, inode or content. Normal
selection retirement precedes its return. Later execution must use the selected
resource with its own existing guarded capture; continuous source queue ownership
across approval and concurrent rename equivalence remain unqualified.

ToolFiles source `read_file/write_text/edit_text/list_directory` accept a trusted
optional final root while preserving their existing default arities. The same
root passes through canonical argument authorization and the Workspace domain
scope. `Workspace.text_files` and `with_directory_entries` also accept that final
root; projection-first reading continues for the same logical URI at execution.
Write/edit preserve a trusted `:display_path` through FileDocuments into the real
planner, retaining the logical path as default. Model arguments cannot supply a
root. SessionAdapter and Filesystem own the invocation record, native hook and
model catalog; these domain APIs do not install them.

NFC/NFD currently uses `String.normalize/2` and OTP Unicode tables. The ordinary
common-character cases qualify the selected test host, not arbitrary Unicode
version equivalence with the pinned Node runtime. POSIX URL cases likewise do not
establish complete WHATWG or Windows file-URL equivalence. Linux-host tests of the
captured Darwin variant policy do not qualify a real macOS filesystem.

Actual Windows system-codepage resolution and native-only external codec fallback
remain mandatory prerequisites before full cross-platform qualification. A missing
trusted Windows encoding has an explicit unresolved branch; no locale or console
codepage is invented. Native-required variants are not silently routed to external child
processes. The new ordinary suites are `filesystem/read_content_functional_test.exs`,
`workspace/read_file_functional_test.exs` and
`packages/tool-host/test/filesystem-read-functional.test.mjs`; they use the exact
qualified Node described below. Exceptional, security, permission, cancellation,
failure, budget and real-provider branches are source-reviewed only. This package
does not by itself qualify connected Worker/Part/Concord replay, cross-OS or
installed-release acceptance.

## Existing edit/write planner

This is the pure planning prerequisite for the filesystem replacement. It runs
the complete OpenClaw `prepareFileEdit` and `prepareFileWriteDiff` implementations
from commit `488631c18fae7cc541ba8fc8beff6cbb0438787b`. The caller supplies decoded
text; `path` is only a receipt label. The helper never acquires or changes target
files. A plan is not a successful filesystem effect receipt.

From the repository root, after installing the workspace's locked dependencies:

```sh
node scripts/build-filesystem-planner.mjs
```

The builder resolves exactly `diff@9.0.0` from the tool-host package, validates its
manifest, ESM entry, license, complete 136-file list and individual SHA-256 hashes,
and packages it under `vendor/diff`. An existing unpacked original npm package can
be supplied explicitly, without installing or fetching anything:

```sh
node scripts/build-filesystem-planner.mjs --diff-root /absolute/path/to/diff-package
node scripts/build-filesystem-planner.mjs --diff-root /absolute/path/to/diff-package --diff-archive /absolute/path/to/diff-9.0.0.tgz --output /absolute/path/to/artifact
```

When an archive is supplied, or the pinned archive sits beside `--diff-root`, the
builder additionally verifies its SHA-256, byte count and original pnpm-lock
SHA-512 integrity. Installed package builds validate the full unpacked payload;
they do not claim to have observed an archive. These two forms produce identical
artifact bytes from identical source and dependency bytes. The builder writes
only its planned artifact files and refuses unrelated existing output entries.
It never deletes an output tree.

The default output is `apps/synapsis_core/priv/filesystem_planner`. It contains
three host modules, 23 generated whole modules, the complete real diff package,
both licenses and provenance. It can be copied intact and launched outside the
checkout without `node_modules`. Generated imports refer to the real
`vendor/diff/libesm/index.js`, retaining its original `type: module` manifests.
No TypeScript loader, VM loader, fixture, `/tmp` checkout or network is needed at
build time after vendoring, or at runtime.

`src/filesystem/vendor/openclaw` retains the 23 exact original TypeScript files
and full MIT license. The adjacent `vendor/provenance.json` pins their hashes,
original aliases/config evidence, fixture hash and the diff archive/file hashes.
The builder uses `node:module.stripTypeScriptTypes` in strip mode on complete
files, preserving every barrel export, and rewrites only static import/export
specifiers checked against the explicit pinned graph. Artifact `provenance.json`
records original/generated hashes, host hashes, import mappings, dependency
identity and all other artifact file hashes; it excludes its own hash, timestamps
and the build runtime's patch version. Transformation schema version 1 identifies
the build recipe. OpenClaw is MIT; diff's complete BSD-3-Clause license is included
separately. No source algorithm, normalization shim or diff substitute is used.

`planner.mjs` exports synchronous `planFilesystem({protocol: 1, id, operation,
input})`, where operation is `edit` or `write_diff`. It validates the request and
the original functions' input types, preserves input and source result fields,
and represents an undefined source result as JSON `null`. The envelope includes
the correlation ID, source commit, diff version, and actual Node/V8/Unicode/ICU/
CLDR/platform/architecture. Exact/normalized edit no-ops retain their original
messages and absent receipt fields.

`stdio.mjs` accepts one JSON request terminated by LF. Keep stdin open throughout
the operation: it remains the live ownership channel. One worker thread parses
the transferred request, runs the synchronous planner and serializes a transferred
response. The controller emits one JSON+LF only after matching the worker's local
correlation and observing its exit0, then waits for stdout flush, destroys stdin
and exits naturally with code0. There is no daemon, executor or persistent cache.
Only the fixed `cancel\n` frame is accepted after the request. EOF/stream error,
invalid protocol, worker error/nonzero exit and timeout terminate the helper with
a fixed generic diagnostic; input text and exception details never become stderr.
These exceptional paths require source review; they are not runtime qualified by
the ordinary functional suite.

The trusted launcher may supply `--timeout-ms=N` for an integer from 1 through
5000; default 5000 covers framing, startup, computation, serialization and output
flush. The model has no CLI/configuration authority. The controller remains live
during worker computation. Request framing is capped at 256 MiB and response
framing at 512 MiB, finite generous transport allowances for JSON escaping of
source/replacement text at Local's 10 MiB input scale. They do not alter the
original source's smaller write-diff computation limits. The worker's serialized
frame is checked before transfer; these bounds do not claim to bound every
temporary allocation inside the original synchronous algorithms. Terminating the
helper retires its worker thread; this pure helper owns no child OS process or
target file handle. The Local broker independently observes OS exit and Port
release before effects.

The frozen ordinary receipts were captured using Node 24.22.1, V8
13.6.233.17-node.58, Unicode 17.0, ICU 78.3 and CLDR 48.0 on Linux x64. Qualify
the artifact with an independently checked concrete Node build. The locked
devenv's separate filesystem Node24.21.0 (V8 13.6.233.17-node.53, Unicode17.0,
ICU78.3, CLDR48.0, Linux x64) has ordinary source-plan and Worker text execution
evidence. It executes the existing artifacts; they were not rebuilt for this
qualification. The workspace engine floor `>=22` and asset/release Node22 do not
establish equivalent Unicode segmentation or general receipt parity; Node22 is
unqualified for this slice. Build outputs depend on the actual type-stripper
implementation, so use the same concrete Node build when checking reproducibility.

Run the dedicated devenv qualification without an external Node override:

```sh
devenv shell --no-tui -- mix test apps/synapsis_core/test/synapsis/filesystem/provisioned_node_functional_test.exs apps/synapsis_agent/test/synapsis/session/native_filesystem_factory_functional_test.exs
```

The dedicated test fixes that exact runtime identity and ten unchanged source
plans. A future nixpkgs lock update requires new qualification evidence; it does
not silently inherit this result. Flake and other OS/architectures remain separate
provisioning and execution work.

Release builds require `SYNAPSIS_FILESYSTEM_RUNTIME_ROOT`, the absolute root of
a trusted official Node24.22.1 distribution containing `bin/node` and `LICENSE`.
The existing Mix assembly step is followed by a build-only copy into
`releases/<version>/filesystem-node/`, before the normal tar step. The release
environment selects that version's bundled absolute path when
`SYNAPSIS_FILESYSTEM_NODE` is unset; an explicit operator setting is preserved.
Moving an extracted release keeps the selection relative to its actual root.
The helper artifacts and application runtime owners remain unchanged. Docker's
context explicitly retains both complete helper trees, including internal npm
dependencies and licenses. Packaging a runtime does not qualify every caller,
codec or platform; actual archive/image checks have their own evidence.

Docker's build stage imports the fixed official Rust1.95.0 toolchain and the
CMake, pkg-config and libclang prerequisites used by the existing Turso native
dependencies. `VIZE_EX_BUILD=1` selects Vize's supported source build for the
Bookworm build environment; the global native mode stays unspecified and other
native packages retain their normal selectors. Compiler tooling remains confined
to the build stage, and version-bound Node packaging is unchanged. Vize is a build-only dependency in production, so its CSS smoke check
runs in the build-stage image; the final image is checked for its packaged file
runtime and ordinary application health. The final Linux image also supplies
`inotify-tools` for the existing config watcher. An isolated ordinary check waits
for a real filesystem event, then verifies automatic Store reload after a TOML
edit and normal watcher exit. Image execution evidence remains separate from
source configuration and does not qualify every installed Worker or platform.

`Synapsis.Filesystem.Planner.PortSession` now owns a dormant Elixir broker for
one packaged helper. `Synapsis.Filesystem.Local.edit_text/4` and `write_text/4`
accept a trusted explicit `:node_executable`, an optional `:helper_path` (default
the application's packaged priv entry), `:observer_pid`, and an absolute
`:deadline`. Trusted nested domain calls can also pass the opaque `:lease` from
`Local.with_paths/4`. The existing Local guardian registers and monitors the dormant
broker before ACK permits Node startup. One operation deadline of at most five
seconds covers source acquisition, framing, helper work and file effects. Normal
success requires the helper's actual exit0, BEAM Port release, normal broker
retirement, and eventual worker/guardian retirement. Broker status retains the
closed actual Port handle and process lifecycle facts without request/result text.

Edit reads one guarded immutable UTF-8 snapshot, calls the original planner once,
and preserves the exact source no-op or changed receipt. Write compares actual
original bytes, preserves the source's small identical-content no-op, and uses
the real create/overwrite diff plan where eligible. Source-suppressed diffs stay
absent. The exact success envelope is checked against Local's existing result
budget before mutation. Changed writes, including surviving internal writers,
recheck the original snapshot, persist, check regular-file size, and reread exact
binary bytes before success. Legacy internal no-op and zero-based paging schemas
remain intact. These are real domain effects; the connected canonical factory
uses them as described above, with remaining consumer boundaries kept separate.

`Synapsis.Filesystem.Access` is the shared node-local path coordinator. A Local
worker reserves its admission before resolving physical identities, then acquires
the complete sorted unique key set. Earlier unresolved reservations preserve
admission order; known intersecting waiting/held sets prevent overtaking while
disjoint sets can run concurrently. Keys use canonical absolute paths, including
missing suffixes for creation, rather than inode, logical URI or session ID.
Directory keys intersect descendants by path component. Move acquires source and
destination together; internal multi-edit acquires every target together.

`Local.with_paths(root, paths, opts, callback)` runs a trusted domain callback under
one existing bounded guardian/worker. The callback receives keyword options with
its opaque `:lease` and original absolute `:deadline`; pass those options explicitly
to nested Local calls. Each nested call validates the actual worker, guardian,
deadline and exact declared key subset against the original coordinator instance,
then repeats guarded path resolution. It runs on the same worker without another
guardian, reacquisition or a new timeout. A declared directory does not implicitly
authorize explicit nested child calls; list every needed file key. A directory
scan itself retains its guarded private descendant reads. Pure materialized page,
search and enumeration helpers keep their separate domain/budget roles.

The Workspace integration primitives use that same boundary. `Local.check_scope/1`
checks an explicitly supplied lease and its original deadline before a trusted
domain publishes; it does not acquire or inherit a scope. `write_binary/4` retains
opaque bytes and the internal path/status/bytes result, including an equal-byte
physical no-op. A later raw document metadata update can still increment its own
version. Source edit/write accept a trusted `:display_path` for planner labels,
messages and receipts while resolution, effects and progress retain the actual
physical target. This prepares logical Workspace receipts without rewriting a
planner's generated patch.

`Local.directory_snapshot/4` captures bounded directory metadata and explicitly
selected binary files under one directory lease. Its selection map accepts
`:pattern` (default `"**/*"`), entry-only `:exclude` prefixes, and independent
`:read_patterns`; excluding metadata from document entries does not prevent an
explicit sidecar read. Results contain sorted root-relative `entries` and a
`files` map of selected bytes. Private guarded traversal/reads stay inside Local;
callers receive no child reader capability. The standard OTP wildcard matcher
uses immutable captured metadata, with Path.wildcard's default dot-name behavior,
and performs no second filesystem scan. Explicit literal hidden prefixes can
select sidecars without traversing unrelated hidden trees such as `.git`.
Prefix capture uses the same OTP wildcard compiler, including valid literal
brackets. Its exported compiler representation is isolated in SnapshotMatcher;
unsupported shapes return an explicit error and require qualification when OTP
changes.
The operation retains the original deadline and heap boundary, counts up to
4,096 visited entries, and reads at most 10 MiB of selected bytes in aggregate.
It has no legacy index depth-ten cap. Errors remain explicit rather than an empty
or truncated successful snapshot.

Direct source listings have a separate owner path. `DirectoryList.page/3` is a
pure Elixir port of pinned OpenClaw `ls.ts`; it does not use the Node planner.
It accepts immutable `%{name: name, is_directory: boolean}` entries, optional
`after` and numeric `limit` arguments, and a trusted `:model_budget` option.
Default count is 500; finite numeric limits are floored and clamped to at least
one. Raw names and cursors compare by UTF-16 code units, including supplementary
Unicode scalars. Each complete name is JSON-quoted with `/` appended only for an
actual directory. A narrow raw-string encoder preserves JSON.stringify's
lowercase control hex escapes and short escapes while retaining literal
backslash sequences and Unicode/name case. The same encoder quotes the raw
continuation cursor. The source text/details envelope omits `nextAfter` on complete
pages and uses the last visible raw name on continuation pages. Empty selections
return `(empty directory)`. No count, path array or legacy offset is added.

Both complete entry candidates and output with its continuation footer must fit
51,200 UTF-8 bytes and `TextBudget.fits?/2`. Footer fitting removes complete
entries and recomputes the cursor; names and footers are never sliced. An entry
that cannot fit returns the existing domain `{:error, :output_limit}`. Upstream's
exact exception text is `A directory entry cannot fit within the listing output budget.`
Projecting that exception into the native model error contract remains pending.
These model/byte-budget branches are source-reviewed only.

`Local.directory_entries/3` captures direct names, including dotnames, using one
bounded `File.ls` and child `File.lstat` calls. It never recurses or reads child
content. Only actual directories receive the directory flag; linked names remain
listed without resolving, following or opening their targets. Requested directory
ancestry still passes the existing guarded path validation. Capture checks the
original operation around I/O and verifies directory identity afterward, retains
the existing 4,096 scanned-entry ceiling, and propagates tagged operational errors.
Only absence during initial requested-directory resolution/stat remains
`:not_found`. After that directory has been confirmed, disappearance during
listing, child capture or final path/stat revalidation is `:conflict`; it cannot
be reclassified as a projection-only directory. These capture-conflict branches
are source-reviewed only, without retrying or skipping entries.
`Local.list_directory/4` validates source arguments and trusted options before
capture, then pages inside the same original lease, guardian, worker and deadline.
The recursive wildcard snapshot API and retained legacy actions stay separate.

`FileDocuments.with_directory_entries/4` holds only the directory key, without
metadata-sidecar acquisition or content reads. Its arity-two callback receives the
tagged raw capture and validated original I/O keyword options. The corresponding
`WorkspaceDocuments.with_directory_entries/3` and
`Workspace.with_directory_entries/3` callbacks receive that result and explicit
`%{root: pinned_root, io: original_io}`. Nested calls retain the captured root and
original scope. `ToolFiles.list_directory/3` uses this actual Workspace owner
chain to merge direct physical names and current domain projections before one
source pagination. Projected logical paths win collisions, exact projections are
files, and existing read permissions filter entries. A missing physical directory
is a virtual directory only when visible projected descendants exist; other
physical errors remain errors. Omitted or empty source paths use the existing
session, agent or shared logical cwd. Listing does not persist metadata, increment
versions, or publish events. The connected canonical factory now uses these
internal owners. Linked-path, error, permission,
cancellation, expiry, cleanup and budget behavior remain source-reviewed only.

Workspace owns the content/sidecar/publication integration. Its trusted
`FileDocuments.with_paths/4` derives the complete content paths and actual
sidecar paths before entering Local. `WorkspaceDocuments.with_paths/3` pins one
root and passes `%{root: root, io: lease_and_deadline}` explicitly through store
and Resources calls. Business attributes and model arguments never carry this
scope. Nested calls keep the same worker, guardian and deadline; they neither
adopt ambient scope nor expand the declared key set.

Raw CRUD uses guarded binary I/O and retains its permissive JSON metadata
decoder, DateTime fields, atom/string attribute precedence and pretty sidecars.
Raw equal-byte puts still increment metadata versions. Metadata-only lists use
one directory snapshot with independent sidecar selectors, so the decoder reads
captured bytes rather than reopening each child under a root-only lease.
`list_result/3` returns tagged operational errors; the legacy list-only wrapper
raises on an operational error instead of reporting an empty successful list.

The internal `ToolFiles.read_text/3`, `write_text/3` and `edit_text/3` entrypoints
prepare the approved source-tool replacement without registering parallel model
tools. They preserve logical role/path and projection rules. Projected reads page
an immutable domain snapshot through TextRead; ordinary text operations use
Workspace and the real Local planner. Source `changed: false` leaves sidecar
bytes, version, timestamps and events untouched. Changed results retain exact
source envelopes and logical diff/patch labels; metadata stays outside receipts.
Recognized uncertain source outcomes project physical content/sidecar evidence
into the requested logical document after each enclosing scope returns. This
pure projection preserves reason and retirement flags, reports unconfirmed
metadata conservatively, and never acquires paths, publishes or repeats work.
It also covers explicit nested operation evidence in a publication error;
it does not recursively rewrite user content or define the future model error
catalog. These exceptional branches are source-reviewed only.

Workspace CRUD and source/retained internal file operations hold their complete
content and sidecar set through metadata persistence and each publication.
Public CRUD normalizes accepted repeated/trailing slash aliases before deriving
the outer keys, matching Resources' storage paths while retaining existing
caller event spellings.
Resources rereads current storage inside the scope before read-modify-write.
ID mutations discover a candidate first, then reread and revalidate its ID under
the exact pair; an exact-file lease does not grant a root ID scan. Handoffs keeps
its original mail-first guardian and deadline, then holds the generated artifact
pair through Workspace, mailbox, session and global publications. Each publication
checks the original scope; Handoff also checks its original owner and deadline.

This preserves existing compatibility limits: slash-to-`__` metadata aliases
share the actual sidecar and may reuse its stored ID; Resources/Workspace move
copies to the destination while retaining the source, whereas the retained
internal file move removes its source. The existing raw sidecar codec omits
`blob_ref`, so large-blob durable reload remains a separate limitation. Content
and sidecars remain separate writes, with no rollback, outbox or filesystem
transaction claim. Projection, mail and blob stores retain their own owners.

Guardian progress uses one stable outer-scope label for each canonical physical
key, so different nested roots cannot collapse distinct files or duplicate one
file's evidence. Per-call normal results retain their own relative paths. Later
no-ops do not erase confirmed changes, and a later update to a file created within
the scope retains its creation status and latest changed byte count. Initial
fallback evidence is budgeted before guardian startup; the complete canonical
declared set reserves its worst-case progress/uncertainty envelope against the
existing output budget before the callback can mutate anything. Nested exact
subsets cannot grow that envelope. These cumulative uncertainty/accounting
branches are source-reviewed only; ordinary success checks do not qualify them.

The coordinator only owns admission metadata and monitors; Local still performs
all target I/O and pure planner invocation. Only actual guardian DOWN releases
the lease, even after normal worker exit. Coordination covers cooperating Local
callers on this BEAM node; it supplies no OS lock or external-writer/other-node
guarantee. Workspace uses the callback boundary to retain content and sidecar
keys through metadata persistence and publication.

Owner/caller loss, deadlines and exceptional cleanup are source-reviewed only.
There is an explicit two-second cleanup grace. If actual child retirement remains
unobserved, the caller receives an unknown outcome with `cleanup_confirmed: false`
and `retirement_confirmed: false`; the same guardian retains its links/monitors
until actual DOWN, discards late results and starts no new work. Returning this
uncertainty does not release operation ownership. The shared path lease follows
that guardian's actual retirement, including this branch. Ordinary success
continues to await actual retirement rather than returning through this branch.
The ordinary suite observes helper OS exit, actual Port release and broker DOWN;
it does not qualify exceptional cleanup or instrument separate guardian/worker
exit events. Access is a temporary supervised child: coordinator loss stops new
admissions rather than automatically restarting with empty state while old effects
may survive. Each Local guardian monitors its exact coordinator instance and uses
the existing cleanup path on loss; recovery requires an explicit service restart.
This loss/recovery boundary is source-reviewed only. Separate ordinary Access
actors verify normal worker exit retains ownership until the guardian exits.

The older scoped ordinary checks require the exact qualified Node24.22.1
described above. Set it inside the devenv shell to override the managed runtime:

```sh
devenv shell --no-tui -- env SYNAPSIS_FILESYSTEM_NODE=/absolute/path/to/qualified/node mix test apps/synapsis_core/test/synapsis/filesystem/snapshot_literal_functional_test.exs apps/synapsis_core/test/synapsis/filesystem/workspace_primitives_functional_test.exs apps/synapsis_core/test/synapsis/filesystem/access_functional_test.exs apps/synapsis_core/test/synapsis/filesystem/planner_effect_functional_test.exs apps/synapsis_core/test/synapsis/filesystem/text_read_functional_test.exs
```

The dedicated Workspace ordinary checks are
`apps/synapsis_workspace/test/synapsis/workspace/file_documents_scope_functional_test.exs`
and `apps/synapsis_workspace/test/synapsis/workspace/filesystem_scope_functional_test.exs`.
They use the same explicit qualified Node and actual packaged planner, Concord
stores, PubSub sender gates and passive admission traces. They cover successful
version/no-op behavior and normal queued operations through publication;
exceptional, cancellation, permission and budget branches remain source-reviewed
only.

Remaining work includes error/recovery qualification and production Workflow
caller/machine assembly. Default selections, Worker/history and internal
Effect/Journal child-ledger evidence have separate scopes in the alignment plan;
the dedicated Node check does not qualify every caller. Local's existing
file/edit-count/result budgets also remain
explicit host boundaries. Release CI/OTP packaging and Docker now have explicit
version-bound Node supply; their actual execution limits are recorded in the
alignment plan. The complete filesystem family and platform acceptance remain
incomplete.
