# 06 — Provider Integration

## Architecture Overview

The provider layer uses an **Anthropic Messages API-shaped internal contract** as
the canonical event format. All providers — Anthropic, OpenAI (and compatibles),
and Google Gemini — are handled by a single unified `Adapter` module that delegates
to per-provider transport plugins and pure-function mappers.

### Module Topology

```
apps/synapsis_provider/lib/synapsis/provider/
  adapter.ex            # unified entry: stream/2, cancel/1, models/1, format_request/3
  event_mapper.ex       # raw provider JSON → Anthropic-shaped event tuples
  message_mapper.ex     # Part.* structs → provider-specific wire format
  model_registry.ex     # static model metadata: capabilities, context windows
  registry.ex           # ETS-backed runtime config store
  retry.ex              # exponential backoff for 429/5xx

  transport/
    anthropic.ex        # Anthropic Messages API specifics
    openai.ex           # OpenAI chat completions + all compat (Ollama, OpenRouter, Groq, etc.)
    google.ex           # Gemini API specifics
    sse.ex              # shared SSE line parser
```

## Streaming Architecture

All providers stream through the unified `Synapsis.Provider.Adapter`. The adapter
resolves the transport type from the provider config, builds the HTTP request, parses
SSE chunks, maps them to canonical events, and sends them to the caller process.

```elixir
defmodule Synapsis.Provider.Adapter do
  def stream(request, config) do
    caller = self()
    transport_type = resolve_transport_type(config[:type])

    task = Task.Supervisor.async_nolink(Synapsis.Provider.TaskSupervisor, fn ->
      # HTTP streaming with SSE parsing and event mapping inline
      do_stream(transport_type, request, config, caller)
    end)

    {:ok, task.ref}
  end

  def cancel(ref) do
    Task.Supervisor.terminate_child(Synapsis.Provider.TaskSupervisor, ref)
    :ok
  end

  def format_request(messages, tools, opts) do
    provider_type = resolve_transport_type(opts[:provider_type])
    MessageMapper.build_request(provider_type, messages, tools, opts)
  end
end
```

### Transport Resolution

The adapter maps provider type strings to transport atoms:

| Config Type                                          | Transport |
|------------------------------------------------------|-----------|
| `"anthropic"`                                         | `:anthropic` |
| `"openai"`, `"openai_compat"`, `"local"`, `"openrouter"`, `"groq"`, `"deepseek"` | `:openai` |
| `"google"`                                            | `:google` |

## Internal Event Protocol

`Session.Worker` receives these canonical Anthropic-shaped events via
`handle_info({:provider_chunk, event}, state)`. The adapter emits the exact same
event shapes regardless of which provider is being used.

```elixir
# Text streaming
:text_start
{:text_delta, text}

# Tool use
{:tool_use_start, tool_name, tool_use_id}
{:tool_input_delta, partial_json}
{:tool_use_complete, name, args}       # Google sends complete tool calls

# Extended thinking / reasoning
:reasoning_start
{:reasoning_delta, text}

# Block lifecycle
:content_block_stop

# Message lifecycle
:message_start
{:message_delta, delta_map}
:done

# Errors
{:error, error_map}
:ignore
```

The adapter also sends lifecycle signals to the caller:
- `{:provider_chunk, event}` — for each SSE event
- `:provider_done` — stream completed
- `{:provider_error, reason}` — stream failed

## Event Mapper

`Synapsis.Provider.EventMapper` contains pure functions that normalize raw decoded
JSON from each provider into the canonical event tuples:

- **Anthropic**: Mostly passthrough — already the canonical format
- **OpenAI**: `choices[0].delta.content` → `{:text_delta, text}`, `tool_calls` → `{:tool_use_start, ...}` / `{:tool_input_delta, ...}`, `reasoning_content` → `{:reasoning_delta, text}`
- **Google**: `candidates[0].content.parts[0].text` → `{:text_delta, text}`, `functionCall` → `{:tool_use_complete, name, args}` (atomic, not streamed)

## Message Mapper

`Synapsis.Provider.MessageMapper` converts `Part.*` domain structs into
provider-specific wire format:

- **Anthropic**: `{role, content: [blocks]}` with `text`, `tool_use`, `tool_result` blocks; top-level `system` field; tools as `{name, description, input_schema}`
- **OpenAI**: `{role, content: "text"}` (merged text); system prompt as first message; tools as `{type: "function", function: {name, description, parameters}}`
- **Google**: `{role, parts: []}` with role mapping (`assistant` → `model`); `systemInstruction` field; tools as `{functionDeclarations: [...]}`

## Model Registry

`Synapsis.Provider.ModelRegistry` provides static metadata for known models:

```elixir
%{
  id: "claude-sonnet-4-20250514",
  name: "Claude Sonnet 4",
  provider: "anthropic",
  context_window: 200_000,
  max_output_tokens: 64_000,
  supports_tools: true,
  supports_thinking: true,
  supports_images: true,
  supports_streaming: true
}
```

For Anthropic and Google, models are returned from the static registry. For OpenAI
(and compatibles), models are fetched dynamically from the `/v1/models` endpoint.

## Provider Registry

ETS-backed GenServer for runtime provider lookup and config caching:

```elixir
defmodule Synapsis.Provider.Registry do
  use GenServer

  def register(provider_name, config), do: :ets.insert(@table, {provider_name, config})
  def get(provider_name), do: # lookup from ETS
  def module_for(provider_name), do: {:ok, Synapsis.Provider.Adapter}  # always returns Adapter
end
```

`module_for/1` always returns `Synapsis.Provider.Adapter` for known provider types.
The adapter internally resolves the transport based on the config's `:type` field.

## Error Handling & Retry

```elixir
defmodule Synapsis.Provider.Retry do
  @max_retries 3
  @backoff_base 1_000  # ms

  def with_retry(fun, retries \\ @max_retries) do
    case fun.() do
      {:ok, result} -> {:ok, result}
      {:error, %{status: status}} when status in [429, 500, 502, 503] and retries > 0 ->
        backoff = @backoff_base * (@max_retries - retries + 1)
        Process.sleep(backoff)
        with_retry(fun, retries - 1)
      {:error, reason} -> {:error, reason}
    end
  end
end
```

## SSE Parser

`Synapsis.Provider.Transport.SSE` provides shared pure functions for parsing
Server-Sent Events data, used by all transports:

```elixir
SSE.parse_lines("data: {\"type\":\"text_delta\"}\ndata: [DONE]\n")
# => [%{"type" => "text_delta"}, "[DONE]"]
```

## Transport Plugins

Each transport module handles provider-specific HTTP concerns:

- **`Transport.Anthropic`**: URL `{base_url}/v1/messages`, `x-api-key` header, `anthropic-version: 2023-06-01`
- **`Transport.OpenAI`**: URL `{base_url}/v1/chat/completions`, `Authorization: Bearer` header (optional for local models), Azure URL pattern support
- **`Transport.Google`**: URL `{base_url}/v1beta/models/{model}:streamGenerateContent?alt=sse&key={api_key}`
