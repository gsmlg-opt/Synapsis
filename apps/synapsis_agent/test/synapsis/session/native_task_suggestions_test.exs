defmodule Synapsis.Session.NativeTaskSuggestionsTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{Store, Worker}
  alias Synapsis.TaskSuggestions

  @moduletag :tmp_dir
  @suggest "synapsis::suggest_task"
  @dismiss "synapsis::dismiss_task"

  setup %{tmp_dir: tmp_dir} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{tools: [@suggest, @dismiss]})

    SessionHarness.subscribe!(harness.session.id)
    %{harness: harness, id: harness.session.id}
  end

  test "selected Worker tools record then dismiss a suggestion on the same Conversation", ctx do
    owner = self()

    Gaoxy.Test.stub(ctx.harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, ctx.id)
      {_, data} = :sys.get_state(worker, 1_000)
      %{root: conversation} = :sys.get_state(data.runtime_pid, 1_000)
      send(owner, {:provider_conversation, conversation})

      Agent.update(
        ctx.harness.counter,
        &%{&1 | provider_requests: &1.provider_requests ++ [request]}
      )

      results = Enum.filter(request["messages"], &(&1["role"] == "tool"))

      chunks =
        case results do
          [] ->
            send(owner, {:suggestion_catalog, request["tools"]})

            tool_call(@suggest, "suggestion-create", %{
              "title" => "Improve docs",
              "prompt" => "Describe the public API in docs.",
              "tldr" => "Help readers use the API."
            })

          [created] ->
            result = Jason.decode!(created["content"])
            send(owner, {:provider_created, result})

            tool_call(@dismiss, "suggestion-dismiss", %{
              "task_id" => result["task_id"],
              "reason" => "Handled"
            })

          [created, dismissed] ->
            send(owner, {:provider_dismissed, Jason.decode!(dismissed["content"])})
            send(owner, {:provider_replayed_created, Jason.decode!(created["content"])})

            [
              DeterministicProvider.text_chunk("Suggestion complete"),
              DeterministicProvider.finish_chunk("stop")
            ]
        end

      DeterministicProvider.send_sse(conn, chunks)
    end)

    SessionHarness.ensure_running!(ctx.id)
    [{pid, _}] = Registry.lookup(Synapsis.Session.Registry, ctx.id)
    assert :ok = Worker.send_message(ctx.id, "Record a follow-up, then dismiss it")
    assert_receive {:suggestion_catalog, descriptors}, 5_000

    assert Enum.sort(Enum.map(descriptors, &ToolName.decode(&1["function"]["name"]))) ==
             Enum.sort([@suggest, @dismiss])

    assert_receive {:provider_created, %{"task_id" => id} = created}, 10_000

    assert_receive {:provider_dismissed, %{"task_id" => ^id, "dismissed" => true} = dismissed},
                   10_000

    assert_receive {:provider_replayed_created, ^created}, 5_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert_receive {:provider_conversation, conversation}, 5_000
    assert is_pid(conversation)
    assert_receive {:provider_conversation, ^conversation}, 5_000
    assert_receive {:provider_conversation, ^conversation}, 5_000
    assert [{^pid, _}] = Registry.lookup(Synapsis.Session.Registry, ctx.id)

    source = %{session_id: ctx.id, agent_id: ctx.harness.agent_config.name}
    assert {:ok, %{status: "dismissed", suggestion: suggestion}} = TaskSuggestions.get(id, source)
    assert suggestion.session_id == ctx.id
    assert suggestion.agent_id == ctx.harness.agent_config.name
    assert suggestion.cwd == ctx.harness.tmp_dir
    assert suggestion.prompt == "Describe the public API in docs."
    assert {:ok, []} = TaskSuggestions.list(source)

    turns =
      for index <- 0..5 do
        assert {:ok, turn} = Store.get_turn(ctx.id, index)
        turn
      end

    results = for turn <- turns, part <- turn.parts, part[:type] == "tool_result", do: part
    assert length(results) == 2
    requests = Agent.get(ctx.harness.counter, & &1.provider_requests)
    assert length(requests) == 3

    for {part, index} <- Enum.with_index(results) do
      assert part.is_error == false
      expected = Enum.at([created, dismissed], index)
      assert part.projection["result"]["structured"] == expected
      assert Jason.decode!(part.content) == expected
      next_request = Enum.fetch!(requests, index + 1)

      tool =
        Enum.find(
          next_request["messages"],
          &(&1["role"] == "tool" and &1["tool_call_id"] == part.tool_use_id)
        )

      assert tool["content"] == part.content
    end
  end

  defp tool_call(name, id, args) do
    [
      DeterministicProvider.tool_call_chunk(ToolName.encode(name), id, args),
      DeterministicProvider.finish_chunk("tool_calls")
    ]
  end
end
