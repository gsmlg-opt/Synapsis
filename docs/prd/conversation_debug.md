# Conversation Debug — Product Requirements Document

## 1. Overview

**Scope:** Cross-cutting enhancement to `synapsis_provider`, `synapsis_agent`, `synapsis_server`, and `synapsis_web`
**Primary modules:** `SynapsisProvider.Sanitizer`, `SynapsisProvider.DebugCapture`, `SynapsisServer.SessionChannel`, `@synapsis/ui` DebugPanel
**Target:** Elixir >= 1.18 / OTP 28+

This PRD defines the conversation debug system for Synapsis. When debug mode is enabled on a session, the raw LLM API request and response payloads are captured at the provider boundary, sanitized, and streamed to the chat UI as interleaved debug entries alongside normal conversation messages.

**The problem it solves:** When an LLM call misbehaves — wrong model selected, rate-limited, malformed tool definitions, unexpected truncation — there is no visibility into what was actually sent and received. Debugging requires reading Elixir logs, grepping telemetry, or adding temporary `IO.inspect` calls. The user (who may not have shell access) has zero insight into the API layer.

**One-line definition:** The debug panel is `curl -v` for your LLM calls, right in the chat.

### What This PRD Covers

- DB-1: Debug mode toggle (per-session, ephemeral)
- DB-2: Request/response capture at the provider boundary
- DB-3: Header sanitization (credential redaction)
- DB-4: SSE stream assembly into canonical response shape
- DB-5: Channel transport and client rendering
- DB-6: Partial failure handling
- DB-7: ETS storage (survives page refresh, dropped on server restart or session cleanup)

### What This PRD Does NOT Cover

- Full session recording / replay — future work
- Provider-side distributed tracing — out of scope
- Debug mode for MCP/LSP plugin calls — future enhancement (same pattern applies)
- Cost/token analytics dashboard — separate feature

### Dependency Position

```
synapsis_provider (capture + sanitize — owns the boundary)
    ↑
synapsis_agent (telemetry subscription, conditional forwarding, ETS writes)
    ↑
synapsis_server (DebugStore ETS, SessionChannel broadcasts debug events)
    ↑
synapsis_web (React DebugPanel renders entries, hydrates from ETS on join)
```

No new cross-app dependencies are introduced. `synapsis_agent` already depends on `synapsis_provider`. The debug capture uses `:telemetry` — a decoupled, existing mechanism.

---

## 2. Motivation

### 2.1 The Black Box Problem

Synapsis supports 8+ LLM providers (Anthropic, OpenAI, Google, Groq, OpenRouter, Bedrock, Azure, local). Each has different error shapes, rate limit headers, model name formats, and streaming conventions. When something breaks, the failure manifests as a vague agent error: "LLM call failed" or an unexpected response.

Today's debugging workflow:

1. Check Elixir application logs (requires shell access)
2. Hope the log level was set to `:debug` before the failure occurred
3. Correlate timestamps between agent logs, provider logs, and PubSub events
4. If the issue was a malformed request, reproduce it manually with `curl`

This is unacceptable for a tool that replaces CLI-based agents where `--verbose` is a flag away.

### 2.2 Multi-Provider Debugging

The most common debugging scenarios are provider-specific:

- **Wrong model name:** `claude-3-sonnet` vs `claude-sonnet-4-20250514` — the request succeeds but with unexpected behavior
- **Rate limiting:** 429 with `retry-after` header — invisible unless you see the response
- **Token overflow:** Request body too large — error buried in response body
- **Tool schema mismatch:** Provider rejects tool definitions silently or returns malformed tool_use
- **Auth failure:** 401/403 — wrong API key for the selected provider

All of these are diagnosable in seconds if you can see the raw request and response.

### 2.3 Why ETS, Not Database

Debug payloads are large (full request/response JSON bodies can be 50-200KB per turn). Persisting them to PostgreSQL would bloat the messages table, require migration, and create retention/cleanup concerns. But purely client-side storage (Redux only) loses debug history on page refresh — frustrating when you're mid-investigation.

ETS hits the sweet spot: debug entries survive page refreshes and are visible across tabs, but vanish on server restart or session cleanup. The lifecycle matches the debugging workflow — you toggle it on, investigate across multiple turns and page loads, and the data cleans itself up when the session ends.

---

## 3. Debug Toggle

### DB-1: Per-Session Debug Flag

**DB-1.1** — New column on `sessions` table:

```elixir
# In migration
alter table(:sessions) do
  add :debug, :boolean, default: false, null: false
end
```

**DB-1.2** — Toggle via channel push:

```
session:{session_id}
  → push("toggle_debug", %{enabled: true | false})
  ← broadcast("debug_toggled", %{enabled: true | false})
```

