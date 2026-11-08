defmodule Synapsis.Provider.WebSearch.Grok do
  @moduledoc "xAI Responses web search requests and raw ordered answer results."

  alias Synapsis.Provider.XAI.Responses

  @default_base "https://api.x.ai/v1"
  @default_model "grok-4.7"
  @content_limit 20_000

  @doc "Canonicalize the configured root before appending the Responses route."
  def endpoint(base), do: {:ok, String.trim_trailing(trim(base) || @default_base, "/")}

  def prepare_config(config) do
    with {:ok, base} <- endpoint(config[:base_url]) do
      {:ok,
       config
       |> Map.put(:base_url, base)
       |> Map.put(:model, Responses.normalize_model(trim(config[:model]) || @default_model))
       |> Map.put(:inline_citations, config[:inline_citations] === true)}
    end
  end

  def prepare(_config, arguments) do
    query = trim(arguments["query"])

    if is_binary(query) and valid_count?(arguments["count"]),
      do: {:ok, %{"query" => query}},
      else:
        {:error,
         {:invalid_arguments, "invalid_grok_options",
          "Grok search requires a query and an optional count from 1 to 10"}}
  end

  def request(config, args) do
    with {:ok, config} <- prepare_config(config) do
      body = %{
        "model" => config.model,
        "input" => [%{"role" => "user", "content" => args["query"]}],
        "tools" => [%{"type" => "web_search"}],
        "store" => false
      }

      body =
        case Responses.reasoning(config.model, "low") do
          nil -> body
          reasoning -> Map.put(body, "reasoning", reasoning)
        end

      {:ok, :post, config.base_url <> "/responses",
       [
         {"accept", "application/json"},
         {"authorization", "Bearer " <> config.api_key},
         {"content-type", "application/json"}
       ], body}
    end
  end

  def result(config, _args, payload) do
    with {:ok, config} <- prepare_config(config),
         {:ok, answer} <-
           Responses.parse(payload,
             content_limit: @content_limit,
             inline_citations: config.inline_citations
           ) do
      {:ok, Map.put(answer, "model", config.model)}
    end
  end

  defp valid_count?(value) when value in [nil, ""], do: true

  defp valid_count?(value) when is_number(value),
    do: value >= 1 and value <= 10 and trunc(value) == value

  defp valid_count?(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      true
    else
      if Regex.match?(~r/\A[+-]?(?:(?:[0-9]+\.?[0-9]*)|(?:\.[0-9]+))(?:e[+-]?[0-9]+)?\z/i, value) do
        value = Regex.replace(~r/\A([+-]?)\./, value, fn _, sign -> sign <> "0." end)
        value = Regex.replace(~r/\.(?=e|\z)/i, value, ".0")

        case Float.parse(value) do
          {number, ""} -> valid_count?(number)
          _ -> false
        end
      else
        false
      end
    end
  end

  defp valid_count?(_), do: false

  defp trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp trim(_), do: nil
end
