defmodule Synapsis.ModelCatalogTest do
  use Synapsis.DataCase, async: false
  alias Synapsis.{Config.Store, Models, Providers}

  setup do
    for type <- [:provider, :model, :agent, :backplane], do: clear_config_store(type)
    :ok
  end

  test "missing contexts use 256k while explicit and known registry capacities survive" do
    {:ok, provider} =
      Providers.create(%{
        name: "context-defaults",
        type: "openai",
        config: %{
          "available_models" => [
            %{"id" => "missing-context"},
            %{"id" => "explicit-context", "context_window" => 128_000},
            %{"id" => "gpt-4o"}
          ]
        }
      })

    assert [
             %{id: "missing-context", context_window: 256_000},
             %{id: "explicit-context", context_window: 128_000},
             %{id: "gpt-4o", context_window: 128_000}
           ] = Providers.cached_models(provider)

    assert [%{context_window: 256_000}] =
             Providers.cached_models(%{
               "config" => %{"available_models" => [%{id: "atom-context"}]}
             })

    Providers.configured_models()
    assert Providers.model_context_window(provider.name, "missing-context") == 256_000
    assert Providers.model_context_window(provider.name, "explicit-context") == 128_000
    assert Providers.model_context_window(provider.name, "gpt-4o") == 128_000
    assert Providers.model_context_window(provider.name, "unknown-context") == 256_000
    assert Providers.model_context_window(provider.name, "claude-sonnet-4-6") == 200_000
  end

  test "runtime model selection accepts legacy providers without a catalog migration marker" do
    cases = [
      {%{}, nil},
      {%{"available_models" => [%{"id" => "cached"}]}, "cached"},
      {%{
         "available_models" => [%{"id" => "cached"}],
         "enabled_models" => ["enabled"]
       }, "enabled"}
    ]

    for {{config, expected}, index} <- Enum.with_index(cases) do
      assert {:ok, provider} =
               Providers.create(%{
                 name: "legacy-runtime-#{index}",
                 type: "openai",
                 config: config
               })

      assert provider.config["model_catalog_migrated"] == nil
      assert Providers.first_runtime_model(provider) == expected
    end
  end

  test "configured models share provider identity and effective context with runtime admission" do
    {:ok, first} =
      Providers.create(%{
        name: "catalog-one",
        type: "openai",
        config: %{"model_catalog_migrated" => true}
      })

    {:ok, second} =
      Providers.create(%{
        name: "catalog-two",
        type: "openai",
        config: %{"model_catalog_migrated" => true}
      })

    {:ok, one} = Models.create(%{provider_id: first.id, model: "manual", context_window: 49_152})
    {:ok, two} = Models.create(%{provider_id: second.id, model: "manual", context_window: 8192})
    rows = Providers.configured_models()

    assert Enum.any?(
             rows,
             &(&1.id == one.id and &1.provider == first.name and &1.context_window == 49_152)
           )

    assert Enum.any?(
             rows,
             &(&1.id == two.id and &1.provider_id == second.id and &1.model == "manual")
           )

    assert Providers.model_context_window(first.name, "manual") == 49_152
    assert Providers.model_runtime_available?(first, "manual")
    refute Providers.model_runtime_available?(first, "not-configured")
    assert {:ok, _} = Models.update(one, %{enabled: false})
    refute Providers.model_runtime_available?(first, "manual")
    assert {:ok, _} = Providers.update(second.id, %{enabled: false})
    assert [] == Providers.configured_models()
  end

  test "migration preserves enabled filters, manual agent defaults and edited catalog records" do
    {:ok, provider} =
      Providers.create(%{
        name: "legacy-catalog",
        type: "anthropic",
        config: %{
          "available_models" => [
            %{"id" => "remote", "context_window" => 32_768},
            %{"id" => "disabled", "context_window" => 4096}
          ],
          "enabled_models" => ["remote", "manual-default"]
        }
      })

    {:ok, _} =
      Store.put(:agent, %{
        "id" => Ecto.UUID.generate(),
        "name" => "legacy-agent",
        "provider" => provider.name,
        "model" => "manual-default"
      })

    assert length(Providers.configured_models()) == 2
    {:ok, manual} = Models.get_by_identity(provider.id, "manual-default")
    {:ok, remote} = Models.get_by_identity(provider.id, "remote")
    {:ok, disabled} = Models.get_by_identity(provider.id, "disabled")
    refute disabled.enabled
    assert {:ok, _} = Models.update(remote, %{context_window: 2048, enabled: false})
    assert {:ok, _} = Models.delete(manual.id)
    assert [] == Providers.configured_models()
    assert {:ok, reloaded} = Models.get(remote.id)
    assert reloaded.context_window == 2048
    assert {:error, :not_found} = Models.get(manual.id)
    assert {:ok, persisted_provider} = Providers.get(provider.id)
    assert persisted_provider.config["model_catalog_migrated"]
    assert {:ok, raw_toml} = Toml.decode(File.read!(Store.file_path(:provider)))

    assert Enum.any?(
             raw_toml["providers"],
             &(&1["id"] == provider.id and
                 get_in(&1, ["config", "model_catalog_migrated"]) == true)
           )

    assert :ok = Store.reload(:provider)
    assert {:ok, reloaded_provider} = Providers.get(provider.id)
    assert reloaded_provider.config["model_catalog_migrated"]
    assert :ok = Store.reload(:model)
    assert [] == Providers.configured_models()
    assert Providers.model_context_window(provider.name, "remote") == 2048
  end

  test "discovery refresh provides suggestions without changing imported choices" do
    bypass = Bypass.open()

    Bypass.expect(bypass, "GET", "/v1/models", fn conn ->
      Plug.Conn.resp(
        Plug.Conn.put_resp_content_type(conn, "application/json"),
        200,
        Jason.encode!(%{
          "data" => [%{"id" => "remote", "context_window" => 128_000}, %{"id" => "new"}]
        })
      )
    end)

    {:ok, provider} =
      Providers.create(%{
        name: "discover-catalog",
        type: "openai",
        base_url: "http://localhost:#{bypass.port}/v1",
        config: %{"model_catalog_migrated" => true}
      })

    {:ok, model} =
      Models.create(%{
        provider_id: provider.id,
        model: "remote",
        context_window: 4096,
        enabled: false
      })

    assert {:ok, _} = Providers.refresh_models(provider.id)
    assert {:ok, same} = Models.get(model.id)
    assert same == model
    assert [] == Providers.configured_models()
    assert {:error, :not_found} = Models.get_by_identity(provider.id, "new")
  end

  test "Backplane catalog admission continues honoring source availability" do
    source_id = Ecto.UUID.generate()
    {:ok, _} = Store.put(:backplane, %{"id" => source_id, "enabled" => true})

    {:ok, provider} =
      Providers.create(%{
        name: "managed-catalog",
        type: "openai",
        config: %{
          "model_catalog_migrated" => true,
          "managed_by" => "backplane",
          "backplane_source_id" => source_id,
          "backplane_models" => [
            %{
              "external_id" => "remote",
              "source_available" => false,
              "backplane_available" => false
            }
          ]
        }
      })

    {:ok, _} = Models.create(%{provider_id: provider.id, model: "remote", context_window: 4096})
    refute Providers.model_runtime_available?(provider, "remote")
    assert [] == Providers.configured_models()
  end

  test "runtime admission rechecks persisted catalog and provider state for stale callers" do
    {:ok, provider} =
      Providers.create(%{
        name: "stale-catalog",
        type: "openai",
        config: %{"available_models" => [%{"id" => "legacy"}]}
      })

    assert [_] = Providers.configured_models()
    {:ok, model} = Models.get_by_identity(provider.id, "legacy")
    {:ok, _} = Models.delete(model.id)
    refute Providers.model_runtime_available?(provider, "legacy")
    {:ok, _} = Models.create(%{provider_id: provider.id, model: "legacy", context_window: 4096})
    {:ok, _} = Providers.update(provider.id, %{enabled: false})
    refute Providers.model_runtime_available?(provider, "legacy")
  end

  test "migration imports the saved session pair once with its configured context" do
    session_id = Ecto.UUID.generate()
    provider_name = "legacy-session-#{Ecto.UUID.generate()}"
    {:ok, provider} = Providers.create(%{name: provider_name, type: "openai"})

    assert :ok =
             Synapsis.Session.Store.put_meta(session_id, %{
               id: session_id,
               provider: provider_name,
               model: "session-only",
               config: %{"model_context_window" => 24576}
             })

    on_exit(fn -> Synapsis.Session.Store.delete_session(session_id) end)
    assert [%{model: "session-only", context_window: 24576}] = Providers.configured_models()
    assert {:ok, imported} = Models.get_by_identity(provider.id, "session-only")
    assert {:ok, _} = Models.delete(imported.id)
    assert [] == Providers.configured_models()
    assert {:ok, meta} = Synapsis.Session.Store.get_meta(session_id)
    assert meta.provider == provider_name
    assert meta.model == "session-only"
  end

  test "migration retains explicit provider model lists and environment defaults" do
    session_id = Ecto.UUID.generate()

    assert :ok =
             Synapsis.Session.Store.put_meta(session_id, %{
               provider: "anthropic",
               model: "saved-session"
             })

    on_exit(fn -> Synapsis.Session.Store.delete_session(session_id) end)

    previous = System.get_env("ANTHROPIC_MODEL")
    System.put_env("ANTHROPIC_MODEL", "environment-default")

    on_exit(fn ->
      if previous,
        do: System.put_env("ANTHROPIC_MODEL", previous),
        else: System.delete_env("ANTHROPIC_MODEL")
    end)

    {:ok, _} =
      Providers.create(%{
        name: "anthropic",
        type: "anthropic",
        config: %{
          "models" => ["custom-model", %{"id" => "metadata-model", "context_window" => 8192}]
        }
      })

    # Earlier umbrella apps may leave durable sessions for this named provider.
    assert {:ok, sessions} = Synapsis.Session.Store.list_metas()

    saved_models =
      for session <- sessions,
          (session[:provider] || session["provider"]) == "anthropic",
          model = session[:model] || session["model"],
          is_binary(model) and model != "",
          do: model

    rows = Providers.configured_models()

    expected = ["custom-model", "environment-default", "metadata-model" | saved_models]
    assert Enum.sort(Enum.map(rows, & &1.model)) == Enum.sort(Enum.uniq(expected))

    assert Enum.any?(rows, &(&1.model == "metadata-model" and &1.context_window == 8192))
  end

  test "migration reads string session keys and ignores invalid context" do
    {:ok, provider} = Providers.create(%{name: "string-session", type: "openai"})

    for {model, context} <- [{"saved-context", 16384}, {"invalid-context", -1}] do
      id = Ecto.UUID.generate()

      :ok =
        Synapsis.Session.Store.put_meta(id, %{
          "provider" => provider.name,
          "model" => model,
          "config" => %{"context_window" => context}
        })

      on_exit(fn -> Synapsis.Session.Store.delete_session(id) end)
    end

    rows = Providers.configured_models()
    assert Enum.any?(rows, &(&1.model == "saved-context" and &1.context_window == 16384))
    assert Enum.any?(rows, &(&1.model == "invalid-context" and &1.context_window == 256_000))
  end

  test "runtime config carries authoritative provider identity for signed history affinity" do
    {:ok, provider} =
      Providers.create(%{
        name: "affinity-provider",
        type: "openai",
        config: %{"provider_name" => "forged", "provider_id" => "forged-id"}
      })

    assert {:ok, config} = Providers.runtime_config(provider.name)
    assert config.provider_id == provider.id
    assert config.provider_name == provider.name
    assert {:ok, ^config} = Synapsis.Provider.Registry.get(provider.name)
  end

  test "legacy named provider metadata keeps its family rather than the wire protocol" do
    {:ok, _} =
      Providers.create(%{
        name: "minimax-cn",
        type: "anthropic",
        base_url: "https://api.minimaxi.com/anthropic"
      })

    models = Providers.configured_models()
    assert Enum.any?(models, &(&1.model == "MiniMax-M2"))
    refute Enum.any?(models, &(&1.model == "claude-sonnet-4-6"))
  end

  test "provider preset identity survives custom names and config reload" do
    {:ok, provider} =
      Providers.create(%{name: "my-backplane", preset: "backplane", type: "openai"})

    assert :ok = Store.reload(:provider)
    assert {:ok, reloaded} = Providers.get(provider.id)
    assert reloaded.preset == "backplane"
  end
end
