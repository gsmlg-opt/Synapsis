defmodule Synapsis.Session.QuarantineTest do
  @moduledoc "ADR-006 B1 poison protection: boot-failure tracking + quarantine."
  use ExUnit.Case, async: false

  alias Synapsis.Session.Quarantine

  setup do
    id = "q-" <> Integer.to_string(System.unique_integer([:positive]))
    on_exit(fn -> Quarantine.clear(id) end)
    {:ok, id: id}
  end

  test "record_failure quarantines once the threshold is reached", %{id: id} do
    refute Quarantine.quarantined?(id)
    t = Quarantine.threshold()

    for n <- 1..(t - 1) do
      assert {:ok, ^n} = Quarantine.record_failure(id)
      refute Quarantine.quarantined?(id)
    end

    assert {:quarantined, ^t} = Quarantine.record_failure(id)
    assert Quarantine.quarantined?(id)
  end

  test "clear resets the failure count and quarantine flag", %{id: id} do
    Quarantine.quarantine(id)
    assert Quarantine.quarantined?(id)

    assert :ok = Quarantine.clear(id)
    refute Quarantine.quarantined?(id)
    assert Quarantine.failure_count(id) == 0
  end

  test "start_session refuses a quarantined session", %{id: id} do
    Quarantine.quarantine(id)
    assert {:error, :quarantined} = Synapsis.Session.DynamicSupervisor.start_session(id)
  end

  test "quarantined? is false for an unknown session", %{id: id} do
    refute Quarantine.quarantined?(id)
    assert Quarantine.failure_count(id) == 0
  end
end