**DB-1.3** — The `SessionChannel` handler updates the session record and broadcasts the new state to all connected clients (multi-tab awareness):

```elixir
def handle_in("toggle_debug", %{"enabled" => enabled}, socket) do
  session_id = socket.assigns.session_id
  {:ok, _session} = SynapsisCore.Sessions.update_debug(session_id, enabled)

  broadcast!(socket, "debug_toggled", %{enabled: enabled})
  {:noreply, assign(socket, :debug, enabled)}
end
```

**DB-1.4** — Debug state is included in the channel join reply so clients hydrate correctly:

```elixir
# In SessionChannel.join/3
reply = %{
  messages: messages,
  ui_state: ui_state,
  debug: session.debug
}
```

**DB-1.5** — Debug flag is passed into the agent graph state when a user message arrives. The `llm_call` node (or its wrapper) checks `state.debug` to decide whether to attach the telemetry handler for that turn.

---

## 4. Capture

### DB-2: Telemetry-Based Request/Response Capture

The capture point is `synapsis_provider` — the Req pipeline that makes HTTP calls to LLM APIs.

**DB-2.1** — Two telemetry events emitted by the provider transport:

```elixir
# Emitted immediately before the HTTP request
:telemetry.execute(
  [:synapsis, :provider, :request],
  %{system_time: System.system_time()},
  %{
    session_id: session_id,
    request_id: request_id,        # UUID, correlates request ↔ response
    method: :post,
    url: url,
    headers: raw_headers,          # NOT yet sanitized
    body: request_body,            # Encoded JSON (the actual bytes sent)
    provider: provider_name,       # :anthropic | :openai | :google | ...
    model: model_name
  }
)

# Emitted after response completes (or stream assembles)
:telemetry.execute(
  [:synapsis, :provider, :response],
  %{duration: duration_native, system_time: System.system_time()},
  %{
    session_id: session_id,
    request_id: request_id,
    status: status_code,
    headers: raw_response_headers,
    body: response_body,           # Assembled JSON for streams (see DB-4)
    complete: complete?,           # false if stream interrupted
    error: error_or_nil            # populated on partial failure (see DB-6)
  }
)
```

**DB-2.2** — Telemetry events are emitted unconditionally. They are cheap (no allocation beyond what the Req pipeline already holds). The decision to *forward* them to PubSub is made by the subscriber — only attached when `state.debug == true`.

**DB-2.3** — The telemetry handler is attached per-turn, scoped to the session:

```elixir
defmodule SynapsisAgent.DebugTelemetry do
  @request_event [:synapsis, :provider, :request]
  @response_event [:synapsis, :provider, :response]

  @doc """
  Attaches telemetry handlers for a single agent turn.
  Returns a handler_id for cleanup.
  """
  @spec attach(session_id :: String.t()) :: :ok
  def attach(session_id) do
    handler_id = "debug-#{session_id}-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(handler_id, [@request_event, @response_event], &handle_event/4, %{
      session_id: session_id,
      handler_id: handler_id
    })

    handler_id
  end

  @spec detach(handler_id :: String.t()) :: :ok
  def detach(handler_id) do
    :telemetry.detach(handler_id)
  end

  defp handle_event(@request_event, _measurements, metadata, config) do
    if metadata.session_id == config.session_id do
      sanitized = SynapsisProvider.Sanitizer.sanitize_request(metadata)
      SynapsisServer.DebugStore.put_request(config.session_id, sanitized)

      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "session:#{config.session_id}",
        {:debug_request, sanitized}
      )
    end
  end

  defp handle_event(@response_event, measurements, metadata, config) do
    if metadata.session_id == config.session_id do
      sanitized = SynapsisProvider.Sanitizer.sanitize_response(metadata, measurements)
      SynapsisServer.DebugStore.put_response(config.session_id, sanitized)

      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "session:#{config.session_id}",
        {:debug_response, sanitized}
      )
    end
  end
end
```

**DB-2.4** — The `llm_call` node (or a wrapping node) manages the handler lifecycle:

```elixir
# Before LLM call
handler_id = if state.debug, do: DebugTelemetry.attach(state.session_id)

# ... perform LLM call ...

# After LLM call (in ensure block — always runs)
if handler_id, do: DebugTelemetry.detach(handler_id)
```

---

## 5. Sanitization

### DB-3: Header Credential Redaction

**DB-3.1** — `SynapsisProvider.Sanitizer` is a pure module in `synapsis_provider`. It owns the knowledge of what is sensitive in HTTP headers.

**DB-3.2** — Allowlist approach. Headers on the safe list pass through verbatim. All other headers have their values redacted:

