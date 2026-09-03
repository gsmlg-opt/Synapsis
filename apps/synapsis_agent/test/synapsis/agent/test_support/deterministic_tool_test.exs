defmodule Synapsis.Agent.TestSupport.DeterministicToolTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.DeterministicTool
  alias Synapsis.Tool.Gateway

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    name = "det_tool_unit_#{suffix}"
    session_id = "det-sess-#{suffix}"

    on_exit(fn ->
      DeterministicTool.unregister(name)
    end)

    %{name: name, session_id: session_id}
  end

  defp exec(name, input, session_id, opts \\ []) do
    Gateway.execute(
      name,
      input,
      %{
        session_id: session_id,
        permission_mode: Keyword.get(opts, :permission_mode, "yolo"),
        attended?: Keyword.get(opts, :attended?, true),
        operator_approval: Keyword.get(opts, :operator_approval, false)
      }
    )
  end

  test "read_success returns ok text", %{name: name, session_id: session_id} do
    :ok = DeterministicTool.register(name, :read_success)

    assert {:ok, "deterministic read: hi"} =
             exec(name, %{"value" => "hi"}, session_id)

    assert length(DeterministicTool.executions(name)) == 1
  end

  test "timeout surfaces as executor timeout", %{name: name, session_id: session_id} do
    :ok = DeterministicTool.register(name, :timeout, timeout: 50, sleep_ms: 200, max_retries: 0)

    assert {:error, :timeout} = exec(name, %{"value" => "x"}, session_id)
  end

  test "crash surfaces as executor error", %{name: name, session_id: session_id} do
    :ok = DeterministicTool.register(name, :crash, max_retries: 0)

    assert {:error, message} = exec(name, %{}, session_id)
    assert message =~ "deterministic tool crash"
  end

  test "idempotent_side_effect increments counter", %{name: name, session_id: session_id} do
    :ok = DeterministicTool.register(name, :idempotent_side_effect)

    assert {:ok, _} = exec(name, %{}, session_id)
    assert {:ok, _} = exec(name, %{}, session_id)
    assert DeterministicTool.side_effect_count(name) == 2
  end

  test "uncertain_outcome records intent then errors", %{name: name, session_id: session_id} do
    :ok = DeterministicTool.register(name, :uncertain_outcome, max_retries: 0)

    assert {:error, message} = exec(name, %{"value" => "x"}, session_id)
    assert message =~ "uncertain outcome"
    assert [%{"value" => "x"}] = DeterministicTool.intents(name)
  end

  test "deny registration uses destructive permission level", %{name: name} do
    :ok = DeterministicTool.register(name, :deny)

    assert {:ok, {_kind, _module, opts}} = Synapsis.Tool.Registry.lookup(name)
    assert opts[:permission_level] == :destructive
  end
end
