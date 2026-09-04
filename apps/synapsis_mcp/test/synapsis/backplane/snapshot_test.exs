defmodule Synapsis.Backplane.SnapshotTest do
  use ExUnit.Case, async: true

  alias Synapsis.Backplane.{Connection, Snapshot}

  @fetched_at "2026-09-04T02:03:04Z"

  test "normalizes every capability with stable source identity and canonical revisions" do
    connection = connection!()

    surfaces = %{
      models:
        {:ok,
         [
           %{"id" => "model-b", "owned_by" => "team"},
           %{"id" => "model-a", "revision" => "model-a-r1"}
         ]},
      skills:
        {:ok,
         [
           %{
             "id" => "skill-42",
             "slug" => "review",
             "name" => "Review",
             "content" => "Review carefully.",
             "content_hash" => String.duplicate("b", 64),
             "source_kind" => "generated"
           }
         ]},
      mcp_tools:
        {:ok,
         [
           %{
             "name" => "memory::search",
             "description" => "Search memory",
             "inputSchema" => %{"type" => "object"}
           }
         ]}
    }

    assert {:ok, first} = Snapshot.normalize(connection, surfaces, fetched_at: @fetched_at)

    assert %{
             __struct__: Synapsis.Backplane.Snapshot,
             providers: [provider],
             models: models,
             skills: [skill],
             mcp_servers: [server],
             mcp_tools: [tool],
             other_capabilities: [],
             errors: %{},
             fetched_at: @fetched_at
           } = first

    for capability <- [provider, skill, server, tool] ++ models do
      assert capability.source == "backplane"
      assert capability.connection_id == connection.id
      assert is_binary(capability.external_id)
      assert capability.external_revision =~ ~r/^[a-f0-9]{64}$/
      assert is_binary(capability.name)
      assert is_binary(capability.kind)
      assert capability.enabled_by_source == true
      assert is_map(capability.metadata)
    end

    assert provider.external_id == "openai-compatible"
    assert Enum.map(models, & &1.external_id) == ["model-a", "model-b"]
    assert skill.external_id == "skill-42"
    assert skill.external_revision == String.duplicate("b", 64)
    assert server.external_id == "mcp"
    assert tool.external_id == "memory::search"
    assert first.source_revision =~ ~r/^[a-f0-9]{64}$/

    assert MapSet.new(Map.keys(first.surface_revisions)) ==
             MapSet.new([:mcp_tools, :models, :skills])

    reordered = %{surfaces | models: {:ok, surfaces.models |> elem(1) |> Enum.reverse()}}
    assert {:ok, second} = Snapshot.normalize(connection, reordered, fetched_at: @fetched_at)
    assert second.source_revision == first.source_revision
    assert second.surface_revisions == first.surface_revisions

    changed =
      put_in(
        surfaces,
        [:skills],
        {:ok, [put_in(hd(elem(surfaces.skills, 1)), ["content_hash"], String.duplicate("c", 64))]}
      )

    assert {:ok, third} = Snapshot.normalize(connection, changed, fetched_at: @fetched_at)
    refute third.source_revision == first.source_revision
    refute hd(third.skills).external_revision == skill.external_revision
  end

  test "retains independent surface errors without inventing failed capabilities" do
    surfaces = %{
      models: {:error, :timeout},
      skills: {:ok, []},
      mcp_tools: {:error, {:http_status, 503}}
    }

    assert {:ok, snapshot} = Snapshot.normalize(connection!(), surfaces, fetched_at: @fetched_at)
    assert snapshot.providers == []
    assert snapshot.models == []
    assert snapshot.skills == []
    assert snapshot.mcp_servers == []
    assert snapshot.mcp_tools == []
    assert snapshot.errors == %{models: :timeout, mcp_tools: {:http_status, 503}}
    assert snapshot.surface_revisions == %{skills: Snapshot.revision([])}
  end

  test "uses the slug when an upstream skill id is absent" do
    surfaces = %{
      models: {:ok, []},
      skills: {:ok, [%{"slug" => "review", "name" => "Review", "content" => "Body"}]},
      mcp_tools: {:ok, []}
    }

    assert {:ok, %{skills: [%{external_id: "review"}]}} =
             Snapshot.normalize(connection!(), surfaces, fetched_at: @fetched_at)
  end

  test "falls back to the stable identity when an upstream display name is invalid" do
    surfaces = %{
      models: {:ok, [%{"id" => "model-a", "name" => 42}]},
      skills: {:ok, []},
      mcp_tools: {:ok, []}
    }

    assert {:ok, %{models: [%{external_id: "model-a", name: "model-a"}]}} =
             Snapshot.normalize(connection!(), surfaces, fetched_at: @fetched_at)
  end

  test "enabled_by_source is independent of local connection enablement" do
    connection = %{connection!() | enabled: false}

    surfaces = %{
      models:
        {:ok, [%{"id" => "enabled-model"}, %{"id" => "disabled-model", "enabled" => false}]},
      skills: {:ok, [%{"slug" => "enabled-skill", "content" => "Body"}]},
      mcp_tools: {:ok, [%{"name" => "enabled-tool"}]}
    }

    assert {:ok, snapshot} = Snapshot.normalize(connection, surfaces, fetched_at: @fetched_at)
    assert [%{enabled_by_source: true}] = snapshot.providers
    assert [%{enabled_by_source: false}, %{enabled_by_source: true}] = snapshot.models
    assert [%{enabled_by_source: true}] = snapshot.skills
    assert [%{enabled_by_source: true}] = snapshot.mcp_servers
    assert [%{enabled_by_source: true}] = snapshot.mcp_tools
  end

  test "preserves nested list order while ignoring top-level capability order" do
    first_schema = %{
      "name" => "tool",
      "inputSchema" => %{
        "prefixItems" => [%{"type" => "string"}, %{"type" => "integer"}]
      }
    }

    reordered_schema =
      put_in(first_schema, ["inputSchema", "prefixItems"], [
        %{"type" => "integer"},
        %{"type" => "string"}
      ])

    refute Snapshot.revision(first_schema) == Snapshot.revision(reordered_schema)

    base = %{
      models: {:ok, [%{"id" => "b"}, %{"id" => "a"}]},
      skills: {:ok, []},
      mcp_tools: {:ok, [first_schema, %{"name" => "other"}]}
    }

    assert {:ok, first} = Snapshot.normalize(connection!(), base, fetched_at: @fetched_at)

    reordered = %{
      base
      | models: {:ok, Enum.reverse(elem(base.models, 1))},
        mcp_tools: {:ok, Enum.reverse(elem(base.mcp_tools, 1))}
    }

    assert {:ok, second} = Snapshot.normalize(connection!(), reordered, fetched_at: @fetched_at)
    assert first.source_revision == second.source_revision
    assert first.surface_revisions == second.surface_revisions

    nested_changed = put_in(base, [:mcp_tools], {:ok, [reordered_schema, %{"name" => "other"}]})

    assert {:ok, third} =
             Snapshot.normalize(connection!(), nested_changed, fetched_at: @fetched_at)

    refute first.surface_revisions.mcp_tools == third.surface_revisions.mcp_tools
  end

  defp connection! do
    {:ok, connection} =
      Connection.new(%{
        id: "018f4e86-c58a-7f47-98bb-37fb0e159e1f",
        name: "team",
        endpoint: "https://backplane.example.test"
      })

    connection
  end
end
