defmodule Synapsis.Agent.Tools.ReadinessTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.Tools.Readiness

  setup do
    scope = %{caller: "host", run_id: "run", incarnation: 1, catalog_revision: 1}
    selected = %{scope: scope, tools: %{"native::read" => 2}}
    evidence = %{scope: scope, tools: %{"native::read" => %{tool_revision: 2, status: :ready}}}
    %{selected: selected, evidence: evidence}
  end

  test "explicit empty selection is ready with scoped evidence", ctx do
    assert :ok = Readiness.check(%{ctx.selected | tools: %{}}, %{ctx.evidence | tools: %{}})
  end

  test "exact selected revisions are ready", ctx do
    assert :ok = Readiness.check(ctx.selected, ctx.evidence)
  end

  test "unavailable evidence retains its reason code and details", ctx do
    reason = %{code: :credential_unavailable, credential_id: "credential-ref"}
    evidence = put_in(ctx.evidence, [:tools, "native::read", :status], {:unavailable, reason})

    assert {:error, {:unavailable, "native::read", ^reason}} =
             Readiness.check(ctx.selected, evidence)
  end

  test "missing and unknown evidence never silently remove selected tools", ctx do
    assert {:error, {:missing_evidence, "native::read"}} =
             Readiness.check(ctx.selected, %{ctx.evidence | tools: %{}})

    evidence = put_in(ctx.evidence, [:tools, "native::read", :status], :unknown)

    assert {:error, {:unknown_readiness, "native::read"}} =
             Readiness.check(ctx.selected, evidence)
  end

  test "every scope field and tool revision is fenced", ctx do
    for {field, value} <- [caller: "other", run_id: "other", incarnation: 2, catalog_revision: 2] do
      evidence = put_in(ctx.evidence, [:scope, field], value)
      assert {:error, :scope_mismatch} = Readiness.check(ctx.selected, evidence)
    end

    evidence = put_in(ctx.evidence, [:tools, "native::read", :tool_revision], 3)
    assert {:error, {:stale_evidence, "native::read"}} = Readiness.check(ctx.selected, evidence)
  end

  test "missing or malformed selections and evidence fail closed", ctx do
    for selected <- [
          nil,
          :none,
          %{},
          %{ctx.selected | tools: %{"native::read" => nil}},
          %{ctx.selected | scope: %{}}
        ] do
      assert {:error, _} = Readiness.check(selected, ctx.evidence)
    end

    for evidence <- [nil, %{}, %{ctx.evidence | tools: nil}] do
      assert {:error, _} = Readiness.check(ctx.selected, evidence)
    end
  end

  test "numeric scope and tool revisions require exact types", ctx do
    for field <- [:incarnation, :catalog_revision] do
      evidence = put_in(ctx.evidence, [:scope, field], 1.0)
      assert {:error, :scope_mismatch} = Readiness.check(ctx.selected, evidence)
    end

    evidence = put_in(ctx.evidence, [:tools, "native::read", :tool_revision], 2.0)
    assert {:error, {:stale_evidence, "native::read"}} = Readiness.check(ctx.selected, evidence)
  end
end