```elixir
defmodule SynapsisProvider.Sanitizer do
  @safe_headers MapSet.new([
    "content-type",
    "accept",
    "user-agent",
    "x-request-id",
    "anthropic-version",
    "anthropic-beta",
    "openai-organization",
    "x-stainless-arch",
    "x-stainless-os",
    "x-stainless-lang",
    "x-stainless-runtime",
    "x-stainless-runtime-version"
  ])

  @type redacted_header :: {String.t(), String.t()}

  @spec redact_headers([{String.t(), String.t()}]) :: [redacted_header()]
  def redact_headers(headers) do
    Enum.map(headers, fn {key, value} ->
      normalized = String.downcase(key)

      if MapSet.member?(@safe_headers, normalized) do
        {key, value}
      else
        {key, redact_value(value)}
      end
    end)
  end

  @spec redact_value(String.t()) :: String.t()
  defp redact_value(value) when byte_size(value) >= 4 do
    last4 = String.slice(value, -4, 4)
    "...#{last4}"
  end

  defp redact_value(_value), do: "..."
end
```

**DB-3.3** — Redaction examples:

| Header | Raw Value | Redacted |
|---|---|---|
| `authorization` | `Bearer sk-ant-api03-abc...xyz` | `Bearer ...xyz` |
| `x-api-key` | `sk-ant-api03-longkey` | `...gkey` |
| `api-key` | `a1b2c3d4e5` | `...d4e5` |
| `x-goog-api-key` | `AIzaSyB...` | `...SyB` |
| `Ocp-Apim-Subscription-Key` | `abcdef123456` | `...3456` |
| `content-type` | `application/json` | `application/json` (safe) |

**DB-3.4** — The `...#{last4}` pattern confirms *which* key was used (critical for multi-provider debugging with different API keys per provider) without exposing the credential.

**DB-3.5** — Sanitization applies to both request and response headers. Providers sometimes echo account identifiers or tokens in response headers.

**DB-3.6** — Convenience functions for the telemetry handler:

```elixir
@spec sanitize_request(map()) :: map()
def sanitize_request(metadata) do
  %{
    request_id: metadata.request_id,
    method: metadata.method,
    url: metadata.url,
    headers: redact_headers(metadata.headers),
    body: metadata.body,
    provider: metadata.provider,
    model: metadata.model,
    timestamp: DateTime.utc_now()
  }
end

@spec sanitize_response(map(), map()) :: map()
def sanitize_response(metadata, measurements) do
  %{
    request_id: metadata.request_id,
    status: metadata.status,
    headers: redact_headers(metadata.headers),
    body: metadata.body,
    complete: metadata.complete,
    error: metadata.error,
    duration_ms: System.convert_time_unit(measurements.duration, :native, :millisecond),
    timestamp: DateTime.utc_now()
  }
end
```

---

## 6. Stream Assembly

### DB-4: SSE Chunks → Canonical Response Body

**DB-4.1** — For streaming LLM calls (SSE), the debug response body must be the **assembled canonical JSON response**, not raw SSE frames. This matches what the provider would return for an equivalent non-streaming call.

**DB-4.2** — The assembly piggybacks on the existing chunk accumulator in the Req streaming pipeline. The same accumulator that builds the final `Message` struct also builds the debug response body. One accumulation pass, two consumers:

```
SSE frames arrive
    ↓
Req streaming callback
    ↓ accumulates
┌───────────────────────────┐
│  Chunk Accumulator        │
│  - builds Message struct  │  ← existing (for agent)
│  - builds debug JSON body │  ← new (for debug capture)
└───────────────────────────┘
    ↓ on stream complete
Emit :telemetry :response with assembled body
```

**DB-4.3** — The assembled body follows the provider's canonical response format. For Anthropic:

```json
{
  "id": "msg_01XFDUDYJgAACzvnptvVoYEL",
  "type": "message",
  "role": "assistant",
  "content": [
    {"type": "text", "text": "Here is the fix..."},
    {"type": "tool_use", "id": "toolu_01...", "name": "file_edit", "input": {...}}
  ],
  "model": "claude-sonnet-4-20250514",
  "stop_reason": "tool_use",
  "usage": {"input_tokens": 1200, "output_tokens": 450}
}
```

**DB-4.4** — For OpenAI-shaped providers, the equivalent `choices[0].message` structure. The debug panel renders whatever JSON it receives — no normalization to a common format. The user sees what the provider actually returned.

**DB-4.5** — `usage` / token counts are included when available. They arrive in the final SSE event for most providers (`message_delta` for Anthropic, the last `[DONE]`-adjacent chunk for OpenAI). The accumulator must capture these.

---

## 7. Partial Failure

