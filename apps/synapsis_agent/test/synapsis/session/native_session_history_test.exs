defmodule Synapsis.Session.NativeSessionHistoryTest do
  use ExUnit.Case, async: false
  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.SessionHistory
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{Store, Worker}
  @moduletag :tmp_dir
  @name "synapsis::sessions_history"

  setup do
    previous = Application.fetch_env(:synapsis_agent, :filesystem_node)
    node = System.get_env("SYNAPSIS_FILESYSTEM_NODE") || System.find_executable("node")
    Application.put_env(:synapsis_agent, :filesystem_node, node)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:synapsis_agent, :filesystem_node, value)
        :error -> Application.delete_env(:synapsis_agent, :filesystem_node)
      end
    end)

    :ok
  end

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

  test "Worker returns current durable history and persists public content and projection", ctx do
    run(ctx, [%{}])
    [page] = pages(ctx)
    assert page["session_id"] == ctx.id

    assert [
             %{
               "role" => "user",
               "content" => [%{"type" => "text", "text" => "Read durable history"}]
             }
           ] = page["messages"]
  end

  test "Worker observes a persisted target through sparse page continuations", ctx do
    target = Ecto.UUID.generate()
    on_exit(fn -> Store.delete_session(target) end)

    for {index, text} <- [{0, "First"}, {7, "Second"}] do
      :ok =
        Store.commit_turn(
          target,
          index,
          %{role: "assistant", parts: [%{type: "text", text: text}]},
          %{id: target, agent: "archive"}
        )
    end

    run(ctx, [
      %{"session_id" => target, "limit" => 1, "offset" => 0},
      %{"session_id" => target, "limit" => 1, "offset" => 1}
    ])

    [first, last] = pages(ctx)
    assert first["hasMore"] and first["nextOffset"] == 1
    assert first["offset"] == 0 and first["totalMessages"] == 2

    assert first["messages"] == [
             %{
               "role" => "assistant",
               "content" => [%{"type" => "text", "text" => "Second"}],
               "__openclaw" => %{"seq" => 2}
             }
           ]

    assert last["hasMore"] == false
    refute Map.has_key?(last, "nextOffset")
    assert last["offset"] == 1 and last["totalMessages"] == 2

    assert last["messages"] == [
             %{
               "role" => "assistant",
               "content" => [%{"type" => "text", "text" => "First"}],
               "__openclaw" => %{"seq" => 1}
             }
           ]
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
      if completed == 0, do: send(owner, {:history_catalog, request["tools"]})

      chunks =
        case Enum.at(calls, completed) do
          nil ->
            [
              DeterministicProvider.text_chunk("History complete"),
              DeterministicProvider.finish_chunk("stop")
            ]

          args ->
            [
              DeterministicProvider.tool_call_chunk(
                ToolName.encode(@name),
                "history-#{completed}",
                args
              ),
              DeterministicProvider.finish_chunk("tool_calls")
            ]
        end

      DeterministicProvider.send_sse(conn, chunks)
    end)

    SessionHarness.ensure_running!(ctx.id)
    assert :ok = Worker.send_message(ctx.id, "Read durable history")
    assert_receive {:history_catalog, [descriptor]}, 5_000
    assert ToolName.decode(descriptor["function"]["name"]) == @name
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert SessionHistory.names() == [@name]
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

    for result <- results do
      assert result.is_error == false
      page = result.projection["result"]["structured"]
      assert Jason.decode!(result.content) == page

      replay =
        for request <- requests,
            message <- request["messages"],
            message["role"] == "tool" and message["tool_call_id"] == result.tool_use_id,
            do: message["content"]

      assert replay != [] and Enum.all?(replay, &(&1 == result.content))
      page
    end
  end
end
