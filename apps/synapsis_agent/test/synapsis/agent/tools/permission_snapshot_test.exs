defmodule Synapsis.Agent.Tools.PermissionSnapshotTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.Tools.{PermissionSnapshot, Policy}

  setup do
    raw = %{
      session_id: "session",
      mode: :interactive,
      allow_read: :allow,
      allow_write: :deny,
      allow_execute: :ask,
      allow_destructive: :deny,
      tool_overrides: %{}
    }

    scope = %{
      caller: "host",
      session_id: "session",
      run_id: "run",
      incarnation: 1,
      catalog_revision: 1,
      permission_fingerprint: expected_fingerprint(raw)
    }

    classifier = fn invocation ->
      {:ok, %{action: "inspect", resource: invocation.arguments["resource"]}}
    end

    bindings = %{
      "native::one" => %{tool_revision: 2, classify: classifier},
      "native::two" => %{tool_revision: 3, classify: classifier}
    }

    targets =
      for name <- Map.keys(bindings),
          do: %{tool: name, action: "inspect", resource: "doc:one", permission_level: :read}

    %{raw: raw, scope: scope, bindings: bindings, targets: targets}
  end

  test "raw validation shares compiler rules without asserting tool binding coverage", ctx do
    assert :ok = PermissionSnapshot.validate(ctx.raw, ctx.raw.session_id)

    assert :ok =
             PermissionSnapshot.validate(
               %Synapsis.SessionPermission{session_id: "session"},
               "session"
             )

    assert :ok =
             PermissionSnapshot.validate(
               %{ctx.raw | tool_overrides: %{"outside" => :deny}},
               "session"
             )

    assert {:needs_review, :session_mismatch} = PermissionSnapshot.validate(ctx.raw, "another")

    for raw <- [
          nil,
          %{},
          %{ctx.raw | mode: :unknown},
          %{ctx.raw | tool_overrides: %{"read_tool(*)" => :unknown}},
          %{ctx.raw | tool_overrides: %{"read_tool" => :allow, "read_tool(*)" => :deny}}
        ] do
      assert {:needs_review, _} = PermissionSnapshot.validate(raw, "session")
    end
  end

  test "explicit level settings compile into Policy without changing input", ctx do
    assert {:ok, policy} = compile(ctx)
    assert policy.tools === ctx.bindings
    assert policy.scope === ctx.scope
    assert :allow = prepare(policy, "native::one", 2)
    assert {:deny, :missing_decision} = prepare(policy, "native::one", 2, "doc:other")
    assert {:deny, :stale_policy} = prepare(policy, "native::one", 3)
  end

  test "all four explicit levels apply equally in both modes", ctx do
    levels = [
      read: :allow_read,
      write: :allow_write,
      execute: :allow_execute,
      destructive: :allow_destructive
    ]

    for mode <- [:interactive, :autonomous],
        {level, setting} <- levels,
        decision <- [:allow, :deny, :ask] do
      raw = ctx.raw |> Map.put(:mode, mode) |> Map.put(setting, decision)
      targets = Enum.map(ctx.targets, &%{&1 | permission_level: level})
      assert {:ok, policy} = compile(ctx, raw: raw, targets: targets)
      assert policy.decisions[{"native::one", "inspect", "doc:one"}] == decision

      expected =
        case decision do
          :allow -> :allow
          :deny -> {:deny, :policy_denied}
          :ask -> {:deny, :approval_required}
        end

      assert prepare(policy, "native::one", 2) == expected
    end
  end

  test "same action and resource retain separate exact tool overrides", ctx do
    raw = %{ctx.raw | tool_overrides: %{"native::one" => "deny", "native::two" => "ask"}}
    assert {:ok, policy} = compile(ctx, raw: raw)
    assert {:deny, :policy_denied} = prepare(policy, "native::one", 2)
    assert {:deny, :approval_required} = prepare(policy, "native::two", 3)
    assert map_size(policy.decisions) == 2
  end

  test "legacy whole-tool forms preserve their exact qualifier", ctx do
    binding = ctx.bindings["native::one"]

    ctx = %{
      ctx
      | bindings: %{"read_tool" => binding},
        targets: [%{hd(ctx.targets) | tool: "read_tool"}]
    }

    for spec <- ["read_tool", "read_tool(*)"], value <- [:deny, :denied, "deny", "denied"] do
      raw = %{ctx.raw | tool_overrides: %{spec => value}}
      assert {:ok, policy} = compile(ctx, raw: raw)
      assert {:deny, :policy_denied} = prepare(policy, "read_tool", 2)
    end

    for value <- [
          :allow,
          :allowed,
          "allow",
          "allowed",
          :ask,
          :requires_approval,
          "ask",
          "requires_approval"
        ] do
      raw = %{ctx.raw | tool_overrides: %{"read_tool(*)" => value}}
      assert {:ok, _} = compile(ctx, raw: raw)
    end

    raw = %{ctx.raw | tool_overrides: %{"read_tool" => :allow, "read_tool(*)" => :deny}}
    assert {:needs_review, {:overlapping_overrides, _}} = compile(ctx, raw: raw)
  end

  test "narrow qualified parenthesized wildcard and overlapping rules need review", ctx do
    for overrides <- [
          %{"bash(git *)" => "allow"},
          %{"file_read(src/a.ex)" => "allow"},
          %{"native::one(*)" => "allow"},
          %{"native::*" => "allow"},
          %{"tool" => "allow", "tool(*)" => "deny"},
          %{native_one: "deny"},
          %{"native::one" => "unrecognized"},
          %{"unselected_tool(exact/restriction)" => "deny"}
        ] do
      raw = %{ctx.raw | tool_overrides: overrides}
      assert {:needs_review, _} = compile(ctx, raw: raw)
    end
  end

  test "outside-binding whole-tool overrides cannot disappear into a base allow", ctx do
    bindings = %{"exec_command" => ctx.bindings["native::one"]}
    targets = [%{hd(ctx.targets) | tool: "exec_command", permission_level: :execute}]

    for spec <- ["bash", "bash(*)", "native::unknown"], decision <- [:deny, :ask, :allow] do
      raw = %{ctx.raw | allow_execute: :allow, tool_overrides: %{spec => decision}}

      assert {:needs_review, {:unbound_override, _}} =
               compile(ctx, raw: raw, bindings: bindings, targets: targets)

      assert {:needs_review, {:unbound_override, _}} =
               compile(ctx, raw: raw, bindings: %{}, targets: [])
    end
  end

  test "struct override and binding containers return needs_review instead of raising", ctx do
    row = struct!(Synapsis.SessionPermission, ctx.raw)
    raw = %{ctx.raw | tool_overrides: row}
    assert {:needs_review, :invalid_permission_snapshot} = compile(ctx, raw: raw)
    assert {:needs_review, :invalid_tool_bindings} = compile(ctx, bindings: row)

    assert {:needs_review, :invalid_permission_snapshot} =
             compile(ctx, raw: %{ctx.raw | tool_overrides: MapSet.new()})

    assert {:needs_review, :invalid_tool_bindings} = compile(ctx, bindings: MapSet.new())
  end

  test "missing malformed and ambiguous raw fields never acquire defaults", ctx do
    for field <- [
          :session_id,
          :mode,
          :allow_read,
          :allow_write,
          :allow_execute,
          :allow_destructive,
          :tool_overrides
        ] do
      assert {:needs_review, _} = compile(ctx, raw: Map.delete(ctx.raw, field))
      raw = Map.put(ctx.raw, Atom.to_string(field), "allow")
      assert {:needs_review, _} = compile(ctx, raw: raw)
    end

    for raw <- [
          nil,
          %{},
          %{ctx.raw | mode: :unknown},
          %{ctx.raw | allow_read: true},
          %{ctx.raw | tool_overrides: nil}
        ] do
      assert {:needs_review, _} = compile(ctx, raw: raw)
    end
  end

  test "source session and expected fingerprint must match trusted scope", ctx do
    for scope <- [
          %{ctx.scope | session_id: "another"},
          %{ctx.scope | permission_fingerprint: "stale"},
          Map.delete(ctx.scope, :session_id),
          Map.delete(ctx.scope, :permission_fingerprint),
          Map.put(ctx.scope, "session_id", "another"),
          %{ctx.scope | incarnation: 1.0},
          %{ctx.scope | catalog_revision: 0}
        ] do
      assert {:needs_review, _} =
               PermissionSnapshot.compile(ctx.raw, scope, ctx.bindings, ctx.targets)
    end

    raw = %{ctx.raw | allow_read: :deny}

    assert {:needs_review, :fingerprint_mismatch} =
             PermissionSnapshot.compile(raw, ctx.scope, ctx.bindings, ctx.targets)
  end

  test "fingerprint is deterministic raw content identity and normalizes persisted structs",
       ctx do
    reordered = ctx.raw |> Enum.reverse() |> Map.new()
    assert PermissionSnapshot.fingerprint(reordered) == expected_fingerprint(ctx.raw)

    assert PermissionSnapshot.fingerprint(%{ctx.raw | allow_read: :deny}) !=
             expected_fingerprint(ctx.raw)

    row = struct!(Synapsis.SessionPermission, ctx.raw)

    assert PermissionSnapshot.fingerprint(row) ==
             PermissionSnapshot.fingerprint(Map.from_struct(row))

    scope = %{ctx.scope | permission_fingerprint: expected_fingerprint(Map.from_struct(row))}
    assert {:ok, _} = PermissionSnapshot.compile(row, scope, ctx.bindings, ctx.targets)
  end

  test "binding and target classification must be explicit unambiguous and finite", ctx do
    for bindings <- [
          nil,
          %{"native::one" => %{}},
          put_in(ctx.bindings, ["native::one", :tool_revision], 2.0),
          put_in(ctx.bindings, ["native::one", :classify], :read),
          put_in(ctx.bindings, ["native::one", "classify"], :untrusted)
        ] do
      assert {:needs_review, _} = compile(ctx, bindings: bindings)
    end

    for targets <- [
          nil,
          [],
          [hd(ctx.targets), hd(ctx.targets)],
          [%{hd(ctx.targets) | tool: "missing"}],
          [%{hd(ctx.targets) | permission_level: :none}],
          [%{hd(ctx.targets) | resource: ""}],
          [Map.put(hd(ctx.targets), "permission_level", :destructive)]
        ] do
      assert {:needs_review, _} = compile(ctx, targets: targets)
    end

    assert {:ok, %{tools: %{}, decisions: %{}}} = compile(ctx, bindings: %{}, targets: [])
  end

  test "compiled snapshot fingerprint fences Policy and readiness evidence", ctx do
    assert {:ok, policy} = compile(ctx)
    context = policy_context(policy)
    stale = put_in(context, [:tool_readiness, :scope, :permission_fingerprint], "stale")
    assert {:deny, :scope_mismatch} = Policy.prepare_tool(invocation("native::one", 2), stale)
    stale = put_in(context, [:tool_scope, :permission_fingerprint], "stale")
    assert {:deny, :scope_mismatch} = Policy.prepare_tool(invocation("native::one", 2), stale)
  end

  defp compile(ctx, opts \\ []) do
    raw = Keyword.get(opts, :raw, ctx.raw)

    scope =
      if is_map(raw),
        do: %{ctx.scope | permission_fingerprint: expected_fingerprint(raw)},
        else: ctx.scope

    PermissionSnapshot.compile(
      raw,
      scope,
      Keyword.get(opts, :bindings, ctx.bindings),
      Keyword.get(opts, :targets, ctx.targets)
    )
  end

  defp expected_fingerprint(raw) do
    raw
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp invocation(name, revision, resource \\ "doc:one") do
    %{
      run_id: "run",
      incarnation: 1,
      catalog_revision: 1,
      tool_name: name,
      tool_revision: revision,
      arguments: %{"resource" => resource}
    }
  end

  defp prepare(policy, name, revision, resource \\ "doc:one"),
    do: Policy.prepare_tool(invocation(name, revision, resource), policy_context(policy))

  defp policy_context(policy) do
    evidence =
      Map.new(policy.tools, fn {name, binding} ->
        {name, %{tool_revision: binding.tool_revision, status: :ready}}
      end)

    %{
      tool_scope: policy.scope,
      tool_policy: policy,
      tool_readiness: %{scope: policy.scope, tools: evidence},
      input_kind: :function
    }
  end
end
