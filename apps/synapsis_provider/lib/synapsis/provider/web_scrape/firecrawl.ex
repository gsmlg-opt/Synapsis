defmodule Synapsis.Provider.WebScrape.Firecrawl do
  @moduledoc "Firecrawl scrape wire format and portable, UTF-16 bounded page results."

  alias Synapsis.Provider.WebScrape.Markdown
  alias Synapsis.Provider.WebSearch.{TextBudget, Transport}

  @response_limit 64 * 1024 * 1024
  @default_age 172_800_000
  @default_chars 50_000

  def prepare(config, arguments) when is_map(arguments) do
    url = string(argument(arguments, "url"))

    with true <- is_binary(url) and url != "",
         {:ok, max_chars} <- integer(arguments, "maxChars", 1),
         {:ok, max_age} <- integer(arguments, "maxAgeMs", 0),
         {:ok, timeout} <- integer(arguments, "timeoutSeconds", 1) do
      seconds = timeout || positive(config[:timeout_ms], 60_000) / 1_000
      timeout_ms = seconds |> floor() |> max(1) |> min(2_147_000) |> Kernel.*(1_000)
      proxy = string(argument(arguments, "proxy"))
      proxy = if proxy in ["auto", "basic", "stealth"], do: proxy, else: "auto"
      mode = if string(argument(arguments, "extractMode")) == "text", do: "text", else: "markdown"

      {:ok,
       %{
         body: %{
           "url" => url,
           "formats" => ["markdown"],
           "onlyMainContent" =>
             boolean(arguments["onlyMainContent"], boolean(config[:only_main_content], true)),
           "timeout" => timeout_ms,
           "maxAge" => floor(max_age || nonnegative(config[:max_age_ms], @default_age)),
           "proxy" => proxy,
           "storeInCache" => boolean(arguments["storeInCache"], true)
         },
         timeout_ms: timeout_ms,
         extract_mode: mode,
         max_chars:
           floor(
             min(max_chars || @default_chars, positive(config[:max_chars_cap], @default_chars))
           )
       }}
    else
      false -> invalid("url", "url required")
      error -> error
    end
  end

  def scrape(config, arguments) do
    with {:ok, prepared} <- prepare(config, arguments),
         {:ok, payload} <-
           Transport.json(
             :post,
             endpoint(Map.get(config, :base_url, "https://api.firecrawl.dev")),
             [
               {"content-type", "application/json"},
               {"authorization", "Bearer " <> config.api_key}
             ],
             prepared.body,
             prepared.timeout_ms,
             max_bytes: @response_limit
           ) do
      result(payload, prepared)
    end
  end

  defp endpoint(base_url) do
    uri = base_url |> String.trim() |> URI.parse()
    URI.to_string(%{uri | path: "/v2/scrape", query: nil, fragment: nil, userinfo: nil})
  end

  defp result(payload, prepared) do
    data = record(payload["data"])
    metadata = record(data["metadata"])
    raw_status = number(metadata["statusCode"]) || number(data["statusCode"])
    status = if raw_status, do: floor(raw_status)
    markdown = nonempty(data["markdown"]) || nonempty(data["content"])

    cond do
      payload["success"] == false ->
        {:error, :malformed_response}

      status && status not in 200..299 ->
        {:error, {:target_status, status}}

      is_nil(markdown) ->
        {:error, :malformed_response}

      true ->
        raw = if prepared.extract_mode == "text", do: Markdown.to_text(markdown), else: markdown
        {text, used} = TextBudget.take(raw, prepared.max_chars)
        {title, remaining, title_cut} = metadata_text(metadata["title"], 4_000)
        {warning, _, warning_cut} = metadata_text(payload["warning"], remaining)
        url = prepared.body["url"]

        {:ok,
         %{
           "url" => url,
           "finalUrl" =>
             canonical_url(metadata["sourceURL"]) || canonical_url(data["url"]) || url,
           "extractor" => "firecrawl",
           "extractMode" => prepared.extract_mode,
           "truncated" => text != raw or title_cut or warning_cut,
           "rawLength" => TextBudget.units(raw),
           "length" => used,
           "text" => text
         }
         |> optional("status", status)
         |> optional("title", title)
         |> optional("warning", warning)}
    end
  end

  defp metadata_text(value, left) do
    case nonempty(value) do
      nil ->
        {nil, left, false}

      value ->
        {text, used} = TextBudget.take(value, left)
        {text, left - used, text != value}
    end
  end

  # Ordinary HTTP(S) URI normalization is portable here. Full WHATWG URL and
  # external-content sanitizer equivalence are unverified; source framing and
  # externalContent are intentionally absent from the host's portable result.
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

  defp integer(arguments, key, minimum) do
    raw = argument(arguments, key)
    value = number(raw)

    cond do
      is_nil(raw) or (is_binary(raw) and String.trim(raw) == "") ->
        {:ok, nil}

      is_number(value) and value >= minimum and value <= 9_007_199_254_740_991 and
          floor(value) == value ->
        {:ok, floor(value)}

      true ->
        invalid(
          key,
          key <>
            " must be " <>
            if(minimum == 0, do: "a non-negative integer", else: "a positive integer")
        )
    end
  end

  defp number(value) when is_number(value), do: value

  defp number(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/\A[+-]?(?:(?:\d+\.?\d*)|(?:\.\d+))(?:e[+-]?\d+)?\z/i, value) do
      # JavaScript accepts decimal/scientific tokens such as .2e3 and 2.e2.
      # Float.parse needs digits on both sides of an existing decimal point.
      normalized = Regex.replace(~r/\A([+-]?)\./, value, fn _, sign -> sign <> "0." end)
      normalized = Regex.replace(~r/\.(?=e|\z)/i, normalized, ".0")

      case Float.parse(normalized) do
        {number, ""} -> number
        _ -> nil
      end
    end
  end

  defp number(_), do: nil

  defp argument(arguments, key) do
    Map.get(arguments, key, Map.get(arguments, Macro.underscore(key)))
  end

  defp positive(value, _) when is_number(value) and value > 0, do: value
  defp positive(_, default), do: default
  defp nonnegative(value, _) when is_number(value) and value >= 0, do: value
  defp nonnegative(_, default), do: default
  defp boolean(value, _) when is_boolean(value), do: value
  defp boolean(_, default), do: default
  defp string(value) when is_binary(value), do: String.trim(value)
  defp string(_), do: nil
  defp nonempty(value) when is_binary(value) and value != "", do: value
  defp nonempty(_), do: nil
  defp record(value) when is_map(value), do: value
  defp record(_), do: %{}
  defp optional(map, _, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp invalid(key, message), do: {:error, {:invalid_arguments, key, message}}
end
