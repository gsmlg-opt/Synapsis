# 06 - Provider Integration

## Ownership

Synapsis supports three provider wire protocols:

- Anthropic Messages (`:anthropic`)
- OpenAI Chat Completions and compatible endpoints (`:openai`)
- Google Gemini GenerateContent (`:google`)

OpenAI Responses is not a supported Synapsis client protocol. The Backplane
Responses observer is an independent host-side observation surface, not a
request/stream codec used here.

Provider responsibilities are split as follows:

| Layer | Responsibility |
|---|---|
| `Synapsis.Provider.MessageMapper` | Convert Synapsis messages, tools, and reasoning state into canonical `Backplane.AiProtocol` values. |
| `Backplane.AiProtocol.Codec` | Encode canonical requests and decode provider responses, errors, and stream bytes. |
| `Synapsis.Provider.EventMapper` | Convert canonical stream events into Synapsis runtime events. |
| `Synapsis.Provider.Adapter` | Own HTTP execution, authentication headers, URL selection, timeouts, OAuth retry, stream codec state, event delivery, and cancellation. |
| `Synapsis.Provider.Transport.*` | Provide model discovery where supported and default endpoint metadata. |

There is no `Transport.stream/3` callback and no Synapsis-owned shared SSE
parser. `Adapter` feeds response bytes directly to the protocol codec. The
transport modules do not own request, response, error, or stream wire handling.

## Dependency Boundary

`synapsis_provider` consumes the published Hex package:

```elixir
{:backplane_ai_protocol, "~> 1.5.0"}
```

The resolved release and package checksum are locked in `mix.lock`. Builds no
longer require a sibling Backplane checkout, so CI and fresh clones resolve the
same protocol implementation from Hex.

## Request Construction

`Adapter.format_request/3` delegates to `MessageMapper.build_request/4` and has
a tagged result contract:

```elixir
{:ok, wire_request} | {:error, %Backplane.AiProtocol.Error{}}
```

`wire_request` is the provider-ready map returned by
`Backplane.AiProtocol.Codec.encode_request/3`. Provider wire maps use string
keys, including core fields such as `"model"` and `"stream"`. Callers pass the
tagged result through to `Adapter.stream/2` or `Adapter.complete/2`; both reject
an error tuple without making an HTTP request.

The mapper preserves explicit `false` options, encodes every tool definition
and historical tool call with `Synapsis.Provider.ToolName`, and supplies the
codec with provider affinity (`profile`, `protocol`, `endpoint`, optional
`account` and `workspace`, and `model`). The codecs reject unsupported or
lossy conversions instead of silently dropping content.

## Streaming And Cancellation

`Adapter.stream/2` starts an async provider task and returns both the task PID
and monitor reference:

```elixir
{:ok, %{pid: pid, ref: monitor_ref}}
```

The PID is the cancellation target; the monitor reference lets
`Synapsis.Session.Stream` detect an unexpected provider-task exit. `cancel/1`
accepts the returned handle or a PID and terminates the supervised task.

The adapter sends these messages to its calling process:

```elixir
{:provider_chunk, event}
:provider_done
{:provider_error, reason}
```

For a successful HTTP response, the adapter initializes codec state, feeds
each byte chunk with `Codec.stream_feed/3`, and closes the stream with
`Codec.stream_finish/3`. The codec's canonical `:terminal` event is not exposed
as a Synapsis chunk. `:provider_done` is emitted only after successful codec
finish and stream-guard flush. HTTP failures, codec failures, unsupported
mapped output, and guard violations emit `{:provider_error, reason}` and do not
also emit `:provider_done`. An empty successful body is therefore a protocol
error rather than a successful empty completion.

The fenced session proxy forwards chunks only for the active stream. A
matching task `:DOWN` becomes
`{:provider_error, stream_ref, {:provider_exit, reason}}`, so collectors do not
wait for the normal stream timeout after a provider task crashes.

## Canonical Events

The Backplane codecs produce `%Backplane.AiProtocol.StreamEvent{}` values.
`EventMapper` maps the supported subset to Synapsis events:

```elixir
{:text_delta, text}
{:reasoning_delta, text}
{:tool_call_delta, index, call_id, name, arguments_delta}
{:tool_call_done, index, call_id, name, content}
{:provider_state, state_map}
{:usage, usage}
```

Canonical text content can be emitted as a text delta. Other canonical content
blocks are rejected explicitly as incompatible provider output. They are not
ignored or treated as successful completion. Tool names are decoded back to
their Synapsis names at this boundary.

