defmodule Synapsis.Session.SuggestedTurnFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.Runtime.SessionAdapter
  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  alias Synapsis.{Message, Models, Providers, Sessions, TaskSuggestions}

  @moduletag timeout: 90_000
  @suggest "synapsis::suggest_task"
  @prefix "Start by addressing this task in the current folder. If an isolated Git worktree is needed, explain why and ask the user before creating or switching to it.\n\n"
  @prompt "Document the follow-up API / 雪."

  test "native proposal acceptance uses captured selection and cwd, checkpointed consumption, and ordinary Worker replay" do
    owner = self()

    root =
      Path.join([
        System.tmp_dir!(),
        "synapsis-suggestion360-agent-#{System.get_env("MIX_TEST_PARTITION", "0")}",
        Ecto.UUID.generate()
      ])

    original_cwd = Path.join(root, "original")
    suggested_cwd = Path.join(root, "suggested")
    File.mkdir_p!(original_cwd)
    File.mkdir_p!(suggested_cwd)

    h =
      SessionHarness.setup_session!(
        tmp_dir: original_cwd,
        install_provider?: false,
        session_config: %{
          "subagents" => false,
          "memory_context" => false,
          "source_only_canary" => "do not inherit"
        }
      )

    {:ok, _} = Synapsis.AgentConfigs.update(h.agent_config, %{tools: [@suggest]})
    fixture = Gaoxy.Test.open()

    {:ok, provider} =
      Providers.create(%{
        name: "suggestion-selected-#{Ecto.UUID.generate()}",
        type: "openai",
        base_url: String.trim_trailing(Gaoxy.Test.url(fixture), "/"),
        api_key_encrypted: "fixture-key"
      })

    {:ok, model} =
      Models.create(%{
        provider_id: provider.id,
        model: "selected-follow-up-model",
        context_window: 32_768
      })

    on_exit(fn ->
      if Process.alive?(h.counter) do
        for {_request, handler} <- Agent.get(h.counter, & &1.provider_requests),
            do: send(handler, :complete_suggested_turn)
      end

      {:ok, sessions} = Sessions.list(h.agent_name)
      Enum.each(sessions, &Sessions.delete(&1.id))
      SessionHarness.cleanup!(h)
      Models.delete(model)
      Providers.delete(provider.id)
      File.rm_rf!(root)
    end)

    Gaoxy.Test.stub(fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      handler = self()

      index =
        Agent.get_and_update(h.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [{request, handler}]}}
        end)

      send(owner, {:suggested_request, index, request, handler})

      chunks =
        case index do
          0 ->
            [
              DeterministicProvider.tool_call_chunk(
                ToolName.encode(@suggest),
                "suggestion-follow-up",
                %{
                  "title" => "Document follow-up",
                  "tldr" => "Continue in the suggested folder",
                  "prompt" => @prompt,
                  "cwd" => suggested_cwd
                }
              ),
              DeterministicProvider.finish_chunk("tool_calls")
            ]

          1 ->
            [
              DeterministicProvider.text_chunk("Proposal recorded"),
              DeterministicProvider.finish_chunk("stop")
            ]

          2 ->
            receive do
              :complete_suggested_turn -> :ok
            after
              20_000 -> raise "ordinary native suggested completion was not released"
            end

            [
              DeterministicProvider.text_chunk("Follow-up complete"),
              DeterministicProvider.finish_chunk("stop")
            ]

          3 ->
            [
              DeterministicProvider.text_chunk("History recalled"),
              DeterministicProvider.finish_chunk("stop")
            ]
        end

      DeterministicProvider.send_sse(conn, chunks)
    end)

    await(fn -> Worker.get_status(h.session.id) == :waiting end)
    assert :ok = Sessions.switch_model(h.session.id, provider.name, model.model)
    SessionHarness.subscribe!(h.session.id)
    assert :ok = Worker.send_message(h.session.id, "Propose the next documentation task")
    assert_receive {:suggested_request, 0, _, _}, 10_000
    assert_receive {:suggested_request, 1, source_request, _}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    await_idle(h.session.id)
    tool_result = Enum.find(source_request["messages"], &(&1["role"] == "tool"))
    %{"task_id" => task_id} = Jason.decode!(tool_result["content"])
    assert {:ok, source_turns} = Store.list_turns(h.session.id)

    assert {:ok, %{status: "pending", suggestion: proposal}} =
             TaskSuggestions.get(task_id, %{session_id: h.session.id, agent_id: h.agent_name})

    assert proposal.cwd == suggested_cwd
    assert proposal.prompt == @prompt
    assert {:ok, before_sessions} = Sessions.list(h.agent_name)
    assert length(before_sessions) == 1

    observe_native_consumption()

    assert {:ok, %{status: "accepting", session_id: destination}} =
             TaskSuggestions.accept(task_id, %{
               session_id: h.session.id,
               requester_id: "synapsis:operator"
             })

    refute destination == h.session.id

    assert_receive {:trace, adapter_pid, :call,
                    {SessionAdapter, :handle_info,
                     [
                       {:agent_runtime, run_id, %{type: :prompt_consumed, mode: :new} = consumed},
                       _state
                     ]}},
                   15_000

    assert_receive {:suggested_request, 2, destination_request, handler}, 10_000
    receipt = receipt(task_id, h)
    assert receipt.run_id == run_id
    assert receipt.turn_id == consumed.turn_id
    assert receipt.message_id == consumed.message.id
    refute receipt.message_id == receipt.input_id
    assert receipt.session_id == destination
    assert receipt.source_session_id == h.session.id
    assert receipt.task_id == task_id

    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, destination)
    {_phase, data} = :sys.get_state(worker)
    assert data.runtime_pid == adapter_pid
    assert data.project_path == suggested_cwd
    assert data.agent.workspace_path == suggested_cwd
    adapter = :sys.get_state(adapter_pid)
    native = :sys.get_state(adapter.root)
    assert native.conversation.turn_id == receipt.turn_id
    assert Enum.count(native.conversation.messages, &(&1.id == receipt.message_id)) == 1
    assert {:ok, checkpoint} = Synapsis.Agent.Runtime.Store.load(adapter.store, receipt.run_id)
    assert checkpoint.run.context.conversation.turn_id == receipt.turn_id

    assert Enum.count(
             checkpoint.run.context.conversation.messages,
             &(&1.id == receipt.message_id)
           ) == 1

    descriptor = native.catalog.registry.tools[@suggest]
    assert descriptor.backend_context.cwd == suggested_cwd
    assert adapter.context.input_context["input_id"] == receipt.input_id
    assert adapter.context.input_context["source_session_id"] == destination

    assert {:ok, session} = Sessions.get(destination)
    assert session.provider == provider.name
    assert session.model == model.model
    assert session.config["provider_id"] == provider.id
    assert session.config["model_id"] == model.id
    refute Map.has_key?(session.config, "source_only_canary")

    assert session.config["creation_context"] == %{
             "version" => 1,
             "kind" => "task_suggestion",
             "task_id" => task_id,
             "source_session_id" => h.session.id,
             "cwd" => suggested_cwd
           }

    assert Synapsis.AgentConfigs.get(h.agent_config.id).provider == h.provider.name
    assert Synapsis.AgentConfigs.get(h.agent_config.id).model == "characterization-model"
    assert destination_request["model"] == model.model
    assert user_texts(destination_request) == [@prefix <> @prompt]
    assert {:ok, ^source_turns} = Store.list_turns(h.session.id)

    SessionHarness.subscribe!(destination)
    send(handler, :complete_suggested_turn)
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    await_idle(destination)
    assert {:ok, turns} = Store.list_turns(destination)
    assert Enum.map(turns, & &1.role) == ["user", "assistant"]
    assert hd(turns).id == receipt.input_id
    assert hd(turns).parts == [%{type: "text", text: @prefix <> @prompt}]

    assert [%Message{id: input_id, role: "user"}, %Message{role: "assistant"}] =
             Message.list_by_session(destination)

    assert input_id == receipt.input_id

    monitor = Process.monitor(worker)
    assert :ok = DynamicSupervisor.stop_session(destination)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5_000
    assert :ok = Sessions.ensure_running(destination)
    [{replacement, _}] = Registry.lookup(Synapsis.Session.Registry, destination)
    refute replacement == worker
    assert {:ok, ^turns} = Store.list_turns(destination)
    assert receipt(task_id, h) == receipt
    assert length(Agent.get(h.counter, & &1.provider_requests)) == 3
    assert :ok = Worker.send_message(destination, "Recall the completed follow-up")
    assert_receive {:suggested_request, 3, replay, _}, 10_000
    assert user_texts(replay) == [@prefix <> @prompt, "Recall the completed follow-up"]
    assert Enum.any?(replay["messages"], &(message_text(&1) == "Follow-up complete"))
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    await_idle(destination)
    {_phase, reopened} = :sys.get_state(replacement)
    assert reopened.project_path == suggested_cwd
    assert {:ok, ^source_turns} = Store.list_turns(h.session.id)
    assert {:ok, final_turns} = Store.list_turns(destination)
    assert Enum.count(final_turns, &(&1.id == receipt.input_id)) == 1
  end

  defp observe_native_consumption do
    Code.ensure_loaded!(SessionAdapter)
    owner = self()
    pattern = [{[{:agent_runtime, :_, %{type: :prompt_consumed, mode: :new}}, :_], [], [true]}]
    :erlang.trace_pattern({SessionAdapter, :handle_info, 2}, pattern, [:local])

    :erlang.trace(Process.whereis(DynamicSupervisor), true, [
      :call,
      :set_on_spawn,
      {:tracer, owner}
    ])

    on_exit(fn ->
      for pid <- Process.list(), :erlang.trace_info(pid, :tracer) == {:tracer, owner} do
        try do
          :erlang.trace(pid, false, [:call, :set_on_spawn])
        catch
          :error, :badarg -> :ok
        end
      end

      :erlang.trace_pattern({SessionAdapter, :handle_info, 2}, false, [:local])
    end)
  end

  defp receipt(id, h) do
    await(fn ->
      match?(
        {:ok, %{status: "accepted"}},
        TaskSuggestions.get(id, %{session_id: h.session.id, agent_id: h.agent_name})
      )
    end)

    {:ok, %{receipt: receipt}} =
      TaskSuggestions.get(id, %{session_id: h.session.id, agent_id: h.agent_name})

    receipt
  end

  defp await_idle(id),
    do: await(fn -> match?({:ok, %{runtime: %{active: false}}}, Worker.public_status(id)) end)

  defp user_texts(request),
    do: for(message <- request["messages"], message["role"] == "user", do: message_text(message))

  defp message_text(%{"content" => content}) when is_binary(content), do: content
  defp message_text(%{"content" => content}), do: Enum.map_join(content, &(&1["text"] || ""))
  defp await(check), do: await(check, System.monotonic_time(:millisecond) + 15_000)

  defp await(check, deadline) do
    unless check.() do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(10)
      await(check, deadline)
    end
  end
end
