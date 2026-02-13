defmodule Synapsis.Provider.Google do
  @moduledoc "Google Gemini provider - streaming."
  @behaviour Synapsis.Provider.Behaviour

  alias Synapsis.Provider.Parser

  @default_base_url "https://generativelanguage.googleapis.com"

  @impl true
  def stream(request, config) do
    caller = self()
    base_url = config[:base_url] || @default_base_url
    model = request[:model] || "gemini-2.0-flash"

    task =
      Task.Supervisor.async_nolink(Synapsis.Provider.TaskSupervisor, fn ->
        url =
          "#{base_url}/v1beta/models/#{model}:streamGenerateContent?alt=sse&key=#{config.api_key}"

        body = Map.drop(request, [:model, :stream])

        try do
          Req.post!(url,
            headers: [{"content-type", "application/json"}],
            json: body,
            receive_timeout: 300_000,
            into: fn {:data, data}, acc ->
              for chunk <- Parser.parse_sse_lines(data) do
                event = Parser.parse_chunk(chunk, :google)
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
  def models(_config) do
    {:ok,
     [
       %{id: "gemini-2.0-flash", name: "Gemini 2.0 Flash", context_window: 1_000_000},
       %{id: "gemini-2.5-pro-preview-05-06", name: "Gemini 2.5 Pro", context_window: 1_000_000},
       %{
         id: "gemini-2.5-flash-preview-05-20",
         name: "Gemini 2.5 Flash",
         context_window: 1_000_000
       }
     ]}
  end

  @impl true
  def format_request(messages, tools, opts) do
    request = %{
      model: opts[:model] || "gemini-2.0-flash",
      stream: true,
      contents: Enum.map(messages, &format_message/1)
    }

    request =
      case opts[:system_prompt] do
        nil -> request
        prompt -> Map.put(request, :systemInstruction, %{parts: [%{text: prompt}]})
      end

    case tools do
      [] ->
        request

      tools ->
        Map.put(request, :tools, [%{functionDeclarations: Enum.map(tools, &format_tool/1)}])
    end
  end

  defp format_message(%{role: role, parts: parts}) do
    google_role = if to_string(role) == "assistant", do: "model", else: "user"
    %{role: google_role, parts: Enum.map(parts, &format_content/1)}
  end

  defp format_message(%{"role" => role, "parts" => parts}) do
    google_role = if role == "assistant", do: "model", else: "user"
    %{role: google_role, parts: Enum.map(parts, &format_content/1)}
  end

  defp format_content(%Synapsis.Part.Text{content: content}), do: %{text: content}
  defp format_content(%{content: content}), do: %{text: to_string(content)}

  defp format_tool(tool) do
    %{
      name: tool.name,
      description: tool.description,
      parameters: tool.parameters
    }
  end
end
