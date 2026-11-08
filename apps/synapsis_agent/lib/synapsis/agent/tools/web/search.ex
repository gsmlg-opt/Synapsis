defmodule Synapsis.Agent.Tools.Web.Search do
  @moduledoc """
  Selected host search contracts using the public native Web adapter boundary.

  Agent configuration selects the generic provider. Dedicated contracts retain
  Tavily and Firecrawl options and results. Descriptors contain configuration
  references only; existing credentials are resolved inside each effect. The
  original query and arguments remain native invocation and history data.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema, ToolCatalog, ToolEffects}
  alias Backplane.AgentRuntime.Codex.{Session, Web}
  alias Synapsis.Agent.Tools.CatalogBinding
  alias Synapsis.{AgentConfig, AgentConfigs, Credentials}

  @generic "synapsis::web_search"
  @tavily "synapsis::tavily_search"
  @firecrawl "synapsis::firecrawl_search"
  @names [@generic, @tavily, @firecrawl]
  @keys ~w(identity agent_id agent_name tool_name config fingerprint session_binding)a
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a
  @config_keys ~w(provider credential_id base_url timeout_ms cache_ttl_ms count mode)
  @timer_limit 2_147_000_000
  @result_limit 1_000_000
  @text_limit 262_144

  def names, do: @names
  def permission_level(name) when name in @names, do: :read

  def bundles(context, identity, authority, selection, binding) do
    selected = Enum.filter(@names, &(&1 in selection))

    with true <- Enum.all?(selected, &(&1 in authority.grants)),
         {:ok, descriptors} <- descriptors(context, identity, selected, binding) do
      if descriptors == [] do
        {:ok, []}
      else
        ceiling = %{
          authority
          | grants: selected,
            tool_revisions: Map.take(authority.tool_revisions, selected)
        }

        case ToolCatalog.admit_batch(descriptors, authority: ceiling, mode: :strict) do
          {:ok, bundle} -> {:ok, [bundle]}
          error -> error
        end
      end
    else
      false -> failure(:forbidden, "Search exceeds the parent authority ceiling")
      error -> error
    end
  end

  def classify(%{backend: __MODULE__, backend_context: context}, identity, operation) do
    with true <- context.identity === identity,
         {:ok, arguments, config} <- invocation(context, operation) do
      resource =
        :crypto.hash(
          :sha256,
          :erlang.term_to_binary(
            {context.agent_id, context.tool_name, config.provider, arguments},
            [:deterministic]
          )
        )
        |> Base.encode16(case: :lower)

      {:ok, %{action: "web.search", resource: "search:" <> config.provider <> ":" <> resource}}
    else
      false -> failure(:forbidden, "Search invocation scope changed")
      error -> error
    end
  end

  def classify(_, _, _), do: failure(:validation, "Search descriptor is unavailable")

  @impl true
  def execute(%{backend_context: enriched} = operation) when is_map(enriched) do
    effect_deadline = Map.get(enriched, :effect_deadline)
    context = Map.take(enriched, @keys)

    with {:ok, arguments, config} <- invocation(context, operation),
         {:ok, runtime} <- runtime(config),
         {:ok, trusted_opts} <- execution_opts(runtime, effect_deadline) do
      execute_ready(arguments, runtime, context.tool_name, trusted_opts)
    else
      {:error, %Error{} = error} -> ToolEffects.reject(operation, error)
      _ -> failure(:execution_failure, "Search configuration is unavailable")
    end
  rescue
    _ -> failure(:unknown_outcome, "Search execution could not be observed")
  catch
    :exit, _ -> failure(:unknown_outcome, "Search execution transport is unavailable")
  end

  def execute(_), do: failure(:validation, "Search context is unavailable")

  @impl true
  # HTTP runs in a linked child of the native effect. Native cancellation owns
  # effect termination; the shared cache process never performs HTTP work.
  def cancel(_operation), do: :ok

  defp execute_ready(arguments, runtime, name, trusted_opts) do
    if Code.ensure_loaded?(Synapsis.Web.Search) do
      opts = [
        search_config: runtime,
        arguments: arguments,
        generic: name == @generic,
        timeout: runtime.timeout_ms,
        result_limit: @result_limit
      ]

      opts = Keyword.merge(opts, trusted_opts)

      opts =
        if runtime.provider == "parallel-free",
          do: Keyword.put(opts, :uncached_search, &Synapsis.MCP.ParallelSearch.search/2),
          else: opts

      case Web.search(Synapsis.Web.Search, query_anchor(arguments, runtime), opts) do
        {:ok, public} -> output(public)
        error -> error
      end
    else
      failure(:unsupported_capability, "Search adapter is unavailable")
    end
  end

  defp execution_opts(%{provider: "gemini"} = runtime, accessor) do
    configured = System.monotonic_time(:millisecond) + runtime.timeout_ms

    case accessor do
      nil ->
        {:ok, [deadline_ms: configured]}

      getter when is_function(getter, 0) ->
        case getter.() do
          {:ok, %{deadline_ms: deadline, remaining_ms: remaining, paused: false}}
          when is_integer(deadline) and is_integer(remaining) and remaining > 0 ->
            # Absolute monotonic timestamps can be negative. Only the remaining
            # duration and comparison with the same monotonic clock matter.
            if deadline > System.monotonic_time(:millisecond),
              do: {:ok, [deadline_ms: min(configured, deadline)]},
              else: failure(:timeout, "Search effect deadline expired")

          _ ->
            failure(:timeout, "Search effect deadline is unavailable")
        end

      _ ->
        failure(:validation, "Search effect deadline is invalid")
    end
  end

  defp execution_opts(_runtime, _accessor), do: {:ok, []}

  defp query_anchor(arguments, %{provider: provider})
       when provider in ["parallel", "parallel-free"] do
    objective = String.trim(arguments["objective"] || "")

    if objective != "" do
      objective
    else
      arguments["search_queries"]
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")
    end
  end

  defp query_anchor(arguments, _runtime), do: arguments["query"]

  defp output(public) do
    case Jason.encode(public) do
      {:ok, text} when byte_size(text) <= @text_limit ->
        result = Map.put(public, "content", text)

        result =
          if public["kind"] == "answer", do: Map.put(result, :structured, public), else: result

        if :erlang.external_size(result) <= @result_limit,
          do: {:ok, result},
          else: failure(:budget_exceeded, "Search result exceeds the public result budget")

      {:ok, _} ->
        failure(:budget_exceeded, "Search result exceeds the public text budget")

      _ ->
        failure(:malformed_result, "Search result is not portable JSON")
    end
  end

  defp descriptors(_context, _identity, [], _binding), do: {:ok, []}

  defp descriptors(context, identity, selected, binding) do
    Enum.reduce_while(selected, {:ok, []}, fn name, {:ok, descriptors} ->
      case configuration(context.agent[:name], name) do
        {:ok, agent, config} ->
          trusted = %{
            identity: identity,
            agent_id: agent.id,
            agent_name: agent.name,
            tool_name: name,
            config: config,
            fingerprint: fingerprint(agent, name, config),
            session_binding: binding
          }

          {:cont, {:ok, descriptors ++ [descriptor(trusted)]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp descriptor(context) do
    %{
      tool_name: context.tool_name,
      tool_revision: 1,
      description: description(context.tool_name, context.config),
      schema: schema(context.tool_name, context.config),
      safety: %{read_only: true, retry_safe: false, parallel_safe: true},
      backend: __MODULE__,
      backend_context: context
    }
  end

  defp invocation(context, operation) do
    with true <- Enum.sort(Map.keys(context)) == Enum.sort(@keys),
         true <- context.tool_name in @names and operation[:tool_name] === context.tool_name,
         :ok <-
           CatalogBinding.host(context, operation, __MODULE__, 1, @native_keys, context.identity),
         {:ok, _} <- Session.validate(context.session_binding, operation),
         {:ok, agent, config} <- configuration(context.agent_name, context.tool_name),
         true <-
           agent.id === context.agent_id and config === context.config and
             fingerprint(agent, context.tool_name, config) === context.fingerprint,
         {:ok, arguments} <-
           InputSchema.validate(schema(context.tool_name, config), operation.arguments) do
      {:ok, arguments, config}
    else
      false -> failure(:forbidden, "Search configuration changed; prepare a new run")
      {:error, %Error{}} = error -> error
      _ -> failure(:validation, "Search invocation is unavailable")
    end
  end

  defp configuration(agent_name, name) do
    with %AgentConfig{enabled: true, config: config} = agent <-
           AgentConfigs.get_by_name(agent_name),
         true <- is_map(config),
         raw when is_map(raw) <- config[config_key(name)],
         true <-
           Map.keys(raw) --
             (@config_keys ++
                (case raw["provider"] do
                   "perplexity" -> ["model"]
                   "gemini" -> ["model", "headers"]
                   "grok" -> ["model", "inline_citations"]
                   "minimax" -> ["region"]
                   "searxng" -> ["categories", "language"]
                   "duckduckgo" -> ["region", "safe_search"]
                   _ -> []
                 end)) == [],
         {:ok, provider} <- provider(name, raw["provider"]),
         {:ok, normalized} <- normalize_config(name, provider, raw),
         {:ok, normalized} <- citation_config(normalized, config["web_allowed_hosts"]) do
      {:ok, agent, normalized}
    else
      _ ->
        failure(
          :unsupported_capability,
          "Search requires an enabled Agent and explicit configured provider and credential reference"
        )
    end
  end

  defp citation_config(%{provider: "gemini"} = config, hosts) do
    hosts = if is_nil(hosts), do: [], else: hosts

    if is_list(hosts) and Enum.all?(hosts, &valid_host?/1) do
      {:ok,
       config
       |> Map.put(
         :citation_allowed_hosts,
         hosts |> Enum.map(&String.downcase/1) |> Enum.uniq() |> Enum.sort()
       )
       |> Map.put(:citation_policy, :declared_hosts_v1)}
    else
      failure(:validation, "Gemini citation hosts must be a list of explicit host names")
    end
  end

  defp citation_config(config, _hosts), do: {:ok, config}

  defp valid_host?(host) when is_binary(host) and byte_size(host) in 1..253 do
    String.valid?(host) and String.trim(host) == host and
      not String.match?(host, ~r/[\s\x00-\x1f\x7f\/:@?#*]/u) and
      match?(
        %URI{host: ^host, userinfo: nil, path: nil, query: nil, fragment: nil},
        URI.parse("https://" <> host)
      )
  end

  defp valid_host?(_), do: false

  defp normalize_config(name, provider, raw) do
    config = %{
      provider: provider,
      credential_id:
        if(provider in ["firecrawl-free", "parallel-free", "searxng", "duckduckgo"],
          do: nil,
          else: raw["credential_id"]
        ),
      base_url: Map.get(raw, "base_url", base_url(provider)),
      timeout_ms:
        Map.get(
          raw,
          "timeout_ms",
          case provider do
            "grok" -> 60_000
            "ollama" -> 15_000
            "searxng" -> 20_000
            "duckduckgo" -> 20_000
            _ -> 30_000
          end
        ),
      cache_ttl_ms: Map.get(raw, "cache_ttl_ms", 900_000),
      count: Map.get(raw, "count", 5),
      mode: Map.get(raw, "mode", if(provider == "perplexity", do: "search_api", else: "web"))
    }

    config =
      if provider == "perplexity",
        do: Map.put(config, :model, Map.get(raw, "model", "perplexity/sonar-pro")),
        else: config

    config =
      if provider == "gemini",
        do:
          config
          |> Map.put(:model, raw["model"])
          |> Map.put(:headers, Map.get(raw, "headers", %{})),
        else: config

    config =
      if provider == "grok",
        do:
          config
          |> Map.put(:model, raw["model"])
          |> Map.put(:inline_citations, Map.get(raw, "inline_citations", false)),
        else: config

    config =
      if provider == "minimax",
        do: Map.put(config, :region, Map.get(raw, "region", "global")),
        else: config

    config =
      if provider == "searxng",
        do:
          config |> Map.put(:categories, raw["categories"]) |> Map.put(:language, raw["language"]),
        else: config

    config =
      if provider == "duckduckgo",
        do:
          config |> Map.put(:region, raw["region"]) |> Map.put(:safe_search, raw["safe_search"]),
        else: config

    config =
      if provider in ["parallel", "parallel-free"] do
        Map.update!(config, :count, fn
          value when is_number(value) -> value |> floor() |> max(1) |> min(40)
          _ -> 5
        end)
      else
        config
      end

    with true <-
           provider != "searxng" or
             Enum.all?(~w(categories language), fn field ->
               is_nil(raw[field]) or is_binary(raw[field])
             end),
         true <-
           provider != "duckduckgo" or
             Enum.all?(~w(region safe_search), fn field ->
               is_nil(raw[field]) or is_binary(raw[field])
             end),
         {:ok, config} <- Synapsis.Provider.WebSearch.prepare_config(config),
         true <- provider != "minimax" or config.region in ["global", "cn"],
         true <-
           provider in ["firecrawl-free", "parallel-free", "searxng", "duckduckgo"] or
             (provider == "ollama" and
                not Synapsis.Provider.WebSearch.Ollama.hosted?(config.base_url) and
                is_nil(config.credential_id)) or
             nonempty_string?(config.credential_id),
         true <- absolute_http_url?(config.base_url),
         true <- is_integer(config.timeout_ms) and config.timeout_ms in 1..@timer_limit,
         true <- is_integer(config.cache_ttl_ms) and config.cache_ttl_ms in 0..@timer_limit,
         true <- is_integer(config.count) and config.count in 1..max_count(name, provider),
         true <-
           if(provider == "perplexity",
             do:
               config.mode in ["search_api", "chat_completions"] and
                 nonempty_string?(config.model),
             else: config.mode in ["web", "llm-context"]
           ) do
      {:ok,
       if(provider == "perplexity", do: Map.update!(config, :model, &String.trim/1), else: config)}
    else
      _ -> failure(:validation, "Search configuration is invalid")
    end
  end

  defp runtime(%{provider: provider} = config)
       when provider in ["firecrawl-free", "parallel-free", "searxng", "duckduckgo"],
       do: {:ok, Map.merge(config, %{api_key: nil, credential_version: nil})}

  defp runtime(%{provider: "ollama", credential_id: nil} = config),
    do: {:ok, Map.merge(config, %{api_key: nil, credential_version: nil})}

  defp runtime(config) do
    with {:ok, key} when is_binary(key) and key != "" <-
           Credentials.resolve(config.credential_id),
         {:ok, version} <- Credentials.version(config.credential_id) do
      {:ok, Map.merge(config, %{api_key: key, credential_version: version})}
    else
      _ -> failure(:unsupported_capability, "Search credential is unavailable")
    end
  end

  defp provider(@generic, provider)
       when provider in [
              "brave",
              "tavily",
              "firecrawl",
              "firecrawl-free",
              "perplexity",
              "exa",
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
       do: {:ok, provider}

  defp provider(@tavily, provider) when provider in [nil, "tavily"], do: {:ok, "tavily"}
  defp provider(@firecrawl, nil), do: {:ok, "firecrawl"}

  defp provider(@firecrawl, provider) when provider in ["firecrawl", "firecrawl-free"],
    do: {:ok, provider}

  defp provider(_, _), do: failure(:validation, "Search provider must be explicitly configured")

  defp config_key(@generic), do: "web_search"
  defp config_key(@tavily), do: "tavily_search"
  defp config_key(@firecrawl), do: "firecrawl_search"
  defp base_url("perplexity"), do: "https://api.perplexity.ai"
  defp base_url("exa"), do: "https://api.exa.ai"
  defp base_url("deepseek"), do: "https://api.deepseek.com"
  defp base_url("kimi"), do: "https://api.moonshot.ai/v1"
  defp base_url("minimax"), do: nil
  defp base_url("parallel"), do: "https://api.parallel.ai/v1/search"
  defp base_url("parallel-free"), do: "https://search.parallel.ai/mcp"
  defp base_url("ollama"), do: "http://127.0.0.1:11434"
  defp base_url("gemini"), do: "https://generativelanguage.googleapis.com/v1beta"
  defp base_url("grok"), do: "https://api.x.ai/v1"
  defp base_url("searxng"), do: nil
  defp base_url("duckduckgo"), do: "https://html.duckduckgo.com/html"
  defp base_url("brave"), do: "https://api.search.brave.com"
  defp base_url("tavily"), do: "https://api.tavily.com"

  defp base_url(provider) when provider in ["firecrawl", "firecrawl-free"],
    do: "https://api.firecrawl.dev"

  defp max_count(@generic, "exa"), do: 100
  defp max_count(@generic, provider) when provider in ["parallel", "parallel-free"], do: 40
  defp max_count(@generic, _provider), do: 10
  defp max_count(@tavily, _provider), do: 20
  defp max_count(@firecrawl, _provider), do: 100

  defp fingerprint(agent, name, config),
    do:
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({agent.id, agent.name, agent.tools, name, config}, [:deterministic])
      )

  defp nonempty_string?(value),
    do: is_binary(value) and String.valid?(value) and String.trim(value) != ""

  defp absolute_http_url?(value) do
    if nonempty_string?(value) do
      uri = URI.parse(value)
      uri.scheme in ["http", "https"] and nonempty_string?(uri.host)
    else
      false
    end
  end

  defp description(@generic, %{provider: provider})
       when provider in ["parallel", "parallel-free"],
       do:
         if(provider == "parallel-free",
           do: "Search the web using Parallel's free Search MCP (no API key). ",
           else: "Search the web using Parallel. "
         ) <>
           "Returns ranked, LLM-optimized dense excerpts from web sources. " <>
           "Pass an `objective` describing the underlying question along with 2-3 short keyword " <>
           "`search_queries` (Parallel's recommended pairing). For multi-step research, thread the prior " <>
           "result's `sessionId` back in as `session_id` to keep Parallel's context grouped."

  defp description(@generic, %{provider: "minimax"}),
    do:
      "Search the web using MiniMax Search API. Returns titles, URLs, snippets, and related search suggestions."

  defp description(@generic, %{provider: "ollama"}),
    do:
      "Search the web using Ollama's web search API. Returns titles, URLs, and snippets from the configured Ollama host."

  defp description(@generic, %{provider: "searxng"}),
    do: "Search the web using a self-hosted SearXNG instance. Returns titles, URLs, and snippets."

  defp description(@generic, %{provider: "duckduckgo"}),
    do:
      "Search the web using DuckDuckGo. Returns titles, URLs, and snippets with no API key required."

  defp description(@generic, %{provider: "gemini"}),
    do:
      "Search the web using Gemini with Google Search grounding. Returns AI-synthesized answers with citations from Google Search."

  defp description(@generic, %{provider: "grok"}),
    do:
      "Search the web using xAI Grok. Returns AI-synthesized answers with citations from real-time web search."

  defp description(@generic, %{provider: "kimi"}),
    do:
      "Search the web using Kimi by Moonshot. Returns structured results with titles, URLs, and descriptions."

  defp description(@generic, %{provider: "deepseek"}),
    do:
      "Search the web using DeepSeek. Returns titles, URLs, and model-oriented summaries. " <>
        "Queries support site:, -site:, lang:, after:, before:, and quoted phrases; maximum 128 Unicode characters."

  defp description(@generic, %{provider: "perplexity", mode: "chat_completions"}),
    do:
      "Search Perplexity Sonar for AI-synthesized answers with ordered citations. Count is accepted but does not affect Sonar requests. Provider, model, endpoint and credentials are Agent configuration."

  defp description(@generic, %{provider: provider}),
    do:
      "Search the web using the explicitly configured #{provider} provider. " <>
        "Returns up to 10 normalized ordered results. Provider, endpoint and credentials " <>
        "are Agent configuration, not tool arguments. Successful requests may use a bounded TTL cache."

  defp description(@tavily, _provider),
    do:
      "Search Tavily with depth, topic, recency and domain filters. Returns up to 20 " <>
        "ordered results, retaining answer summaries and scores when returned."

  defp description(@firecrawl, _provider),
    do:
      "Search Firecrawl with sources, categories, domain/time/location filters and optional " <>
        "scraped Markdown. Returns up to 100 ordered results. A per-call timeout_seconds " <>
        "bounds the HTTP request; the native effect watchdog remains authoritative."

  defp schema(@generic, %{provider: "duckduckgo"}) do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "description" => "Search query string."},
        "count" => %{
          "type" => "integer",
          "description" => "Number of results to return (1-10).",
          "minimum" => 1,
          "maximum" => 10
        },
        "region" => %{
          "type" => "string",
          "description" => "Optional DuckDuckGo region code such as us-en, uk-en, or de-de."
        },
        "safeSearch" => %{
          "type" => "string",
          "description" => "SafeSearch level: strict, moderate, or off."
        }
      },
      "required" => ["query"],
      "additionalProperties" => false
    }
  end

  defp schema(@generic, %{provider: "gemini"}) do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "description" => "Search query string."},
        "count" => %{
          "type" => "integer",
          "description" => "Number of results to return (1-10).",
          "minimum" => 1,
          "maximum" => 10
        },
        "country" => %{"type" => "string", "description" => "Not supported by Gemini."},
        "language" => %{"type" => "string", "description" => "Not supported by Gemini."},
        "freshness" => %{
          "type" => "string",
          "description" =>
            "Filter Gemini search freshness: week, month, and year use hard Google Search time ranges; day prioritizes the last 24 hours as a recency hint."
        },
        "date_after" => %{
          "type" => "string",
          "description" => "Only ground with results published after this date (YYYY-MM-DD)."
        },
        "date_before" => %{
          "type" => "string",
          "description" => "Only ground with results published before this date (YYYY-MM-DD)."
        }
      },
      "required" => ["query"],
      "additionalProperties" => false
    }
  end

  defp schema(@generic, %{provider: provider}) when provider in ["parallel", "parallel-free"] do
    %{
      "type" => "object",
      "properties" => %{
        "objective" => %{
          "type" => "string",
          "description" =>
            "Natural-language description of the underlying question or goal driving the search. " <>
              "Should be self-contained with enough context to understand the intent. Used together " <>
              "with search_queries to focus results on the most relevant content.",
          "maxLength" => 5_000
        },
        "search_queries" => %{
          "type" => "array",
          "description" =>
            "Concise keyword search queries, 3-6 words each. Provide 2-3 diverse queries for best " <>
              "results (max 5). Vary entity names, synonyms, and angles. Each query is a keyword " <>
              "phrase, not a sentence; do not use site: operators.",
          "items" => %{"type" => "string", "maxLength" => 200},
          "minItems" => 1,
          "maxItems" => 5
        },
        "count" => %{
          "type" => "integer",
          "description" => "Number of results to return (1-40).",
          "minimum" => 1,
          "maximum" => 40
        },
        "session_id" => %{
          "type" => "string",
          "description" =>
            "Optional session id returned by an earlier Parallel search. Pass it on follow-up " <>
              "searches that are part of the same task to keep Parallel's server-side context " <>
              "grouped (look for `sessionId` in the prior tool result).",
          "maxLength" => if(provider == "parallel-free", do: 100, else: 1_000)
        },
        "client_model" => %{
          "type" => "string",
          "description" =>
            "The identifier of the LLM model making this tool call (e.g. 'claude-opus-4-7', " <>
              "'gpt-6-astra', 'gemini-3.1-pro'). Pass the exact active model slug verbatim; never " <>
              "shorten or substitute a family alias like 'gpt-5'. Lets Parallel tailor default " <>
              "settings for your model's capabilities.",
          "maxLength" => 100
        }
      },
      "required" => ["objective", "search_queries"],
      "additionalProperties" => false
    }
  end

  defp schema(name, config) do
    properties = %{
      "query" => %{"type" => "string", "minLength" => 1},
      "count" => %{
        "type" => "integer",
        "minimum" => 1,
        "maximum" => max_count(name, config.provider)
      }
    }

    properties =
      if name == @generic and config.provider in ["kimi", "minimax", "ollama", "grok", "searxng"] do
        properties
        |> Map.put("query", %{"type" => "string", "description" => "Search query string."})
        |> Map.update!(
          "count",
          &Map.put(&1, "description", "Number of results to return (1-10).")
        )
      else
        properties
      end

    properties =
      if name == @generic and config.provider == "deepseek" do
        properties
        |> Map.update!("query", fn query ->
          Map.merge(query, %{
            "maxLength" => 128,
            "description" => "Search query, including any search operators."
          })
        end)
        |> Map.update!(
          "count",
          &Map.put(&1, "description", "Number of results (1-10; default 5).")
        )
      else
        properties
      end

    %{
      "type" => "object",
      "properties" => Map.merge(properties, extra_properties(name, config)),
      "required" => ["query"],
      "additionalProperties" => false
    }
  end

  defp extra_properties(@generic, %{provider: "kimi"}) do
    Map.new(
      ~w(country language freshness date_after date_before),
      &{&1, %{"type" => "string", "description" => "Not supported by Kimi."}}
    )
  end

  defp extra_properties(@generic, %{provider: "searxng"}) do
    %{
      "categories" => %{
        "type" => "string",
        "description" =>
          "Optional comma-separated search categories such as general, news, or science."
      },
      "language" => %{
        "type" => "string",
        "description" => "Optional language code for results such as en, de, or fr."
      }
    }
  end

  defp extra_properties(@generic, %{provider: "perplexity", mode: "chat_completions"}),
    do: %{"freshness" => %{"type" => "string"}}

  defp extra_properties(@generic, %{provider: "exa"}) do
    %{
      "type" => string_enum(~w(auto neural fast deep deep-reasoning instant)),
      "freshness" => string_enum(~w(day week month year)),
      "date_after" => %{"type" => "string"},
      "date_before" => %{"type" => "string"},
      "contents" => %{
        "type" => "object",
        "properties" => %{
          "text" => contents_option(~w(maxCharacters)),
          "highlights" => contents_option(~w(maxCharacters query numSentences highlightsPerUrl)),
          "summary" => contents_option(~w(query))
        },
        "additionalProperties" => false
      }
    }
  end

  defp extra_properties(@generic, %{provider: "perplexity"}) do
    Map.new(~w(freshness country language date_after date_before), &{&1, %{"type" => "string"}})
    |> Map.merge(%{
      "domain_filter" => string_array(),
      "max_tokens" => %{"type" => "integer", "minimum" => 1, "maximum" => 1_000_000},
      "max_tokens_per_page" => %{"type" => "integer", "minimum" => 1}
    })
  end

  defp extra_properties(@generic, %{provider: "brave"}) do
    Map.new(
      ~w(country language freshness date_after date_before search_lang ui_lang),
      &{&1, %{"type" => "string"}}
    )
  end

  defp extra_properties(@generic, _provider), do: %{}

  defp extra_properties(@tavily, _provider) do
    %{
      "search_depth" => string_enum(~w(basic advanced)),
      "topic" => string_enum(~w(general news finance)),
      "include_answer" => %{"type" => "boolean"},
      "time_range" => string_enum(~w(day week month year)),
      "include_domains" => string_array(),
      "exclude_domains" => string_array()
    }
  end

  defp extra_properties(@firecrawl, _provider) do
    %{
      "sources" => string_array(),
      "categories" => string_array(),
      "include_domains" => string_array(),
      "exclude_domains" => string_array(),
      "tbs" => %{"type" => "string"},
      "location" => %{"type" => "string"},
      "country" => %{"type" => "string"},
      "scrape_results" => %{"type" => "boolean"},
      "timeout_seconds" => %{
        "type" => "integer",
        "minimum" => 1,
        "maximum" => div(@timer_limit, 1_000)
      }
    }
  end

  defp contents_option(fields) do
    properties =
      Map.new(fields, fn
        "query" -> {"query", %{"type" => "string"}}
        field -> {field, %{"type" => "integer", "minimum" => 1}}
      end)

    %{
      "oneOf" => [
        %{"type" => "boolean"},
        %{"type" => "object", "properties" => properties, "additionalProperties" => false}
      ]
    }
  end

  defp string_enum(values), do: %{"type" => "string", "enum" => values}
  defp string_array, do: %{"type" => "array", "items" => %{"type" => "string"}}
  defp failure(class, message), do: {:error, Error.new(class, message)}
end
