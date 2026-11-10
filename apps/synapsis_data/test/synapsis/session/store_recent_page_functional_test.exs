defmodule Synapsis.Session.StoreRecentPageFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Concord.Turso, as: KV
  alias Synapsis.Session.Store

  setup do
    assert :ok = Store.ensure_started()
    %{id: Ecto.UUID.generate()}
  end

  test "sparse newest pages continue exclusively toward index zero and a true end", %{id: id} do
    persist([
      {Store.turn_key(id, 91), %{text: "ninety-one"}},
      {Store.turn_key(id, 0), %{text: "zero"}},
      {Store.turn_key(id, 999_999_999_999), %{text: "last"}},
      {Store.turn_key(id, 7), %{text: "seven"}}
    ])

    assert {:ok,
            %{
              turns: [
                %{index: 91, turn: %{text: "ninety-one"}},
                %{index: 999_999_999_999, turn: %{text: "last"}}
              ],
              next_cursor: 91,
              has_more: true,
              truncated: false
            }} = Store.list_recent_turn_page(id, limit: 2)

    assert {:ok,
            %{
              turns: [
                %{index: 0, turn: %{text: "zero"}},
                %{index: 7, turn: %{text: "seven"}}
              ],
              next_cursor: nil,
              has_more: false,
              truncated: false
            }} = Store.list_recent_turn_page(id, cursor: 91, limit: 2)

    assert {:ok,
            %{
              turns: [%{index: 0, turn: %{text: "zero"}}],
              next_cursor: nil,
              has_more: false,
              truncated: false
            }} = Store.list_recent_turn_page(id, cursor: 7, limit: 1)

    assert {:ok, %{turns: [], next_cursor: nil, has_more: false, truncated: false}} =
             Store.list_recent_turn_page(id, cursor: 0)
  end

  test "a fresh durable namespace returns an empty successful page", %{id: id} do
    assert {:ok, %{turns: [], next_cursor: nil, has_more: false, truncated: false}} =
             Store.list_recent_turn_page(id)
  end

  test "Unicode and opaque nested maps retain their exact values at the shared byte boundary", %{
    id: id
  } do
    earlier = %{"text" => "你好 🌙", "opaque" => {:bytes, <<0, 255>>}}
    latest = %{messages: [%{text: "雪と光", at: ~U[2026-11-05 00:00:00Z]}]}
    bytes = :erlang.external_size(earlier) + :erlang.external_size(latest)
    persist([{Store.turn_key(id, 4), earlier}, {Store.turn_key(id, 90), latest}])

    assert {:ok,
            %{
              turns: [%{index: 4, turn: ^earlier}, %{index: 90, turn: ^latest}],
              next_cursor: nil,
              has_more: false,
              truncated: false
            }} = Store.list_recent_turn_page(id, max_bytes: bytes)
  end

  test "descending one-key seeks share finite timeouts and fetch only selected payloads", %{
    id: id
  } do
    persist(for n <- 0..39, do: {Store.turn_key(id, n), %{n: n}})
    deadline = System.monotonic_time(:millisecond) + 5_000

    {result, calls} =
      observe(fn -> Store.list_recent_turn_page(id, limit: 3, deadline: deadline) end)

    assert result ==
             {:ok,
              %{
                turns: [
                  %{index: 37, turn: %{n: 37}},
                  %{index: 38, turn: %{n: 38}},
                  %{index: 39, turn: %{n: 39}}
                ],
                next_cursor: 37,
                has_more: true,
                truncated: false
              }}

    lists = for {:list, [opts]} <- calls, do: opts
    assert length(lists) == 4
    assert length(lists) <= 512
    assert Enum.all?(lists, &(&1[:order] == :desc and &1[:limit] == 1))
    assert Enum.all?(lists, &(&1[:keys_only] == true and &1[:queue] == true))

    assert Enum.map(lists, & &1[:range]) == [
             {Store.turns_prefix(id), Store.session_prefix(id) <> "turns0"},
             {Store.turns_prefix(id), Store.turn_key(id, 39)},
             {Store.turns_prefix(id), Store.turn_key(id, 38)},
             {Store.turns_prefix(id), Store.turn_key(id, 37)}
           ]

    gets = for {:get, [key, opts]} <- calls, do: {key, opts}

    assert Enum.map(gets, &elem(&1, 0)) == [
             Store.turn_key(id, 37),
             Store.turn_key(id, 38),
             Store.turn_key(id, 39)
           ]

    assert Enum.map(calls, &elem(&1, 0)) == [:list, :list, :list, :list, :get, :get, :get]

    timeouts =
      Enum.map(calls, fn
        {:list, [opts]} -> opts[:timeout]
        {:get, [_key, opts]} -> opts[:timeout]
      end)

    assert Enum.all?(timeouts, &(&1 in 1..5_000))
    assert timeouts == Enum.sort(timeouts, :desc)
  end

  test "the default twenty and maximum hundred limits read the newest chronological page", %{
    id: id
  } do
    persist(for n <- 0..21, do: {Store.turn_key(id, n), %{n: n}})

    assert {:ok, %{turns: newest, next_cursor: 2, has_more: true, truncated: false}} =
             Store.list_recent_turn_page(id)

    assert newest == Enum.map(2..21, &%{index: &1, turn: %{n: &1}})

    assert {:ok, %{turns: all, next_cursor: nil, has_more: false, truncated: false}} =
             Store.list_recent_turn_page(id, limit: 100)

    assert all == Enum.map(0..21, &%{index: &1, turn: %{n: &1}})
  end

  defp persist(puts) do
    keys = Enum.map(puts, &elem(&1, 0))

    on_exit(fn ->
      for chunk <- Enum.chunk_every(keys, 100), do: KV.delete_many(chunk, timeout: 5_000)
    end)

    for chunk <- Enum.chunk_every(puts, 100) do
      assert {:ok, _} = KV.put_many(chunk, timeout: 5_000)
    end
  end

  defp observe(fun) do
    Code.ensure_loaded!(KV)
    observer = spawn(fn -> collect([]) end)
    monitor = Process.monitor(observer)
    :erlang.trace_pattern({KV, :list, 1}, true, [:local])
    :erlang.trace_pattern({KV, :get, 2}, true, [:local])
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
      :erlang.trace_pattern({KV, :get, 2}, false, [:local])
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
