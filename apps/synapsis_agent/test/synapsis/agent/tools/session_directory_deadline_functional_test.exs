defmodule Synapsis.Agent.Tools.SessionDirectoryDeadlineFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.Tools.SessionDirectory
  alias Synapsis.Session.Store
  alias Synapsis.SessionDirectory, as: Domain

  setup do
    assert :ok = Store.ensure_started()
    id = Ecto.UUID.generate()
    assert :ok = Store.put_meta(id, %{id: id, title: "Deadline directory", agent: "archive"})
    on_exit(fn -> Store.delete_session(id) end)

    context = %{
      session_id: id,
      agent_id: "main",
      run_id: "directory/deadline",
      incarnation: 1,
      catalog_revision: 1
    }

    assert {:ok, [descriptor]} = SessionDirectory.descriptors(context)
    input = %{"search" => id}

    operation =
      Map.merge(context, %{
        tool_name: descriptor.tool_name,
        tool_revision: 3,
        arguments: input,
        backend_context: context
      })

    %{id: id, context: context, input: input, operation: operation}
  end

  test "a short live native deadline is read once and passed unchanged to the durable directory",
       ctx do
    native_deadline = System.monotonic_time(:millisecond) + 3_000
    {result, calls, _started} = execute_observed(ctx.operation, native_deadline)

    assert [
             {:getter_read, _read_at},
             {:list_rendered, [input, trusted, [deadline: ^native_deadline]]}
           ] = calls

    assert input == ctx.input
    assert trusted == Map.take(ctx.context, [:session_id, :agent_id])
    assert_page(result, ctx.id)
  end

  test "a long live native deadline is read once and clipped to the local five-second ceiling",
       ctx do
    native_deadline = System.monotonic_time(:millisecond) + 20_000
    {result, calls, started} = execute_observed(ctx.operation, native_deadline)

    assert [
             {:getter_read, read_at},
             {:list_rendered, [input, trusted, [deadline: chosen_deadline]]}
           ] = calls

    assert input == ctx.input
    assert trusted == Map.take(ctx.context, [:session_id, :agent_id])
    assert chosen_deadline >= started + 5_000
    assert chosen_deadline <= read_at + 5_000
    assert chosen_deadline < native_deadline
    assert_page(result, ctx.id)
  end

  defp assert_page(result, id) do
    expected = %{
      source: "durable",
      count: 1,
      sessions: [
        %{
          id: id,
          title: "Deadline directory",
          agent: "archive",
          provider: nil,
          model: nil,
          status: nil,
          inserted_at: nil,
          updated_at: nil
        }
      ],
      has_more: false,
      limit_applied: 100
    }

    assert result ==
             {:ok, %{content: Jason.encode!(expected, pretty: true), structured: expected}}
  end

  defp execute_observed(operation, native_deadline) do
    Code.ensure_loaded!(Domain)
    observer = spawn(fn -> collect([]) end)
    monitor = Process.monitor(observer)
    :erlang.trace_pattern({Domain, :list_rendered, 2}, true, [:local])
    :erlang.trace_pattern({Domain, :list_rendered, 3}, true, [:local])
    :erlang.trace(self(), true, [:call, {:tracer, observer}])

    getter = fn ->
      now = System.monotonic_time(:millisecond)
      send(observer, {:getter_read, now})

      {:ok,
       %{
         selected_timeout_ms: 20_000,
         deadline_ms: native_deadline,
         remaining_ms: native_deadline - now,
         paused: false
       }}
    end

    enriched = Map.put(operation.backend_context, :effect_deadline, getter)

    try do
      started = System.monotonic_time(:millisecond)
      result = SessionDirectory.execute(%{operation | backend_context: enriched})
      delivered = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _, ^delivered}, 5_000
      send(observer, {:finish, self()})
      assert_receive {:observed_calls, calls}, 5_000
      assert_receive {:DOWN, ^monitor, :process, ^observer, :normal}, 5_000
      {result, calls, started}
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({Domain, :list_rendered, 2}, false, [:local])
      :erlang.trace_pattern({Domain, :list_rendered, 3}, false, [:local])
      send(observer, :stop)

      if Process.alive?(observer) do
        assert_receive {:DOWN, ^monitor, :process, ^observer, :normal}, 5_000
      end

      Process.demonitor(monitor, [:flush])
    end
  end

  defp collect(calls) do
    receive do
      {:getter_read, _} = call -> collect([call | calls])
      {:trace, _, :call, {Domain, function, args}} -> collect([{function, args} | calls])
      {:finish, owner} -> send(owner, {:observed_calls, Enum.reverse(calls)})
      :stop -> :ok
    end
  end
end