## Signed Provider State

Anthropic signed thinking and Google thought signatures are opaque,
provider-bound state. Stream events carry that state with its source profile,
source protocol, and public affinity. Synapsis persists it on
`Synapsis.Part.Reasoning.provider_states` with the reasoning content so session
snapshots can replay it.

Replay is deliberately strict. Signed reasoning without provider-origin
metadata is rejected. The codec also requires the original protocol, profile,
endpoint, and model, and checks optional account/workspace affinity when
present. State cannot be replayed through a different provider origin. Google
signed content that is not marked as thought is rejected because its semantics
cannot be preserved.

An explicit idle session model change enables `history_projection: :portable`.
`Synapsis.Provider.RequestHistory` constructs the target request view: valid
incompatible opaque state and its nonportable reasoning are removed; compatible
state, visible content and paired tool calls/results are retained. Invalid or
missing origin metadata still reaches strict codec validation and fails closed.
The original durable messages are unchanged. Codec acceptance does not prove a
remote model will accept converted signed history, particularly Google content.

## Configured Models And Session Selection

Provider connections own endpoint, credential reference, protocol, preset and enabled
state in `providers.toml`. `Synapsis.Models` owns `models.toml`: stable model UUID,
provider UUID, raw model ID, optional display name, positive token context window,
and enabled state. Raw IDs are unique within a provider. Discovery provides import
candidates; repeat imports preserve configured context and enabled choices.
Missing context defaults to 256,000 tokens; explicit provider metadata and saved
values are preserved. Model settings use a modal editor with 256k, 384k, 500k,
768k and 1M presets (decimal tokens), retain existing custom values, and support
bulk context, enable/disable and confirmed delete operations on selected records,
plus importing all discovery suggestions.

`Providers.configured_models/0` is the shared selectable catalog for agent defaults
and sessions. Both provider and model must be runtime-available. One-time import
preserves legacy provider choices, agent defaults and durable session pairs;
the migration marker prevents deleted catalog entries from being recreated.
Legacy environment and `.opencode.json` runtime resolution remains available.

An agent model initializes a new session. Saved sessions own their provider/model
pair and catalog identity independently of later agent-default refreshes. Idle
switching validates projected history before persistence and updates the worker,
provider configuration and engine together. Deleted/disabled choices require an
explicit replacement; a recreated raw name cannot replace a deleted UUID.

`Providers.model_context_window/2` supplies the configured token window to turn
preparation, compaction, skill metadata and memory budgeting. Static ModelRegistry
metadata remains the fallback for legacy pairs and capability information.

## Model Discovery And Endpoints

- `Transport.Anthropic` discovers models for configured compatible endpoints
  when requested and exposes the default Anthropic base URL.
- `Transport.OpenAI` discovers models through the configured models endpoint
  and exposes the default OpenAI base URL.
- `Transport.Google` exposes the default Gemini base URL; model metadata comes
  from `ModelRegistry`.

`Synapsis.Provider.ModelRegistry` owns static capability metadata such as model
IDs, context windows, output limits, tool support, reasoning support, image
support, and streaming support. Anthropic and Google normally use this static
metadata. OpenAI-compatible providers use dynamic discovery.

`Synapsis.Provider.Registry` is the ETS-backed runtime provider configuration
store. For supported provider types, `module_for/1` returns
`Synapsis.Provider.Adapter`; the configured type selects the codec and endpoint
behavior inside the adapter.

Req automatic retries are disabled for streaming submissions. The adapter owns
the bounded OpenAI OAuth refresh retry on a 401 response; callers receive other
HTTP and codec failures through the normal tagged error or `provider_error`
contract.

## Backplane Preset

Backplane remains an opt-in OpenAI-compatible provider preset. The hosted
endpoint defaults to `https://backplane.gsmlg.net/v1` and requires an access
token. Local development commonly uses `http://localhost:4220/v1` and may run
without authentication. Synapsis sends `Authorization: Bearer <token>` only
when a non-empty token is configured.

