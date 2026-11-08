defmodule Synapsis.Provider.WebSearch.Exa do
  @moduledoc "Exa request options and complete ordered provider results before generic projection."

  @types ~w(auto neural fast deep deep-reasoning instant)
  @freshness ~w(day week month year)
  @sections %{
    "text" => ~w(maxCharacters),
    "highlights" => ~w(maxCharacters query numSentences highlightsPerUrl),
    "summary" => ~w(query)
  }

  def prepare(config, arguments) do
    query = trim(arguments["query"])
    freshness = arguments["freshness"] |> trim() |> downcase()
    type = trim(arguments["type"])

    with true <- is_binary(query),
         true <- is_nil(freshness) or freshness in @freshness,
         {:ok, after_date} <- date(trim(arguments["date_after"])),
         {:ok, before_date} <- date(trim(arguments["date_before"])),
         true <- is_nil(freshness) or (is_nil(after_date) and is_nil(before_date)),
         true <- is_nil(after_date) or is_nil(before_date) or after_date <= before_date,
         {:ok, count} <- count(arguments["count"], Map.get(config, :count)),
         {:ok, contents} <- contents(arguments) do
      {:ok,
       %{
         "query" => query,
         "count" => count,
         "type" => if(type in @types, do: type, else: "auto"),
         "contents" => contents
       }
       |> optional("freshness", freshness)
       |> optional("date_after", after_date)
       |> optional("date_before", before_date)}
    else
      _ -> invalid("Exa search arguments are invalid")
    end
  end

  @doc "Normalize an Exa base URL into its query-preserving search endpoint."
  def endpoint(base_url) do
    configured = trim(base_url)

    candidate =
      cond do
        is_nil(configured) -> "https://api.exa.ai/search"
        Regex.match?(~r/\Ahttps?:\/\//i, configured) -> configured
        Regex.match?(~r/\A[a-z][a-z0-9+.-]*:\/\//i, configured) -> nil
        true -> "https://" <> configured
      end

    with true <- is_binary(candidate),
         %URI{scheme: scheme, host: host} = uri <- URI.parse(candidate),
         true <-
           is_binary(scheme) and String.downcase(scheme) in ["http", "https"] and
             is_binary(host) and host != "" do
      path = String.trim_trailing(uri.path || "", "/")
      path = if String.ends_with?(path, "/search"), do: path, else: path <> "/search"

      {:ok,
       URI.to_string(%{
         uri
         | scheme: String.downcase(scheme),
           host: String.downcase(host),
           path: path,
           fragment: nil
       })}
    else
      _ -> invalid("Exa base URL must be an HTTP or HTTPS URL")
    end
  rescue
    _ -> invalid("Exa base URL must be an HTTP or HTTPS URL")
  end

  def request(config, args) do
    with {:ok, endpoint} <- endpoint(config[:base_url]) do
      body = %{
        "query" => args["query"],
        "numResults" => args["count"],
        "type" => args["type"],
        "contents" => args["contents"]
      }

      published_after =
        cond do
          is_binary(args["date_after"]) ->
            args["date_after"]

          is_binary(args["freshness"]) ->
            args["freshness"]
            |> freshness_start(DateTime.utc_now())
            |> DateTime.to_iso8601()

          true ->
            nil
        end

      body =
        body
        |> optional("startPublishedDate", published_after)
        |> optional("endPublishedDate", args["date_before"])

      {:ok, :post, endpoint,
       [
         {"accept", "application/json"},
         {"content-type", "application/json"},
         {"x-api-key", config.api_key},
         {"x-exa-integration", "synapsis"}
       ], body}
    end
  end

  @doc "Subtract UTC freshness at millisecond precision, clamping months and rolling leap-day years."
  def freshness_start(freshness, %DateTime{} = datetime) when freshness in @freshness do
    datetime = datetime |> DateTime.to_unix(:millisecond) |> DateTime.from_unix!(:millisecond)

    case freshness do
      "day" ->
        DateTime.add(datetime, -86_400, :second)

      "week" ->
        DateTime.add(datetime, -7 * 86_400, :second)

      "month" ->
        {year, month} =
          if datetime.month == 1,
            do: {datetime.year - 1, 12},
            else: {datetime.year, datetime.month - 1}

        first = Date.new!(year, month, 1)
        date = Date.new!(year, month, min(datetime.day, Date.days_in_month(first)))
        DateTime.new!(date, DateTime.to_time(datetime), "Etc/UTC")

      "year" ->
        date = Date.new!(datetime.year - 1, datetime.month, 1) |> Date.add(datetime.day - 1)
        DateTime.new!(date, DateTime.to_time(datetime), "Etc/UTC")
    end
  end

  def result(_config, args, payload) do
    rows =
      payload
      |> Map.get("results", [])
      |> list()
      |> Enum.filter(&(is_map(&1) and not is_struct(&1)))
      |> Enum.take(args["count"])
      |> Enum.map(&row/1)

    {:ok, %{"results" => rows, "count" => length(rows)}}
  end

  defp row(entry) do
    url = text(entry["url"])
    highlights = entry["highlights"] |> list() |> Enum.map(&trim/1) |> Enum.reject(&is_nil/1)
    summary = trim(entry["summary"])

    description =
      if highlights == [],
        do: summary || trim(entry["text"]) || "",
        else: Enum.join(highlights, "\n")

    scores = entry["highlightScores"] |> list() |> Enum.filter(&is_number/1)

    %{
      "title" => text(entry["title"]),
      "url" => url,
      "description" => description
    }
    |> optional("published", nonempty_text(entry["publishedDate"]))
    |> optional("siteName", site(url))
    |> optional("summary", summary)
    |> optional("highlightScores", if(scores == [], do: nil, else: scores))
  end

  defp contents(arguments) do
    if Map.has_key?(arguments, "contents") do
      case arguments["contents"] do
        value when is_map(value) and not is_struct(value) ->
          with true <- Map.keys(value) -- Map.keys(@sections) == [],
               {:ok, parsed} <- parse_contents(value) do
            {:ok, if(parsed == %{}, do: %{"highlights" => true}, else: parsed)}
          else
            _ -> :error
          end

        _ ->
          :error
      end
    else
      {:ok, %{"highlights" => true}}
    end
  end

  defp parse_contents(value) do
    Enum.reduce_while(~w(text highlights summary), {:ok, %{}}, fn section, {:ok, result} ->
      case Map.fetch(value, section) do
        :error ->
          {:cont, {:ok, result}}

        {:ok, flag} when is_boolean(flag) ->
          {:cont, {:ok, Map.put(result, section, flag)}}

        {:ok, options} when is_map(options) and not is_struct(options) ->
          if Map.keys(options) -- @sections[section] == [] and
               Enum.all?(options, fn
                 {"query", query} -> is_binary(query)
                 {_key, number} -> is_number(number) and number > 0 and trunc(number) == number
               end) do
            options =
              Map.new(options, fn
                {"query", query} -> {"query", query}
                {key, number} -> {key, trunc(number)}
              end)

            {:cont, {:ok, Map.put(result, section, options)}}
          else
            {:halt, :error}
          end

        _ ->
          {:halt, :error}
      end
    end)
  end

  defp count(raw, configured) do
    if is_nil(raw) or (is_binary(raw) and String.trim(raw) == "") do
      {:ok, min(configured_count(configured) || 5, 100)}
    else
      case number(raw) do
        value when is_number(value) and value >= 1 and value <= 100 and trunc(value) == value ->
          {:ok, trunc(value)}

        _ ->
          :error
      end
    end
  end

  defp configured_count(value)
       when is_integer(value) and value > 0 and value <= 9_007_199_254_740_991,
       do: value

  defp configured_count(value)
       when is_float(value) and value > 0 and value <= 9_007_199_254_740_991,
       do: if(trunc(value) == value, do: trunc(value))

  defp configured_count(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/\A[+-]?[0-9]+\z/, value) do
      configured_count(String.to_integer(value))
    end
  end

  defp configured_count(_), do: nil

  defp number(value) when is_number(value), do: value

  defp number(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/\A[+-]?(?:(?:[0-9]+\.?[0-9]*)|(?:\.[0-9]+))(?:e[+-]?[0-9]+)?\z/i, value) do
      normalized = Regex.replace(~r/\A([+-]?)\./, value, fn _, sign -> sign <> "0." end)
      normalized = Regex.replace(~r/\.(?=e|\z)/i, normalized, ".0")

      case Float.parse(normalized) do
        {number, ""} -> number
        _ -> nil
      end
    end
  end

  defp number(_), do: nil

  defp date(nil), do: {:ok, nil}

  defp date(value) do
    value =
      case Regex.run(~r/\A([0-9]{1,2})\/([0-9]{1,2})\/([0-9]{4})\z/, value) do
        [_, month, day, year] ->
          year <>
            "-" <> String.pad_leading(month, 2, "0") <> "-" <> String.pad_leading(day, 2, "0")

        _ ->
          value
      end

    with true <- Regex.match?(~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/, value),
         {:ok, %Date{year: year}} when year >= 100 <- Date.from_iso8601(value) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  defp site(url) do
    case url |> String.trim() |> URI.parse() do
      %URI{host: host} when is_binary(host) and host != "" -> String.downcase(host)
      _ -> nil
    end
  end

  defp list(value) when is_list(value), do: value
  defp list(_), do: []
  defp text(value) when is_binary(value), do: value
  defp text(_), do: ""
  defp nonempty_text(value) when is_binary(value) and value != "", do: value
  defp nonempty_text(_), do: nil

  defp trim(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp trim(_), do: nil
  defp downcase(nil), do: nil
  defp downcase(value), do: String.downcase(value)
  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp invalid(message), do: {:error, {:invalid_arguments, "invalid_exa_options", message}}
end
