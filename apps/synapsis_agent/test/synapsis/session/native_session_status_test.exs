defmodule Synapsis.Session.NativeSessionStatusTest do
  use ExUnit.Case, async: false
  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.SessionStatus
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{Store, Worker}
  @moduletag :tmp_dir
  @name "synapsis::session_status"

  setup %{tmp_dir: tmp_dir} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)
    assert {:ok, _} = Synapsis.AgentConfigs.update(harness.agent_config, %{tools: [@name]})
    SessionHarness.subscribe!(harness.session.id)
    %{harness: harness, id: harness.session.id}
  end

  test "Worker observes its own live active turn and an explicit durable target", ctx do
    target = Ecto.UUID.generate()
    :ok = Store.put_meta(target, %{id: target, title: "Archived target", status: "idle"})
    on_exit(fn -> Store.delete_session(target) end)
    run(ctx, [%{}, %{"source" => "durable", "session_id" => target}])
    [live, durable] = pages(ctx)
    assert live["source"] == "live"
    assert live["session"]["id"] == ctx.id
    assert live["runtime"] == %{"status" => "running", "phase" => "generating", "active" => true}

    assert Map.keys(live["session"]) |> Enum.sort() ==
             ~w(agent id inserted_at model provider title updated_at)

    assert durable["source"] == "durable"
    assert durable["session"]["id"] == target
    assert durable["session"]["title"] == "Archived target"
  end

  test "public API returns idle observation and expired deadline", ctx do
    SessionHarness.ensure_running!(ctx.id)
    assert {:ok, status} = Worker.public_status(ctx.id)
    assert status.source == "live"
    assert status.runtime == %{status: "waiting", phase: "idle", active: false}

    assert {:error, :timeout} =
             Worker.public_status(ctx.id, deadline: System.monotonic_time(:millisecond) - 1)
  end

  test "public observation retains owned data and renews inactivity, including history error",
       ctx do
    SessionHarness.ensure_running!(ctx.id)
    [{pid, _}] = Registry.lookup(Synapsis.Session.Registry, ctx.id)
    {:idle, data} = :sys.get_state(pid)
    data = %{data | runtime_history_error: :history_unavailable}
    deadline = System.monotonic_time(:millisecond) + 1_000
    from = {self(), make_ref()}

    assert {:keep_state_and_data, [reply, {:timeout, timeout, :inactivity}]} =
             Worker.handle_event({:call, from}, {:public_status, deadline}, :idle, data)

    assert timeout > 0
    assert {:reply, ^from, {:ok, result}} = reply
    assert result.runtime == %{status: "error", phase: "idle", active: false}
    assert result.session.id == ctx.id
  end

  test "a suspended real Worker has a finite status timeout without durable fallback", ctx do
    SessionHarness.ensure_running!(ctx.id)
    [{pid, _}] = Registry.lookup(Synapsis.Session.Registry, ctx.id)
    :ok = :sys.suspend(pid)

    try do
      started = System.monotonic_time(:millisecond)
      assert {:error, :timeout} = Worker.public_status(ctx.id, deadline: started + 30)
      assert System.monotonic_time(:millisecond) - started < 1_000

      context = %{
        session_id: ctx.id,
        agent_id: ctx.harness.agent_config.name,
        run_id: "status/timeout",
        incarnation: 1,
        catalog_revision: 1
      }

      operation =
        Map.merge(context, %{
          tool_name: @name,
          tool_revision: 1,
          arguments: %{},
          backend_context: context
        })

      assert {:error, error} = SessionStatus.execute(operation)
      assert error.details.code == "timeout"
    after
      :ok = :sys.resume(pid)
    end

    assert {:ok, %{source: "live"}} = Worker.public_status(ctx.id)
  end

  defp run(ctx, calls) do
    owner = self()

    Gaoxy.Test.stub(ctx.harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      Agent.update(
        ctx.harness.counter,
        &%{&1 | provider_requests: &1.provider_requests ++ [request]}
      )

      completed = Enum.count(request["messages"], &(&1["role"] == "tool"))
      if completed == 0, do: send(owner, {:status_catalog, request["tools"]})

      chunks =
        case Enum.at(calls, completed) do
          nil ->
            [
              DeterministicProvider.text_chunk("Status complete"),
              DeterministicProvider.finish_chunk("stop")
            ]

          args ->
            [
              DeterministicProvider.tool_call_chunk(
                ToolName.encode(@name),
                "status-#{completed}",
                args
              ),
              DeterministicProvider.finish_chunk("tool_calls")
            ]
        end

      DeterministicProvider.send_sse(conn, chunks)
    end)

    SessionHarness.ensure_running!(ctx.id)
    assert :ok = Worker.send_message(ctx.id, "Observe session status")
    assert_receive {:status_catalog, [descriptor]}, 5_000
    assert ToolName.decode(descriptor["function"]["name"]) == @name
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert SessionStatus.names() == [@name]
  end

  defp pages(ctx) do
    requests = Agent.get(ctx.harness.counter, & &1.provider_requests)

    calls =
      requests |> List.last() |> Map.fetch!("messages") |> Enum.count(&(&1["role"] == "tool"))

    turns =
      for index <- 0..(2 * calls + 1) do
        assert {:ok, turn} = Store.get_turn(ctx.id, index)
        turn
      end

    results = for turn <- turns, part <- turn.parts, part[:type] == "tool_result", do: part

    requests = Agent.get(ctx.harness.counter, & &1.provider_requests)

    for {result, index} <- Enum.with_index(results) do
      assert result.is_error == false
      page = result.projection["result"]["structured"]
      assert Jason.decode!(result.content) == page

      next_request = Enum.fetch!(requests, index + 1)

      message =
        Enum.find(next_request["messages"], fn message ->
          message["role"] == "tool" and message["tool_call_id"] == result.tool_use_id
        end)

      assert message
      assert message["content"] == result.content
      page
    end
  end
end
