defmodule Synapsis.Agent.Tools.Web.Scrape do
  @moduledoc "Selected Firecrawl scraping through the existing native ToolEffects boundary."
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema, ToolCatalog, ToolEffects}
  alias Backplane.AgentRuntime.Codex.Session
  alias Synapsis.Agent.Tools.CatalogBinding
  alias Synapsis.{AgentConfig, AgentConfigs, Credentials}

  @name "synapsis::firecrawl_scrape"
  @keys ~w(identity agent_id agent_name tool_name config fingerprint session_binding)a
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a
  @config_keys ~w(credential_id base_url timeout_ms only_main_content max_age_ms max_chars_cap)
  @result_limit 1_000_000
  @text_limit 262_144

  def names, do: [@name]
  def permission_level(@name), do: :read

  def bundles(context, identity, authority, selection, binding) do
    if @name in selection do
      with true <- @name in authority.grants,
           {:ok, agent, config} <- configuration(context.agent[:name]) do
        trusted = %{
          identity: identity,
          agent_id: agent.id,
          agent_name: agent.name,
          tool_name: @name,
          config: config,
          fingerprint: fingerprint(agent, config),
          session_binding: binding
        }

        descriptor = %{
          tool_name: @name,
          tool_revision: 1,
          description:
            "Scrape a page with configured Firecrawl, preserving Markdown or converting it to text. Supports main-content, age, proxy and remote-cache options. Endpoint and credential are Agent configuration.",
          schema: schema(),
          safety: %{read_only: true, retry_safe: false, parallel_safe: true},
          backend: __MODULE__,
          backend_context: trusted
        }

        ceiling = %{
          authority
          | grants: [@name],
            tool_revisions: Map.take(authority.tool_revisions, [@name])
        }

        case ToolCatalog.admit_batch([descriptor], authority: ceiling, mode: :strict) do
          {:ok, bundle} -> {:ok, [bundle]}
          error -> error
        end
      else
        false -> failure(:forbidden, "Scrape exceeds the parent authority ceiling")
        error -> error
      end
    else
      {:ok, []}
    end
  end

  def classify(%{backend: __MODULE__, backend_context: context}, identity, operation) do
    with true <- context.identity === identity,
         {:ok, arguments, _config} <- invocation(context, operation) do
      resource =
        :crypto.hash(
          :sha256,
          :erlang.term_to_binary({context.agent_id, arguments}, [:deterministic])
        )
        |> Base.encode16(case: :lower)

      {:ok, %{action: "web.scrape", resource: "scrape:firecrawl:" <> resource}}
    else
      false -> failure(:forbidden, "Scrape invocation scope changed")
      error -> error
    end
  end

  def classify(_, _, _), do: failure(:validation, "Scrape descriptor is unavailable")

  @impl true
  def execute(%{backend_context: enriched} = operation) when is_map(enriched) do
    context = Map.take(enriched, @keys)

    with {:ok, arguments, config} <- invocation(context, operation),
         {:ok, runtime} <- runtime(config) do
      case Synapsis.Web.Scrape.scrape(runtime, arguments, result_limit: @result_limit) do
        {:ok, public} -> output(public)
        error -> error
      end
    else
      {:error, %Error{} = error} -> ToolEffects.reject(operation, error)
      _ -> failure(:execution_failure, "Scrape configuration is unavailable")
    end
  rescue
    _ -> failure(:unknown_outcome, "Scrape execution could not be observed")
  catch
    :exit, _ -> failure(:unknown_outcome, "Scrape transport is unavailable")
  end

  def execute(_), do: failure(:validation, "Scrape context is unavailable")

  # The existing HTTP transport runs in a linked child of the native effect.
  @impl true
  def cancel(_operation), do: :ok

  defp output(public) do
    with {:ok, text} <- Jason.encode(public),
         true <- byte_size(text) <= @text_limit,
         result = %{content: text, structured: public},
         true <- :erlang.external_size(result) <= @result_limit do
      {:ok, result}
    else
      false -> failure(:budget_exceeded, "Scrape result exceeds the public result budget")
      _ -> failure(:malformed_result, "Scrape result is not portable JSON")
    end
  end

  defp invocation(context, operation) do
    with true <- Enum.sort(Map.keys(context)) == Enum.sort(@keys),
         true <- context.tool_name == @name and operation[:tool_name] === @name,
         :ok <-
           CatalogBinding.host(context, operation, __MODULE__, 1, @native_keys, context.identity),
         {:ok, _} <- Session.validate(context.session_binding, operation),
         {:ok, agent, config} <- configuration(context.agent_name),
         true <-
           agent.id === context.agent_id and config === context.config and
             fingerprint(agent, config) === context.fingerprint,
         {:ok, arguments} <- InputSchema.validate(schema(), operation.arguments) do
      {:ok, arguments, config}
    else
      false -> failure(:forbidden, "Scrape configuration changed; prepare a new run")
      {:error, %Error{}} = error -> error
      _ -> failure(:validation, "Scrape invocation is unavailable")
    end
  end

  defp configuration(name) do
    with %AgentConfig{enabled: true, config: saved} = agent <- AgentConfigs.get_by_name(name),
         raw when is_map(raw) <- saved["firecrawl_scrape"],
         true <- Map.keys(raw) -- @config_keys == [],
         credential_id when is_binary(credential_id) and credential_id != "" <-
           raw["credential_id"],
         base_url = Map.get(raw, "base_url", "https://api.firecrawl.dev"),
         true <- is_binary(base_url) and String.valid?(base_url),
         %URI{scheme: scheme, host: host} <- URI.parse(base_url),
         true <- scheme in ["http", "https"] and is_binary(host) and host != "",
         timeout_ms = Map.get(raw, "timeout_ms", 60_000),
         true <- is_integer(timeout_ms) and timeout_ms in 1..2_147_000_000,
         only_main_content = Map.get(raw, "only_main_content", true),
         true <- is_boolean(only_main_content),
         max_age_ms = Map.get(raw, "max_age_ms", 172_800_000),
         true <- is_integer(max_age_ms) and max_age_ms >= 0,
         max_chars_cap = Map.get(raw, "max_chars_cap", 50_000),
         true <- is_integer(max_chars_cap) and max_chars_cap > 0 do
      {:ok, agent,
       %{
         credential_id: credential_id,
         base_url: base_url,
         timeout_ms: timeout_ms,
         only_main_content: only_main_content,
         max_age_ms: max_age_ms,
         max_chars_cap: max_chars_cap
       }}
    else
      _ ->
        failure(
          :unsupported_capability,
          "Scrape requires an enabled Agent with config.firecrawl_scrape and a credential reference"
        )
    end
  end

  defp runtime(config) do
    with {:ok, key} when is_binary(key) and key != "" <-
           Credentials.resolve(config.credential_id),
         {:ok, version} <- Credentials.version(config.credential_id) do
      {:ok, Map.merge(config, %{api_key: key, credential_version: version})}
    else
      _ -> failure(:unsupported_capability, "Scrape credential is unavailable")
    end
  end

  defp fingerprint(agent, config),
    do:
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({agent.id, agent.name, agent.tools, config}, [:deterministic])
      )

  defp schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["url"],
      "properties" => %{
        "url" => %{
          "type" => "string",
          "description" => "HTTP or HTTPS URL to scrape via Firecrawl."
        },
        "extractMode" => %{"type" => "string", "enum" => ["markdown", "text"]},
        "maxChars" => %{"type" => "integer", "minimum" => 100},
        "onlyMainContent" => %{"type" => "boolean"},
        "maxAgeMs" => %{"type" => "integer", "minimum" => 0},
        "proxy" => %{"type" => "string", "enum" => ["auto", "basic", "stealth"]},
        "storeInCache" => %{"type" => "boolean"},
        "timeoutSeconds" => %{"type" => "integer", "minimum" => 1}
      }
    }
  end

  defp failure(class, message), do: {:error, Error.new(class, message)}
end
