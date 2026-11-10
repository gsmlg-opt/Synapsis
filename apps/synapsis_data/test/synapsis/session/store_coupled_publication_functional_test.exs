defmodule Synapsis.Session.StoreCoupledPublicationFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Concord.{KV, Turso}
  alias Concord.KV.Record
  alias Synapsis.Message
  alias Synapsis.Session.Store

  @timeout 5_000
  @observed [
    {:replace_prefix, 3},
    {:put, 2},
    {:put, 3},
    {:delete, 1},
    {:delete, 2},
    {:put_many, 1},
    {:put_many, 2},
    {:delete_many, 1},
    {:delete_many, 2},
    {:txn, 1},
    {:txn, 2}
  ]

  setup do
    assert :ok = Store.ensure_started()
    id = Ecto.UUID.generate()
    on_exit(fn -> assert :ok = Store.delete_session(id) end)
    %{id: id, prefix: Store.turns_prefix(id), meta_key: Store.meta_key(id)}
  end

  test "official Turso publishes five hundred turns plus metadata in one revision", ctx do
    %{id: id, prefix: prefix, meta_key: meta_key} = ctx

    old_turns = [
      {Store.turn_key(id, 0), %{text: "old head"}},
      {Store.turn_key(id, 701), %{text: "old sparse tail"}}
    ]

    old_meta = %{:title => "old", "opaque" => {:bytes, <<0, 255>>}, :turn_count => 2}
    seed(old_turns, meta_key, old_meta)
    unrelated_key = "sessions/" <> id <> "/opaque/value"
    assert {:ok, _} = put(unrelated_key, %{kept: {:opaque, <<128, 255>>}})
    original_turn = record(Store.turn_key(id, 0))
    original_meta = record(meta_key)
    original_unrelated = record(unrelated_key)
    before = revision()
    turns = for n <- 0..499, do: %{index: n, text: "native turn #{n} 雪"}
    expected = turn_pairs(id, turns)

    meta = %{
      :title => "native five hundred",
      "opaque" => {:bytes, <<0, 254>>},
      :turn_count => 500
    }

    assert {:ok, %{succeeded: true, revision: published, written: 501, deleted: 1}} =
             Turso.replace_prefix(prefix, expected ++ [{meta_key, meta}], timeout: @timeout)

    assert published == before + 1
    assert revision() == published
    assert rows(prefix, before) == old_turns
    assert rows(prefix, published) == expected
    assert record(meta_key, before) == original_meta
    assert record(Store.turn_key(id, 0), before) == original_turn
    assert_publication(id, turns, meta, published)
    assert_retained(record(meta_key), original_meta, published)
    assert_retained(record(Store.turn_key(id, 0)), original_turn, published)
    assert record(unrelated_key, before) == original_unrelated
    assert record(unrelated_key, published) == original_unrelated
  end

  test "coupled shrinking preserves complete historical rows and metadata lifecycle", ctx do
    %{id: id, prefix: prefix, meta_key: meta_key} = ctx
    old_turns = turn_pairs(id, [%{text: "old one"}, %{text: "old two"}, %{text: "old three"}])
    old_meta = %{title: "before", opaque: %{tuple: {:kept, <<0, 255>>}}, turn_count: 3}
    seed(old_turns, meta_key, old_meta)
    original_meta = record(meta_key)
    original_turn = record(Store.turn_key(id, 0))
    before = revision()
    turns = [%{text: "new one"}, %{text: "new two"}]
    meta = %{:title => "after", "raw" => [%{bytes: <<0, 255>>}], :turn_count => 2}
    puts = turn_pairs(id, turns) ++ [{meta_key, meta}]
    {result, calls} = observe(fn -> Store.replace_turns(id, turns, meta) end)

    assert result == :ok
    assert calls == [{:replace_prefix, [prefix, puts, [timeout: 5_000]]}]
    published = revision()
    assert published == before + 1
    assert rows(prefix, before) == old_turns
    assert record(meta_key, before) == original_meta
    assert_publication(id, turns, meta, published)
    assert_retained(record(meta_key), original_meta, published)
    assert_retained(record(Store.turn_key(id, 0)), original_turn, published)
  end

  test "empty coupled replacement clears sparse turns and publishes full opaque metadata", ctx do
    %{id: id, prefix: prefix, meta_key: meta_key} = ctx

    old_turns = [
      {Store.turn_key(id, 0), %{text: "head"}},
      {Store.turn_key(id, 99), %{text: "sparse"}}
    ]

    seed(old_turns, meta_key, %{title: "old empty candidate", turn_count: 2})
    original_meta = record(meta_key)
    before = revision()
    meta = %{"title" => "empty 雪", :turn_count => 0, :opaque => {:bytes, <<0, 255>>}}
    {result, calls} = observe(fn -> Store.replace_turns(id, [], meta) end)

    assert result == :ok
    assert calls == [{:replace_prefix, [prefix, [{meta_key, meta}], [timeout: 5_000]]}]
    published = revision()
    assert published == before + 1
    assert rows(prefix, before) == old_turns
    assert record(meta_key, before) == original_meta
    assert_publication(id, [], meta, published)
    assert_retained(record(meta_key), original_meta, published)
  end

  test "Store publishes all five hundred turns with related metadata", ctx do
    %{id: id, prefix: prefix, meta_key: meta_key} = ctx

    old_turns = [
      {Store.turn_key(id, 0), %{text: "old"}},
      {Store.turn_key(id, 900), %{text: "stale tail"}}
    ]

    seed(old_turns, meta_key, %{title: "before", turn_count: 2})
    original_meta = record(meta_key)
    before = revision()
    turns = for n <- 0..499, do: %{index: n, text: "wrapper turn #{n}"}
    meta = %{title: "wrapper five hundred", turn_count: 500, opaque: {:retained, <<255>>}}

    assert :ok = Store.replace_turns(id, turns, meta)
    published = revision()
    assert published == before + 1
    assert rows(prefix, before) == old_turns
    assert record(meta_key, before) == original_meta
    assert_publication(id, turns, meta, published)
    assert_retained(record(meta_key), original_meta, published)
  end

  test "coupled replacement admits an ordinary value above the generic transaction envelope",
       ctx do
    %{id: id, prefix: prefix, meta_key: meta_key} = ctx
    old_turns = [{Store.turn_key(id, 0), %{text: "small old value"}}]
    seed(old_turns, meta_key, %{title: "old"})
    original_meta = record(meta_key)
    before = revision()
    turn = %{text: String.duplicate("ordinary accepted value 雪 ", 50_000)}
    assert :erlang.external_size(turn) > 1_000_000
    meta = %{title: "large ordinary value", turn_count: 1}

    assert :ok = Store.replace_turns(id, [turn], meta)
    published = revision()
    assert published == before + 1
    assert rows(prefix, before) == old_turns
    assert record(meta_key, before) == original_meta
    assert_publication(id, [turn], meta, published)
  end

  test "Message coupled persistence retains typed encoding provenance and absent identities", %{
    id: id
  } do
    inserted_at = ~U[2026-11-06 01:02:03.000000Z]
    provenance = %{"source" => "automation", "nested" => %{"id" => "source-1"}}
    presentation = %{"phase" => "final", "forwarded" => true}
    projection = %{"type" => "table", "rows" => [["雪", 7]]}
    states = [%{"provider" => "ordinary", "state" => "kept"}]

    messages = [
      %Message{
        id: "explicit-message",
        session_id: id,
        role: "assistant",
        token_count: 17,
        inserted_at: inserted_at,
        input_provenance: provenance,
        internal_turn_source: "automation",
        reply_presentation: presentation,
        parts: [
          %Synapsis.Part.Text{content: "typed 雪"},
          %Synapsis.Part.Reasoning{content: "thought", signature: "sig", provider_states: states},
          %Synapsis.Part.ToolResult{
            tool_use_id: "tool-1",
            content: "result",
            is_error: false,
            projection: projection
          }
        ]
      },
      %Message{
        session_id: id,
        role: "user",
        token_count: nil,
        parts: [%Synapsis.Part.Text{content: "unstamped"}]
      }
    ]

    expected = [
      %{
        id: "explicit-message",
        role: "assistant",
        token_count: 17,
        inserted_at: inserted_at,
        input_provenance: provenance,
        internal_turn_source: "automation",
        reply_presentation: presentation,
        parts: [
          %{type: "text", text: "typed 雪"},
          %{type: "reasoning", content: "thought", signature: "sig", provider_states: states},
          %{
            type: "tool_result",
            tool_use_id: "tool-1",
            content: "result",
            is_error: false,
            projection: projection
          }
        ]
      },
      %{
        id: nil,
        role: "user",
        token_count: 0,
        inserted_at: nil,
        parts: [%{type: "text", text: "unstamped"}]
      }
    ]

    meta = %{title: "typed publication", opaque: {:kept, <<0, 255>>}}
    before = revision()

    assert :ok = Message.persist_list(id, messages, meta)
    published = revision()
    assert published == before + 1
    assert_publication(id, expected, meta, published)
    [first, second] = Message.list_by_session(id)
    assert first == hd(messages)
    assert second == %{List.last(messages) | token_count: 0}
  end

  defp seed(turns, meta_key, meta) do
    for {key, value} <- turns, do: assert({:ok, _} = put(key, value))
    assert {:ok, _} = put(meta_key, meta)
  end

  defp turn_pairs(id, turns) do
    turns |> Enum.with_index() |> Enum.map(fn {turn, n} -> {Store.turn_key(id, n), turn} end)
  end

  defp assert_publication(id, turns, meta, published) do
    assert rows(Store.turns_prefix(id), published) == turn_pairs(id, turns)
    assert {:ok, ^turns} = Store.list_turns(id)
    assert {:ok, ^meta} = Store.get_meta(id)
    assert %Record{value: ^meta, mod_revision: ^published} = record(Store.meta_key(id), published)

    for {key, value} <- turn_pairs(id, turns) do
      assert %Record{value: ^value, mod_revision: ^published} = record(key, published)
    end
  end

  defp assert_retained(current, original, published) do
    assert current.create_revision == original.create_revision
    assert current.version == original.version + 1
    assert current.mod_revision == published
  end

  defp put(key, value),
    do: KV.put(key, value, engine: :turso, compress: false, timeout: @timeout)

  defp revision do
    assert {:ok, revision} = Turso.revision(timeout: @timeout)
    revision
  end

  defp record(key, revision \\ nil) do
    opts = [engine: :turso, range: {key, key <> <<0>>}, limit: 1, timeout: @timeout]
    opts = if revision, do: Keyword.put(opts, :revision, revision), else: opts
    assert {:ok, [record], %{has_more: false}} = KV.list(opts)
    record
  end

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
