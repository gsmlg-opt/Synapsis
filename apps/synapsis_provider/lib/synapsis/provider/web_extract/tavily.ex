defmodule Synapsis.Provider.WebExtract.Tavily do
  @moduledoc "Tavily extraction request format and bounded, ordered portable results."

  alias Synapsis.Provider.WebSearch.{TextBudget, Transport}

  @response_limit 64 * 1024 * 1024
  @row_limit 20
  @content_limit 20_000
  @error_limit 4_000

  def prepare(_config, arguments) when is_map(arguments) do
    urls = arguments["urls"]
    query = trim(arguments["query"])
    depth = trim(arguments["extract_depth"])
    chunks = arguments["chunks_per_source"]

    cond do
      not is_list(urls) or length(urls) not in 1..20 or
          not Enum.all?(urls, &is_binary/1) ->
        invalid("invalid_urls", "urls must contain between one and twenty URL strings")

      Enum.all?(urls, &(String.trim(&1) == "")) ->
        invalid("invalid_urls", "tavily_extract requires at least one URL.")

      depth not in [nil, "basic", "advanced"] ->
        invalid("invalid_extract_depth", "extract_depth must be basic or advanced")

      not is_nil(chunks) and (not is_integer(chunks) or chunks not in 1..5) ->
        invalid("invalid_chunks_per_source", "chunks_per_source must be an integer from 1 to 5.")

      not is_nil(chunks) and is_nil(query) ->
        invalid("missing_query", "tavily_extract requires query when chunks_per_source is set.")

      true ->
        {:ok,
         %{"urls" => urls |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))}
         |> optional("query", query)
         |> optional("extract_depth", depth)
         |> optional("chunks_per_source", chunks)
         |> optional("include_images", if(arguments["include_images"] == true, do: true))}
    end
  end

  def extract(config, arguments) do
    with {:ok, body} <- prepare(config, arguments) do
      start = System.monotonic_time(:millisecond)

      headers = [
        {"accept", "application/json"},
        {"authorization", "Bearer " <> config.api_key},
        {"content-type", "application/json"},
        {"x-client-source", "openclaw"}
      ]

      with {:ok, payload} <-
             Transport.json(
               :post,
               endpoint(config.base_url),
               headers,
               body,
               Map.get(config, :timeout_ms, 60_000),
               max_bytes: @response_limit
             ) do
        {:ok,
         payload |> result() |> Map.put("tookMs", System.monotonic_time(:millisecond) - start)}
      end
    end
  end

  defp endpoint(base_url) do
    uri = URI.parse(base_url)
    path = String.replace(uri.path || "", ~r/\/$/, "") <> "/extract"
    URI.to_string(%{uri | path: path})
  end

  defp result(payload) do
    raw = list(payload["results"])
    state = %{content: @content_limit, images: @row_limit, truncated: length(raw) > @row_limit}

    {results, state} =
      raw |> Enum.take(@row_limit) |> Enum.map_reduce(state, &row/2)

    results = Enum.reject(results, &is_nil/1)
    failed = list(payload["failed_results"])
    state = %{state | truncated: state.truncated or length(failed) > @row_limit}

    {failures, {_, truncated}} =
      failed
      |> Enum.take(@row_limit)
      |> Enum.map_reduce({@error_limit, state.truncated}, &failed_row/2)

    failures = Enum.reject(failures, &is_nil/1)

    %{"provider" => "tavily", "count" => length(results), "results" => results}
    |> optional("failedResults", if(failures != [], do: failures))
    |> optional("truncated", if(truncated, do: true))
  end

  defp row(entry, state) when is_map(entry) do
    case canonical_url(entry["url"]) do
      nil ->
        {nil, state}

      url ->
        {images, state} = images(entry["images"], state)
        {raw, state} = content(entry["raw_content"], state)
        {content, state} = content(entry["content"], state)
        result = %{"url" => url, "rawContent" => raw || ""}
        {result |> optional("content", content) |> optional("images", images), state}
    end
  end

  defp row(_, state), do: {nil, state}

  defp images(raw, state) when is_list(raw) do
    images =
      raw |> Enum.take(state.images) |> Enum.map(&canonical_url/1) |> Enum.reject(&is_nil/1)

    {images,
     %{
       state
       | images: state.images - length(images),
         truncated: state.truncated or length(raw) > state.images
     }}
  end

  defp images(_, state), do: {nil, state}

  defp content(value, state) when is_binary(value) do
    {text, used} = TextBudget.take(value, state.content)
    {text, %{state | content: state.content - used, truncated: state.truncated or text != value}}
  end

  defp content(_, state), do: {nil, state}

  defp failed_row(entry, {left, cut}) when is_map(entry) do
    url = canonical_url(entry["url"])
    error = entry["error"]

    if url && is_binary(error) do
      {text, used} = TextBudget.take(error, left)
      {%{"url" => url, "error" => text}, {left - used, cut or text != error}}
    else
      {nil, {left, cut}}
    end
  end

  defp failed_row(_, state), do: {nil, state}

  # URI covers the ordinary ASCII HTTP(S) cases. Full WHATWG and source
  # external-content sanitation/framing remain outside this portable projection.
  defp canonical_url(value) when is_binary(value) do
    if TextBudget.units(value) <= 2048 do
      uri = value |> String.trim() |> URI.parse()
      scheme = if is_binary(uri.scheme), do: String.downcase(uri.scheme)

      if scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
        normalized = %{
          uri
          | scheme: scheme,
            host: String.downcase(uri.host),
            path: uri.path || "/"
        }

        url = normalized |> URI.to_string() |> URI.encode(&(&1 > 32 and &1 < 127))
        if TextBudget.units(url) <= 2048, do: if(url == value <> "/", do: value, else: url)
      end
    end
  end

  defp canonical_url(_), do: nil
  defp list(value) when is_list(value), do: value
  defp list(_), do: []

  defp trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp trim(_), do: nil
  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp invalid(code, message), do: {:error, {:invalid_arguments, code, message}}
end
