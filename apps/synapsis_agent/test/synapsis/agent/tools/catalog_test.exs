defmodule Synapsis.Agent.Tools.CatalogTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Codex, Error, ToolCatalog}
  alias Synapsis.Agent.Tools.Catalog

  defmodule Backend do
    def execute(operation) do
      send(operation.backend_context.owner, :unexpected_backend_effect)
      {:ok, %{content: "inert"}}
    end
  end

  setup do
    authority = %{
      caller: "catalog-test",
      run_id: "catalog-run",
      grants: ["clock::curr_time", "host::inspect"],
      tool_revision: 1,
      tool_revisions: %{"clock::curr_time" => 1, "host::inspect" => 7}
    }

    {:ok, native} =
      Codex.profile(:pinned_local, %{}, %{authority | grants: ["clock::curr_time"]},
        tools: ["clock::curr_time"]
      )

    host = %{
      tool_name: "host::inspect",
      tool_revision: 7,
      description: "Trusted inert host descriptor",
      schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      safety: %{read_only: true, retry_safe: false, parallel_safe: false},
      backend: Backend,
      backend_context: %{owner: self(), binding: make_ref()}
    }

    %{authority: authority, native: native, host: host}
  end

  test "strictly composes native and trusted host descriptors with exact mixed revisions", ctx do
    assert {:ok, composed} =
             Catalog.compose([ctx.native], [ctx.host], ctx.authority, [
               "host::inspect",
               "clock::curr_time"
             ])

    assert composed.registry.tools["clock::curr_time"] ==
             ctx.native.registry.tools["clock::curr_time"]

    assert composed.registry.tools["host::inspect"] == ctx.host

    assert MapSet.new(composed.authority.grants) ==
             MapSet.new(["host::inspect", "clock::curr_time"])

    assert composed.authority.tool_revisions == %{"clock::curr_time" => 1, "host::inspect" => 7}
    assert MapSet.new(Enum.map(composed.tools, & &1.name)) == MapSet.new(composed.accepted)
    assert composed.rejected == []

    assert {:ok, readmitted} =
             ToolCatalog.admit_batch(
               [ctx.host, ctx.native.registry.tools["clock::curr_time"]],
               authority: composed.authority,
               mode: :strict
             )

    assert readmitted == composed
    refute_receive :unexpected_backend_effect, 0
  end

  test "selection narrows a wider ceiling without exposing unselected tools", ctx do
    assert {:ok, composed} =
             Catalog.compose([ctx.native], [ctx.host], ctx.authority, ["host::inspect"])

    assert Map.keys(composed.registry.tools) == ["host::inspect"]
    assert composed.authority.grants == ["host::inspect"]
    assert composed.authority.tool_revisions == %{"host::inspect" => 7}
    assert Enum.map(composed.tools, & &1.name) == ["host::inspect"]
  end

  test "explicit none and empty selection admit an empty native bundle", ctx do
    for selection <- [:none, []] do
      assert {:ok, composed} = Catalog.compose([ctx.native], [ctx.host], ctx.authority, selection)
      assert composed.registry.tools == %{}
      assert composed.tools == []
      assert composed.accepted == []
      assert composed.authority.grants == []
      assert composed.authority.tool_revisions == %{}
    end
  end

  test "there is no implicit full or wildcard selection", ctx do
    for selection <- [:full, :all, nil, "*"] do
      assert {:error, %Error{class: :validation}} =
               Catalog.compose([ctx.native], [ctx.host], ctx.authority, selection)
    end
  end

  test "unknown or explicitly unavailable selections fail closed", ctx do
    assert {:error, %Error{class: :unsupported_capability}} =
             Catalog.compose([ctx.native], [ctx.host], ctx.authority, ["unknown"])

    unavailable = %{ctx.host | backend: nil}

    assert {:error, %Error{class: :unsupported_capability}} =
             Catalog.compose([ctx.native], [unavailable], ctx.authority, ["host::inspect"])

    assert {:ok, _} =
             Catalog.compose([ctx.native], [unavailable], ctx.authority, ["clock::curr_time"])

    refute_receive :unexpected_backend_effect, 0
  end

  test "available descriptors cannot expand the target grant ceiling", ctx do
    for grants <- [[], ["clock::curr_time"], ["*"]] do
      assert {:error, %Error{class: :forbidden}} =
               Catalog.compose([ctx.native], [ctx.host], %{ctx.authority | grants: grants}, [
                 "host::inspect"
               ])
    end
  end

  test "explicit stale native and host revision ceilings are never replaced", ctx do
    for {name, revision} <- [{"clock::curr_time", 2}, {"host::inspect", 6}] do
      authority = put_in(ctx.authority, [:tool_revisions, name], revision)

      assert {:error, %Error{class: :forbidden}} =
               Catalog.compose([ctx.native], [ctx.host], authority, [name])
    end

    refute_receive :unexpected_backend_effect, 0
  end

  test "a scalar revision ceiling applies only where no explicit revision exists", ctx do
    authority = Map.delete(ctx.authority, :tool_revisions)

    assert {:ok, native} =
             Catalog.compose([ctx.native], [ctx.host], authority, ["clock::curr_time"])

    assert native.authority.tool_revisions == %{"clock::curr_time" => 1}

    assert {:error, %Error{class: :forbidden}} =
             Catalog.compose([ctx.native], [ctx.host], authority, ["host::inspect"])

    explicit = %{ctx.authority | tool_revision: 99}
    assert {:ok, _} = Catalog.compose([ctx.native], [ctx.host], explicit, ["host::inspect"])
  end

  test "source native bundles cannot cross target run or caller boundaries", ctx do
    for authority <- [
          %{ctx.authority | caller: "another-caller"},
          %{ctx.authority | run_id: "another-run"}
        ] do
      assert {:error, %Error{class: :forbidden}} =
               Catalog.compose([ctx.native], [ctx.host], authority, ["clock::curr_time"])
    end
  end

  test "duplicate descriptors fail even if the selection would omit the collision", ctx do
    duplicate = ctx.native.registry.tools["clock::curr_time"]

    for {bundles, hosts} <- [
          {[ctx.native, ctx.native], [ctx.host]},
          {[ctx.native], [duplicate, ctx.host]},
          {[ctx.native], [ctx.host, ctx.host]}
        ] do
      assert {:error, %Error{class: :validation}} =
               Catalog.compose(bundles, hosts, ctx.authority, :none)
    end
  end

  test "provider definitions alone are never treated as a native bundle", ctx do
    assert {:error, %Error{class: :validation}} =
             Catalog.compose(
               [%{tools: ctx.native.tools, authority: ctx.native.authority}],
               [ctx.host],
               ctx.authority,
               ["clock::curr_time"]
             )
  end
end
