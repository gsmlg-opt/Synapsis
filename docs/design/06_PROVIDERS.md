# 06 — Provider Integration

## Streaming Architecture

Each provider implements `Synapsis.Provider.Behaviour`. The streaming flow uses Req + Finch for HTTP/2 SSE connections.

```elixir
defmodule Synapsis.Provider.Anthropic do
  @behaviour Synapsis.Provider.Behaviour

  @impl true
  def stream(request, config) do
    caller = self()
    
    task = Task.Supervisor.async_nolink(Synapsis.Provider.TaskSupervisor, fn ->
      Req.post!(
        url: "#{config.base_url}/v1/messages",
        headers: [{"x-api-key", config.api_key}, {"anthropic-version", "2023-06-01"}],
        json: request,
        into: fn {:data, data}, acc ->
          for line <- String.split(data, "\n", trim: true),
              String.starts_with?(line, "data: ") do
            chunk = line |> String.trim_leading("data: ") |> Jason.decode!()
            send(caller, {:provider_chunk, chunk})
          end
          {:cont, acc}
        end
      )
      send(caller, :provider_done)
    end)
    
    {:ok, task.ref}
  end

  @impl true
  def cancel(ref), do: Task.Supervisor.terminate_child(Synapsis.Provider.TaskSupervisor, ref)

  @impl true
  def format_request(messages, tools, opts) do
    %{
      model: opts.model,
      max_tokens: opts[:max_tokens] || 8192,
      system: opts.system_prompt,
      messages: Enum.map(messages, &format_message/1),
      tools: Enum.map(tools, &format_tool/1),
      stream: true
    }
  end
end
```

## Provider Registry

ETS-backed registry for runtime provider lookup and model caching:

```elixir
defmodule Synapsis.Provider.Registry do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def init(:ok) do
    table = :ets.new(:providers, [:named_table, :set, :public, read_concurrency: true])
    {:ok, table}
  end

  def register(provider_name, config) do
    :ets.insert(:providers, {provider_name, config})
  end

  def get(provider_name) do
    case :ets.lookup(:providers, provider_name) do
      [{^provider_name, config}] -> {:ok, config}
      [] -> {:error, :not_found}
    end
  end
end
```

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

## OpenAI-Compatible Provider

Covers OpenAI, local models (Ollama), OpenRouter, Groq, etc:

```elixir
defmodule Synapsis.Provider.OpenAICompat do
  @behaviour Synapsis.Provider.Behaviour
  # Same SSE streaming pattern, different message format
  # base_url configurable: "http://localhost:11434/v1" for Ollama
end
```
