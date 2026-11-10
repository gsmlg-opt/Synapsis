defmodule Synapsis.Session.StoreRecentTurnsFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Concord.Turso, as: KV
  alias Synapsis.Session.Store

  setup do
    assert :ok = Store.ensure_started()
    %{id: Ecto.UUID.generate()}
  end

  test "recent reads seek only the requested newest keys and return exact chronological turns", %{
    id: id
  } do
    turns = for n <- 0..39, do: %{n: n, text: "消息 #{n}", payload: String.duplicate("雪", 1_000)}

    assert {:ok, _} =
             KV.put_many(Enum.with_index(turns, fn turn, n -> {Store.turn_key(id, n), turn} end))

    other = Ecto.UUID.generate()
    assert :ok = KV.put(Store.turn_key(other, 999), %{n: 999})

    {result, calls} = observe(fn -> Store.list_recent_turns(id, 6) end)
    assert result == {:ok, Enum.take(turns, -6)}
    assert [{:list, [opts]}] = Enum.filter(calls, &(elem(&1, 0) == :list))
    assert opts[:order] == :desc
    assert opts[:limit] == 6
    assert opts[:keys_only] == true
    assert opts[:queue] == true
    assert opts[:timeout] == 5_000
    assert [{:get_many, [keys, _]}] = Enum.filter(calls, &(elem(&1, 0) == :get_many))
    assert keys == Enum.map(34..39, &Store.turn_key(id, &1))

    {complete, complete_calls} = observe(fn -> Store.list_recent_turns(id, 50) end)
    assert complete == {:ok, turns}
    assert [{:list, [complete_opts]}] = Enum.filter(complete_calls, &(elem(&1, 0) == :list))
    assert complete_opts[:limit] == 50
  end

  test "requests beyond one upstream page retain every requested turn without duplicate boundaries",
       %{
         id: id
       } do
    for chunk <- Enum.chunk_every(0..10_002, 500) do
      assert {:ok, _} = KV.put_many(Enum.map(chunk, &{Store.turn_key(id, &1), %{n: &1}}))
    end

    {result, calls} = observe(fn -> Store.list_recent_turns(id, 10_002) end)
    assert result == {:ok, Enum.map(1..10_002, &%{n: &1})}
    lists = for {:list, [opts]} <- calls, do: opts
    assert Enum.map(lists, & &1[:limit]) == [10_000, 2]
    assert Enum.all?(lists, &(&1[:order] == :desc and &1[:keys_only] and &1[:queue]))
    assert Enum.at(lists, 1)[:range] == {Store.turns_prefix(id), Store.turn_key(id, 3)}
    reads = for {:get_many, [keys, _]} <- calls, key <- keys, do: key
    assert reads == Enum.map(1..10_002, &Store.turn_key(id, &1))
  end

  test "existing ascending context pages opt into finite queued list reads", %{id: id} do
    assert :ok = KV.put(Store.turn_key(id, 2), %{text: "earlier"})
    assert :ok = KV.put(Store.turn_key(id, 9), %{text: "latest"})

    {result, calls} = observe(fn -> Store.list_turn_page(id, limit: 2) end)

    assert result ==
             {:ok,
              %{
                turns: [
                  %{index: 2, turn: %{text: "earlier"}},
                  %{index: 9, turn: %{text: "latest"}}
                ],
                next_cursor: nil,
                has_more: false,
                truncated: false
              }}

    lists = for {:list, [opts]} <- calls, do: opts
    assert length(lists) == 3
    assert Enum.all?(lists, &(&1[:queue] == true and &1[:timeout] in 1..5_000))
    assert Enum.map(lists, & &1[:timeout]) == Enum.sort(Enum.map(lists, & &1[:timeout]), :desc)
  end

  defp observe(fun) do
    Code.ensure_loaded!(KV)
    observer = spawn(fn -> collect([]) end)
    monitor = Process.monitor(observer)
    :erlang.trace_pattern({KV, :list, 1}, true, [:local])
    :erlang.trace_pattern({KV, :get_many, 2}, true, [:local])
    :erlang.trace(self(), true, [:call, {:tracer, observer}])

    try do
      result = fun.()
      delivered = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _, ^delivered}, 5_000
      send(observer, {:finish, self()})
      assert_receive {:observed_calls, calls}, 5_000
      assert_receive {:DOWN, ^monitor, :process, ^observer, :normal}, 5_000
      {result, calls}
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({KV, :list, 1}, false, [:local])
      :erlang.trace_pattern({KV, :get_many, 2}, false, [:local])
      send(observer, :stop)
    end
  end

  defp collect(calls) do
    receive do
      {:trace, _, :call, {KV, function, args}} -> collect([{function, args} | calls])
      {:finish, owner} -> send(owner, {:observed_calls, Enum.reverse(calls)})
      :stop -> :ok
    end
  end
end
