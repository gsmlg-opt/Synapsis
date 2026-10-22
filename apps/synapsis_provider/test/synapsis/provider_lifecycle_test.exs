defmodule Synapsis.ProviderLifecycleTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.{Config.Store, Models, Providers}
  alias Synapsis.Provider.Registry, as: ProviderRegistry

  setup do
    for type <- [:provider, :model, :agent, :backplane, :mcp, :skill, :toolset],
        do: clear_config_store(type)

    :ok
  end

  test "deleting a provider clears its catalog, defaults and runtime registry" do
    {:ok, provider} = Providers.create(%{name: "lifecycle", type: "openai"})
    {:ok, model} = Models.create(%{provider_id: provider.id, model: "configured"})

    {:ok, _} =
      Store.put(:agent, %{
        "id" => Ecto.UUID.generate(),
        "name" => "lifecycle-agent",
        "provider" => provider.name,
        "model" => model.model
      })

    assert {:ok, _} = Providers.delete(provider.id)
    assert {:error, :not_found} = Models.get(model.id)
    assert [agent] = Store.list(:agent)
    refute agent["provider"]
    refute agent["model"]
    assert {:error, :not_found} = ProviderRegistry.get(provider.name)
  end

  test "provider changes publish local catalog invalidations after persistence" do
    assert :ok = Providers.subscribe()
    assert {:ok, provider} = Providers.create(%{name: "notified", type: "openai"})
    assert_receive {:provider_catalog_changed}
    assert {:ok, _} = Providers.update(provider.id, %{enabled: false})
    assert_receive {:provider_catalog_changed}
    assert {:ok, _} = Providers.delete(provider.id)
    assert_receive {:provider_catalog_changed}
    assert {:error, :not_found} = Providers.delete(provider.id)
    refute_receive {:provider_catalog_changed}
  end

  test "a delayed discovery response cannot recreate a deleted provider or populate its replacement" do
    bypass = Bypass.open()
    observer = self()

    Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
      send(observer, {:discovery_waiting, self()})
      receive do: (:respond -> :ok)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"data" => [%{"id" => "late-model"}]}))
    end)

    {:ok, provider} =
      Providers.create(%{
        name: "delayed",
        type: "openai",
        base_url: "http://localhost:#{bypass.port}/v1",
        config: %{"model_catalog_migrated" => true}
      })

    task = Task.async(fn -> Providers.refresh_models(provider.id) end)
    assert_receive {:discovery_waiting, request}, 2_000
    assert {:ok, _} = Providers.delete(provider.id)
    assert {:ok, replacement} = Providers.create(%{name: provider.name, type: "openai"})
    send(request, :respond)
    assert {:error, :not_found} = Task.await(task, 5_000)
    assert {:error, :not_found} = Providers.get(provider.id)
    assert {:ok, current} = Providers.get(replacement.id)
    assert Providers.cached_models(current) == []
  end
end
