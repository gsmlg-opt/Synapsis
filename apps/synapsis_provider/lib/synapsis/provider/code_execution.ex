defmodule Synapsis.Provider.CodeExecution do
  @moduledoc "xAI remote code-interpreter requests and complete text/citation results, without a local executor."

  alias Synapsis.Provider.WebSearch.Transport
  alias Synapsis.Provider.XAI.Responses

  def prepare(config, arguments) when is_map(config) and is_map(arguments) do
    case string(arguments["task"]) do
      nil ->
        invalid("task", "Code execution requires an analysis task")

      task ->
        model = Responses.normalize_model(string(config[:model]) || "grok-4.7")

        # The pinned standalone tool uses api.x.ai. The host's explicit endpoint
        # is a transport setting for configured proxies and local HTTP fixtures.
        endpoint =
          String.trim_trailing(string(config[:base_url]) || "https://api.x.ai/v1", "/") <>
            "/responses"

        body =
          %{
            "model" => model,
            "input" => [%{"role" => "user", "content" => task}],
            "tools" => [%{"type" => "code_interpreter"}],
            "store" => false
          }
          |> optional("reasoning", Responses.reasoning(model, "low"))
          |> optional("max_turns", positive_integer(config[:max_turns]))

        {:ok,
         %{
           endpoint: endpoint,
           body: body,
           timeout_ms: timeout(config[:timeout_ms]),
           task: task,
           model: model
         }}
    end
  end

  def prepare(_, _), do: invalid("arguments", "Code execution arguments are unavailable")

  def execute(config, prepared) do
    started = System.monotonic_time(:millisecond)

    with {:ok, payload} <-
           Transport.json(
             :post,
             prepared.endpoint,
             [
               {"content-type", "application/json"},
               {"authorization", "Bearer " <> config.api_key}
             ],
             prepared.body,
             prepared.timeout_ms
           ),
         {:ok, answer} <- Responses.parse(payload) do
      types = output_types(payload["output"])

      {:ok,
       %{
         "task" => prepared.task,
         "provider" => "xai",
         "model" => prepared.model,
         "tookMs" => System.monotonic_time(:millisecond) - started,
         "content" => answer["content"],
         "citations" => answer["citations"],
         "usedCodeExecution" => "code_interpreter_call" in types,
         "outputTypes" => types
       }}
    end
  end

  defp output_types(output) when is_list(output) do
    output
    |> Enum.flat_map(fn
      %{"type" => type} when is_binary(type) and type != "" -> [type]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp output_types(_), do: []

  defp timeout(value) when is_number(value) and value > 0,
    do: value |> floor() |> max(1) |> min(2_147_000_000)

  defp timeout(_), do: 30_000
  defp positive_integer(value) when is_number(value) and value >= 1, do: floor(value)
  defp positive_integer(_), do: nil

  defp string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp string(_), do: nil
  defp optional(map, _, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp invalid(code, message), do: {:error, {:invalid_arguments, code, message}}
end