### DB-6: Interrupted Streams and Error Responses

**DB-6.1** — If the SSE stream is interrupted (connection drop, provider 500 mid-stream, timeout), the telemetry response event is still emitted with what was accumulated:

```elixir
%{
  request_id: request_id,
  status: 200,                          # HTTP status was 200 (stream started)
  headers: redacted_response_headers,
  body: partial_assembled_json,         # what we got before failure
  complete: false,                      # key flag
  error: %{
    reason: :connection_closed | :timeout | :provider_error,
    message: "Connection reset by peer after 1200ms",
    last_event: "event: content_block_delta\ndata: {\"type\":...}"
  },
  duration_ms: 1200,
  timestamp: ~U[2026-03-23 10:00:00Z]
}
```

**DB-6.2** — The `complete` field distinguishes successful from partial responses. The UI uses this to render partial failures distinctly (e.g., yellow border vs green).

**DB-6.3** — For non-streaming error responses (4xx, 5xx), the response body is captured verbatim. These are often JSON error objects from the provider:

```json
{
  "error": {
    "type": "rate_limit_error",
    "message": "Rate limit exceeded. Retry after 30s."
  }
}
```

**DB-6.4** — Status code rendering guidance:

| Status | Meaning | UI Indicator |
|---|---|---|
| 200 + complete | Success | Green |
| 200 + !complete | Stream interrupted | Yellow |
| 400 | Bad request (malformed body) | Red |
| 401, 403 | Auth failure | Red |
| 404 | Model not found | Red |
| 429 | Rate limited | Orange |
| 500, 502, 503 | Provider error | Red |

---

## 8. ETS Storage

### DB-7: Session-Scoped Debug Entry Store

**DB-7.1** — Debug entries are stored in an ETS table, scoped per session. The table is owned by `SynapsisServer.DebugStore`, a GenServer started under the server supervision tree:

```elixir
defmodule SynapsisServer.DebugStore do
  use GenServer

  @table :debug_entries

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    table = :ets.new(@table, [
      :named_table,
      :ordered_set,          # ordered by {session_id, timestamp}
      :public,               # channel processes write directly
      read_concurrency: true
    ])

    {:ok, %{table: table}}
  end
end
```

**DB-7.2** — Entry key structure: `{session_id, request_id}`. Value is the full debug entry map (request fields populated first, response fields merged when received):

```elixir
@type entry_key :: {session_id :: String.t(), request_id :: String.t()}
@type debug_entry :: %{
  request_id: String.t(),
  method: atom(),
  url: String.t(),
  request_headers: [{String.t(), String.t()}],
  request_body: String.t(),
  provider: atom(),
  model: String.t(),
  request_timestamp: DateTime.t(),
  # Response fields — nil until response arrives
  status: non_neg_integer() | nil,
  response_headers: [{String.t(), String.t()}] | nil,
  response_body: String.t() | nil,
  complete: boolean() | nil,
  error: map() | nil,
  duration_ms: non_neg_integer() | nil,
  response_timestamp: DateTime.t() | nil
}
```

**DB-7.3** — Write API (called from PubSub handler in `DebugTelemetry`, not from channel):

```elixir
@spec put_request(String.t(), map()) :: true
def put_request(session_id, sanitized_request) do
  entry = Map.put(sanitized_request, :status, nil)
  :ets.insert(@table, {{session_id, sanitized_request.request_id}, entry})
end

@spec put_response(String.t(), map()) :: true
def put_response(session_id, sanitized_response) do
  key = {session_id, sanitized_response.request_id}

  case :ets.lookup(@table, key) do
    [{^key, existing}] ->
      merged = Map.merge(existing, sanitized_response)
      :ets.insert(@table, {key, merged})

    [] ->
      # Response arrived without request (race condition) — store anyway
      :ets.insert(@table, {key, sanitized_response})
  end
end
```

**DB-7.4** — Read API (called from `SessionChannel.join/3` to hydrate client):

```elixir
@spec list_entries(String.t()) :: [debug_entry()]
def list_entries(session_id) do
  match_spec = [{{{session_id, :_}, :"$1"}, [], [:"$1"]}]
  :ets.select(@table, match_spec)
end
```

**DB-7.5** — Cleanup API — called when a session ends or debug is toggled off:

```elixir
@spec clear_entries(String.t()) :: non_neg_integer()
def clear_entries(session_id) do
  match_spec = [{{{session_id, :_}, :_}, [], [true]}]
  :ets.select_delete(@table, match_spec)
end
```

**DB-7.6** — Lifecycle rules:

