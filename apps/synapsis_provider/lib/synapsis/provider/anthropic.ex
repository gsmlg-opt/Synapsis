defmodule Synapsis.Provider.Anthropic do
  @moduledoc "Anthropic Claude provider - streaming SSE via Messages API."
  @behaviour Synapsis.Provider.Behaviour

  alias Synapsis.Provider.Parser

  @default_base_url "https://api.anthropic.com"
  @api_version "2023-06-01"

  @impl true
  def stream(request, config) do
    caller = self()
    base_url = config[:base_url] || @default_base_url

    task =
      Task.Supervisor.async_nolink(Synapsis.Provider.TaskSupervisor, fn ->
        url = "#{base_url}/v1/messages"

        headers = [
          {"x-api-key", config.api_key},
          {"anthropic-version", @api_version},
          {"content-type", "application/json"}
        ]

        try do
          Req.post!(url,
            headers: headers,
            json: request,
            receive_timeout: 300_000,
            into: fn {:data, data}, acc ->
              for chunk <- Parser.parse_sse_lines(data) do
                event = Parser.parse_chunk(chunk, :anthropic)
                send(caller, {:provider_chunk, event})
              end

              {:cont, acc}
            end
          )

          send(caller, :provider_done)
        rescue
          e ->
            send(caller, {:provider_error, Exception.message(e)})
        end
      end)

    {:ok, task.ref}
  end

  @impl true
  def cancel(ref) do
    Task.Supervisor.terminate_child(Synapsis.Provider.TaskSupervisor, ref)
    :ok
  end

  @impl true
  def models(config) do
    _base_url = config[:base_url] || @default_base_url

    {:ok,
     [
       %{id: "claude-sonnet-4-20250514", name: "Claude Sonnet 4", context_window: 200_000},
       %{id: "claude-opus-4-20250514", name: "Claude Opus 4", context_window: 200_000},
       %{id: "claude-haiku-3-5-20241022", name: "Claude 3.5 Haiku", context_window: 200_000}
     ]}
  end

  @impl true
  def format_request(messages, tools, opts) do
    request = %{
      model: opts[:model] || "claude-sonnet-4-20250514",
      max_tokens: opts[:max_tokens] || 8192,
      stream: true,
      messages: Enum.map(messages, &format_message/1)
    }

    request =
      case opts[:system_prompt] do
        nil -> request
        prompt -> Map.put(request, :system, prompt)
      end

    case tools do
      [] -> request
      tools -> Map.put(request, :tools, Enum.map(tools, &format_tool/1))
    end
  end

  defp format_message(%{role: role, parts: parts}) do
    %{role: to_string(role), content: Enum.map(parts, &format_content/1)}
  end

  defp format_message(%{"role" => role, "parts" => parts}) do
    %{role: role, content: Enum.map(parts, &format_content/1)}
  end

  defp format_content(%Synapsis.Part.Text{content: content}) do
    %{type: "text", text: content}
  end

  defp format_content(%Synapsis.Part.ToolUse{tool: tool, tool_use_id: id, input: input}) do
    %{type: "tool_use", id: id, name: tool, input: input}
  end

  defp format_content(%Synapsis.Part.ToolResult{
         tool_use_id: id,
         content: content,
         is_error: is_error
       }) do
    %{type: "tool_result", tool_use_id: id, content: content, is_error: is_error}
  end

  defp format_content(%Synapsis.Part.Reasoning{content: content}) do
    %{type: "text", text: "[thinking] #{content}"}
  end

  defp format_content(%{content: content}) do
    %{type: "text", text: to_string(content)}
  end

  defp format_tool(tool) do
    %{
      name: tool.name,
      description: tool.description,
      input_schema: tool.parameters
    }
  end
end
