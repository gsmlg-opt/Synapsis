defmodule Synapsis.Agent.TestSupport.DeterministicToolTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.DeterministicTool

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    name = "det_tool_unit_#{suffix}"

    on_exit(fn ->
      DeterministicTool.unregister(name)
    end)

    %{name: name}
  end

  test "read_success returns ok text", %{name: name} do
    :ok = DeterministicTool.register(name, :read_success)

    assert {:ok, "deterministic read: hi"} =
             Synapsis.Tool.Executor.execute_approved(name, %{"value" => "hi"}, %{})

    assert length(DeterministicTool.executions(name)) == 1
  end

  test "timeout surfaces as executor timeout", %{name: name} do
    :ok = DeterministicTool.register(name, :timeout, timeout: 50, sleep_ms: 200, max_retries: 0)

    assert {:error, :timeout} =
             Synapsis.Tool.Executor.execute_approved(name, %{"value" => "x"}, %{})
  end

  test "crash surfaces as executor error", %{name: name} do
    :ok = DeterministicTool.register(name, :crash, max_retries: 0)

    assert {:error, message} =
             Synapsis.Tool.Executor.execute_approved(name, %{}, %{})

    assert message =~ "deterministic tool crash"
  end

  test "idempotent_side_effect increments counter", %{name: name} do
    :ok = DeterministicTool.register(name, :idempotent_side_effect)

    assert {:ok, _} = Synapsis.Tool.Executor.execute_approved(name, %{}, %{})
    assert {:ok, _} = Synapsis.Tool.Executor.execute_approved(name, %{}, %{})
    assert DeterministicTool.side_effect_count(name) == 2
  end

  test "uncertain_outcome records intent then errors", %{name: name} do
    :ok = DeterministicTool.register(name, :uncertain_outcome, max_retries: 0)

    assert {:error, message} =
             Synapsis.Tool.Executor.execute_approved(name, %{"value" => "x"}, %{})

    assert message =~ "uncertain outcome"
    assert [%{"value" => "x"}] = DeterministicTool.intents(name)
  end

  test "deny registration uses destructive permission level", %{name: name} do
    :ok = DeterministicTool.register(name, :deny)

    assert {:ok, {_kind, _module, opts}} = Synapsis.Tool.Registry.lookup(name)
    assert opts[:permission_level] == :destructive
  end
end
