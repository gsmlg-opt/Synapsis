defmodule Synapsis.SessionsTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.{ProviderConfig, Providers, Session, Sessions}
  alias Synapsis.Session.Store

  defmodule FailingSessionRuntime do
    def configure(mode), do: Process.put({__MODULE__, :mode}, mode)

    def start_session(session_id) do
      send(self(), {:session_start_attempted, session_id})

      case Process.get({__MODULE__, :mode}) do
        :raise ->
          raise "session runtime exploded"

        :exit ->
          exit(:session_runtime_down)

        :boot_error ->
          {:error, :boot_failed}

        :boot_error_stop_raises ->
          {:error, :boot_failed}

        :boot_error_with_failure ->
          Synapsis.Session.Quarantine.record_failure(session_id)
          {:error, :boot_failed}
      end
    end

    def stop_session(session_id) do
      send(self(), {:session_stop_attempted, session_id})

      if Process.get({__MODULE__, :mode}) == :boot_error_stop_raises,
        do: raise("session stop exploded"),
        else: {:error, :not_found}
    end
  end

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

  test "create returns the effective model persisted during worker boot" do
    provider_name = "create-mixed-provider-#{System.unique_integer([:positive])}"

    assert {:ok, %ProviderConfig{}} =
             create_mixed_backplane_provider(provider_name, [
               "disabled-model",
               "enabled-model"
             ])

    assert {:ok, session} =
             Sessions.create("main", %{provider: provider_name, model: "disabled-model"})

    on_exit(fn -> Sessions.delete(session.id) end)

    assert session.model == "enabled-model"
    assert {:ok, %{model: "enabled-model"}} = Sessions.get(session.id)
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

  test "failed worker boot removes the new session and session-scoped permission state" do
    provider_name = "failed-create-provider-#{System.unique_integer([:positive])}"
    agent_name = "failed-create-agent-#{System.unique_integer([:positive])}"

    assert {:ok, %ProviderConfig{}} =
             create_mixed_backplane_provider(provider_name, ["disabled-model"])

    assert {:error, _reason} =
             Sessions.create(agent_name, %{
               provider: provider_name,
               model: "disabled-model"
             })

    assert {:ok, []} = Sessions.list(agent_name)
  end

  test "create cleans persisted state when session startup raises" do
    provider_name = "raising-create-provider-#{System.unique_integer([:positive])}"

    assert {:ok, %ProviderConfig{}} =
             create_mixed_backplane_provider(provider_name, ["enabled-model"])

    FailingSessionRuntime.configure(:raise)

    result =
      Sessions.create("main", %{
        provider: provider_name,
        model: "enabled-model",
        session_runtime: FailingSessionRuntime
      })

    assert {:error, _reason} = result
    assert_receive {:session_start_attempted, session_id}
    assert_receive {:session_stop_attempted, ^session_id}
    assert {:error, :not_found} = Sessions.get(session_id)
    assert :missing = Store.get_value(session_id, "permission", :missing)
  end

  test "create cleans persisted state when session startup exits" do
    provider_name = "exiting-create-provider-#{System.unique_integer([:positive])}"

    assert {:ok, %ProviderConfig{}} =
             create_mixed_backplane_provider(provider_name, ["enabled-model"])

    FailingSessionRuntime.configure(:exit)

    assert {:error, {:exit, :session_runtime_down}} =
             Sessions.create("main", %{
               provider: provider_name,
               model: "enabled-model",
               session_runtime: FailingSessionRuntime
             })

    assert_receive {:session_start_attempted, session_id}
    assert_receive {:session_stop_attempted, ^session_id}
    assert {:error, :not_found} = Sessions.get(session_id)
    assert :missing = Store.get_value(session_id, "permission", :missing)
  end

  test "failed create clears session quarantine counters" do
    provider_name = "quarantined-create-provider-#{System.unique_integer([:positive])}"

    assert {:ok, %ProviderConfig{}} =
             create_mixed_backplane_provider(provider_name, ["enabled-model"])

    FailingSessionRuntime.configure(:boot_error_with_failure)

    assert {:error, :boot_failed} =
             Sessions.create("main", %{
               provider: provider_name,
               model: "enabled-model",
               session_runtime: FailingSessionRuntime
             })

    assert_receive {:session_start_attempted, session_id}
    assert Synapsis.Session.Quarantine.failure_count(session_id) == 0
    refute Synapsis.Session.Quarantine.quarantined?(session_id)
  end

  test "failed create still deletes persisted state when runtime cleanup raises" do
    provider_name = "cleanup-raising-provider-#{System.unique_integer([:positive])}"

    assert {:ok, %ProviderConfig{}} =
             create_mixed_backplane_provider(provider_name, ["enabled-model"])

    FailingSessionRuntime.configure(:boot_error_stop_raises)

    assert {:error, {:session_create_failed, :boot_failed, {:cleanup_failed, _reason}}} =
             Sessions.create("main", %{
               provider: provider_name,
               model: "enabled-model",
               session_runtime: FailingSessionRuntime
             })

    assert_receive {:session_start_attempted, session_id}
    assert_receive {:session_stop_attempted, ^session_id}
    assert {:error, :not_found} = Sessions.get(session_id)
    assert :missing = Store.get_value(session_id, "permission", :missing)
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

  test "unsupported recovery accepts a keyless built-in provider fallback" do
    model = Providers.default_model("anthropic")
    session = persisted_session("anthropic", model)
    on_exit(fn -> Sessions.delete(session.id) end)

    assert {:ok, %{provider: "anthropic", model: ^model}} =
             Sessions.recover_unsupported_provider_model(session)
  end

  test "stale recovery accepts an explicit session-local provider fallback" do
    provider_name = "session-local-#{System.unique_integer([:positive])}"
    model = "local-model"

    config = %{
      "providers" => %{
        provider_name => %{"baseURL" => "http://localhost:11434/v1"}
      }
    }

    session = persisted_session(provider_name, model, config)

    stale = %{
      session
      | status: "streaming",
        updated_at: DateTime.add(DateTime.utc_now(), -60, :second)
    }

    :ok = Store.put_meta(stale.id, Session.to_meta(stale))
    on_exit(fn -> Sessions.delete(stale.id) end)

    assert {:ok, %{status: "idle", provider: ^provider_name, model: ^model}} =
             Sessions.recover_stale_transient_status(stale, after_seconds: 0)
  end

  test "recovery does not let local fallback override an unavailable imported provider" do
    model = Providers.default_model("anthropic")

    assert {:ok, %ProviderConfig{}} =
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

    config = %{
      "providers" => %{
        "anthropic" => %{"baseURL" => "http://localhost:11434/v1"}
      }
    }

    session = persisted_session("anthropic", model, config)
    on_exit(fn -> Sessions.delete(session.id) end)

    assert {:error, :model_unavailable} =
             Sessions.recover_unsupported_provider_model(session)

    assert {:ok, %{provider: "anthropic", model: ^model}} = Sessions.get(session.id)
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

  defp persisted_session(provider, model, config \\ %{}) do
    now = DateTime.utc_now()

    session = %Session{
      id: Ecto.UUID.generate(),
      agent: "main",
      provider: provider,
      model: model,
      config: config,
      status: "idle",
      inserted_at: now,
      updated_at: now
    }

    :ok = Store.put_meta(session.id, Session.to_meta(session))
    session
  end
end
