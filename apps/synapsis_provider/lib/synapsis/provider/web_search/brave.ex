defmodule Synapsis.Provider.WebSearch.Brave do
  @moduledoc "Canonical Brave search arguments prepared privately before HTTP and caching."

  @countries ~w(AR AU AT BE BR CA CL DK FI FR DE GR HK IN ID IT JP KR MY MX NL NZ NO CN PL PT PH RU SA ZA ES SE CH TW TR GB US ALL)
  @languages ~w(ar eu bn bg ca zh-hans zh-hant hr cs da nl en en-gb et fi fr gl de el gu he hi hu is it jp kn ko lv lt ms ml mr nb pl pt-br pt-pt pa ro ru sr sk sl es sv ta te th tr uk vi)
  @language_aliases %{
    "ja" => "jp",
    "zh" => "zh-hans",
    "zh-cn" => "zh-hans",
    "zh-hk" => "zh-hant",
    "zh-sg" => "zh-hans",
    "zh-tw" => "zh-hant"
  }
  @freshness_aliases %{
    "day" => "pd",
    "week" => "pw",
    "month" => "pm",
    "year" => "py",
    "pd" => "pd",
    "pw" => "pw",
    "pm" => "pm",
    "py" => "py"
  }
  @filter_keys ~w(country language search_lang ui_lang freshness date_after date_before)

  def prepare(config, arguments, today \\ Date.utc_today()) do
    mode = Map.get(config, :mode, "web")

    with {:ok, query} <- required_query(arguments),
         {:ok, search_lang, ui_lang} <- locales(arguments, mode),
         {:ok, freshness, date_after, date_before} <- time_filters(arguments),
         {:ok, date_before} <- date_end(mode, date_after, date_before, today) do
      {:ok,
       arguments
       |> Map.drop(@filter_keys)
       |> Map.put("query", query)
       |> optional("country", country(arguments["country"]))
       |> optional("search_lang", search_lang)
       |> optional("ui_lang", ui_lang)
       |> optional("freshness", freshness)
       |> optional("date_after", date_after)
       |> optional("date_before", date_before)}
    end
  end

  defp required_query(arguments) do
    case trim(arguments["query"]) do
      nil -> invalid("invalid_query", "query required")
      query -> {:ok, query}
    end
  end

  defp country(value) do
    case trim(value) do
      nil -> nil
      value -> if String.upcase(value) in @countries, do: String.upcase(value), else: "ALL"
    end
  end

  defp locales(arguments, mode) do
    search = trim(arguments["search_lang"]) || trim(arguments["language"])
    ui = trim(arguments["ui_lang"])

    {search, ui} =
      if ui_language(search) && search_language(ui), do: {ui, search}, else: {search, ui}

    normalized_search = search_language(search)
    normalized_ui = ui_language(ui)

    cond do
      search && is_nil(normalized_search) ->
        invalid(
          "invalid_search_lang",
          "search_lang must be a Brave-supported language code like 'en', 'en-gb', 'zh-hans', or 'zh-hant'."
        )

      ui && is_nil(normalized_ui) ->
        invalid("invalid_ui_lang", "ui_lang must be a language-region locale like 'en-US'.")

      normalized_ui && mode == "llm-context" ->
        invalid(
          "unsupported_ui_lang",
          "ui_lang is not supported by Brave llm-context mode. Remove ui_lang or use Brave web mode for locale-based UI hints."
        )

      true ->
        {:ok, normalized_search, normalized_ui}
    end
  end

  defp search_language(nil), do: nil

  defp search_language(value) do
    lower = String.downcase(value)
    canonical = Map.get(@language_aliases, lower, lower)
    if canonical in @languages, do: canonical
  end

  defp ui_language(nil), do: nil

  defp ui_language(value) do
    case Regex.run(~r/^([a-z]{2})-([a-z]{2})$/i, value) do
      [_, language, region] -> String.downcase(language) <> "-" <> String.upcase(region)
      _ -> nil
    end
  end

  defp time_filters(arguments) do
    raw_freshness = trim(arguments["freshness"])
    raw_after = trim(arguments["date_after"])
    raw_before = trim(arguments["date_before"])
    freshness = normalize_freshness(raw_freshness)

    cond do
      raw_freshness && is_nil(freshness) ->
        invalid("invalid_freshness", "freshness must be day, week, month, or year.")

      raw_freshness && (raw_after || raw_before) ->
        invalid(
          "conflicting_time_filters",
          "freshness and date_after/date_before cannot be used together. Use either freshness (day/week/month/year) or a date range (date_after/date_before), not both."
        )

      true ->
        with {:ok, date_after} <- date_bound(raw_after, "date_after"),
             {:ok, date_before} <- date_bound(raw_before, "date_before"),
             :ok <- date_order(date_after, date_before) do
          {:ok, freshness, date_after, date_before}
        end
    end
  end

  defp normalize_freshness(nil), do: nil

  defp normalize_freshness(value) do
    Map.get(@freshness_aliases, String.downcase(value)) || freshness_range(value)
  end

  defp freshness_range(value) do
    case Regex.run(~r/^(\d{4}-\d{2}-\d{2})to(\d{4}-\d{2}-\d{2})$/, value) do
      [_, first, last] ->
        if iso_date(first) && iso_date(last) && first <= last, do: first <> "to" <> last

      _ ->
        nil
    end
  end

  defp date_bound(nil, _name), do: {:ok, nil}

  defp date_bound(value, name) do
    case normalize_date(value) do
      nil -> invalid("invalid_date", name <> " must be YYYY-MM-DD format.")
      date -> {:ok, date}
    end
  end

  defp normalize_date(value) do
    case Regex.run(~r/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/, value) do
      [_, month, day, year] ->
        iso_date(
          year <>
            "-" <> String.pad_leading(month, 2, "0") <> "-" <> String.pad_leading(day, 2, "0")
        )

      _ ->
        iso_date(value)
    end
  end

  defp iso_date(value) do
    # The reference Date.UTC validation rejects years 0000..0099.
    with true <- Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, value),
         {:ok, date} <- Date.from_iso8601(value),
         true <- date.year >= 100 do
      value
    else
      _ -> nil
    end
  end

  defp date_order(first, last) when is_binary(first) and is_binary(last) and first > last,
    do: invalid("invalid_date_range", "date_after must be before date_before.")

  defp date_order(_, _), do: :ok

  defp date_end("llm-context", date_after, date_before, today) do
    today = Date.to_iso8601(today)

    cond do
      date_after && is_nil(date_before) && date_after > today ->
        invalid(
          "invalid_date_range",
          "date_after cannot be in the future for Brave llm-context mode."
        )

      date_before && is_nil(date_after) ->
        invalid(
          "unsupported_date_filter",
          "Brave llm-context mode requires date_after when date_before is set. Use a bounded date range or freshness."
        )

      date_after ->
        # Freeze the implicit LLM end date before Core computes its cache key.
        {:ok, date_before || today}

      true ->
        {:ok, date_before}
    end
  end

  defp date_end(_mode, _date_after, date_before, _today), do: {:ok, date_before}

  defp trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp trim(_), do: nil
  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp invalid(code, message), do: {:error, {:invalid_arguments, code, message}}
end
