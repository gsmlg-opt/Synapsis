defmodule Synapsis.Provider.OpenAICompat do
  @moduledoc """
  OpenAI-compatible provider. Covers OpenAI, Ollama, OpenRouter, Groq, etc.
  Uses configurable base_url.
  """
  @behaviour Synapsis.Provider.Behaviour

  alias Synapsis.Provider.Parser

  @default_base_url "https://api.openai.com"

  @impl true
  def stream(request, config) do
    caller = self()
    base_url = config[:base_url] || @default_base_url

    task =
      Task.Supervisor.async_nolink(Synapsis.Provider.TaskSupervisor, fn ->
        url = "#{base_url}/v1/chat/completions"

        headers =
          [{"content-type", "application/json"}] ++
            if config[:api_key] do
              [{"authorization", "Bearer #{config.api_key}"}]
            else
              []
            end

        try do
          Req.post!(url,
            headers: headers,
            json: request,
            receive_timeout: 300_000,
            into: fn {:data, data}, acc ->
              for chunk <- Parser.parse_sse_lines(data) do
                event = Parser.parse_chunk(chunk, :openai)
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
    base_url = config[:base_url] || @default_base_url

    case Req.get("#{base_url}/v1/models",
           headers:
             if(config[:api_key], do: [{"authorization", "Bearer #{config.api_key}"}], else: [])
         ) do
      {:ok, %{status: 200, body: %{"data" => models}}} ->
        {:ok,
         Enum.map(models, fn m ->
           %{id: m["id"], name: m["id"], context_window: m["context_length"] || 128_000}
         end)}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def format_request(messages, tools, opts) do
    request = %{
      model: opts[:model] || "gpt-4o",
      stream: true,
      messages: format_messages(messages, opts)
    }

    case tools do
      [] -> request
      tools -> Map.put(request, :tools, Enum.map(tools, &format_tool/1))
    end
  end

  defp format_messages(messages, opts) do
    system_messages =
      case opts[:system_prompt] do
        nil -> []
        prompt -> [%{role: "system", content: prompt}]
      end

    system_messages ++ Enum.map(messages, &format_message/1)
  end

  defp format_message(%{role: role, parts: parts}) do
    content = parts |> Enum.map(&format_content/1) |> merge_text_content()
    %{role: to_string(role), content: content}
  end

  defp format_message(%{"role" => role, "parts" => parts}) do
    content = parts |> Enum.map(&format_content/1) |> merge_text_content()
    %{role: role, content: content}
  end

  defp format_content(%Synapsis.Part.Text{content: content}), do: content
  defp format_content(%Synapsis.Part.ToolResult{content: content}), do: content
  defp format_content(%{content: content}), do: to_string(content)

  defp merge_text_content(parts) do
    case parts do
      [single] when is_binary(single) -> single
      parts -> Enum.join(parts, "\n")
    end
  end

  defp format_tool(tool) do
    %{
      type: "function",
      function: %{
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters
      }
    }
  end
end