- **Server restart** → ETS table is recreated empty (GenServer `init/1`). All debug entries lost. This is the desired behavior — no stale data.
- **Session deleted** → `clear_entries/1` called from `SynapsisCore.Sessions.delete/1` callback (via PubSub `{:session_deleted, session_id}`).
- **Debug toggled off** → `clear_entries/1` called from `SessionChannel.handle_in("toggle_debug", %{"enabled" => false}, ...)`. Turning debug off wipes the history.
- **Session idle cleanup** → if session processes are reaped by `phoenix_session_process` timeout, the associated debug entries are cleaned up in the same callback.

**DB-7.7** — Size guard. Debug payloads can be large. Cap at 100 entries per session (most recent wins):

```elixir
@max_entries_per_session 100

defp maybe_evict(session_id) do
  entries = :ets.select(@table, [{{{session_id, :_}, :_}, [], [:"$_"]}])

  if length(entries) > @max_entries_per_session do
    entries
    |> Enum.sort_by(fn {_key, entry} -> entry.request_timestamp end)
    |> Enum.take(length(entries) - @max_entries_per_session)
    |> Enum.each(fn {key, _} -> :ets.delete(@table, key) end)
  end
end
```

---

## 9. Channel Transport

### DB-5: SessionChannel Debug Events

**DB-5.1** — Two new broadcast events on `session:{session_id}`:

```
← broadcast("debug_request", %{
    request_id: uuid,
    method: "POST",
    url: "https://api.anthropic.com/v1/messages",
    headers: [{"content-type", "application/json"}, {"authorization", "Bearer ...xyz"}],
    body: request_json_string,
    provider: "anthropic",
    model: "claude-sonnet-4-20250514",
    timestamp: iso8601
  })

← broadcast("debug_response", %{
    request_id: uuid,
    status: 200,
    headers: [{...}],
    body: assembled_response_json_string,
    complete: true,
    error: null,
    duration_ms: 3400,
    timestamp: iso8601
  })
```

**DB-5.2** — The `request_id` field correlates request and response pairs. The client groups them together in the debug timeline.

**DB-5.3** — Debug events are broadcast only when the session's debug flag is true. The `SessionChannel` PubSub handler filters:

```elixir
def handle_info({:debug_request, payload}, socket) do
  if socket.assigns.debug do
    push(socket, "debug_request", payload)
  end

  {:noreply, socket}
end

def handle_info({:debug_response, payload}, socket) do
  if socket.assigns.debug do
    push(socket, "debug_response", payload)
  end

  {:noreply, socket}
end
```

**DB-5.4** — Debug entries **are** included in the channel join reply when debug is enabled. The channel reads from ETS on join, so page refresh restores the debug timeline:

```elixir
# In SessionChannel.join/3
debug_entries =
  if session.debug do
    SynapsisServer.DebugStore.list_entries(session_id)
  else
    []
  end

reply = %{
  messages: messages,
  ui_state: ui_state,
  debug: session.debug,
  debug_entries: debug_entries
}
```

**DB-5.5** — The `DebugTelemetry` PubSub handler writes to ETS *before* broadcasting to PubSub, ensuring ETS is always ahead of or in sync with the channel:

```elixir
defp handle_event(@request_event, _measurements, metadata, config) do
  if metadata.session_id == config.session_id do
    sanitized = SynapsisProvider.Sanitizer.sanitize_request(metadata)
    SynapsisServer.DebugStore.put_request(config.session_id, sanitized)

    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "session:#{config.session_id}",
      {:debug_request, sanitized}
    )
  end
end
```

---

## 10. Client Rendering

### DB-5.6: Redux State

New state in `chat` slice:

```typescript
interface DebugEntry {
  requestId: string
  // Request (populated first)
  method: string
  url: string
  requestHeaders: [string, string][]
  requestBody: string           // raw JSON string
  provider: string
  model: string
  requestTimestamp: string
  // Response (populated when received)
  status: number | null
  responseHeaders: [string, string][] | null
  responseBody: string | null   // assembled JSON string
  complete: boolean | null
  error: object | null
  durationMs: number | null
  responseTimestamp: string | null
}

interface ChatState {
  // ... existing fields ...
  debugEnabled: boolean
  debugEntries: DebugEntry[]    // ordered by requestTimestamp
}
```

### DB-5.7: Channel → Redux Wiring

```typescript
// On join, hydrate from ETS-backed entries
channel.join().receive("ok", (reply) => {
  store.dispatch(chatActions.hydrate(reply))
  if (reply.debug_entries) {
    store.dispatch(chatActions.hydrateDebugEntries(reply.debug_entries))
  }
})

channel.on("debug_toggled", (payload) =>
  store.dispatch(chatActions.setDebugEnabled(payload.enabled))
)
channel.on("debug_request", (payload) =>
  store.dispatch(chatActions.addDebugRequest(payload))
)
channel.on("debug_response", (payload) =>
  store.dispatch(chatActions.addDebugResponse(payload))  // merges by request_id
)
```

