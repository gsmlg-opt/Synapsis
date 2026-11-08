defmodule Synapsis.Runtime.StoreDeadlineFunctionalTest do
  use ExUnit.Case, async: false

  alias Concord.KV
  alias Concord.KV.Record
  alias Synapsis.Runtime.Store

  test "successful updates preserve the full aggregate and use its observed storage fence" do
    assert :ok = Synapsis.Session.Store.ensure_started()
    namespace = Ecto.UUID.generate()
    run_id = Ecto.UUID.generate()
    key = "coord/runtime/runs/#{segment(namespace)}/#{segment(run_id)}"

    fact_key =
      "coord/runtime/facts/#{segment(namespace)}/#{segment(:qualification)}/#{segment(run_id)}"

    projection_key = "coord/runtime/projections/#{segment(namespace)}"

    on_exit(fn ->
      for owned_key <- [key, fact_key, projection_key] do
        assert {:ok, _} = KV.delete(owned_key, engine: :turso, timeout: 5_000)
      end
    end)

    fact = %{run_id: run_id, event: :admitted, text: "原始事实"}
    projection = %{run_id: run_id, revision: 1, text: "投影保持"}
    assert :ok = Store.put_fact(namespace, :qualification, run_id, fact)
    assert :ok = Store.put_projection(namespace, projection)

    first = %{
      revision: 1,
      incarnation: 7,
      run: %{run_id: run_id, state: :running, history: [%{text: "开始 雪", bytes: <<0, 255>>}]},
      transition: %{event: :admitted},
      effects: [%{id: "effect-1", arguments: %{text: "原文\n"}}],
      outbox: [%{id: "intent-1", arguments: %{bytes: <<1, 0, 254>>}}]
    }

    assert :ok = Store.commit(namespace, run_id, 0, 7, first)
    assert {:ok, ^first} = Store.load(namespace, run_id)
    first_record = metadata(key)
    assert first_record.value == first
    assert first_record.version == 1
    assert first_record.mod_revision > first.revision
    fact_record = metadata(fact_key)
    projection_record = metadata(projection_key)

    second = %{
      first
      | revision: 2,
        incarnation: 8,
        run: %{
          first.run
          | history: first.run.history ++ [%{text: "继续 🌙", bytes: <<2, 0, 253>>}]
        },
        transition: %{event: :tool_invoked},
        effects: first.effects ++ [%{id: "effect-2", arguments: %{text: "完整效果"}}],
        outbox: first.outbox ++ [%{id: "intent-2", arguments: %{text: "完整待发"}}]
    }

    second_record = assert_update(namespace, run_id, key, first_record, second)

    third = %{
      second
      | revision: 3,
        incarnation: 9,
        run: %{
          second.run
          | state: :completed,
            history: second.run.history ++ [%{text: "完成\n保留全部", bytes: <<3, 0, 252>>}]
        },
        transition: %{event: :tool_completed},
        effects: second.effects ++ [%{id: "effect-3", arguments: %{bytes: <<0, 251>>}}],
        outbox: second.outbox ++ [%{id: "intent-3", arguments: %{text: "最后意图"}}]
    }

    assert_update(namespace, run_id, key, second_record, third)
    assert {:ok, ^third} = Store.load(namespace, run_id)
    assert {:ok, ^fact} = Store.get_fact(namespace, :qualification, run_id)
    assert {:ok, ^projection} = Store.get_projection(namespace)
    assert metadata(fact_key) == fact_record
    assert metadata(projection_key) == projection_record
  end

  defp assert_update(namespace, run_id, key, previous, aggregate) do
    {result, events} =
      observe(fn ->
        Store.commit(
          namespace,
          run_id,
          previous.value.revision,
          previous.value.incarnation,
          aggregate
        )
      end)

    assert result === :ok
    caller = self()

    assert [
             {:trace_ts, ^caller, :call, {KV, :get, [^key, get_opts]}, get_at},
             {:trace_ts, ^caller, :return_from, {KV, :get, 2}, {:ok, ^previous}, got_at},
             {:trace_ts, ^caller, :call,
              {Concord.Turso, :compare_and_swap, [^key, ^aggregate, cas_opts]}, cas_at},
             {:trace_ts, ^caller, :return_from, {Concord.Turso, :compare_and_swap, 3}, ack,
              ack_at}
           ] = events

    get_timeout = Keyword.fetch!(get_opts, :timeout)
    cas_timeout = Keyword.fetch!(cas_opts, :timeout)
    assert get_timeout in 1..5_000
    assert cas_timeout in 1..get_timeout
    assert Enum.sort(get_opts) == Enum.sort(engine: :turso, metadata: true, timeout: get_timeout)

    assert Enum.sort(cas_opts) ==
             Enum.sort(mod_revision: previous.mod_revision, timeout: cas_timeout)

    assert Enum.all?([get_at, got_at, cas_at, ack_at], &is_integer/1)
    assert get_at <= got_at and got_at <= cas_at and cas_at <= ack_at

    # Millisecond resolution can yield equal budgets. These ordinary observations
    # do not establish expiry behavior or a hard wall-clock/no-late-write bound.
    current = metadata(key)
    assert current.value === aggregate
    assert current.version == previous.version + 1
    assert current.create_revision == previous.create_revision
    assert current.mod_revision > previous.mod_revision

    assert ack ==
             {:ok,
              %{
                succeeded: true,
                revision: current.mod_revision,
                current_kv: %{current | value: nil}
              }}

    assert {:ok, ^aggregate} = Store.load(namespace, run_id)
    current
  end

  defp metadata(key) do
    assert {:ok, %Record{} = record} =
             KV.get(key, engine: :turso, metadata: true, timeout: 5_000)

    record
  end

  defp observe(fun) do
    Code.ensure_loaded!(KV)
    Code.ensure_loaded!(Concord.Turso)
    {observer, monitor} = spawn_monitor(fn -> collect([]) end)
    patterns = [{KV, :get, 2}, {Concord.Turso, :compare_and_swap, 3}]

    try do
      for pattern <- patterns do
        :erlang.trace_pattern(pattern, [{:_, [], [{:return_trace}]}], [:local])
      end

      :erlang.trace(self(), true, [:call, :monotonic_timestamp, {:tracer, observer}])
      result = fun.()
      :erlang.trace(self(), false, [:call, :monotonic_timestamp])
      delivered = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _, ^delivered}, 5_000
      reference = make_ref()
      send(observer, {:finish, self(), reference})
      assert_receive {:observed_events, ^reference, events}, 5_000
      {result, events}
    after
      :erlang.trace(self(), false, [:call, :monotonic_timestamp])
      for pattern <- patterns, do: :erlang.trace_pattern(pattern, false, [:local])
      send(observer, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^observer, :normal}, 5_000
    end
  end

  defp collect(events) do
    receive do
      {:trace_ts, _, _, _, _} = event ->
        collect([event | events])

      {:trace_ts, _, _, _, _, _} = event ->
        collect([event | events])

      {:finish, owner, reference} ->
        send(owner, {:observed_events, reference, Enum.reverse(events)})
        collect(events)

      :stop ->
        :ok
    end
  end

  defp segment(value), do: value |> to_string() |> Base.url_encode64(padding: false)
end
