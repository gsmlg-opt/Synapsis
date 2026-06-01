defmodule Synapsis.Session.ReadTest do
  @moduledoc "ADR-006 B2: read-authority fallback to Concord when the process is down."
  use ExUnit.Case, async: false

  alias Synapsis.Session.{Read, Store}

  setup do
    assert Store.ensure_started() == :ok
    {:ok, id: "read-" <> Integer.to_string(System.unique_integer([:positive]))}
  end

  test "falls back to Concord's durable snapshot when no process is running", %{id: id} do
    refute Read.live?(id)

    meta = %{status: "idle", turn_count: 1}
    assert Store.commit_turn(id, 0, %{role: "user", parts: []}, meta) == :ok

    assert {:durable, %{meta: ^meta, turns: [%{role: "user"}]}} = Read.live_snapshot(id)
  end

  test "returns :not_found when there is neither a process nor a snapshot", %{id: id} do
    refute Read.live?(id)
    assert {:error, :not_found} = Read.live_snapshot(id)
  end
end
