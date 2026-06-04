defmodule Synapsis.Session.Worker.Config do
  @moduledoc "Provider, agent, and mode resolution for Session.Worker."

  alias Synapsis.Session
  alias Synapsis.Session.Store

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
    agent = Synapsis.Agent.Resolver.resolve(session.agent, session.config)
    ensure_agent_model(agent, session)
  end

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
    case Synapsis.Provider.Registry.get(provider_name) do
      {:ok, config} ->
        config

      {:error, _} ->
        case Synapsis.Providers.get_by_name(provider_name) do
          {:ok, provider} ->
            %{
              api_key: provider.api_key_encrypted,
              base_url: provider.base_url,
              type: provider.type
            }

          {:error, _} ->
            auth = Synapsis.Config.load_auth()
            api_key = get_in(auth, [provider_name, "apiKey"]) || env_key(provider_name)
            base_url = provider_base_url(provider_name, auth)

            %{
              api_key: api_key,
              base_url: base_url,
              type: Synapsis.Providers.provider_type(provider_name)
            }
            |> maybe_put(:default_model, Synapsis.Providers.env_default_model(provider_name))
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

  def do_switch_model(provider_name, model, state) do
    case persist_session(state.session, %{provider: provider_name, model: model}) do
      {:ok, updated_session} ->
        provider_config = resolve_provider_config(provider_name)
        agent = Map.put(state.agent, :model, model)
        {:ok, updated_session, provider_config, agent}

      {:error, _changeset} ->
        {:error, :db_update_failed}
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
