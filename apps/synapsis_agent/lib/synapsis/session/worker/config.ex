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

  def apply_mode(mode_name, state) when mode_name in @valid_modes do
    config = @mode_configs[mode_name]
    agent = Synapsis.Agent.Resolver.resolve(config.agent, state.session.config)
    agent = ensure_agent_model(agent, state.session)
    {:ok, _} = state.session |> Session.changeset(%{agent: config.agent}) |> Repo.update()

    case Synapsis.Tool.Permission.update_config(state.session_id, config.permission) do
      {:ok, _} ->
        session = %{state.session | agent: config.agent}

        Phoenix.PubSub.broadcast(
          Synapsis.PubSub,
          "session:#{state.session_id}",
          {"mode_switched", %{mode: mode_name, agent: config.agent}}
        )

        {:ok, %{state | agent: agent, session: session}}

      {:error, _} ->
        {:error, :permission_update_failed}
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
