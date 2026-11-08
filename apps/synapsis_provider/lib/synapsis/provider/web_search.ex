defmodule Synapsis.Provider.WebSearch do
  @moduledoc "Configured web search HTTP formats and ordered domain results."

  alias Synapsis.Provider.WebSearch.{
    Brave,
    DeepSeek,
    DuckDuckGo,
    Exa,
    Firecrawl,
    Gemini,
    Grok,
    Kimi,
    MiniMax,
    Ollama,
    Parallel,
    ParallelFree,
    Perplexity,
    Searxng,
    Tavily,
    TextBudget,
    Transport
  }

  @content_limit 20_000
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @doc "Canonicalize provider endpoint identity before preparing arguments or reading the cache."
  def prepare_config(%{provider: "gemini"} = config), do: Gemini.prepare_config(config)

  def prepare_config(%{provider: "grok"} = config), do: Grok.prepare_config(config)

  def prepare_config(%{provider: "ollama"} = config), do: Ollama.prepare_config(config)

  def prepare_config(%{provider: "searxng"} = config), do: Searxng.prepare_config(config)

  def prepare_config(%{provider: "duckduckgo"} = config), do: DuckDuckGo.prepare_config(config)

  def prepare_config(%{provider: "parallel-free"} = config) do
    with {:ok, endpoint} <- ParallelFree.endpoint(config[:base_url]),
         do: {:ok, Map.put(config, :base_url, endpoint)}
  end

  def prepare_config(%{provider: "parallel"} = config) do
    with {:ok, endpoint} <- Parallel.endpoint(config[:base_url]),
         do: {:ok, Map.put(config, :base_url, endpoint)}
  end

  def prepare_config(%{provider: "minimax"} = config) do
    with {:ok, endpoint} <- MiniMax.endpoint(config[:base_url], config[:region]),
         do: {:ok, Map.put(config, :base_url, endpoint)}
  end

  def prepare_config(%{provider: "kimi"} = config) do
    with {:ok, endpoint} <- Kimi.endpoint(config[:base_url]),
         do: {:ok, Map.put(config, :base_url, endpoint)}
  end

  def prepare_config(%{provider: "deepseek"} = config) do
    with {:ok, endpoint} <- DeepSeek.endpoint(config[:base_url]),
         do: {:ok, Map.put(config, :base_url, endpoint)}
  end

  def prepare_config(%{provider: "exa"} = config) do
    with {:ok, endpoint} <- Exa.endpoint(config.base_url),
         do: {:ok, Map.put(config, :base_url, endpoint)}
  end

  def prepare_config(config), do: {:ok, config}

  def prepare(%{provider: provider} = config, arguments)
      when provider in ["parallel", "parallel-free"],
      do: Parallel.prepare(config, arguments)

  def prepare(%{provider: "minimax"} = config, arguments), do: MiniMax.prepare(config, arguments)

  def prepare(%{provider: "kimi"} = config, arguments), do: Kimi.prepare(config, arguments)

  def prepare(%{provider: "deepseek"} = config, arguments),
    do: DeepSeek.prepare(config, arguments)

  def prepare(%{provider: "exa"} = config, arguments), do: Exa.prepare(config, arguments)

  def prepare(%{provider: "brave"} = config, arguments), do: Brave.prepare(config, arguments)

  def prepare(%{provider: "tavily"} = config, arguments), do: Tavily.prepare(config, arguments)

  def prepare(%{provider: "perplexity"} = config, arguments),
    do: Perplexity.prepare(config, arguments)

  def prepare(%{provider: provider} = config, arguments)
      when provider in ["firecrawl", "firecrawl-free"],
      do: Firecrawl.prepare(config, arguments)

  def prepare(%{provider: "ollama"} = config, arguments), do: Ollama.prepare(config, arguments)

  def prepare(%{provider: "searxng"} = config, arguments), do: Searxng.prepare(config, arguments)

  def prepare(%{provider: "duckduckgo"} = config, arguments),
    do: DuckDuckGo.prepare(config, arguments)

  def prepare(%{provider: "gemini"} = config, arguments), do: Gemini.prepare(config, arguments)

  def prepare(%{provider: "grok"} = config, arguments), do: Grok.prepare(config, arguments)

  def prepare(_config, arguments), do: {:ok, arguments}

  def search(config, arguments) when is_map(config) and is_map(arguments) do
    with {:ok, config} <- prepare_config(config),
         {:ok, arguments} <- prepare(config, arguments) do
      search_prepared(config, arguments)
    end
  end

  @doc false
  def search_prepared(config, arguments) when is_map(config) and is_map(arguments) do
    start = System.monotonic_time(:millisecond)
    count = Map.get(arguments, "count", config.count)

    arguments =
      if config.provider in ["gemini", "grok"],
        do: Map.delete(arguments, "count"),
        else: Map.put(arguments, "count", count)

    with {:ok, payload} <- fetch(config, arguments),
         {:ok, result} <- result(config, arguments, payload) do
      result =
        if config.provider == "parallel",
          do: result,
          else: Map.put(result, "query", arguments["query"])

      {:ok,
       result
       |> Map.put("provider", config.provider)
       |> Map.put("tookMs", System.monotonic_time(:millisecond) - start)
       |> bound_content()}
    end
  end

  defp fetch(%{provider: "ollama"} = config, args), do: Ollama.fetch(config, args)
  defp fetch(%{provider: "searxng"} = config, args), do: Searxng.fetch(config, args)
  defp fetch(%{provider: "duckduckgo"} = config, args), do: DuckDuckGo.fetch(config, args)

  defp fetch(config, args) do
    with {:ok, method, url, headers, body} <- request(config, args),
         do: Transport.json(method, url, headers, body, config.timeout_ms)
  end

  defp request(%{provider: "parallel"} = config, args), do: Parallel.request(config, args)
  defp request(%{provider: "gemini"} = config, args), do: Gemini.request(config, args)
  defp request(%{provider: "grok"} = config, args), do: Grok.request(config, args)
  defp request(%{provider: "minimax"} = config, args), do: MiniMax.request(config, args)
  defp request(%{provider: "kimi"} = config, args), do: Kimi.request(config, args)
  defp request(%{provider: "deepseek"} = config, args), do: DeepSeek.request(config, args)
  defp request(%{provider: "exa"} = config, args), do: Exa.request(config, args)
  defp request(%{provider: "perplexity"} = config, args), do: Perplexity.request(config, args)
  defp request(%{provider: "tavily"} = config, args), do: Tavily.request(config, args)

  defp request(%{provider: provider} = config, args)
       when provider in ["firecrawl", "firecrawl-free"],
       do: Firecrawl.request(config, args)

  defp request(%{provider: "brave"} = config, args) do
    mode = Map.get(config, :mode, "web")
    path = if mode == "llm-context", do: "/res/v1/llm/context", else: "/res/v1/web/search"

    query =
      %{"q" => args["query"]}
      |> optional("country", args["country"])
      |> optional("search_lang", args["search_lang"])
      |> optional("freshness", freshness(args))

    query =
      if mode == "web" do
        query
        |> Map.put("count", args["count"])
        |> optional("ui_lang", args["ui_lang"])
      else
        query
      end

    url =
      append_path(config.base_url, path)
      |> URI.parse()
      |> Map.put(:query, URI.encode_query(query))

    {:ok, :get, URI.to_string(url),
     [{"accept", "application/json"}, {"x-subscription-token", config.api_key}], nil}
  end

  defp request(_, _), do: {:error, :unsupported_provider}

  defp result(%{provider: "parallel"} = config, args, payload),
    do: Parallel.result(config, args, payload)

  defp result(%{provider: "gemini"} = config, args, payload),
    do: Gemini.result(config, args, payload)

  defp result(%{provider: "grok"} = config, args, payload),
    do: Grok.result(config, args, payload)

  defp result(%{provider: "ollama"} = config, args, payload),
    do: Ollama.result(config, args, payload)

  defp result(%{provider: "searxng"} = config, args, payload),
    do: Searxng.result(config, args, payload)

  defp result(%{provider: "duckduckgo"} = config, args, payload),
    do: DuckDuckGo.result(config, args, payload)

  defp result(%{provider: "minimax"} = config, args, payload),
    do: MiniMax.result(config, args, payload)

  defp result(%{provider: "kimi"} = config, args, payload), do: Kimi.result(config, args, payload)

  defp result(%{provider: "deepseek"} = config, args, payload),
    do: DeepSeek.result(config, args, payload)

  defp result(%{provider: "exa"} = config, args, payload), do: Exa.result(config, args, payload)

  defp result(%{provider: "tavily"} = config, args, payload),
    do: Tavily.result(config, args, payload)

  defp result(%{provider: "perplexity"} = config, args, payload),
    do: Perplexity.result(config, args, payload)

  defp result(%{provider: provider} = config, args, payload)
       when provider in ["firecrawl", "firecrawl-free"],
       do: Firecrawl.result(config, args, payload)

  defp result(%{provider: "brave"} = config, args, payload) do
    if Map.get(config, :mode, "web") == "llm-context" do
      rows = get_in(payload, ["grounding", "generic"]) || []
      sources = map(payload["sources"])

      results =
        rows
        |> Enum.take(args["count"])
        |> Enum.filter(&is_map/1)
        |> Enum.map(fn row ->
          url = text(row["url"])
          age = get_in(sources, [url, "age"])

          %{
            "title" => text(row["title"]),
            "url" => url,
            "snippets" => Enum.filter(list(row["snippets"]), &(is_binary(&1) and &1 != "")),
            "siteName" => site(url)
          }
          |> optional("published", published(age_value(age, 3) || age_value(age, 1)))
        end)

      {:ok,
       %{
         "mode" => "llm-context",
         "results" => results,
         "count" => length(results),
         "sources" => sources
       }}
    else
      results =
        payload
        |> get_in(["web", "results"])
        |> list()
        |> Enum.take(args["count"])
        |> Enum.filter(&is_map/1)
        |> Enum.map(fn row ->
          url = text(row["url"])

          %{
            "title" => text(row["title"]),
            "url" => url,
            "description" => text(row["description"]),
            "siteName" => site(url)
          }
          |> optional("published", published(row["page_age"]))
        end)

      {:ok, %{"results" => results, "count" => length(results)}}
    end
  end

  defp bound_content(%{"provider" => provider} = result)
       when provider in [
              "brave",
              "gemini",
              "grok",
              "perplexity",
              "exa",
              "deepseek",
              "kimi",
              "minimax",
              "parallel",
              "ollama",
              "searxng",
              "duckduckgo"
            ],
       do: result

  defp bound_content(result) do
    {rows, {remaining, truncated}} =
      Enum.map_reduce(result["results"], {@content_limit, result["truncated"] == true}, fn row,
                                                                                           state ->
        Enum.reduce(~w(title snippet description content), {row, state}, fn key,
                                                                            {current, {left, cut}} ->
          if is_binary(current[key]) do
            {value, used} = TextBudget.take(current[key], left)

            {Map.put(current, key, value), {left - used, cut or value != current[key]}}
          else
            {current, {left, cut}}
          end
        end)
      end)

    result = Map.put(result, "results", rows)

    {result, truncated} =
      if is_binary(result["answer"]) do
        {answer, _used} = TextBudget.take(result["answer"], remaining)
        {Map.put(result, "answer", answer), truncated or answer != result["answer"]}
      else
        {result, truncated}
      end

    if truncated, do: Map.put(result, "truncated", true), else: result
  end

  defp append_path(base, path) do
    uri = URI.parse(base)

    uri
    |> Map.put(:path, String.trim_trailing(uri.path || "", "/") <> path)
    |> Map.put(:query, nil)
    |> URI.to_string()
  end

  defp freshness(args) do
    cond do
      is_binary(args["freshness"]) ->
        args["freshness"]

      is_binary(args["date_after"]) ->
        args["date_after"] <> "to" <> (args["date_before"] || Date.to_iso8601(Date.utc_today()))

      is_binary(args["date_before"]) ->
        "1970-01-01to" <> args["date_before"]

      true ->
        nil
    end
  end

  defp published(value) when is_binary(value) do
    cond do
      Regex.match?(~r/^\d{4}-\d{2}-\d{2}(?:[T ][\d:.+Z-]{0,20})?$/, value) and
          valid_date?(String.slice(value, 0, 10)) ->
        value

      true ->
        published_rfc(value)
    end
  end

  defp published(_), do: nil

  defp published_rfc(value) do
    case Regex.run(
           ~r/^[A-Z][a-z]{2}, (\d{2}) ([A-Z][a-z]{2}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$/,
           value
         ) do
      [_, day, month, year, hour, minute, second] ->
        with month when is_integer(month) <- Enum.find_index(@months, &(&1 == month)),
             {:ok, date} <- Date.new(String.to_integer(year), month + 1, String.to_integer(day)),
             {:ok, time} <-
               Time.new(
                 String.to_integer(hour),
                 String.to_integer(minute),
                 String.to_integer(second),
                 {0, 3}
               ),
             {:ok, datetime} <- DateTime.new(date, time, "Etc/UTC") do
          DateTime.to_iso8601(datetime)
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp valid_date?(value), do: match?({:ok, _}, Date.from_iso8601(value))

  defp site(url), do: String.replace_prefix(URI.parse(url).host || "", "www.", "")
  defp age_value(age, index) when is_list(age), do: Enum.at(age, index)
  defp age_value(age, index) when is_map(age), do: age[Integer.to_string(index)]
  defp age_value(_, _), do: nil
  defp optional(map, _key, value) when value in [nil, "", []], do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp text(value) when is_binary(value), do: value
  defp text(_), do: ""
  defp list(value) when is_list(value), do: value
  defp list(_), do: []
  defp map(value) when is_map(value), do: value
  defp map(_), do: %{}
end
