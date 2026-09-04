defmodule Synapsis.SessionsTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.{ProviderConfig, Providers, Session, Sessions}
  alias Synapsis.Session.Store

  setup do
    Synapsis.DataCase.clear_config_store(:provider)

    on_exit(fn ->
      Synapsis.DataCase.clear_config_store(:provider)
    end)

    :ok
  end

  test "recovers a source-disabled Backplane model to its available sibling" do
    provider_name = "mixed-provider-#{System.unique_integer([:positive])}"

    assert {:ok, %ProviderConfig{}} =
             Providers.create(%{
               name: provider_name,
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

    session = persisted_session(provider_name, "disabled-model")
    on_exit(fn -> Sessions.delete(session.id) end)

    assert {:ok, %{provider: ^provider_name, model: "enabled-model"}} =
             Sessions.recover_unsupported_provider_model(session)
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
