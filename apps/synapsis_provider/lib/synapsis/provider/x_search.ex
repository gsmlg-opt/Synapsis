defmodule Synapsis.Provider.XSearch do
  @moduledoc "xAI Responses X-search requests and portable, UTF-16 bounded answer results."

  alias Synapsis.Provider.WebSearch.Transport
  alias Synapsis.Provider.XAI.Responses

  @content_limit 20_000
  def prepare(config, arguments) when is_map(config) and is_map(arguments) do
    query = string(arguments["query"])
    allowed = handles(arguments["allowed_x_handles"])
    excluded = handles(arguments["excluded_x_handles"])

    with true <- is_binary(query),
         :ok <- validate_handles(allowed, excluded),
         {:ok, from} <- date(arguments["from_date"], "from_date"),
         {:ok, to} <- date(arguments["to_date"], "to_date"),
         true <- is_nil(from) or is_nil(to) or from <= to do
      model = Responses.normalize_model(string(config[:model]) || "grok-4.7")

      endpoint =
        String.trim_trailing(string(config[:base_url]) || "https://api.x.ai/v1", "/") <>
          "/responses"

      options =
        %{}
        |> optional("allowed_x_handles", allowed)
        |> optional("excluded_x_handles", excluded)
        |> optional("from_date", from)
        |> optional("to_date", to)
        |> enabled("enable_image_understanding", arguments["enable_image_understanding"])
        |> enabled("enable_video_understanding", arguments["enable_video_understanding"])

      body =
        %{
          "model" => model,
          "input" => [%{"role" => "user", "content" => query}],
          "tools" => [Map.put(options, "type", "x_search")],
          "store" => false
        }
        |> optional("reasoning", Responses.reasoning(model, "none"))
        |> optional("max_turns", positive_integer(config[:max_turns]))

      {:ok,
       %{
         endpoint: endpoint,
         body: body,
         timeout_ms: timeout(config[:timeout_ms]),
         inline_citations: config[:inline_citations] === true,
         query: query,
         model: model,
         options: options
       }}
    else
      false -> invalid("query_or_date", "X search requires a query and an ordered date range")
      error -> error
    end
  end

  def prepare(_, _), do: invalid("arguments", "X search arguments are unavailable")

  def search(config, prepared) do
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
         {:ok, answer} <-
           Responses.parse(payload,
             content_limit: @content_limit,
             inline_citations: prepared.inline_citations
           ) do
      result =
        %{
          "query" => prepared.query,
          "provider" => "xai",
          "model" => prepared.model,
          "tookMs" => System.monotonic_time(:millisecond) - started
        }
        |> Map.merge(answer)

      {:ok,
       Enum.reduce(prepared.options, result, fn {key, value}, result ->
         Map.put(result, public_key(key), value)
       end)}
    end
  end

  defp validate_handles(allowed, excluded) do
    cond do
      allowed && excluded ->
        invalid("handles", "X search handle filters cannot be combined")

      length(allowed || []) > 20 or length(excluded || []) > 20 ->
        invalid("handles", "X search accepts at most twenty handles")

      true ->
        :ok
    end
  end

  defp handles(values) do
    values = values |> List.wrap() |> Enum.map(&string/1) |> Enum.reject(&is_nil/1)
    if values == [], do: nil, else: values
  end

  defp date(value, key) do
    case string(value) do
      nil ->
        {:ok, nil}

      value ->
        if Regex.match?(~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/, value) and
             match?({:ok, _}, Date.from_iso8601(value)),
           do: {:ok, value},
           else: invalid(key, "X search dates must be valid YYYY-MM-DD calendar dates")
    end
  end

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
  defp enabled(map, key, true), do: Map.put(map, key, true)
  defp enabled(map, _, _), do: map
  defp public_key("allowed_x_handles"), do: "allowedXHandles"
  defp public_key("excluded_x_handles"), do: "excludedXHandles"
  defp public_key("from_date"), do: "fromDate"
  defp public_key("to_date"), do: "toDate"
  defp public_key("enable_image_understanding"), do: "enableImageUnderstanding"
  defp public_key("enable_video_understanding"), do: "enableVideoUnderstanding"
  defp invalid(code, message), do: {:error, {:invalid_arguments, code, message}}
end
