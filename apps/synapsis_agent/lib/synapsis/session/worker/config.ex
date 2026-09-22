defmodule Synapsis.Session.Worker.Config do
  @moduledoc "Provider, agent, and mode resolution for Session.Worker."

  alias Synapsis.Session
  alias Synapsis.Session.Store
  alias Synapsis.Agent.Daemon.Toolsets

  @valid_modes ~w(bypass_permissions ask_before_edits edit_automatically plan_mode assistant_mode)
  @mode_configs %{
    "bypass_permissions" => %{
      agent: "main",
      permission: %{
        mode: :autonomous,
        allow_read: :allow,
        allow_write: :allow,
        allow_execute: :allow,
        allow_destructive: :allow,
        tool_overrides: %{}
      }
    },
    "ask_before_edits" => %{
      agent: "main",
      permission: %{
        mode: :interactive,
        allow_read: :allow,
        allow_write: :ask,
        allow_execute: :ask,
        allow_destructive: :ask,
        tool_overrides: %{}
      }
    },
    "edit_automatically" => %{
      agent: "main",
      permission: %{
        mode: :autonomous,
        allow_read: :allow,
        allow_write: :allow,
        allow_execute: :allow,
        allow_destructive: :ask,
        tool_overrides: %{}
      }
    },
    "plan_mode" => %{
      agent: "main",
      permission: %{
        mode: :interactive,
        allow_read: :allow,
        allow_write: :deny,
        allow_execute: :deny,
        allow_destructive: :deny,
        tool_overrides: %{}
      }
    },
    "assistant_mode" => %{
      agent: "main",
      permission: %{
        mode: :interactive,
        allow_read: :allow,
        allow_write: :deny,
        allow_execute: :deny,
        allow_destructive: :deny,
        tool_overrides: %{}
      }
    }
  }

  def resolve_agent(session) do
    agent =
      session.agent
      |> Synapsis.Agent.Resolver.resolve(session.config)
      |> apply_daemon_run_tools(session.config)

    ensure_agent_model(agent, session)
  end

  defp apply_daemon_run_tools(
         agent,
         %{
           "daemon_run_tool_names" => tool_names,
           "daemon_run_tool_profile" => tool_profile
         }
       )
       when is_list(tool_names) and is_binary(tool_profile) do
    case Toolsets.resolve_for_query_loop(tool_profile) do
      {:ok, tools} ->
        names = Enum.map(tools, & &1.name)
        registrations = Map.new(tools, &{&1.name, &1.registration})

        agent
        |> Map.put(:tools, names)
        |> Map.put(:resolved_tools, tools)
        |> Map.put(:tool_modules, registrations)
        |> Map.put(:daemon_tool_profile, tool_profile)

      {:error, _reason} ->
        agent
        |> Map.put(:tools, [])
        |> Map.put(:resolved_tools, [])
        |> Map.put(:tool_modules, %{})
        |> Map.put(:daemon_tool_profile, tool_profile)
    end
  end

  defp apply_daemon_run_tools(agent, %{"daemon_run_tool_names" => tool_names})
       when is_list(tool_names),
       do: Map.put(agent, :tools, tool_names)

  defp apply_daemon_run_tools(agent, _config), do: agent

  def resolve_session_defaults(%Session{} = session) do
    agent = resolve_agent(session)
    provider = agent[:provider] || session.provider
    selected_model = agent[:model] || session.model

    with {:ok, provider_config} <- resolve_provider_config(provider),
         {:ok, model} <- resolve_runtime_model(provider, selected_model),
         {:ok, updated_session} <-
           persist_session_if_changed(session, %{provider: provider, model: model}) do
      agent = agent |> Map.put(:provider, provider) |> Map.put(:model, model)
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
           engine_state: refresh_engine_state(state.engine_state, agent)
       }}
    end
  end

  defp preserve_skill_catalog(agent, previous) when is_map(previous) do
    case Map.fetch(previous, :skill_catalog) do
      {:ok, catalog} -> Map.put(agent, :skill_catalog, catalog)
      :error -> agent
    end
  end

  defp preserve_skill_catalog(agent, _previous), do: agent

  def ensure_agent_model(agent, session) do
    cond do
      not is_nil(agent[:model]) ->
        agent

      not is_nil(session.model) ->
        Map.put(agent, :model, session.model)

      true ->
        tier = agent[:model_tier] || :default
        provider = agent[:provider] || session.provider
        Map.put(agent, :model, Synapsis.Providers.model_for_tier(provider, tier))
    end
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
              type: Synapsis.Providers.provider_type(provider_name)
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
                 Synapsis.Tool.Permission.config_for_mode(agent[:permission_mode])
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

      Store.put_meta(updated.id, Session.to_meta(updated))
      {:ok, updated}
    else
      {:error, :db_update_failed}
    end
  end

  defp persist_session_if_changed(%Session{} = session, attrs) do
    provider = attrs[:provider]
    model = attrs[:model]

    if session.provider == provider and session.model == model do
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

  defp refresh_engine_state(engine_state, agent) when is_map(engine_state) do
    Map.put(engine_state, :agent_config, agent)
  end

  defp refresh_engine_state(engine_state, _agent), do: engine_state

  def do_switch_model(provider_name, model, state) do
    with {:ok, provider_config} <- resolve_provider_config(provider_name),
         :ok <- ensure_model_runtime_available(provider_name, model),
         {:ok, updated_session} <-
           persist_session(state.session, %{provider: provider_name, model: model}) do
      agent = Map.put(state.agent, :model, model)
      {:ok, updated_session, provider_config, agent}
    else
      {:error, :provider_unavailable} = error -> error
      {:error, :model_unavailable} = error -> error
      {:error, _changeset} -> {:error, :db_update_failed}
    end
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

  defp resolve_runtime_model(provider_name, selected_model) do
    case Synapsis.Providers.get_by_name(provider_name) do
      {:ok, provider} ->
        cond do
          Synapsis.Providers.model_runtime_available?(provider, selected_model) ->
            {:ok, selected_model}

          model = Synapsis.Providers.first_runtime_model(provider) ->
            {:ok, model}

          true ->
            {:error, :model_unavailable}
        end

      {:error, :not_found} ->
        {:ok, selected_model}
    end
  end

  def apply_mode(mode_name, state) when mode_name in @valid_modes do
    config = @mode_configs[mode_name]
    agent = Synapsis.Agent.Resolver.resolve(config.agent, state.session.config)
    agent = ensure_agent_model(agent, state.session)

    execution_mode =
      case config.agent do
        "assistant" -> :query_loop
        _ -> state.execution_mode
      end

    with {:ok, updated_session} <- persist_session(state.session, %{agent: config.agent}),
         {:ok, _} <-
           Synapsis.Tool.Permission.update_config(state.session_id, config.permission) do
      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "session:#{state.session_id}",
        {"mode_switched", %{mode: mode_name, agent: config.agent}}
      )

      {:ok, %{state | agent: agent, session: updated_session, execution_mode: execution_mode}}
    else
      {:error, _} -> {:error, :mode_switch_failed}
    end
  end

  def apply_mode(_mode_name, _state), do: {:error, :invalid_mode}

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
