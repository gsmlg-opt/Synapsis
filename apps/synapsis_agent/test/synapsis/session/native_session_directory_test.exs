defmodule Synapsis.Session.NativeSessionDirectoryTest do
  use ExUnit.Case, async: false
  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.SessionDirectory
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{Store, Worker}
  @moduletag :tmp_dir
  @name "synapsis::sessions_list"

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

  test "Worker lists durable sessions and continues rows in the next local provider request",
       ctx do
    marker = "directory-#{Ecto.UUID.generate()}"

    ids =
      for year <- [2024, 2025] do
        id = Ecto.UUID.generate()

        :ok =
          Store.put_meta(id, %{
            id: id,
            title: marker,
            agent: "archive",
            updated_at: "#{year}-01-01T00:00:00Z"
          })

        on_exit(fn -> Store.delete_session(id) end)
        {year, id}
      end

    run(ctx, [
      %{"search" => marker, "limit" => 1},
      %{"search" => marker, "limit" => 1, "offset" => 1}
    ])

    [first, last] = pages(ctx)
    assert first["source"] == "durable" and first["has_more"]
    assert first["next_offset"] == 1 and first["count"] == 1
    assert Enum.map(first["sessions"], & &1["id"]) == [Map.fetch!(Map.new(ids), 2025)]
    assert last["has_more"] == false
    refute Map.has_key?(last, "next_offset")
    assert Enum.map(last["sessions"], & &1["id"]) == [Map.fetch!(Map.new(ids), 2024)]
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
      if completed == 0, do: send(owner, {:directory_catalog, request["tools"]})

      chunks =
        case Enum.at(calls, completed) do
          nil ->
            [
              DeterministicProvider.text_chunk("Directory complete"),
              DeterministicProvider.finish_chunk("stop")
            ]

          args ->
            [
              DeterministicProvider.tool_call_chunk(
                ToolName.encode(@name),
                "directory-#{completed}",
                args
              ),
              DeterministicProvider.finish_chunk("tool_calls")
            ]
        end

      DeterministicProvider.send_sse(conn, chunks)
    end)

    SessionHarness.ensure_running!(ctx.id)
    assert :ok = Worker.send_message(ctx.id, "Read durable directory")
    assert_receive {:directory_catalog, [descriptor]}, 5_000
    assert ToolName.decode(descriptor["function"]["name"]) == @name
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert SessionDirectory.names() == [@name]
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
