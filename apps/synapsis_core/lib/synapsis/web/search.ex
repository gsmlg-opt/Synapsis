defmodule Synapsis.Web.Search do
  @moduledoc "Native Web.search callback preserving configured provider detail and bounded generic results."

  alias Backplane.AgentRuntime.Error
  alias Synapsis.Provider.WebSearch
  alias Synapsis.Provider.WebSearch.TextBudget
  alias Synapsis.Web.Search.Cache

  @generic_limit 20_000

  def search(query, opts) do
    config = Keyword.fetch!(opts, :search_config)
    generic = Keyword.get(opts, :generic, true)

    prepared_query =
      if generic and config.provider in ["tavily", "firecrawl", "firecrawl-free"],
        do: query,
        else: String.trim(query)

    arguments = Keyword.get(opts, :arguments, %{})

    arguments =
      if config.provider in ["parallel", "parallel-free"] and
           (Map.has_key?(arguments, "objective") or Map.has_key?(arguments, "search_queries") or
              Map.has_key?(arguments, "query")),
         do: arguments,
         else: Map.put(arguments, "query", prepared_query)

    arguments =
      if generic and
           config.provider not in [
             "brave",
             "perplexity",
             "exa",
             "deepseek",
             "kimi",
             "parallel",
             "parallel-free",
             "gemini",
             "searxng",
             "duckduckgo"
           ],
         do: Map.take(arguments, ~w(query count)),
         else: arguments

    arguments =
      if config.provider in [
           "deepseek",
           "kimi",
           "minimax",
           "parallel",
           "parallel-free",
           "ollama",
           "gemini",
           "grok",
           "searxng",
           "duckduckgo"
         ],
         do: arguments,
         else: Map.put_new(arguments, "count", config.count)

    arguments =
      if config.provider == "tavily" and not generic,
        do: Map.put(arguments, "include_answer", arguments["include_answer"] == true),
        else: arguments

    with {:ok, config} <- WebSearch.prepare_config(config),
         {:ok, config} <- citation_policy(config),
         {:ok, arguments} <- WebSearch.prepare(config, arguments) do
      case cached_search(config, arguments, generic, opts) do
        {:ok, %{"kind" => "raw", "provider" => "duckduckgo"}} = result ->
          result

        {:ok, public}
        when config.provider in [
               "perplexity",
               "exa",
               "deepseek",
               "kimi",
               "minimax",
               "ollama",
               "gemini",
               "grok",
               "searxng",
               "duckduckgo"
             ] and
               generic ->
          {:ok, Map.put(public, "query", query)}

        result ->
          result
      end
    else
      {:error, {:invalid_arguments, code, message}} ->
        {:error, Error.new(:validation, message, details: %{reason: code})}
    end
  end

  defp cached_search(config, arguments, generic, opts) do
    timeout =
      case arguments["timeout_seconds"] do
        seconds when is_integer(seconds) and seconds > 0 -> seconds * 1_000
        _ -> Keyword.get(opts, :timeout, config.timeout_ms)
      end

    config = Map.put(config, :timeout_ms, timeout)
    key = cache_key(config, arguments, generic)

    with {:ok, opts} <- execution_opts(config, timeout, opts) do
      case Cache.get(key, config.cache_ttl_ms) do
        {:ok, result} ->
          if live?(config, opts),
            do: {:ok, cached_result(result)},
            else: failure(:timeout, "Search deadline expired")

        :miss ->
          execute(config, arguments, generic, key, opts)
      end
    end
  end

  defp execute(config, arguments, generic, key, opts) do
    case uncached_result(config, arguments, opts) do
      {:ok, result} ->
        result = if generic, do: generic_result(result), else: result

        cond do
          not live?(config, opts) ->
            failure(:timeout, "Search deadline expired")

          :erlang.external_size(result) <= Keyword.get(opts, :result_limit, 1_000_000) ->
            cached =
              if config.provider in ["parallel", "parallel-free"] and
                   is_nil(arguments["session_id"]),
                 do: Map.delete(result, "sessionId"),
                 else: result

            :ok = Cache.put(key, cached, config.cache_ttl_ms)
            {:ok, result}

          true ->
            failure(:budget_exceeded, "Search result exceeds its configured bound")
        end

      {:error, :timeout} ->
        failure(:timeout, "Search provider request timed out")

      {:error, :response_too_large} ->
        failure(:budget_exceeded, "Search provider response exceeds its byte bound")

      {:error, :transport} ->
        failure(:transient_transport, "Search provider request failed")

      {:error, {:http_status, _}} ->
        failure(:transient_transport, "Search provider returned an unsuccessful response")

      {:error, _} ->
        failure(:malformed_result, "Search provider returned an unsupported response")
    end
  end

  defp uncached_result(%{provider: "gemini"} = config, arguments, opts) do
    started = now()
    deadline = Keyword.fetch!(opts, :deadline_ms)
    remaining = deadline - started

    if remaining > 0 do
      # The request clock is supplied only after cache lookup; neither it nor
      # executable routing callbacks become part of effective model config.
      runtime =
        config
        |> Map.put(:timeout_ms, remaining)
        |> Map.put(:request_time, Keyword.get(opts, :request_time) || DateTime.utc_now())

      search = Keyword.get(opts, :uncached_search, &WebSearch.search_prepared/2)

      with {:ok, result} <- search.(runtime, arguments),
           {:ok, citations} <-
             Synapsis.Web.CitationRedirect.resolve(result["citations"],
               allowed_hosts: config.citation_allowed_hosts,
               deadline_ms: deadline,
               transport: Keyword.get(opts, :citation_transport, &Synapsis.Web.Transport.head/2)
             ) do
        {:ok, result |> Map.put("citations", citations) |> Map.put("tookMs", now() - started)}
      end
    else
      {:error, :timeout}
    end
  end

  defp uncached_result(config, arguments, opts) do
    search = Keyword.get(opts, :uncached_search, &WebSearch.search_prepared/2)
    search.(config, arguments)
  end

  defp citation_policy(%{provider: "gemini"} = config) do
    hosts = Map.get(config, :citation_allowed_hosts, [])

    if is_list(hosts) and Enum.all?(hosts, &is_binary/1) do
      {:ok,
       config
       |> Map.put(
         :citation_allowed_hosts,
         hosts |> Enum.map(&String.downcase/1) |> Enum.uniq() |> Enum.sort()
       )
       |> Map.put(:citation_policy, :declared_hosts_v1)}
    else
      {:error,
       {:invalid_arguments, "invalid_gemini_hosts",
        "Gemini citation hosts must be an explicit host list"}}
    end
  end

  defp citation_policy(config), do: {:ok, config}

  defp execution_opts(%{provider: "gemini"}, timeout, opts) do
    configured = now() + timeout

    case Keyword.fetch(opts, :deadline_ms) do
      {:ok, deadline} when is_integer(deadline) ->
        if deadline > now(),
          do: {:ok, Keyword.put(opts, :deadline_ms, min(configured, deadline))},
          else: failure(:timeout, "Search deadline expired")

      :error ->
        {:ok, Keyword.put(opts, :deadline_ms, configured)}

      _ ->
        failure(:validation, "Search deadline is invalid")
    end
  end

  defp execution_opts(_config, _timeout, opts), do: {:ok, opts}
  defp live?(%{provider: "gemini"}, opts), do: Keyword.fetch!(opts, :deadline_ms) > now()
  defp live?(_config, _opts), do: true
  defp now, do: System.monotonic_time(:millisecond)

  defp cached_result(%{"kind" => "raw", "provider" => "duckduckgo"} = result),
    do: Map.update!(result, "data", &Map.put(&1, "cached", true))

  defp cached_result(result), do: Map.put(result, "cached", true)

  defp generic_result(%{"provider" => provider} = result)
       when provider in ["parallel", "parallel-free"],
       do: Map.put(result, "kind", "results")

  defp generic_result(%{"provider" => provider, "content" => content} = result)
       when provider in ["perplexity", "gemini", "grok"] do
    {citations, left, truncated} =
      answer_citations(result["citations"], result["truncated"] == true)

    text = answer_text(content)
    {content, used} = TextBudget.take(text, left)

    {citations, {_, truncated}} =
      Enum.map_reduce(citations, {left - used, truncated or content != text}, fn citation,
                                                                                 state ->
        case citation["title"] do
          title when is_binary(title) ->
            {left, cut} = state
            text = answer_text(title)
            {title, used} = TextBudget.take(text, left)
            {Map.put(citation, "title", title), {left - used, cut or title != text}}

          _ ->
            {citation, state}
        end
      end)

    public = %{
      "kind" => "answer",
      "provider" => result["provider"],
      "query" => result["query"],
      "content" => content,
      "citations" => citations,
      "tookMs" => result["tookMs"]
    }

    if truncated, do: Map.put(public, "truncated", true), else: public
  end

  defp generic_result(%{"provider" => provider, "results" => rows} = result)
       when provider in ["perplexity", "exa", "deepseek", "kimi", "minimax", "ollama", "searxng"] do
    rows =
      Enum.map(rows, fn row ->
        row = Map.put(row, "url", canonical_url!(row["url"]))

        case row["published"] do
          value when is_binary(value) ->
            if valid_published?(value), do: row, else: Map.delete(row, "published")

          _ ->
            Map.delete(row, "published")
        end
      end)

    generic_rows(Map.put(result, "results", rows))
  end

  defp generic_result(%{"provider" => "duckduckgo", "results" => rows} = result) do
    if Enum.all?(rows, &(not is_nil(canonical_url(&1["url"])))) do
      rows = Enum.map(rows, &Map.put(&1, "url", canonical_url!(&1["url"])))
      generic_rows(Map.put(result, "results", rows))
    else
      %{"kind" => "raw", "provider" => "duckduckgo", "data" => result}
    end
  end

  defp generic_result(result), do: generic_rows(result)

  defp answer_text(value) do
    value
    |> String.replace(
      ~r/^[ \t]*<<<EXTERNAL_UNTRUSTED_CONTENT id="[0-9a-f]+">>>[ \t]*\r?\n(?:Source: [^\n]*\r?\n---\r?\n)?/mu,
      ""
    )
    |> String.replace(
      ~r/^[ \t]*<<<END_EXTERNAL_UNTRUSTED_CONTENT id="[0-9a-f]+">>>[ \t]*\r?\n?/mu,
      ""
    )
    |> String.trim()
  end

  defp answer_citations(citations, truncated) do
    citations
    |> Enum.with_index(1)
    |> Enum.reduce_while({[], @generic_limit, truncated}, fn {entry, index}, {rows, left, cut} ->
      if index > 1000 or length(rows) >= 20 do
        {:halt, {rows, left, true}}
      else
        source = if is_binary(entry), do: %{"url" => entry}, else: entry
        url = if is_map(source), do: canonical_url(source["url"])

        cond do
          is_nil(url) ->
            {:cont, {rows, left, cut}}

          TextBudget.units(url) > left ->
            {:cont, {rows, left, true}}

          true ->
            row = Map.take(source, ["title"]) |> Map.put("url", url)
            {:cont, {rows ++ [row], left - TextBudget.units(url), cut}}
        end
      end
    end)
  end

  # URI supplies parsing and percent encoding; normalize ordinary HTTP URL
  # serialization before charging the shared UTF-16 budget.
  defp canonical_url(value) when is_binary(value) do
    if TextBudget.units(value) <= 2048 do
      uri = value |> String.trim() |> URI.parse()

      if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
        uri = %{uri | host: String.downcase(uri.host), path: uri.path || "/"}
        url = URI.to_string(uri) |> URI.encode(&(&1 > 32 and &1 < 127))
        if TextBudget.units(url) <= 2048, do: url
      end
    end
  end

  defp canonical_url(_), do: nil

  defp canonical_url!(value) do
    canonical_url(value) || raise ArgumentError, "Search result URL cannot be normalized"
  end

  defp valid_published?(value) do
    Regex.match?(~r/^\d{4}-\d{2}-\d{2}(?:[T ][\d:.+Z-]{0,20})?$/, value) and
      match?({:ok, _}, Date.from_iso8601(String.slice(value, 0, 10)))
  end

  defp generic_rows(result) do
    {rows, remaining} =
      result["results"]
      |> Enum.take(10)
      |> Enum.reduce({[], @generic_limit}, fn row, {rows, left} ->
        size = TextBudget.units(row["url"])
        if size <= left, do: {[row | rows], left - size}, else: {rows, left}
      end)

    rows = Enum.reverse(rows)

    {results, {_, truncated}} =
      Enum.map_reduce(
        rows,
        {remaining, result["truncated"] == true or length(result["results"]) > length(rows)},
        fn row, state ->
          fields =
            %{"title" => row["title"], "url" => row["url"]}
            |> optional(
              "snippet",
              row["snippet"] || row["description"] || List.first(Map.get(row, "snippets", []))
            )
            |> optional("published", row["published"])
            |> optional("siteName", row["siteName"])

          Enum.reduce(~w(title snippet siteName), {fields, state}, fn key,
                                                                      {current, {left, cut}} ->
            if is_binary(current[key]) do
              text = String.trim(current[key])
              {value, used} = TextBudget.take(text, left)

              {Map.put(current, key, value), {left - used, cut or value != text}}
            else
              {current, {left, cut}}
            end
          end)
        end
      )

    public = %{
      "kind" => "results",
      "provider" => result["provider"],
      "query" => result["query"],
      "count" => length(results),
      "results" => results,
      "tookMs" => result["tookMs"]
    }

    if truncated, do: Map.put(public, "truncated", true), else: public
  end

  defp cache_key(config, arguments, generic) do
    identity =
      config
      |> Map.drop([:api_key, :timeout_ms, :cache_ttl_ms, :count, :ollama_prepared_base_url])
      |> Map.put(:credential_digest, :crypto.hash(:sha256, config[:api_key] || ""))

    identity =
      cond do
        config.provider == "minimax" ->
          Map.drop(identity, [:region, :mode])

        config.provider == "searxng" ->
          Map.drop(identity, [:mode, :categories, :language])

        config.provider == "duckduckgo" ->
          Map.drop(identity, [:mode, :region, :safe_search])

        config.provider in ["parallel", "parallel-free", "ollama", "grok"] ->
          Map.delete(identity, :mode)

        config.provider == "gemini" ->
          Map.drop(identity, [:mode, :request_time, :deadline_ms, :citation_transport])

        true ->
          identity
      end

    arguments =
      if config.provider == "perplexity" and config.mode == "chat_completions",
        do: Map.delete(arguments, "count"),
        else: arguments

    arguments =
      if config.provider in ["firecrawl", "firecrawl-free"],
        do: Map.delete(arguments, "timeout_seconds"),
        else: arguments

    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({identity, arguments, generic}, [:deterministic])
    )
  end

  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp failure(class, message), do: {:error, Error.new(class, message)}
end
