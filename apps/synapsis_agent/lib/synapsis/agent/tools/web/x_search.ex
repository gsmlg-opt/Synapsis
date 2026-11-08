defmodule Synapsis.Agent.Tools.Web.XSearch do
  @moduledoc "Selected xAI X searching through the existing native ToolEffects boundary."
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema, ToolCatalog, ToolEffects}
  alias Backplane.AgentRuntime.Codex.Session
  alias Synapsis.Agent.Tools.CatalogBinding
  alias Synapsis.{AgentConfig, AgentConfigs, Credentials}

  @name "synapsis::x_search"
  @keys ~w(identity agent_id agent_name tool_name config fingerprint session_binding)a
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a
  @config_keys ~w(credential_id base_url model timeout_ms inline_citations max_turns cache_ttl_ms)
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
            "Search X using configured xAI, including post or thread lookups, handle and date filters, and optional image or video understanding. For post statistics prefer an exact post URL or status ID.",
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
        false -> failure(:forbidden, "X search exceeds the parent authority ceiling")
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

      {:ok, %{action: "web.search", resource: "search:xai:" <> resource}}
    else
      false -> failure(:forbidden, "X search invocation scope changed")
      error -> error
    end
  end

  def classify(_, _, _), do: failure(:validation, "X search descriptor is unavailable")

  @impl true
  def execute(%{backend_context: enriched} = operation) when is_map(enriched) do
    context = Map.take(enriched, @keys)

    with {:ok, arguments, config} <- invocation(context, operation),
         {:ok, runtime} <- runtime(config) do
      case Synapsis.Web.XSearch.search(runtime, arguments, result_limit: @result_limit) do
        {:ok, public} -> output(public)
        error -> error
      end
    else
      {:error, %Error{} = error} -> ToolEffects.reject(operation, error)
      _ -> failure(:execution_failure, "X search configuration is unavailable")
    end
  rescue
    _ -> failure(:unknown_outcome, "X search execution could not be observed")
  catch
    :exit, _ -> failure(:unknown_outcome, "X search transport is unavailable")
  end

  def execute(_), do: failure(:validation, "X search context is unavailable")

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
      false -> failure(:budget_exceeded, "X search result exceeds the public result budget")
      _ -> failure(:malformed_result, "X search result is not portable JSON")
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
      false -> failure(:forbidden, "X search configuration changed; prepare a new run")
      {:error, %Error{}} = error -> error
      _ -> failure(:validation, "X search invocation is unavailable")
    end
  end

  defp configuration(name) do
    with %AgentConfig{enabled: true, config: saved} = agent <- AgentConfigs.get_by_name(name),
         raw when is_map(raw) <- saved["x_search"],
         true <- Map.keys(raw) -- @config_keys == [],
         credential_id when is_binary(credential_id) and credential_id != "" <-
           raw["credential_id"],
         base_url = Map.get(raw, "base_url", "https://api.x.ai/v1"),
         true <- is_binary(base_url) and String.valid?(base_url),
         base_url = String.trim(base_url),
         %URI{scheme: scheme, host: host} <- URI.parse(base_url),
         true <- scheme in ["http", "https"] and is_binary(host) and host != "",
         timeout_ms = Map.get(raw, "timeout_ms", 30_000),
         true <- is_integer(timeout_ms) and timeout_ms in 1..2_147_000_000,
         model = Map.get(raw, "model", "grok-4.7"),
         true <- is_binary(model) and String.valid?(model) and String.trim(model) != "",
         inline_citations = Map.get(raw, "inline_citations", false),
         true <- is_boolean(inline_citations),
         max_turns = raw["max_turns"],
         true <- is_nil(max_turns) or (is_integer(max_turns) and max_turns > 0),
         cache_ttl_ms = Map.get(raw, "cache_ttl_ms", 900_000),
         true <- is_integer(cache_ttl_ms) and cache_ttl_ms >= 0 do
      {:ok, agent,
       %{
         credential_id: credential_id,
         base_url: base_url,
         model: String.trim(model),
         timeout_ms: timeout_ms,
         inline_citations: inline_citations,
         max_turns: max_turns,
         cache_ttl_ms: cache_ttl_ms
       }}
    else
      _ ->
        failure(
          :unsupported_capability,
          "X search requires an enabled Agent with config.x_search and a credential reference"
        )
    end
  end

  defp runtime(config) do
    with {:ok, key} when is_binary(key) and key != "" <-
           Credentials.resolve(config.credential_id),
         {:ok, version} <- Credentials.version(config.credential_id) do
      {:ok, Map.merge(config, %{api_key: key, credential_version: version})}
    else
      _ -> failure(:unsupported_capability, "X search credential is unavailable")
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
      "required" => ["query"],
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "Natural-language instruction for the Grok X-search agent."
        },
        "allowed_x_handles" => %{
          "type" => "array",
          "maxItems" => 20,
          "items" => %{"type" => "string", "minLength" => 1}
        },
        "excluded_x_handles" => %{
          "type" => "array",
          "maxItems" => 20,
          "items" => %{"type" => "string", "minLength" => 1}
        },
        "from_date" => %{"type" => "string", "description" => "Posts on or after YYYY-MM-DD."},
        "to_date" => %{"type" => "string", "description" => "Posts on or before YYYY-MM-DD."},
        "enable_image_understanding" => %{"type" => "boolean"},
        "enable_video_understanding" => %{"type" => "boolean"}
      }
    }
  end

  defp failure(class, message), do: {:error, Error.new(class, message)}
end
