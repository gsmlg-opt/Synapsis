defmodule Synapsis.Provider.WebSearch.DuckDuckGo do
  @moduledoc "DuckDuckGo HTML requests and ordered results before shared generic projection."

  alias Synapsis.Provider.WebSearch.Transport

  @endpoint "https://html.duckduckgo.com/html"
  @safe_search %{"strict" => "1", "moderate" => "-1", "off" => "-2"}
  @result ~r/<a\b(?=[^>]*\bclass="[^"]*\bresult__a\b[^"]*")([^>]*)>([\s\S]*?)<\/a>/i
  @next_result ~r/<a\b(?=[^>]*\bclass="[^"]*\bresult__a\b[^"]*")[^>]*>/i
  @snippet ~r/<a\b(?=[^>]*\bclass="[^"]*\bresult__snippet\b[^"]*")[^>]*>([\s\S]*?)<\/a>/i
  @entities ~r/&(?:lt|gt|quot|apos|#39|#x27|#x2F|nbsp|ndash|mdash|hellip|amp|#\d+|#x[0-9a-f]+);/i
  @named %{
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "nbsp" => "\u00A0",
    "ndash" => "–",
    "mdash" => "—",
    "hellip" => "…",
    "amp" => "&"
  }
  @entity_text %{"\u00A0" => " ", "–" => "-", "—" => "--", "…" => "..."}
  @whitespace ~r/[\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+/u

  @doc "Normalize the complete HTML endpoint without appending a path or changing its identity."
  def endpoint(nil), do: {:ok, @endpoint}

  def endpoint(base_url) do
    with value when is_binary(value) <- trim(base_url),
         %URI{scheme: scheme, host: host} <- URI.parse(value),
         true <- scheme in ["http", "https"] and is_binary(host) and host != "" do
      {:ok, value}
    else
      _ -> invalid("DuckDuckGo requires an HTTP or HTTPS endpoint")
    end
  end

  def prepare_config(config) do
    with {:ok, endpoint} <- endpoint(config[:base_url]) do
      {:ok,
       config
       |> Map.put(:base_url, endpoint)
       |> Map.put(:region, trim(config[:region]))
       |> Map.put(:safe_search, configured_safe_search(config[:safe_search]))}
    end
  end

  def prepare(config, arguments) do
    query = trim(arguments["query"])

    with true <- is_binary(query),
         {:ok, count} <- count(arguments["count"]) do
      safe_search = trim(arguments["safeSearch"])

      safe_search =
        if safe_search in ["strict", "moderate", "off"],
          do: safe_search,
          else: configured_safe_search(config[:safe_search])

      {:ok,
       %{"query" => query, "count" => count, "safeSearch" => safe_search}
       |> optional("region", trim(arguments["region"]) || trim(config[:region]))}
    else
      _ -> invalid("DuckDuckGo search requires a query and a count from 1 to 10")
    end
  end

  def request(config, args) do
    with {:ok, endpoint} <- endpoint(config[:base_url]) do
      query = [{"q", args["query"]}]
      query = if args["region"], do: query ++ [{"kl", args["region"]}], else: query
      query = query ++ [{"kp", Map.fetch!(@safe_search, args["safeSearch"])}]
      url = URI.parse(endpoint) |> Map.put(:query, URI.encode_query(query)) |> URI.to_string()

      user_agent =
        "synapsis-duckduckgo/#{Application.spec(:synapsis_provider, :vsn)} (+https://github.com/gsmlg-opt/Synapsis)"

      {:ok, :get, url, [{"user-agent", user_agent}], nil}
    end
  end

  def fetch(config, args) do
    with {:ok, method, url, headers, body} <- request(config, args),
         do: Transport.text(method, url, headers, body, config.timeout_ms)
  end

  def result(_config, args, html) when is_binary(html) do
    results =
      @result
      |> Regex.scan(html, return: :index)
      |> Stream.map(fn [{start, length}, attributes, title] ->
        raw_attributes = binary_part(html, elem(attributes, 0), elem(attributes, 1))
        raw_title = binary_part(html, elem(title, 0), elem(title, 1))
        trailing = binary_part(html, start + length, byte_size(html) - start - length)

        scoped =
          case Regex.run(@next_result, trailing, return: :index) do
            [{next, _}] -> binary_part(trailing, 0, next)
            _ -> trailing
          end

        raw_url = capture(~r/\bhref="([^"]*)"/i, raw_attributes)
        snippet = capture(@snippet, scoped) |> prose()
        url = raw_url |> decode_entities() |> unwrap_url()

        %{"title" => prose(raw_title), "url" => url, "snippet" => snippet}
        |> optional("siteName", site(url))
      end)
      |> Stream.filter(&(&1["title"] != "" and &1["url"] != ""))
      |> Enum.take(args["count"])

    {:ok, %{"results" => results, "count" => length(results)}}
  end

  def result(_config, _args, _payload), do: {:error, :provider_response}

  defp capture(regex, value) do
    case Regex.run(regex, value) do
      [_, captured] -> captured
      _ -> ""
    end
  end

  defp prose(html) do
    html
    |> then(&Regex.replace(~r/<\/?b\b[^>]*>/i, &1, ""))
    |> then(&Regex.replace(~r/<[^>]+>/, &1, " "))
    |> then(&Regex.replace(@whitespace, &1, " "))
    |> String.trim()
    |> decode_entities()
  end

  defp decode_entities(text) do
    Regex.replace(@entities, text, fn entity ->
      decoded = decode_entity(entity)
      Map.get(@entity_text, decoded, decoded)
    end)
  end

  defp decode_entity("&#" <> rest = entity) do
    token = String.trim_trailing(rest, ";")

    {digits, base} =
      case token do
        <<prefix, digits::binary>> when prefix in [?x, ?X] -> {digits, 16}
        _ -> {token, 10}
      end

    case Integer.parse(digits, base) do
      {scalar, ""} when scalar >= 0 and scalar <= 0x10FFFF and scalar not in 0xD800..0xDFFF ->
        <<scalar::utf8>>

      _ ->
        entity
    end
  end

  defp decode_entity(entity) do
    name = entity |> String.trim_leading("&") |> String.trim_trailing(";") |> String.downcase()
    Map.fetch!(@named, name)
  end

  defp unwrap_url(url) do
    normalized = if String.starts_with?(url, "//"), do: "https:" <> url, else: url
    parsed = URI.parse(normalized)

    if is_binary(parsed.scheme) and is_binary(parsed.host) and is_binary(parsed.query) do
      case parsed.query |> URI.query_decoder() |> Enum.find(fn {key, _} -> key == "uddg" end) do
        {_, target} when target != "" -> target
        _ -> url
      end
    else
      url
    end
  end

  defp site(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        String.downcase(host)

      _ ->
        nil
    end
  end

  defp configured_safe_search(value) do
    case value |> trim() |> then(&if(is_binary(&1), do: String.downcase(&1), else: nil)) do
      value when value in ["strict", "off"] -> value
      _ -> "moderate"
    end
  end

  defp count(raw) when raw in [nil, ""], do: {:ok, 5}

  defp count(raw) when is_binary(raw) do
    if String.trim(raw) == "", do: count(nil), else: count(number(raw))
  end

  defp count(raw) when is_number(raw) and raw >= 1 and raw <= 10 and trunc(raw) == raw,
    do: {:ok, trunc(raw)}

  defp count(_), do: :error

  defp number(value) do
    value = String.trim(value)

    if Regex.match?(~r/\A[+-]?(?:(?:[0-9]+\.?[0-9]*)|(?:\.[0-9]+))(?:e[+-]?[0-9]+)?\z/i, value) do
      normalized = Regex.replace(~r/\A([+-]?)\./, value, fn _, sign -> sign <> "0." end)
      normalized = Regex.replace(~r/\.(?=e|\z)/i, normalized, ".0")

      case Float.parse(normalized) do
        {number, ""} -> number
        _ -> :invalid
      end
    else
      :invalid
    end
  end

  defp trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp trim(_), do: nil
  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp invalid(message), do: {:error, {:invalid_arguments, "invalid_duckduckgo_options", message}}
end
