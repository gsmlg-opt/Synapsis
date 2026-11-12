defmodule Synapsis.Session.Worker.Config do
  @moduledoc "Provider and agent resolution for Session.Worker."

  alias Synapsis.Session
  alias Synapsis.Session.Store

  def resolve_agent(session) do
    agent =
      session.agent
      |> Synapsis.Agent.Resolver.resolve(session.config)
      |> apply_daemon_run_tools(session)

    agent
    |> Map.put(:configured_default_model, configured_identity(agent))
    |> ensure_agent_model(session)
  end

  @doc """
  Minimal read-only configured-default projection, before session selection.
  Mirrors Resolver's saved-Agent/project fill-blank rules without resolving tools
  or loading skills. Project configuration is the session's existing projection.
  """
  def configured_default_model(name, project_config \\ %{}) do
    saved = Synapsis.AgentConfigs.get_by_name(to_string(name))
    saved = saved || Synapsis.AgentConfigs.default_attrs(to_string(name)) || %{}
    agents = Map.get(project_config || %{}, "agents", %{})
    base = if to_string(name) == "main", do: Map.get(agents, "default", %{}), else: %{}
    exact = Map.get(agents, to_string(name), %{})

    project =
      Map.merge(base, exact, fn _key, left, right ->
        if right in [nil, ""], do: left, else: right
      end)

    saved
    |> Map.put(:provider, nonblank(Map.get(saved, :provider), project["provider"]))
    |> Map.put(:model, nonblank(Map.get(saved, :model), project["model"]))
    |> configured_identity()
  end

  defp configured_identity(agent) do
    provider = Map.get(agent, :provider)

    tier =
      case Map.get(agent, :model_tier) do
        value when value in [:fast, "fast"] -> :fast
        value when value in [:expert, "expert"] -> :expert
        _ -> :default
      end

    model =
      case Map.get(agent, :model) do
        value when value in [nil, ""] ->
          if provider not in [nil, ""], do: Synapsis.Providers.model_for_tier(provider, tier)

        selected ->
          selected
      end

    if is_binary(provider) and provider != "" and is_binary(model) and model != "",
      do: %{provider: provider, model: model},
      else: nil
  end

  defp nonblank(value, fallback) when value in [nil, ""], do: fallback
  defp nonblank(value, _fallback), do: value

  defp apply_daemon_run_tools(agent, %Session{config: %{"daemon_run_id" => _}} = session) do
    Synapsis.Agent.Daemon.NativeSelection.overlay(agent, session)
  end

  defp apply_daemon_run_tools(agent, %Session{config: config}) when is_map(config) do
    keys = [
      "daemon_run_id",
      :daemon_run_id,
      "daemon_run_tool_names",
      "daemon_run_tool_profile",
      "daemon_run_tool_contract_version",
      :daemon_run_tool_names,
      :daemon_run_tool_profile,
      :daemon_run_tool_contract_version
    ]

    if Enum.any?(keys, &Map.has_key?(config, &1)),
      do: reject_daemon_tools(agent),
      else: agent
  end

  defp apply_daemon_run_tools(agent, _config), do: agent

  defp reject_daemon_tools(agent) do
    # Current daemon profiles bind legacy Registrations. Neither the selected
    # agent nor a session version label can establish native provenance for them.
    agent
    |> Map.put(:tools, [])
    |> Map.put(:resolved_tools, [])
    |> Map.put(:tool_modules, %{})
    |> Map.put(:tool_contract_version, 0)
    |> Map.put_new(:tool_selection_error, :legacy_daemon_tool_selection)
  end

  def resolve_session_defaults(%Session{} = session) do
    agent = resolve_agent(session)
    provider = session.provider || agent[:provider]
    selected_model = session.model || agent[:model]

    with {:ok, provider, selected_model} <-
           resolve_catalog_identity(session, provider, selected_model),
         {:ok, provider_config} <- resolve_provider_config(provider),
         :ok <- ensure_model_runtime_available(provider, selected_model),
         {:ok, updated_session} <-
           persist_session_if_changed(session, selection_attrs(session, provider, selected_model)) do
      agent = selected_agent(agent, updated_session)
      {:ok, updated_session, agent, provider, provider_config}
    end
  end

  def refresh_agent_defaults(%{session: %Session{} = session} = state) do
    with {:ok, updated_session, agent, provider, provider_config} <-
           resolve_session_defaults(session) do
      agent = preserve_skill_catalog(agent, state.agent)

      {:ok,
       %{
         state
         | session: updated_session,
           agent: agent,
           provider_config: provider_config,
           engine_ctx: refresh_engine_ctx(state.engine_ctx, provider, agent[:model]),
           engine_state: refresh_engine_state(state.engine_state, agent, provider_config)
       }}
    end
  end

  defp preserve_skill_catalog(agent, previous) when is_map(previous) do
    case previous do
      %{skill_catalog: catalog, skill_snapshot: snapshot} ->
        agent |> Map.put(:skill_catalog, catalog) |> Map.put(:skill_snapshot, snapshot)

      _ ->
        agent
    end
  end

  defp preserve_skill_catalog(agent, _previous), do: agent

  def ensure_agent_model(agent, session) do
    cond do
      session.provider not in [nil, ""] and session.model not in [nil, ""] ->
        selected_agent(agent, session)

      agent[:model] not in [nil, ""] ->
        agent

      true ->
        tier = agent[:model_tier] || :default
        provider = agent[:provider] || session.provider
        Map.put(agent, :model, Synapsis.Providers.model_for_tier(provider, tier))
    end
  end

  defp selected_agent(agent, session) do
    agent
    |> Map.put(:provider, session.provider)
    |> Map.put(:model, session.model)
    |> Map.put(
      :model_context_window,
      Synapsis.Providers.model_context_window(session.provider, session.model)
    )
    |> Map.put(
      :history_projection,
      if((session.config || %{})["history_projection"] == "portable", do: :portable)
    )
  end

  defp resolve_catalog_identity(session, provider, model) do
    case (session.config || %{})["model_id"] do
      nil ->
        {:ok, provider, model}

      id ->
        with {:ok, record} <- Synapsis.Models.get(id),
             true <- record.enabled,
             {:ok, connection} <- Synapsis.Providers.get(record.provider_id) do
          {:ok, connection.name, record.model}
        else
          _ -> {:error, :model_unavailable}
        end
    end
  end

  defp selection_attrs(session, provider, model) do
    config = session.config || %{}

    config =
      with {:ok, connection} <- Synapsis.Providers.get_by_name(provider),
           {:ok, record} <- Synapsis.Models.get_by_identity(connection.id, model) do
        config |> Map.put("provider_id", connection.id) |> Map.put("model_id", record.id)
      else
        _ -> config |> Map.delete("provider_id") |> Map.delete("model_id")
      end

    config = if config == %{} and is_nil(session.config), do: nil, else: config
    %{provider: provider, model: model, config: config}
  end

  def resolve_provider_config(provider_name) do
    case Synapsis.Providers.runtime_config(provider_name) do
      {:ok, config} ->
        {:ok, config}

      {:error, :provider_unavailable} = error ->
        error

      {:error, :not_found} ->
        auth = Synapsis.Config.load_auth()

        if Synapsis.Providers.fallback_configured?(provider_name, auth) do
          api_key = get_in(auth, [provider_name, "apiKey"]) || env_key(provider_name)
          base_url = provider_base_url(provider_name, auth)

          config =
            %{
              api_key: api_key,
              base_url: base_url,
              type: Synapsis.Providers.provider_type(provider_name),
              provider_name: provider_name
            }
            |> maybe_put(:default_model, Synapsis.Providers.env_default_model(provider_name))

          {:ok, config}
        else
          {:error, :provider_unavailable}
        end
    end
  end

  def do_switch_agent(agent_name, session) do
    name_str = to_string(agent_name)

    case persist_session(session, %{agent: name_str}) do
      {:ok, updated_session} ->
        agent = resolve_agent(updated_session)

        with {:ok, _permission} <-
               Synapsis.Tool.Permission.update_config(
                 updated_session.id,
                 Synapsis.Tool.Permission.config_for_mode(agent[:permission_mode],
                   interactive: (updated_session.config || %{})["interactive"] == true
                 )
               ) do
          {:ok, agent, updated_session}
        else
          {:error, _changeset} -> {:error, :permission_update_failed}
        end

      {:error, _changeset} ->
        {:error, :db_update_failed}
    end
  end

  # ADR-006 C4: persist a session field change to the Concord meta snapshot.
  defp persist_session(%Session{} = session, attrs) do
    changeset = Session.changeset(session, attrs)

    if changeset.valid? do
      updated =
        changeset |> Ecto.Changeset.apply_changes() |> Map.put(:updated_at, DateTime.utc_now())

      case Store.put_meta(updated.id, Session.to_meta(updated)) do
        :ok -> {:ok, updated}
        {:error, _reason} -> {:error, :db_update_failed}
      end
    else
      {:error, :db_update_failed}
    end
  end

  defp persist_session_if_changed(%Session{} = session, attrs) do
    provider = attrs[:provider]
    model = attrs[:model]

    if session.provider == provider and session.model == model and
         session.config == attrs[:config] do
      {:ok, session}
    else
      persist_session(session, attrs)
    end
  end

  defp refresh_engine_ctx(ctx, provider, model) do
    (ctx || %{})
    |> Map.put(:provider, provider)
    |> Map.put(:model, model)
  end

  defp refresh_engine_state(engine_state, agent, provider_config) when is_map(engine_state) do
    engine_state |> Map.put(:agent_config, agent) |> Map.put(:provider_config, provider_config)
  end

  defp refresh_engine_state(engine_state, _agent, _provider_config), do: engine_state

  # TODO(upstream): gsmlg-dev/concord#107 — bounded revision-fenced model selection;
  # independent metadata writers must preserve concurrent selection changes.
  def do_switch_model(provider_name, model, state) do
    with {:ok, provider_config} <- resolve_provider_config(provider_name),
         :ok <- ensure_model_runtime_available(provider_name, model),
         :ok <- preflight_history(state.session.id, provider_name, model, provider_config),
         attrs = selection_attrs(state.session, provider_name, model),
         attrs =
           Map.update!(attrs, :config, &Map.put(&1 || %{}, "history_projection", "portable")),
         {:ok, updated_session} <- persist_session(state.session, attrs) do
      {:ok, updated_session, provider_config, selected_agent(state.agent, updated_session)}
    end
  end

  defp preflight_history(session_id, provider, model, config) do
    messages = Synapsis.Message.list_by_session(session_id)

    opts =
      Map.merge(config, %{
        provider_name: provider,
        provider_type: config[:type],
        model: model,
        history_projection: :portable
      })

    case Synapsis.Provider.Adapter.format_request(messages, [], opts) do
      {:ok, _request} -> :ok
      {:error, reason} -> {:error, {:history_incompatible, reason}}
    end
  end

  def update_model_state(state, session, provider_config, agent) do
    %{
      state
      | session: session,
        provider_config: provider_config,
        agent: agent,
        engine_ctx: refresh_engine_ctx(state.engine_ctx, session.provider, session.model),
        engine_state: refresh_engine_state(state.engine_state, agent, provider_config)
    }
  end

  defp ensure_model_runtime_available(provider_name, model) do
    case Synapsis.Providers.get_by_name(provider_name) do
      {:ok, provider} ->
        if Synapsis.Providers.model_runtime_available?(provider, model),
          do: :ok,
          else: {:error, :model_unavailable}

      {:error, :not_found} ->
        :ok
    end
  end

  # Session modes are retired: every run is an execution run with default
  # provenance. Retained goal facts from older plan/user modes stay readable
  # through GoalLifecycle's provenance validation.
  def mode_provenance(%Session{}),
    do: %{version: 1, mode: :execution, source: :default, selected_mode: nil}

  defp env_key(provider_name) do
    Synapsis.Providers.env_api_key(provider_name)
  end

  defp provider_base_url(provider_name, auth) do
    get_in(auth, [provider_name, "baseURL"]) ||
      get_in(auth, [provider_name, "baseUrl"]) ||
      get_in(auth, [provider_name, "base_url"]) ||
      Synapsis.Providers.env_base_url(provider_name) ||
      Synapsis.Providers.default_base_url(provider_name)
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
