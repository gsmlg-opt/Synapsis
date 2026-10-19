defmodule Synapsis.Session.CommitTurnsTest do
  use ExUnit.Case, async: false

  alias Synapsis.Session.Store

  setup do
    :ok = Store.ensure_started()
    %{id: Ecto.UUID.generate()}
  end

  test "appends a complete turn and metadata without touching the transcript prefix", %{id: id} do
    prefix = %{role: "user", content: "existing", immutable_marker: Ecto.UUID.generate()}
    assert :ok = Store.commit_turn(id, 0, prefix, %{status: "streaming"})
    turns = [%{role: "assistant", content: "working"}, %{role: "user", content: "tool result"}]
    meta = %{status: "idle", latest_turn: 2}

    assert :ok = Store.commit_turns(id, 1, turns, meta)
    assert {:ok, ^prefix} = Store.get_turn(id, 0)
    assert {:ok, [^prefix | ^turns]} = Store.list_turns(id)
    assert {:ok, ^meta} = Store.get_meta(id)
  end

  test "recommitting the same fixed offset is idempotent", %{id: id} do
    turns = [%{id: "assistant-id", role: "assistant", content: "done"}]
    meta = %{status: "idle", latest_turn: 0}

    assert :ok = Store.commit_turns(id, 0, turns, meta)
    assert :ok = Store.commit_turns(id, 0, turns, meta)
    assert {:ok, ^turns} = Store.list_turns(id)
    assert {:ok, ^meta} = Store.get_meta(id)
  end

  test "an empty turn list still acknowledges metadata", %{id: id} do
    meta = %{status: "idle"}
    assert :ok = Store.commit_turns(id, 0, [], meta)
    assert {:ok, []} = Store.list_turns(id)
    assert {:ok, ^meta} = Store.get_meta(id)
  end

  test "oversized batches leave both transcript and metadata unchanged", %{id: id} do
    prefix = %{role: "user", content: "keep me"}
    meta = %{status: "streaming", latest_turn: 0}
    assert :ok = Store.commit_turn(id, 0, prefix, meta)
    turns = for n <- 1..Concord.Validation.max_batch_size(), do: %{sequence: n}

    assert {:error, :batch_too_large} = Store.commit_turns(id, 1, turns, %{status: "idle"})
    assert {:ok, [^prefix]} = Store.list_turns(id)
    assert {:ok, ^meta} = Store.get_meta(id)
    assert {:error, :not_found} = Store.get_turn(id, 1)
  end
end
