defmodule Synapsis.MCPConfigsTest do
  use ExUnit.Case, async: false

  alias Synapsis.Config.Store
  alias Synapsis.{MCPConfig, MCPConfigs}

  setup do
    Synapsis.DataCase.clear_config_store(:backplane)

    on_exit(fn ->
      for c <- MCPConfigs.list(), do: MCPConfigs.delete(c)
      Synapsis.DataCase.clear_config_store(:backplane)
    end)

    :ok
  end

  test "create + get_by_name round-trips a stdio config" do
    {:ok, cfg} =
      MCPConfigs.create(%{
        name: "ctx7_#{System.unique_integer([:positive])}",
        transport: "stdio",
        command: "uvx",
        args: ["mcp-server-context7"],
        env: %{"TOKEN" => "abc"},
        enabled: true
      })

    assert cfg.transport == "stdio"
    assert MCPConfigs.get_by_name(cfg.name).command == "uvx"
  end

  test "rejects unknown transport" do
    {:error, changeset} =
      MCPConfigs.create(%{name: "bad", transport: "carrier-pigeon", command: "x"})

    assert "is invalid" in errors_on(changeset).transport
  end

  test "rejects invalid HTTP headers before persisting a config" do
    for headers <- [
          %{"{\"Authorization\"" => "\"Bearer test-token\"}"},
          %{"Bad Header" => "value"},
          %{"X-Test" => "value\r\nInjected: value"},
          %{"X-Test" => 123}
        ] do
      assert {:error, changeset} =
               MCPConfigs.create(%{
                 name: "invalid-headers",
                 transport: "streamable_http",
                 url: "http://localhost/mcp",
                 headers: headers
               })

      assert errors_on(changeset).headers != []
      assert MCPConfigs.get_by_name("invalid-headers") == nil
    end
  end

  test "invalid header updates preserve the existing HTTP config" do
    headers = %{"Authorization" => "Bearer test-token", "X-Client" => "synapsis:local"}

    assert {:ok, config} =
             MCPConfigs.create(%{
               name: "valid-headers",
               transport: "streamable_http",
               url: "http://localhost/mcp",
               headers: headers
             })

    assert {:error, _changeset} =
             MCPConfigs.update(config, %{headers: %{"{\"Authorization\"" => "bad"}})

    assert MCPConfigs.get(config.id).headers == headers
  end

  test "enabled/0 returns only effectively available configs" do
    suffix = System.unique_integer([:positive])

    assert {:ok, _connection} =
             Store.put(:backplane, %{
               "id" => "source-1",
               "name" => "source-1",
               "enabled" => true
             })

    {:ok, local} =
      MCPConfigs.create(%{
        name: "local-#{suffix}",
        transport: "stdio",
        command: "local-command",
        config: %{"backplane_available" => false}
      })

    {:ok, local_disabled} =
      MCPConfigs.create(%{
        name: "local-disabled-#{suffix}",
        transport: "stdio",
        command: "local-command",
        enabled: false
      })

    {:ok, managed} =
      MCPConfigs.create(%{
        name: "managed-#{suffix}",
        transport: "stdio",
        command: "managed-command",
        config: %{
          "managed_by" => "backplane",
          "backplane_source_id" => "source-1",
          "backplane_available" => true
        }
      })

    {:ok, unavailable} =
      MCPConfigs.create(%{
        name: "unavailable-#{suffix}",
        transport: "stdio",
        command: "managed-command",
        config: %{
          "managed_by" => "backplane",
          "backplane_source_id" => "source-1",
          "backplane_available" => false
        }
      })

    assert Enum.map(MCPConfigs.enabled(), & &1.id) |> Enum.sort() ==
             Enum.sort([local.id, managed.id])

    assert Enum.all?([local, local_disabled, managed, unavailable], fn config ->
             MCPConfigs.get(config.id)
           end)
  end

  test "managed configs require a present, enabled, well-formed source connection" do
    source_id = Ecto.UUID.generate()

    config = %MCPConfig{
      name: "managed-source-guard",
      transport: "stdio",
      command: "managed-command",
      enabled: true,
      config: %{
        "managed_by" => "backplane",
        "backplane_source_id" => source_id,
        "backplane_available" => true
      }
    }

    refute MCPConfigs.runtime_available?(config)

    assert {:ok, _connection} =
             Store.put(:backplane, %{"id" => source_id, "enabled" => false})

    refute MCPConfigs.runtime_available?(config)

    assert {:ok, _connection} =
             Store.put(:backplane, %{"id" => source_id, "enabled" => "true"})

    refute MCPConfigs.runtime_available?(config)

    assert {:ok, _connection} =
             Store.put(:backplane, %{"id" => source_id, "enabled" => true})

    assert MCPConfigs.runtime_available?(config)

    assert {:ok, _connection} =
             Store.put(:backplane, %{
               "id" => source_id,
               "enabled" => true,
               "metadata_json" => Jason.encode!(%{"runtime_blocked_surfaces" => ["tools"]})
             })

    refute MCPConfigs.runtime_available?(config)

    assert {:ok, _connection} =
             Store.put(:backplane, %{
               "id" => source_id,
               "enabled" => true,
               "metadata_json" => Jason.encode!(%{"runtime_blocked_surfaces" => ["skills"]})
             })

    assert MCPConfigs.runtime_available?(config)

    assert {:ok, _connection} =
             Store.put(:backplane, %{
               "id" => source_id,
               "enabled" => true,
               "metadata_json" => "invalid"
             })

    refute MCPConfigs.runtime_available?(config)

    assert :ok = Store.delete(:backplane, source_id)
    refute MCPConfigs.runtime_available?(config)
  end

  test "managed configs fail closed when source metadata JSON is not an object" do
    source_id = Ecto.UUID.generate()

    config = %MCPConfig{
      name: "managed-source-metadata-shape",
      transport: "stdio",
      command: "managed-command",
      enabled: true,
      config: %{
        "managed_by" => "backplane",
        "backplane_source_id" => source_id,
        "backplane_available" => true
      }
    }

    for metadata_json <- ["null", "[]"] do
      assert {:ok, _connection} =
               Store.put(:backplane, %{
                 "id" => source_id,
                 "enabled" => true,
                 "metadata_json" => metadata_json
               })

      refute MCPConfigs.runtime_available?(config)
    end
  end

  test "MCP annotation trust requires an enabled Backplane source and explicit local opt-in" do
    source_id = Ecto.UUID.generate()

    local = %MCPConfig{name: "local", enabled: true, config: %{}}

    managed = %MCPConfig{
      name: "managed",
      enabled: true,
      config: %{
        "managed_by" => "backplane",
        "backplane_source_id" => source_id,
        "backplane_available" => true
      }
    }

    refute MCPConfigs.trust_tool_annotations?(local)
    refute MCPConfigs.trust_tool_annotations?(managed)

    assert {:ok, _connection} =
             Store.put(:backplane, %{
               "id" => source_id,
               "enabled" => true,
               "connection_options_json" => Jason.encode!(%{"trust_mcp_annotations" => false})
             })

    refute MCPConfigs.trust_tool_annotations?(managed)

    assert {:ok, _connection} =
             Store.put(:backplane, %{
               "id" => source_id,
               "enabled" => true,
               "connection_options_json" => Jason.encode!(%{"trust_mcp_annotations" => true})
             })

    assert MCPConfigs.trust_tool_annotations?(managed)

    for malformed <- ["true", "null", "[]", "not-json"] do
      assert {:ok, _connection} =
               Store.put(:backplane, %{
                 "id" => source_id,
                 "enabled" => true,
                 "connection_options_json" => malformed
               })

      refute MCPConfigs.trust_tool_annotations?(managed)
    end

    assert {:ok, _connection} =
             Store.put(:backplane, %{
               "id" => source_id,
               "enabled" => false,
               "connection_options_json" => Jason.encode!(%{"trust_mcp_annotations" => true})
             })

    refute MCPConfigs.trust_tool_annotations?(managed)
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