### DB-5.8: DebugPanel Component

The `<DebugPanel>` component renders debug entries interleaved in the message timeline:

- Collapsible by default — header shows: `POST anthropic claude-sonnet-4-20250514 → 200 (3.4s)`
- Expanded view: two-pane JSON viewer (request | response) with syntax highlighting
- Status-colored indicator (green/yellow/orange/red per DB-6.4)
- Headers rendered as a collapsible sub-section
- Request body is collapsible and searchable (tool definitions can be large)
- `complete: false` entries show a warning badge with the error reason

### DB-5.9: Toggle UI

A debug toggle button in the session header bar (next to the agent mode selector). Icon: a bug or terminal icon. Toggle dispatches:

```typescript
channel.push("toggle_debug", { enabled: !debugEnabled })
```

---

## 11. Data Model

### DB-1 Schema Change

```
sessions (existing table)
  + debug: boolean, default: false, null: false
```

No other schema changes. Debug entries are stored in ETS (see DB-7), not PostgreSQL.

---

## 12. Implementation Phases

### Phase 1: Capture + Sanitize

- `SynapsisProvider.Sanitizer` — `redact_headers/1`, `sanitize_request/1`, `sanitize_response/1`
- Telemetry events in provider Req pipeline — `[:synapsis, :provider, :request]`, `[:synapsis, :provider, :response]`
- Stream accumulator extended to build debug response body alongside Message struct
- Unit tests for sanitizer, telemetry emission

**Deliverable:** Raw capture works, sanitized payloads available via telemetry. No UI yet — verifiable via `:telemetry.attach/4` in IEx.

### Phase 2: Agent Wiring + ETS + Channel Transport

- `SynapsisServer.DebugStore` — ETS table, put/list/clear API, eviction
- `SynapsisAgent.DebugTelemetry` — attach/detach per turn, writes to ETS before PubSub
- `llm_call` node integration — conditional handler lifecycle
- `sessions` migration — add `debug` column
- `SessionChannel` — `toggle_debug`, `debug_request`, `debug_response` events, ETS hydration on join
- PubSub handler filtering in channel
- Cleanup hooks: session delete, debug toggle off, session process timeout

**Deliverable:** Debug events flow from provider → agent → ETS → channel → browser console. Toggle works. Page refresh restores debug timeline from ETS.

### Phase 3: Client Rendering

- Redux `chat` slice extensions — `debugEnabled`, `debugEntries`, reducers
- Channel middleware wiring for debug events
- `<DebugPanel>` component — collapsible JSON viewer, status indicators
- Debug toggle button in session header
- Status color coding per DB-6.4

**Deliverable:** Full end-to-end debug visibility in the chat UI.

---

## 13. Test Tree

### Phase 1 Tests

```
test/synapsis_provider/sanitizer_test.exs
├── describe "redact_headers/1"
│   ├── passes safe headers through verbatim
│   ├── redacts authorization header with last4
│   ├── redacts x-api-key with last4
│   ├── redacts api-key with last4
│   ├── redacts x-goog-api-key with last4
│   ├── redacts Ocp-Apim-Subscription-Key with last4
│   ├── redacts unknown headers with last4
│   ├── handles short values (< 4 chars) with "..."
│   ├── handles empty header list
│   ├── case-insensitive header matching
│   └── preserves header key casing
├── describe "sanitize_request/1"
│   ├── includes all required fields
│   ├── redacts headers
│   ├── preserves body verbatim
│   ├── includes provider and model
│   └── adds timestamp
├── describe "sanitize_response/1"
│   ├── includes all required fields
│   ├── redacts response headers
│   ├── converts duration from native to milliseconds
│   ├── includes complete flag
│   └── includes error when present

test/synapsis_provider/debug_capture_test.exs
├── describe "telemetry emission"
│   ├── emits :request event before HTTP call
│   ├── emits :response event after HTTP response
│   ├── emits :response event after stream completes
│   ├── request_id correlates request and response
│   ├── response includes assembled body for streaming calls
│   ├── response includes usage/token data when available
│   ├── response has complete: false on stream interruption
│   ├── response includes error metadata on partial failure
│   └── non-streaming response captured verbatim
```

### Phase 2 Tests

