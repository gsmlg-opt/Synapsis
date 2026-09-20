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

These preset details do not create a fourth wire protocol and do not enable the
OpenAI Responses client API.
