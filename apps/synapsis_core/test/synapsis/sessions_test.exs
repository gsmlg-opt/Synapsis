defmodule Synapsis.SessionsTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.{ProviderConfig, Providers, Session, Sessions}
  alias Synapsis.Session.Store

  setup do
    Synapsis.DataCase.clear_config_store(:provider)
    Synapsis.DataCase.clear_config_store(:backplane)

    assert {:ok, _connection} =
             Synapsis.Config.Store.put(:backplane, %{"id" => "source-1", "enabled" => true})

    on_exit(fn ->
      Synapsis.DataCase.clear_config_store(:provider)
      Synapsis.DataCase.clear_config_store(:backplane)
    end)

    :ok
  end

  test "recovers a source-disabled Backplane model to its available sibling" do
    provider_name = "mixed-provider-#{System.unique_integer([:positive])}"

    assert {:ok, %ProviderConfig{}} =
             create_mixed_backplane_provider(provider_name, [
               "disabled-model",
               "enabled-model"
             ])

    session = persisted_session(provider_name, "disabled-model")
    on_exit(fn -> Sessions.delete(session.id) end)

    assert {:ok, %{provider: ^provider_name, model: "enabled-model"}} =
             Sessions.recover_unsupported_provider_model(session)
  end

  test "does not persist a model when local and Backplane availability have no intersection" do
    provider_name = "no-valid-model-#{System.unique_integer([:positive])}"

    assert {:ok, %ProviderConfig{}} =
             create_mixed_backplane_provider(provider_name, ["disabled-model"])

    session = persisted_session(provider_name, "disabled-model")
    on_exit(fn -> Sessions.delete(session.id) end)

    assert {:error, :model_unavailable} = Sessions.recover_unsupported_provider_model(session)
    assert {:ok, %{provider: ^provider_name, model: "disabled-model"}} = Sessions.get(session.id)
  end

  test "local providers prefer an explicit environment default over cached models" do
    previous_model = System.get_env("ANTHROPIC_MODEL")

    on_exit(fn ->
      if previous_model,
        do: System.put_env("ANTHROPIC_MODEL", previous_model),
        else: System.delete_env("ANTHROPIC_MODEL")
    end)

    System.put_env("ANTHROPIC_MODEL", "env-model")

    assert {:ok, %ProviderConfig{}} =
             Providers.create(%{
               name: "anthropic",
               type: "anthropic",
               enabled: true,
               config: %{
                 "enabled_models" => [],
                 "available_models" => [%{"id" => "cached-model"}]
               }
             })

    assert {:ok, session} = Sessions.create("main", %{provider: "anthropic"})
    on_exit(fn -> Sessions.delete(session.id) end)

    assert session.model == "env-model"
    assert {:ok, %{model: "env-model"}} = Sessions.get(session.id)
  end

  test "stale status recovery does not persist an unavailable fallback model" do
    provider_name = "stale-no-valid-model-#{System.unique_integer([:positive])}"

    assert {:ok, %ProviderConfig{}} =
             create_mixed_backplane_provider(provider_name, ["disabled-model"])

    session = persisted_session(provider_name, "disabled-model")

    stale = %{
      session
      | status: "streaming",
        updated_at: DateTime.add(DateTime.utc_now(), -60, :second)
    }

    :ok = Store.put_meta(stale.id, Session.to_meta(stale))
    on_exit(fn -> Sessions.delete(stale.id) end)

    assert {:error, :model_unavailable} =
             Sessions.recover_stale_transient_status(stale, after_seconds: 0)

    assert {:ok, %{status: "streaming", model: "disabled-model"}} = Sessions.get(stale.id)
  end

  defp create_mixed_backplane_provider(provider_name, enabled_models) do
    Providers.create(%{
      name: provider_name,
      type: "openai",
      enabled: true,
      config: %{
        "managed_by" => "backplane",
        "backplane_source_id" => "source-1",
        "backplane_available" => true,
        "enabled_models" => enabled_models,
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
  end

  defp persisted_session(provider, model) do
    now = DateTime.utc_now()

    session = %Session{
      id: Ecto.UUID.generate(),
      agent: "main",
      provider: provider,
      model: model,
      config: %{},
      status: "idle",
      inserted_at: now,
      updated_at: now
    }

    :ok = Store.put_meta(session.id, Session.to_meta(session))
    session
  end
end