```
test/synapsis_server/debug_store_test.exs
├── describe "put_request/2"
│   ├── inserts entry keyed by {session_id, request_id}
│   ├── response fields are nil on initial insert
│   └── overwrites existing entry with same key
├── describe "put_response/2"
│   ├── merges response into existing request entry
│   ├── handles response arriving without prior request
│   └── preserves request fields when merging response
├── describe "list_entries/1"
│   ├── returns all entries for session
│   ├── returns empty list for unknown session
│   └── does not return entries from other sessions
├── describe "clear_entries/1"
│   ├── removes all entries for session
│   ├── does not affect other sessions
│   └── returns count of deleted entries
├── describe "eviction"
│   ├── evicts oldest entries when over max per session
│   ├── keeps exactly max_entries_per_session entries
│   └── eviction does not affect other sessions
├── describe "lifecycle"
│   ├── table recreated empty on GenServer restart
│   └── entries lost on application restart

test/synapsis_agent/debug_telemetry_test.exs
├── describe "attach/1"
│   ├── attaches handler for session
│   ├── returns handler_id
│   └── handler only forwards events matching session_id
├── describe "detach/1"
│   ├── removes handler
│   └── no events forwarded after detach
├── describe "ETS + PubSub forwarding"
│   ├── writes sanitized request to DebugStore before PubSub broadcast
│   ├── writes sanitized response to DebugStore before PubSub broadcast
│   ├── broadcasts sanitized request to session topic
│   ├── broadcasts sanitized response to session topic
│   └── does not write or broadcast when session_id does not match

test/synapsis_server/session_channel_debug_test.exs
├── describe "toggle_debug"
│   ├── updates session debug flag to true
│   ├── updates session debug flag to false
│   ├── broadcasts debug_toggled to all clients
│   ├── assigns debug to socket
│   └── toggle off calls DebugStore.clear_entries
├── describe "debug event forwarding"
│   ├── pushes debug_request when debug enabled
│   ├── pushes debug_response when debug enabled
│   ├── does not push debug_request when debug disabled
│   ├── does not push debug_response when debug disabled
│   └── debug state included in join reply
├── describe "join hydration"
│   ├── includes debug_entries from ETS when debug enabled
│   ├── includes empty debug_entries when debug disabled
│   └── entries survive client disconnect and rejoin
├── describe "llm_call node integration"
│   ├── attaches telemetry handler when state.debug is true
│   ├── does not attach when state.debug is false
│   ├── detaches handler after LLM call completes
│   └── detaches handler on LLM call error (ensure cleanup)
```

### Phase 3 Tests (Client — Jest/RTL)

```
test/js/debug-panel.test.tsx
├── describe "DebugPanel"
│   ├── renders nothing when debugEnabled is false
│   ├── renders entries when debugEnabled is true
│   ├── shows request before response arrives
│   ├── merges response into existing entry by requestId
│   ├── renders green indicator for 200 + complete
│   ├── renders yellow indicator for 200 + incomplete
│   ├── renders red indicator for 4xx/5xx
│   ├── renders orange indicator for 429
│   ├── collapsed by default — shows summary line
│   ├── expands to show request/response JSON
│   ├── headers section is collapsible
│   └── shows error badge for partial failures

test/js/debug-hydration.test.tsx
├── describe "join hydration"
│   ├── populates debugEntries from join reply debug_entries
│   ├── handles empty debug_entries gracefully
│   └── appends new entries after hydration without duplicates

test/js/debug-toggle.test.tsx
├── describe "DebugToggle"
│   ├── renders toggle button
│   ├── pushes toggle_debug on click
│   ├── reflects debugEnabled state
│   └── dispatches setDebugEnabled on debug_toggled event
```

---

## 14. Acceptance Criteria

- [ ] **AC-1:** Toggle debug on → next LLM call shows request/response JSON in chat timeline
- [ ] **AC-2:** API keys are never visible in debug entries — only `...#{last4}` shown
- [ ] **AC-3:** Streaming responses display as assembled canonical JSON, not raw SSE frames
- [ ] **AC-4:** Status code is visible in debug entry header (e.g., `→ 200 (3.4s)`)
- [ ] **AC-5:** Partial stream failure shows `complete: false` with error reason
- [ ] **AC-6:** Toggle debug off → no debug entries appear for subsequent calls, existing entries cleared
- [ ] **AC-7:** Debug entries survive page refresh — rejoin hydrates from ETS
- [ ] **AC-8:** Multi-tab: toggling debug in one tab broadcasts to other tabs viewing same session
- [ ] **AC-9:** `request_id` correctly pairs request and response in the UI
- [ ] **AC-10:** Response headers are also sanitized (provider may echo credentials)
- [ ] **AC-11:** 429 rate limit response shows status, body, and `retry-after` header value
- [ ] **AC-12:** Debug entries cleared on session delete
- [ ] **AC-13:** Debug entries lost on server restart (ETS is ephemeral — no stale data)

---

## 15. Integration Points

