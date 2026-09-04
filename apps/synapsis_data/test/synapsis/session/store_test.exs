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

    test "list_recent_turns reads only the newest bounded range", %{id: id} do
      for n <- 0..9 do
        assert :ok = KV.put(Store.turn_key(id, n), %{n: n, payload: String.duplicate("x", 2_000)})
      end

      for n <- 10..29 do
        assert :ok =
                 KV.put(Store.turn_key(id, n), %{
                   n: n,
                   payload: String.duplicate("recent", 500)
                 })
      end

      assert {:ok, recent} = Store.list_recent_turns(id, 10)
      assert Enum.map(recent, & &1.n) == Enum.to_list(20..29)
    end

    test "commit_turn advances recent reads after replace_turns without meta count", %{id: id} do
      assert Store.replace_turns(id, [%{n: 0}, %{n: 1}]) == :ok
      assert Store.commit_turn(id, 2, %{n: 2}, %{latest_turn: 2}) == :ok

      assert {:ok, [%{n: 2}]} = Store.list_recent_turns(id, 1)
    end

    test "out-of-order commit_turn keeps recent reads at the highest turn", %{id: id} do
      assert Store.replace_turns(id, Enum.map(0..3, &%{n: &1})) == :ok
      assert Store.commit_turn(id, 4, %{n: 4}, %{latest_turn: 4}) == :ok
      assert Store.commit_turn(id, 1, %{n: 1, overwritten: true}, %{latest_turn: 1}) == :ok

      assert {:ok, [%{n: 4}]} = Store.list_recent_turns(id, 1)
    end

    test "concurrent commits return the newest turn regardless of completion order", %{id: id} do
      assert Store.replace_turns(id, [%{n: 0}]) == :ok
      parent = self()

      tasks =
        for n <- 100..1//-1 do
          Task.async(fn ->
            send(parent, {:commit_ready, self()})

            receive do
              :commit -> Store.commit_turn(id, n, %{n: n}, %{latest_turn: n})
            end
          end)
        end

      for _task <- tasks, do: assert_receive({:commit_ready, _pid}, 5_000)
      Enum.each(tasks, &send(&1.pid, :commit))
      assert Enum.all?(Task.await_many(tasks, 30_000), &(&1 == :ok))

      assert {:ok, %{n: 100}} = Store.get_turn(id, 100)
      assert {:ok, [%{n: 100}]} = Store.list_recent_turns(id, 1)
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
