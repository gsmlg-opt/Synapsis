defmodule Synapsis.Agent.Tools.Decisions do
  @moduledoc """
  Selected native decision evaluation of caller-supplied evidence.

  Agent `decision.provider` and `decision.model` explicitly declare the native
  endpoint/model capability. This host does not infer it from the chat catalog.
  Native semantic maps use deterministic provider serialization; the original
  function argument order is not available. Arrays and text remain unchanged.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema, ToolCatalog, ToolEffects}
  alias Backplane.AgentRuntime.Codex.Session
  alias Synapsis.Agent.Tools.CatalogBinding
  alias Synapsis.Provider.Decision
  alias Synapsis.Provider.Decision.{OpenAI, OpenRouter}
  alias Synapsis.{AgentConfig, AgentConfigs, Providers}

  @name "synapsis::decision_evaluate"
  @keys ~w(identity agent_id agent_name fingerprint provider_id provider_name provider_type provider_fingerprint runtime_generation session_binding)a
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a
  @timeout 30_000
  @openrouter_models ~w(typesafe/jev-1.13 typesafe/jev-1.14 ~typesafe/jev-latest)

  def names, do: [@name]
  def permission_level(@name), do: :execute

  def bundles(context, identity, authority, selection, binding) do
    if @name in selection do
      with true <- @name in authority.grants,
           {:ok, agent, config, provider, _runtime} <- configuration(context.agent[:name]),
           trusted = %{
             identity: identity,
             agent_id: agent.id,
             agent_name: agent.name,
             fingerprint: fingerprint(agent, config),
             provider_id: provider.id,
             provider_name: provider.name,
             provider_type: provider.type,
             provider_fingerprint: provider_fingerprint(provider),
             runtime_generation: Ecto.UUID.generate(),
             session_binding: binding
           },
           ceiling = %{
             authority
             | grants: [@name],
               tool_revisions: Map.take(authority.tool_revisions, [@name])
           },
           {:ok, bundle} <-
             ToolCatalog.admit_batch([descriptor(trusted)], authority: ceiling, mode: :strict) do
        {:ok, [bundle]}
      else
        false -> failure(:forbidden, "Decision evaluation exceeds the parent authority ceiling")
        {:error, %Error{}} = error -> error
        _ -> unavailable()
      end
    else
      {:ok, []}
    end
  end

  def classify(%{backend: __MODULE__, backend_context: context}, identity, operation) do
    with true <- context.identity === identity,
         {:ok, batch, _config} <- invocation(context, operation, now() + @timeout) do
      {:ok,
       %{
         action: "decision.evaluate",
         resource:
           "decision:" <>
             digest({context.agent_id, context.provider_id, Decision.rubric_version(batch)}),
         permission_level: :execute
       }}
    else
      false -> failure(:forbidden, "Decision invocation scope changed")
      error -> error
    end
  end

  def classify(_, _, _), do: failure(:validation, "Decision descriptor is unavailable")

  @impl true
  def execute(%{backend_context: enriched} = operation) do
    started = now()
    context = Map.take(enriched, @keys)

    with {:ok, deadline} <- deadline(enriched[:effect_deadline], started),
         {:ok, batch, config} <- invocation(context, operation, deadline) do
      module = adapter(context.provider_type)

      case module.evaluate(batch, config) do
        {:ok, %{"status" => "ok"} = outcome} ->
          output(
            Map.put(outcome, "provenance", %{
              "providerId" => context.provider_id,
              "rubricVersion" => Decision.rubric_version(batch),
              "runtimeGeneration" => context.runtime_generation
            })
          )

        {:ok, %{"status" => "unavailable"} = outcome} ->
          output(outcome)

        {:error, reason} when reason in [:timeout, :transport] ->
          uncertain()

        _ ->
          failure(:execution_failure, "Decision evaluation did not complete")
      end
    else
      {:error, %Error{} = error} -> ToolEffects.reject(operation, error)
      _ -> failure(:execution_failure, "Decision evaluation is unavailable")
    end
  rescue
    _ -> uncertain()
  catch
    :exit, _ -> uncertain()
  end

  def execute(_), do: failure(:validation, "Decision context is unavailable")

  @impl true
  # The native effect owner owns the provider adapter's linked HTTP task.
  def cancel(_operation), do: :ok

  defp invocation(context, operation, deadline) do
    with true <- Enum.sort(Map.keys(context)) == Enum.sort(@keys),
         true <- operation[:tool_name] === @name,
         :ok <-
           CatalogBinding.host(context, operation, __MODULE__, 1, @native_keys, context.identity),
         {:ok, _} <- Session.validate(context.session_binding, operation),
         {:ok, agent, config, provider, runtime} <- configuration(context.agent_name),
         true <-
           agent.id === context.agent_id and provider.id === context.provider_id and
             provider.name === context.provider_name and
             provider.type === context.provider_type and
             fingerprint(agent, config) === context.fingerprint and
             provider_fingerprint(provider) === context.provider_fingerprint,
         {:ok, arguments} <- InputSchema.validate(Decision.schema(), operation.arguments),
         {:ok, batch} <- Decision.normalize(arguments),
         {:ok, provider_config} <- provider_config(config, provider, runtime, deadline),
         :ok <- prepare(adapter(provider.type), batch, provider_config) do
      {:ok, batch, provider_config}
    else
      false -> failure(:forbidden, "Decision configuration changed; prepare a new run")
      {:error, %Error{}} = error -> error
      _ -> failure(:validation, "Decision invocation is unavailable")
    end
  end

  defp configuration(name) do
    with %AgentConfig{enabled: true, config: %{"decision" => config}} = agent <-
           AgentConfigs.get_by_name(name),
         true <- is_map(config) and not is_struct(config),
         config = Map.take(config, ~w(provider model params)),
         true <- Enum.all?(~w(provider model), &nonblank?(config[&1])),
         {:ok, provider} <- Providers.get_by_name(config["provider"]),
         true <-
           provider.type in ~w(openai_responses openrouter) and
             Providers.runtime_available?(provider),
         true <- provider.type != "openrouter" or config["model"] in @openrouter_models,
         {:ok, runtime} <- Providers.runtime_config(provider.name),
         true <- runtime[:provider_id] === provider.id,
         true <- supported_runtime?(runtime),
         {:ok, _params} <- merge_params(runtime[:params], config["params"]) do
      {:ok, agent, config, provider, runtime}
    else
      _ -> unavailable()
    end
  end

  defp provider_config(config, provider, runtime, deadline) do
    # Saved provider URLs use the shared adapter's API-root convention.
    base = runtime[:base_url] || default_base_url(provider.type)

    with true <- is_binary(base),
         {:ok, params} <- merge_params(runtime[:params], config["params"]) do
      root = String.trim_trailing(base, "/")
      prefix = if String.ends_with?(root, "/v1"), do: root, else: root <> "/v1"

      {:ok,
       %{
         api_key: runtime[:api_key],
         base_url: prefix,
         model: config["model"],
         deadline: deadline,
         params: params,
         headers: runtime[:headers] || %{}
       }}
    else
      _ -> {:error, :unsupported_input}
    end
  end

  # A generic valid question remains admissible even when the selected provider
  # cannot execute it; evaluate/2 returns its explicit public unavailable result.
  defp prepare(module, batch, config) do
    case module.build_request(batch, config) do
      {:ok, _} -> :ok
      {:error, :unsupported_input} -> :ok
      error -> error
    end
  end

  defp adapter("openai_responses"), do: OpenAI
  defp adapter("openrouter"), do: OpenRouter
  defp default_base_url("openai_responses"), do: "https://api.openai.com/v1"
  defp default_base_url("openrouter"), do: "https://openrouter.ai/api/v1"

  defp merge_params(provider_params, agent_params) do
    with {:ok, provider_params} <- optional_map(provider_params),
         {:ok, agent_params} <- optional_map(agent_params) do
      merged = Map.merge(provider_params, agent_params)

      merged =
        case {provider_params["provider"], agent_params["provider"]} do
          {provider, agent} when is_map(provider) and is_map(agent) ->
            Map.put(merged, "provider", Map.merge(provider, agent))

          _ ->
            merged
        end

      {:ok, merged}
    end
  end

  defp optional_map(nil), do: {:ok, %{}}
  defp optional_map(value) when is_map(value) and not is_struct(value), do: {:ok, value}
  defp optional_map(_), do: {:error, :unsupported_input}

  # These adapters consume effective headers and routing parameters, but do not
  # implement the reference host's full request/proxy/TLS configuration service.
  defp supported_runtime?(runtime) do
    runtime[:request] in [nil, %{}] and is_nil(runtime[:proxy]) and is_nil(runtime[:tls])
  end

  defp deadline(getter, started) when is_function(getter, 0) do
    with {:ok, %{remaining_ms: remaining}} when is_integer(remaining) and remaining > 0 <-
           getter.() do
      {:ok, min(started + @timeout, now() + remaining)}
    else
      {:error, %Error{}} = error -> error
      _ -> failure(:timeout, "Decision effect has no active allowance")
    end
  end

  defp deadline(_, _), do: failure(:resource_conflict, "Decision effect deadline is unavailable")

  defp output(outcome) do
    result = %{content: [%{type: "text", text: Jason.encode!(outcome)}], details: outcome}

    case ToolEffects.validate_output(%{payload: result}) do
      {:ok, _} -> {:ok, result}
      _ -> failure(:budget_exceeded, "Decision result exceeds the native result budget")
    end
  end

  defp fingerprint(agent, config), do: digest({agent.id, agent.name, agent.tools, config})

  defp provider_fingerprint(provider),
    do:
      digest({
        Map.take(provider, [:id, :name, :type, :enabled, :base_url, :config, :credential_id]),
        Providers.authentication_generation(provider)
      })

  defp digest(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)

  defp descriptor(context) do
    %{
      tool_name: @name,
      tool_revision: 1,
      description:
        "Evaluate only supplied state with the explicitly configured decision model. Ask independent boolean, choice or score questions. Use contractVersion 2 tagged state for images, box, list sorting or tags when the selected provider supports them; unsupported capabilities return unavailable. OpenAI supports boolean/choice/score with text/JSON/PNG/JPEG/WebP. OpenRouter Jev supports text/JSON/PNG/JPEG, with box on 1.14/latest. A box does not prove presence; ask a companion boolean question. No ambient conversation or files are sent. Preserve explicit choices, fractional scores, distributions, metadata and usage; never infer or normalize estimates. Hosted evaluation may charge. Results do not authorize actions.",
      schema: Decision.schema(),
      safety: %{read_only: false, retry_safe: false, parallel_safe: false},
      codex_exposure: :direct_model_only,
      backend: __MODULE__,
      backend_context: context
    }
  end

  defp nonblank?(value),
    do: is_binary(value) and String.valid?(value) and String.trim(value) != ""

  defp unavailable,
    do:
      failure(
        :unsupported_capability,
        "Decision evaluation requires an enabled Agent and explicit available native decision provider/model"
      )

  defp uncertain,
    do:
      failure(
        :unknown_outcome,
        "Decision evaluation could not be confirmed; it was not replayed"
      )

  defp now, do: System.monotonic_time(:millisecond)
  defp failure(class, message), do: {:error, Error.new(class, message)}
end