The preset is not startup-seeded, and its base URL remains editable during
creation. Creation attempts model discovery through the OpenAI-compatible
models endpoint (`<base_url>/models` when the URL already ends in `/v1`,
otherwise `<base_url>/v1/models`) and caches models when discovery succeeds. A
discovery failure leaves the provider configured for a later retry.
Backplane suggestions come only from successful discovery; an empty discovery
result remains empty rather than falling back to built-in OpenAI models. Model
settings identify authentication failures and link to the provider connection.
Open model settings reconcile the selected provider after connection changes.
Model editor and bulk context forms use native submit buttons to avoid duplicate
submissions when custom elements reconnect (duskmoon-dev/duskmoon-elements#88).

These preset details do not create a fourth wire protocol and do not enable the
OpenAI Responses client API.

MCP and remote skill setup may explicitly select a Backplane provider. Linked
sources resolve current provider credentials when used, preserve existing source
UUIDs and skill locators, and keep source trust/sync state separate. MCP may save
an explicit URL override; its default follows the provider endpoint. Creating a
provider alone does not create either source or assign skills to agents.

Backplane tool snapshots are diagnostic only; live MCP discovery owns tool
admission. Their schemas may contain JSON nulls, so MCP configuration persists
them in `config.backplane_tools_json`. `Synapsis.MCPConfigs` decodes this field
to the existing `backplane_tools` list and continues to read legacy inline lists.

## Provider Lifecycle

### Credentials

`/settings/credentials` manages named API keys and Backplane access tokens through
modal forms. `Synapsis.Credentials` in `synapsis_data` owns encrypted records in
`credentials.toml`, using the existing AES-256-GCM `enc:v1:` format. Providers store
only `credential_id`; Models, linked MCP services and remote Skills keep their
existing Provider/source identities. Multiple Providers can share a Credential.
OAuth login, refresh and logout retain their existing lifecycle and storage.

Lists return safe metadata and a masked suffix only for keys longer than eight
characters. Edit forms never preload a saved key; leaving the key empty preserves
it. Phoenix filters credential parameters in nested request/LiveView logs.
Deleting a referenced Credential fails with the referencing Providers; deleting a
Provider retains its Credential. Reference lists and blocked-deletion warnings
refresh when Provider references change. Explicit “No credential” is a valid selection.
Missing or corrupt explicit references fail unavailable, without falling back to
an inline key, environment variable or unauthenticated request.

Credential writes and reference checks share the Store write lock. Notifications
run after the outer write completes, refresh Provider Registry/catalog state and
replace already-running linked MCP clients through supervised tasks. No-op file
reloads do not reconnect clients. External ciphertext edits, even with unchanged
timestamps, change the authentication generation. Request and tool boundaries
resolve current authentication and generations; correctness does not depend only
on notification delivery. A session's next request uses the current key while an
already-started request keeps its lifecycle. Remote Skill suppliers resolve the
current key on use. Delayed model/tool discoveries and Backplane snapshots cannot
publish capabilities after their authentication generation changes.

Startup migrates legacy manual Provider keys after a private backup under the
config directory's `backups/credentials-migration-*`. It saves a Credential before
replacing the Provider's inline field, preserves UUIDs and reuses a per-Provider
legacy marker on retries without overwriting a subsequent key rotation. Different
Providers with equal keys are not automatically deduplicated. Failures keep the
legacy record and log the affected Provider UUID with a sanitized error class;
the cross-file migration is recoverable rather than crash-atomic.

Provider REST inputs accept `credential_id` and retain `api_key` /
`api_key_encrypted` compatibility: a raw-key update can rotate an unshared
Credential, but a shared Credential requires an explicit Credentials update.
Clearing a Provider key detaches its reference and retains the Credential.

### Provider Removal

Deleting a provider removes its configured models, linked Backplane sources,
MCP services and remote skills. It also clears affected agent defaults, fallback
models, skill assignments and MCP selections, plus tool references in agents,
toolsets and surviving skills. Independent services, local skills and historical
sessions remain intact. MCP teardown stops linked clients and unregisters their
discovered tools; the provider's runtime registry entry is removed as well.

Configuration mutations and immediate registry updates share a local write lock.
Updates replace existing records without recreating deleted identities, and new
linked writes require their provider/source to exist. Consequently, discovery or
sync results arriving after deletion cannot revive the removed records. Cleanup
spans several TOML files rather than a crash-atomic transaction: a persistence
failure is reported and retains the provider/source needed to retry cleanup.

Successful provider changes and model-setting operations publish a local catalog
invalidation. Open settings, agent and session pages reload their choices while
preserving unsaved form drafts. Discovery refreshes import candidates; importing
models remains explicit. Recreating a provider with the same name creates a new
identity and does not inherit the deleted provider's models or agent defaults.
