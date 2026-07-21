defmodule Synapsis.Session.StoreTest do
  @moduledoc """
  B0 spike validation: confirms Concord's real API satisfies the four ADR-006
  session-storage assumptions — node-local readiness, meta/turn round-trip,
  atomic whole-turn commit, and ordered range reads.
  """
  use ExUnit.Case, async: false

  alias Concord.Turso, as: KV
  alias Synapsis.Session.Store

  setup do
    assert Store.ensure_started() == :ok
    # Unique id per test keeps the shared node-local store isolated.
    {:ok, id: "sess-" <> Ecto.UUID.generate()}
  end

  describe "meta round-trip" do
    test "writes and reads back a meta snapshot", %{id: id} do
      meta = %{agent: "main", provider: "anthropic", status: "idle"}
      assert Store.put_meta(id, meta) == :ok
      assert {:ok, ^meta} = Store.get_meta(id)
    end

    test "missing meta returns :not_found", %{id: id} do
      assert Store.get_meta(id) == {:error, :not_found}
    end
  end

  describe "turn round-trip + ordering" do
    test "commit_turn persists the turn and updated meta atomically", %{id: id} do
      turn = %{role: "user", content: "hello"}
      meta = %{status: "streaming", latest_turn: 0}

      assert Store.commit_turn(id, 0, turn, meta) == :ok
      assert {:ok, ^turn} = Store.get_turn(id, 0)
      assert {:ok, ^meta} = Store.get_meta(id)
    end

    test "list_turns returns turns in ascending order regardless of commit order",
         %{id: id} do
      # Commit out of numeric order on purpose.
      assert Store.commit_turn(id, 2, %{n: 2}, %{latest_turn: 2}) == :ok
      assert Store.commit_turn(id, 0, %{n: 0}, %{latest_turn: 0}) == :ok
      assert Store.commit_turn(id, 1, %{n: 1}, %{latest_turn: 1}) == :ok

      assert {:ok, [%{n: 0}, %{n: 1}, %{n: 2}]} = Store.list_turns(id)
    end

    test "list_turns is empty for an unknown session", %{id: id} do
      assert {:ok, []} = Store.list_turns(id)
    end
  end

  describe "atomicity (single-command multi-key commit)" do
    # commit_turn relies on put_many persisting a whole turn batch together.
    test "put_many commits all keys in the batch together", %{id: id} do
      key_a = "atomic/" <> id <> "/a"
      key_b = "atomic/" <> id <> "/b"

      assert {:ok, %{^key_a => :ok, ^key_b => :ok}} =
               KV.put_many([{key_a, %{v: 1}}, {key_b, %{v: 2}}])

      assert {:ok, %{v: 1}} = KV.get(key_a)
      assert {:ok, %{v: 2}} = KV.get(key_b)
    end
  end

  describe "idempotency" do
    test "re-committing the same turn number overwrites in place (no duplicate)", %{id: id} do
      turn = %{role: "assistant", content: "hi"}
      meta = %{status: "idle", latest_turn: 0}

      assert Store.commit_turn(id, 0, turn, meta) == :ok
      assert Store.commit_turn(id, 0, turn, meta) == :ok

      assert {:ok, ^turn} = Store.get_turn(id, 0)
      assert {:ok, [^turn]} = Store.list_turns(id)
    end
  end

  describe "delete_session" do
    test "removes meta and all turns", %{id: id} do
      assert Store.commit_turn(id, 0, %{n: 0}, %{latest_turn: 0}) == :ok
      assert Store.commit_turn(id, 1, %{n: 1}, %{latest_turn: 1}) == :ok

      assert Store.delete_session(id) == :ok

      assert Store.get_meta(id) == {:error, :not_found}
      assert {:ok, []} = Store.list_turns(id)
    end

    test "deletes sessions with more keys than Concord's batch limit", %{id: id} do
      assert Store.put_meta(id, %{id: id, agent: "main", status: "idle"}) == :ok

      values =
        for n <- 1..501 do
          {Store.value_key(id, "bulk/#{n}"), %{n: n}}
        end

      for chunk <- Enum.chunk_every(values, 500) do
        assert {:ok, _results} = KV.put_many(chunk)
      end

      assert Store.delete_session(id) == :ok
      assert Store.get_meta(id) == {:error, :not_found}

      assert {:ok, []} = KV.prefix_scan(Store.session_prefix(id))
    end
  end
end