### With synapsis_provider

- Telemetry events emitted unconditionally by Req pipeline
- `SynapsisProvider.Sanitizer` — pure module, no external dependencies
- Stream accumulator builds debug response body alongside existing Message accumulation
- Provider-specific response formats passed through unsanitized (body content)

### With synapsis_agent

- `SynapsisAgent.DebugTelemetry` — per-turn attach/detach
- `llm_call` node checks `state.debug` flag
- Handler lifecycle managed in ensure block (always detaches)
- Writes to `DebugStore` ETS before PubSub broadcast

### With synapsis_data

- `sessions` table: new `debug` boolean column
- No new tables or schemas — debug entries live in ETS, not PostgreSQL

### With synapsis_server

- `SynapsisServer.DebugStore` — ETS-backed GenServer, started under server supervision tree
- `SessionChannel` handles `toggle_debug` push
- `SessionChannel` forwards PubSub debug events as channel broadcasts
- `SessionChannel.join/3` hydrates client with `DebugStore.list_entries/1`
- Filtering: only pushes when `socket.assigns.debug == true`
- Cleanup: `DebugStore.clear_entries/1` on session delete, debug toggle off, session process timeout

### With synapsis_web

- Redux `chat` slice: `debugEnabled`, `debugEntries`
- `<DebugPanel>` component in `@synapsis/ui`
- Debug toggle in session header bar
- JSON viewer with syntax highlighting (collapsible)
- Join reply hydration: `debug_entries` populated from ETS

### With PubSub

- `{:debug_request, payload}` → session topic
- `{:debug_response, payload}` → session topic
- `{:session_deleted, session_id}` → triggers `DebugStore.clear_entries/1`

---

## 16. Resolved Design Decisions

### RD-1: Telemetry Over Callback — Decoupled Capture

**Decision:** Use `:telemetry` events in the provider pipeline, not a callback or configuration option.

**Rationale:** The provider layer should not know or care about debug mode. Telemetry is fire-and-forget with zero overhead when no handler is attached. The agent layer decides whether to listen, and the channel layer decides whether to forward. Each layer has a single responsibility.

**Alternative considered:** Passing a `debug: true` option through the Req pipeline and having the provider conditionally emit data. Rejected because it couples the provider to UI concerns and requires threading the flag through every provider adapter.

### RD-2: Allowlist for Header Sanitization

**Decision:** Maintain an explicit allowlist of safe headers. Everything not on the list gets redacted.

**Rationale:** A denylist (`authorization`, `x-api-key`, etc.) requires enumerating every provider's auth header. New providers or custom headers silently leak credentials. An allowlist fails safe — unknown headers are redacted by default. The cost is occasionally redacting a harmless header, which is acceptable.

### RD-3: ETS-Backed Ephemeral Storage — Not Database, Not Client-Only

**Decision:** Debug entries are stored in a named ETS table owned by `SynapsisServer.DebugStore`. They are not persisted to PostgreSQL and not stored exclusively in client-side Redux state.

**Rationale:** Three options were considered:

1. **Client-only (Redux)** — entries lost on page refresh. Frustrating during active debugging, especially when switching tabs or the browser reloads mid-investigation. Rejected.
2. **Database (PostgreSQL)** — entries survive everything, but payloads are large (50-200KB per turn). Bloats storage, requires migration, retention policy, and cleanup jobs. Overkill for a diagnostic tool. Rejected.
3. **ETS** — entries survive page refresh (channel rejoin hydrates from ETS) and are visible across tabs, but vanish on server restart or session cleanup. The lifecycle matches the debugging workflow exactly. No migration, no retention policy, no disk I/O. Accepted.

**Cleanup triggers:** session delete, debug toggle off, session process timeout, server restart (ETS table recreated empty).

### RD-4: Assembled Response for Streams — Not Raw SSE Frames

**Decision:** The debug response body for streaming calls is the assembled canonical JSON, not individual SSE frames.

**Rationale:** Raw SSE frames are noisy (dozens to hundreds per response) and provider-specific in format. The useful information is the *result* of the stream — the complete message object with content, tool_use blocks, and usage stats. A "verbose" sub-mode showing individual frames can be added later without changing the current design.

### RD-5: Per-Turn Handler Attach/Detach

**Decision:** Telemetry handlers are attached at the start of an LLM call and detached at the end, not left permanently attached.

**Rationale:** A permanently attached handler would fire for every LLM call across all sessions (telemetry is global). Filtering by session_id in the handler works but wastes cycles. Attach/detach scopes the handler precisely to when it's needed and prevents handler accumulation from leaked references.

---

## 17. Open Questions

None. All design decisions have been resolved through conversation prior to this PRD.
