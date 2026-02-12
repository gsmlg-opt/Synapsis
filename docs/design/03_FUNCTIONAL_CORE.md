# 03 — Functional Core

## Pure Functions (no side effects)

### Message Building

```elixir
defmodule Synapsis.MessageBuilder do
  @doc "Build provider-specific request from session history"
  def build_request(messages, agent, provider) do
    %{
      system: agent.system_prompt,
      messages: messages |> Enum.map(&format_message(&1, provider)),
      tools: agent.tools |> Enum.map(&format_tool(&1, provider)),
      model: agent.model,
      stream: true
    }
  end

  @doc "Format a message for a specific provider's API format"
  def format_message(message, :anthropic), do: # ...
  def format_message(message, :openai), do: # ...
end
```

### Context Window Management

```elixir
defmodule Synapsis.ContextWindow do
  @doc "Calculate if compaction is needed"
  def needs_compaction?(messages, model_context_limit, threshold \\ 0.8) do
    total = Enum.sum(Enum.map(messages, & &1.token_count))
    total > model_context_limit * threshold
  end

  @doc "Select messages to keep vs compact"
  def partition_for_compaction(messages, keep_recent: n) do
    {to_compact, to_keep} = Enum.split(messages, length(messages) - n)
    {to_compact, to_keep}
  end
end
```

### Tool Permission Logic

```elixir
defmodule Synapsis.Tool.Permission do
  @auto_approve [:file_read, :grep, :glob, :diagnostics]
  @always_ask [:bash, :file_edit, :file_write]

  def check(tool_name, _session) when tool_name in @auto_approve, do: :approved
  def check(tool_name, _session) when tool_name in @always_ask, do: :requires_approval
  def check(_tool_name, _session), do: :requires_approval
end
```

### Agent Resolution

```elixir
defmodule Synapsis.Agent.Resolver do
  @doc "Merge default agent config with project overrides"
  def resolve(agent_name, project_config) do
    default = default_agent(agent_name)
    overrides = get_in(project_config, ["agents", to_string(agent_name)]) || %{}
    
    %{default |
      model: overrides["model"] || default.model,
      system_prompt: overrides["systemPrompt"] || default.system_prompt,
      tools: resolve_tools(default.tools, overrides["tools"])
    }
  end
end
```

### Config Merging

```elixir
defmodule Synapsis.Config do
  @doc "Merge config layers: defaults < user < project < env"
  def resolve(project_path) do
    defaults()
    |> deep_merge(load_user_config())
    |> deep_merge(load_project_config(project_path))
    |> deep_merge(load_env_overrides())
  end
end
```

### Provider Response Parsing

```elixir
defmodule Synapsis.Provider.Parser do
  @doc "Parse SSE chunk into domain Part structs — pure, no side effects"
  def parse_chunk(data, :anthropic) do
    case data do
      %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => text}} ->
        {:text, text}
      %{"type" => "content_block_delta", "delta" => %{"type" => "input_json_delta"}} ->
        {:tool_input_delta, data["delta"]["partial_json"]}
      %{"type" => "content_block_start", "content_block" => %{"type" => "tool_use"} = block} ->
        {:tool_use_start, block["name"], block["id"]}
      %{"type" => "message_stop"} ->
        :done
      _ ->
        :ignore
    end
  end
end
```
