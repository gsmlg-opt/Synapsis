defmodule Synapsis.Session.StoreAtomicReplacementFunctionalTest do
  use ExUnit.Case, async: false

  alias Concord.KV
  alias Concord.KV.Record
  alias Concord.Turso
  alias Synapsis.Session.Store

  @timeout 5_000
  @observed [
    {:replace_prefix, 3},
    {:prefix_scan, 1},
    {:prefix_scan, 2},
    {:delete_many, 1},
    {:delete_many, 2},
    {:put_many, 1},
    {:put_many, 2}
  ]

  setup do
    assert :ok = Store.ensure_started()
    id = Ecto.UUID.generate()
    on_exit(fn -> assert :ok = Store.delete_session(id) end)
    %{id: id, prefix: "sessions/" <> id <> "/turns/", meta_key: "sessions/" <> id <> "/meta"}
  end

  test "shrinking publishes complete old and new rows in one native replacement", %{
    id: id,
    prefix: prefix,
    meta_key: meta_key
  } do
    first_key = prefix <> "000000000000"
    assert {:ok, %{revision: created}} = put(first_key, %{text: "old first"})
    assert {:ok, _} = put(prefix <> "000000000001", %{text: "old second"})
    assert {:ok, _} = put(prefix <> "000000000002", %{text: "old third"})
    assert {:ok, _} = put(meta_key, %{title: "unchanged metadata", turn_count: 3})
    assert {:ok, original_meta} = record(meta_key)
    assert {:ok, before} = Turso.revision(timeout: @timeout)

    turns = [%{text: "new first"}, %{text: "new second"}]
    {result, calls} = observe(fn -> Store.replace_turns(id, turns) end)

    assert result == :ok

    assert calls == [
             {:replace_prefix,
              [
                prefix,
                [
                  {prefix <> "000000000000", %{text: "new first"}},
                  {prefix <> "000000000001", %{text: "new second"}}
                ],
                [timeout: 5_000]
              ]}
           ]

    assert {:ok, published} = Turso.revision(timeout: @timeout)
    assert published == before + 1

    assert rows(prefix, before) == [
             {prefix <> "000000000000", %{text: "old first"}},
             {prefix <> "000000000001", %{text: "old second"}},
             {prefix <> "000000000002", %{text: "old third"}}
           ]

    assert rows(prefix, published) == [
             {prefix <> "000000000000", %{text: "new first"}},
             {prefix <> "000000000001", %{text: "new second"}}
           ]

    assert {:ok, ^turns} = Store.list_turns(id)

    assert {:ok,
            %Record{
              value: %{text: "new first"},
              create_revision: ^created,
              mod_revision: ^published,
              version: 2
            }} = record(first_key)

    assert {:ok, %Record{mod_revision: ^published, version: 2}} =
             record(prefix <> "000000000001")

    assert {:ok, ^original_meta} = record(meta_key)

    for revision <- [before, published] do
      for keys_only <- [false, true] do
        assert {:ok, [historical_meta], %{has_more: false, last_key: ^meta_key}} =
                 KV.list(
                   engine: :turso,
                   range: {meta_key, meta_key <> <<0>>},
                   revision: revision,
                   keys_only: keys_only,
                   limit: 1,
                   timeout: @timeout
                 )

        expected = Map.put(original_meta, :key, meta_key)
        expected = if keys_only, do: Map.put(expected, :value, nil), else: expected
        assert historical_meta == expected
      end

      assert {:ok, %{title: "unchanged metadata", turn_count: 3}} =
               KV.get(meta_key, engine: :turso, revision: revision, timeout: @timeout)
    end
  end

  test "empty replacement publishes a true empty prefix without changing metadata", %{
    id: id,
    prefix: prefix,
    meta_key: meta_key
  } do
    assert {:ok, _} = put(prefix <> "000000000000", %{text: "first"})
    assert {:ok, _} = put(prefix <> "000000000004", %{text: "sparse tail"})
    assert {:ok, _} = put(meta_key, %{title: "kept for an empty transcript"})
    assert {:ok, original_meta} = record(meta_key)
    assert {:ok, before} = Turso.revision(timeout: @timeout)

    assert :ok = Store.replace_turns(id, [])
    assert {:ok, published} = Turso.revision(timeout: @timeout)
    assert published == before + 1

    assert rows(prefix, before) == [
             {prefix <> "000000000000", %{text: "first"}},
             {prefix <> "000000000004", %{text: "sparse tail"}}
           ]

    assert rows(prefix, published) == []
    assert {:ok, []} = Store.list_turns(id)
    assert {:ok, ^original_meta} = record(meta_key)
  end

  test "all five hundred ordinary turns fit one publication", %{
    id: id,
    prefix: prefix,
    meta_key: meta_key
  } do
    assert {:ok, %{revision: created}} = put(prefix <> "000000000000", %{text: "original"})
    assert {:ok, _} = put(prefix <> "000000000501", %{text: "stale tail"})
    assert {:ok, _} = put(meta_key, %{title: "five hundred turns"})
    assert {:ok, original_meta} = record(meta_key)
    assert {:ok, before} = Turso.revision(timeout: @timeout)

    turns = for index <- 0..499, do: %{index: index, text: "ordinary turn #{index}"}
    assert :ok = Store.replace_turns(id, turns)
    assert {:ok, published} = Turso.revision(timeout: @timeout)
    assert published == before + 1

    assert rows(prefix, before) == [
             {prefix <> "000000000000", %{text: "original"}},
             {prefix <> "000000000501", %{text: "stale tail"}}
           ]

    expected =
      for index <- 0..499 do
        key = prefix <> String.pad_leading(Integer.to_string(index), 12, "0")
        {key, %{index: index, text: "ordinary turn #{index}"}}
      end

    assert rows(prefix, published) == expected
    assert {:ok, ^turns} = Store.list_turns(id)

    assert {:ok, records, %{has_more: false}} =
             KV.list(
               engine: :turso,
               prefix: prefix,
               revision: published,
               keys_only: true,
               limit: 500,
               timeout: @timeout
             )

    assert length(records) == 500
    assert [retained | added] = records
    assert retained.create_revision == created
    assert retained.mod_revision == published
    assert retained.version == 2
    assert Enum.all?(added, &(&1.create_revision == published and &1.mod_revision == published))
    assert {:ok, ^original_meta} = record(meta_key)
  end

  test "an ordinary value larger than the generic transaction envelope remains admitted", %{
    id: id,
    prefix: prefix,
    meta_key: meta_key
  } do
    assert {:ok, _} = put(prefix <> "000000000000", %{text: "small original"})
    assert {:ok, _} = put(meta_key, %{title: "large ordinary value"})
    assert {:ok, original_meta} = record(meta_key)
    assert {:ok, before} = Turso.revision(timeout: @timeout)
    value = %{text: String.duplicate("ordinary accepted value 雪 ", 50_000)}
    assert :erlang.external_size(value) > 1_000_000

    assert :ok = Store.replace_turns(id, [value])
    assert {:ok, published} = Turso.revision(timeout: @timeout)
    assert published == before + 1
    assert rows(prefix, before) == [{prefix <> "000000000000", %{text: "small original"}}]
    assert rows(prefix, published) == [{prefix <> "000000000000", value}]
    assert {:ok, [^value]} = Store.list_turns(id)
    assert {:ok, ^original_meta} = record(meta_key)
  end

  defp put(key, value),
    do: KV.put(key, value, engine: :turso, compress: false, timeout: @timeout)

  defp record(key),
    do: KV.get(key, engine: :turso, metadata: true, timeout: @timeout)

  defp rows(prefix, revision) do
    assert {:ok, records, %{has_more: false}} =
             KV.list(
               engine: :turso,
               prefix: prefix,
               revision: revision,
               limit: 500,
               timeout: @timeout
             )

    Enum.map(records, &{&1.key, &1.value})
  end

  defp observe(fun) do
    Code.ensure_loaded!(Turso)
    observer = spawn(fn -> collect([]) end)
    monitor = Process.monitor(observer)

    for {function, arity} <- @observed,
        do: :erlang.trace_pattern({Turso, function, arity}, true, [:local])

    :erlang.trace(self(), true, [:call, {:tracer, observer}])

    try do
      result = fun.()
      delivered = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _, ^delivered}, @timeout
      send(observer, {:finish, self()})
      assert_receive {:observed_calls, calls}, @timeout
      assert_receive {:DOWN, ^monitor, :process, ^observer, :normal}, @timeout
      {result, calls}
    after
      :erlang.trace(self(), false, [:call])

      for {function, arity} <- @observed,
          do: :erlang.trace_pattern({Turso, function, arity}, false, [:local])

      send(observer, :stop)
    end
  end

  defp collect(calls) do
    receive do
      {:trace, _, :call, {Turso, function, args}} -> collect([{function, args} | calls])
      {:finish, owner} -> send(owner, {:observed_calls, Enum.reverse(calls)})
      :stop -> :ok
    end
  end
end
