defmodule Synapsis.Session.Worker.Config do
  @moduledoc "Provider, agent, and mode resolution for Session.Worker."

  alias Synapsis.{Repo, Session}

  @valid_modes ~w(bypass_permissions ask_before_edits edit_automatically plan_mode)
  @mode_configs %{
    "bypass_permissions" => %{
      agent: "build",
      permission: %{
        mode: :autonomous,
        allow_write: :allow,
        allow_execute: :allow,
        allow_destructive: :allow
      }
    },
    "ask_before_edits" => %{
      agent: "build",
      permission: %{
        mode: :interactive,
        allow_write: :ask,
        allow_execute: :ask,
        allow_destructive: :ask
      }
    },
    "edit_automatically" => %{
      agent: "build",
      permission: %{
        mode: :autonomous,
        allow_write: :allow,
        allow_execute: :allow,
        allow_destructive: :ask
      }
    },
    "plan_mode" => %{
      agent: "plan",
      permission: %{
        mode: :interactive,
        allow_write: :deny,
        allow_execute: :deny,
        allow_destructive: :deny
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

            %{
              api_key: api_key,
              base_url: Synapsis.Providers.default_base_url(provider_name),
              type: provider_name
            }
        end
    end
  end

  def do_switch_agent(agent_name, session) do
    name_str = to_string(agent_name)

    case session |> Session.changeset(%{agent: name_str}) |> Repo.update() do
      {:ok, updated_session} ->
        agent = resolve_agent(updated_session)
        {:ok, agent, updated_session}

      {:error, _changeset} ->
        {:error, :db_update_failed}
    end
  end

  def do_switch_model(provider_name, model, state) do
    case state.session
         |> Session.changeset(%{provider: provider_name, model: model})
         |> Repo.update() do
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

    with {:ok, updated_session} <-
           state.session |> Session.changeset(%{agent: config.agent}) |> Repo.update(),
         {:ok, _} <-
           Synapsis.Tool.Permission.update_config(state.session_id, config.permission) do
      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "session:#{state.session_id}",
        {"mode_switched", %{mode: mode_name, agent: config.agent}}
      )

      {:ok, %{state | agent: agent, session: updated_session}}
    else
      {:error, _} -> {:error, :mode_switch_failed}
    end
  end

  def apply_mode(_mode_name, _state), do: {:error, :invalid_mode}

  defp env_key(provider_name) do
    case Synapsis.Providers.env_var_name(provider_name) do
      nil -> nil
      var -> System.get_env(var)
    end
  end
end
