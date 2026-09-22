defmodule Synapsis.Session.Worker.ConfigTest do
  use ExUnit.Case, async: false

  alias Synapsis.{Providers, Session}
  alias Synapsis.Agent.QueryLoop
  alias Synapsis.Agent.QueryLoop.{Context, State}
  alias Synapsis.Provider.Registry, as: ProviderRegistry
  alias Synapsis.Session.Worker.Config

  setup do
    Synapsis.DataCase.clear_config_store(:provider)
    Synapsis.DataCase.clear_config_store(:backplane)

    assert {:ok, _connection} =
             Synapsis.Config.Store.put(:backplane, %{"id" => "source-1", "enabled" => true})

    ProviderRegistry.unregister("anthropic")

    on_exit(fn ->
      Synapsis.DataCase.clear_config_store(:provider)
      Synapsis.DataCase.clear_config_store(:backplane)
      ProviderRegistry.unregister("anthropic")
    end)

    :ok
  end

  test "rejects a known unavailable provider before registry or environment fallback" do
    previous_api_key = System.get_env("ANTHROPIC_API_KEY")

    on_exit(fn ->
      if previous_api_key,
        do: System.put_env("ANTHROPIC_API_KEY", previous_api_key),
        else: System.delete_env("ANTHROPIC_API_KEY")
    end)

    System.put_env("ANTHROPIC_API_KEY", "env-key-that-must-not-be-used")

    assert {:ok, _provider} =
             Providers.create(%{
               name: "anthropic",
               type: "anthropic",
               enabled: true,
               config: %{
                 "managed_by" => "backplane",
                 "backplane_source_id" => "source-1",
                 "backplane_available" => false
               }
             })

    :ok = ProviderRegistry.register("anthropic", %{type: "anthropic", api_key: "stale-key"})

    assert {:error, :provider_unavailable} = Config.resolve_provider_config("anthropic")

    session = %Session{
      id: Ecto.UUID.generate(),
      agent: "main",
      provider: "anthropic",
      model: "claude-sonnet-4-6",
      config: %{}
    }

    assert {:error, :provider_unavailable} = Config.resolve_session_defaults(session)

    caller = self()

    context =
      Context.new(
        session_id: session.id,
        system_prompt: "Test",
        tools: [],
        model: session.model,
        provider_config: %{type: "anthropic", api_key: "stale-key"},
        subscriber: self(),
        agent_config: %{
          provider: "anthropic",
          stream_fn: fn _request, _config ->
            send(caller, :provider_called)
            {:error, :unexpected_provider_call}
          end
        }
      )

    assert {:ok, :model_error, _state} =
             QueryLoop.run(State.new(messages: [%{role: "user", content: "Hello"}]), context)

    refute_received :provider_called
  end

  test "known built-in providers retain keyless local fallback resolution" do
    assert {:ok, %{type: "anthropic"} = anthropic} = Config.resolve_provider_config("anthropic")
    refute Map.has_key?(anthropic, :provider_id)

    assert {:ok, %{type: "google"} = google} = Config.resolve_provider_config("google")
    refute Map.has_key?(google, :provider_id)
  end

  test "refresh preserves the Skill catalog frozen at session boot" do
    session = %Session{
      id: Ecto.UUID.generate(),
      agent: "main",
      provider: "anthropic",
      model: "claude-sonnet-4-6",
      config: %{}
    }

    frozen = [%{locator: "synapsis://skills/boot-snapshot"}]

    state = %{
      session: session,
      agent: %{skill_catalog: frozen},
      provider_config: %{},
      engine_ctx: %{},
      engine_state: %{agent_config: %{}}
    }

    assert {:ok, refreshed} = Config.refresh_agent_defaults(state)
    assert refreshed.agent.skill_catalog == frozen
    assert refreshed.engine_state.agent_config.skill_catalog == frozen

    on_exit(fn -> Synapsis.Session.Store.delete_session(session.id) end)
  end

  test "renamed imported providers do not fall through to local config or custom streams" do
    old_name = "backplane-old-#{System.unique_integer([:positive])}"
    new_name = "backplane-new-#{System.unique_integer([:positive])}"

    assert {:ok, provider} =
             Providers.create(%{
               name: old_name,
               type: "openai",
               enabled: true,
               config: %{
                 "managed_by" => "backplane",
                 "backplane_source_id" => "source-1",
                 "backplane_available" => true,
                 "backplane_models" => [
                   %{
                     "external_id" => "disabled-model",
                     "source_available" => false,
                     "backplane_available" => false
                   }
                 ]
               }
             })

    assert {:ok, provider_config} = Providers.runtime_config(old_name)
    assert {:ok, _renamed} = Providers.update(provider.id, %{name: new_name})
    assert {:error, :provider_unavailable} = Config.resolve_provider_config(old_name)

    caller = self()

    context =
      Context.new(
        session_id: Ecto.UUID.generate(),
        system_prompt: "Test",
        tools: [],
        model: "disabled-model",
        provider_config: provider_config,
        subscriber: self(),
        agent_config: %{
          provider: old_name,
          stream_fn: fn _request, _config ->
            send(caller, :provider_called)
            {:error, :unexpected_provider_call}
          end
        }
      )

    assert {:ok, :model_error, _state} =
             QueryLoop.run(State.new(messages: [%{role: "user", content: "Hello"}]), context)

    refute_received :provider_called

    assert {:ok, _deleted} = Providers.delete(provider.id)
    assert {:error, :provider_unavailable} = Config.resolve_provider_config(new_name)

    deleted_context = %{
      context
      | agent_config: Map.put(context.agent_config, :provider, new_name)
    }

    assert {:ok, :model_error, _state} =
             QueryLoop.run(
               State.new(messages: [%{role: "user", content: "Hello again"}]),
               deleted_context
             )

    refute_received :provider_called
  end

  test "keeps local providers available even when they carry an unrelated false marker" do
    name = "local-provider-#{System.unique_integer([:positive])}"

    assert {:ok, provider} =
             Providers.create(%{
               name: name,
               type: "anthropic",
               enabled: true,
               config: %{"backplane_available" => false}
             })

    assert {:ok, %{provider_id: provider_id, type: "anthropic"}} =
             Config.resolve_provider_config(name)

    assert provider_id == provider.id

    session = %Session{
      id: Ecto.UUID.generate(),
      agent: "main",
      provider: name,
      model: "old-local-model",
      config: %{}
    }

    state = %{session: session, agent: %{model: session.model}}

    assert {:ok, %{model: "arbitrary-local-model"}, _provider_config, _agent} =
             Config.do_switch_model(name, "arbitrary-local-model", state)

    on_exit(fn -> Synapsis.Session.Store.delete_session(session.id) end)
  end

  test "rejects switching directly to a source-disabled model without persisting it" do
    name = "mixed-provider-#{System.unique_integer([:positive])}"

    assert {:ok, _provider} =
             Providers.create(%{
               name: name,
               type: "openai",
               enabled: true,
               config: %{
                 "managed_by" => "backplane",
                 "backplane_source_id" => "source-1",
                 "backplane_available" => true,
                 "enabled_models" => ["disabled-model", "enabled-model"],
                 "backplane_models" => [
                   %{
                     "external_id" => "disabled-model",
                     "source_available" => false,
                     "backplane_available" => false
                   },
                   %{
                     "external_id" => "enabled-model",
                     "source_available" => true,
                     "backplane_available" => true
                   }
                 ]
               }
             })

    session = %Session{
      id: Ecto.UUID.generate(),
      agent: "main",
      provider: name,
      model: "enabled-model",
      config: %{}
    }

    :ok = Synapsis.Session.Store.put_meta(session.id, Session.to_meta(session))
    on_exit(fn -> Synapsis.Session.Store.delete_session(session.id) end)

    state = %{session: session, agent: %{model: session.model}}

    assert {:error, :model_unavailable} = Config.do_switch_model(name, "disabled-model", state)

    assert {:ok, persisted} = Synapsis.Session.Store.get_meta(session.id)
    assert Session.from_meta(persisted).model == "enabled-model"

    assert {:ok, %{model: "enabled-model"}, _provider_config, %{model: "enabled-model"}} =
             Config.do_switch_model(name, "enabled-model", state)

    caller = self()
    assert {:ok, provider_config} = Providers.runtime_config(name)

    context =
      Context.new(
        session_id: session.id,
        system_prompt: "Test",
        tools: [],
        model: "disabled-model",
        provider_config: provider_config,
        subscriber: self(),
        agent_config: %{
          provider: name,
          stream_fn: fn _request, _config ->
            send(caller, :provider_called)
            {:error, :unexpected_provider_call}
          end
        }
      )

    assert {:ok, :model_error, _state} =
             QueryLoop.run(State.new(messages: [%{role: "user", content: "Hello"}]), context)

    refute_received :provider_called
  end

  test "session default resolution replaces a source-disabled model with an enabled sibling" do
    name = "mixed-default-provider-#{System.unique_integer([:positive])}"

    assert {:ok, _provider} =
             Providers.create(%{
               name: name,
               type: "openai",
               enabled: true,
               config: %{
                 "managed_by" => "backplane",
                 "backplane_source_id" => "source-1",
                 "backplane_available" => true,
                 "enabled_models" => ["disabled-model", "enabled-model"],
                 "available_models" => [%{"id" => "enabled-model"}],
                 "backplane_models" => [
                   %{
                     "external_id" => "disabled-model",
                     "source_available" => false,
                     "backplane_available" => false
                   },
                   %{
                     "external_id" => "enabled-model",
                     "source_available" => true,
                     "backplane_available" => true
                   }
                 ]
               }
             })

    session = %Session{
      id: Ecto.UUID.generate(),
      agent: "main",
      provider: name,
      model: "disabled-model",
      config: %{}
    }

    :ok = Synapsis.Session.Store.put_meta(session.id, Session.to_meta(session))
    on_exit(fn -> Synapsis.Session.Store.delete_session(session.id) end)

    assert {:ok, %{model: "enabled-model"}, %{model: "enabled-model"}, ^name, _provider_config} =
             Config.resolve_session_defaults(session)

    assert {:ok, persisted} = Synapsis.Session.Store.get_meta(session.id)
    assert Session.from_meta(persisted).model == "enabled-model"
  end
end
