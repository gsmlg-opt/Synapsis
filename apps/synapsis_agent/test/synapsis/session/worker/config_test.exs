defmodule Synapsis.Session.Worker.ConfigTest do
  use ExUnit.Case, async: false

  alias Synapsis.{Providers, Session}
  alias Synapsis.Provider.Registry, as: ProviderRegistry
  alias Synapsis.Session.Worker.Config

  setup do
    Synapsis.DataCase.clear_config_store(:provider)
    Synapsis.DataCase.clear_config_store(:model)
    Synapsis.DataCase.clear_config_store(:backplane)

    assert {:ok, _connection} =
             Synapsis.Config.Store.put(:backplane, %{"id" => "source-1", "enabled" => true})

    ProviderRegistry.unregister("anthropic")

    on_exit(fn ->
      Synapsis.DataCase.clear_config_store(:provider)
      Synapsis.DataCase.clear_config_store(:model)
      Synapsis.DataCase.clear_config_store(:backplane)
      ProviderRegistry.unregister("anthropic")
    end)

    :ok
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

  test "session default resolution requires an explicit choice for a source-disabled model" do
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

    assert {:error, :model_unavailable} = Config.resolve_session_defaults(session)

    assert {:ok, persisted} = Synapsis.Session.Store.get_meta(session.id)
    assert Session.from_meta(persisted).model == "disabled-model"
  end

  test "switching records a coherent provider/model pair, context, and catalog identity" do
    {:ok, provider} = Providers.create(%{name: "target", type: "openai"})

    {:ok, model} =
      Synapsis.Models.create(%{
        provider_id: provider.id,
        model: "target-model",
        context_window: 4096
      })

    session = %Session{
      id: Ecto.UUID.generate(),
      agent: "main",
      provider: "anthropic",
      model: "old",
      config: %{}
    }

    :ok = Synapsis.Session.Store.put_meta(session.id, Session.to_meta(session))
    on_exit(fn -> Synapsis.Session.Store.delete_session(session.id) end)

    state = %{session: session, agent: %{provider: "anthropic", model: "old"}}

    assert {:ok, switched, config, agent} =
             Config.do_switch_model("target", "target-model", state)

    assert agent.provider == "target"
    assert agent.model == "target-model"
    assert agent.model_context_window == 4096
    assert agent.history_projection == :portable
    assert config.provider_id == provider.id
    assert switched.config["model_id"] == model.id
    assert switched.config["provider_id"] == provider.id
    assert {:ok, persisted} = Synapsis.Session.Store.get_meta(session.id)
    assert Session.from_meta(persisted).config == switched.config

    assert {:ok, rebooted, resolved, "target", _} = Config.resolve_session_defaults(switched)
    assert rebooted.model == "target-model"
    assert resolved.provider == "target"
    assert resolved.model_context_window == 4096
    assert resolved.history_projection == :portable
  end

  test "deleted catalog identities require selection even if the raw name is reused" do
    {:ok, provider} = Providers.create(%{name: "catalog-provider", type: "openai"})

    {:ok, model} =
      Synapsis.Models.create(%{provider_id: provider.id, model: "model", context_window: 4096})

    {:ok, _} = Synapsis.Models.delete(model.id)

    {:ok, _replacement} =
      Synapsis.Models.create(%{provider_id: provider.id, model: "model", context_window: 8192})

    session = %Session{
      id: Ecto.UUID.generate(),
      agent: "main",
      provider: provider.name,
      model: "model",
      config: %{"model_id" => model.id, "provider_id" => provider.id}
    }

    assert {:error, :model_unavailable} = Config.resolve_session_defaults(session)
  end

  test "incompatible history is rejected before persisting a model switch" do
    session = %Session{
      id: Ecto.UUID.generate(),
      agent: "main",
      provider: "anthropic",
      model: "old",
      config: %{}
    }

    :ok = Synapsis.Session.Store.put_meta(session.id, Session.to_meta(session))

    :ok =
      Synapsis.Message.persist_list(session.id, [
        %Synapsis.Message{
          session_id: session.id,
          role: "assistant",
          parts: [%Synapsis.Part.Reasoning{content: "private", signature: "unbound"}]
        }
      ])

    on_exit(fn -> Synapsis.Session.Store.delete_session(session.id) end)

    assert {:error, {:history_incompatible, _reason}} =
             Config.do_switch_model("google", "gemini-2.5-pro", %{session: session, agent: %{}})

    assert {:ok, persisted} = Synapsis.Session.Store.get_meta(session.id)
    assert Session.from_meta(persisted).model == "old"
  end
end
