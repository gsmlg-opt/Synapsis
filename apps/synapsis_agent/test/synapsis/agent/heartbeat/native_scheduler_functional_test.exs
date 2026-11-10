defmodule Synapsis.Agent.Heartbeat.NativeSchedulerFunctionalTest do
  use Synapsis.Agent.DaemonCase, async: false
  @moduletag :functional

  alias Synapsis.Agent.Heartbeat.LocalScheduler
  alias Synapsis.Agent.TestSupport.DeterministicProvider, as: Provider
  alias Synapsis.Config.Store, as: ConfigStore
  alias Synapsis.Part.ToolResult
  alias Synapsis.Session.Store

  @moduletag :tmp_dir
  @dream_output Jason.encode!(%{
                  "recent_summary" => "Native dream complete",
                  "memory_candidates" => [],
                  "open_questions" => [],
                  "risks" => [],
                  "proposed_tasks" => [],
                  "ignored_noise" => []
                })

  for kind <- ["schedule", "dream"] do
    @kind kind
    test "stored native #{@kind} manual trigger completes and persists scheduler state", ctx do
      kind = @kind
      label = "manual-#{kind}"
      saved = native_fixture(ctx.tmp_dir, label, response(kind))
      config = stored_routine(saved, kind, "0 0 1 1 *")
      scheduler = scheduler()
      assert {:ok, queued} = LocalScheduler.trigger(scheduler, config["id"])
      completed = assert_native_run(queued, saved, ctx.tmp_dir, label)
      assert_scheduler_terminal(scheduler, config, completed)
      if kind == "dream", do: assert(completed.summary == @dream_output)
    end
  end

  @tag timeout: 90_000
  test "actual cron timers execute stored native schedule and dream through production dispatch",
       ctx do
    cases =
      for kind <- ["schedule", "dream"] do
        label = "timer-#{kind}"
        saved = native_fixture(ctx.tmp_dir, label, response(kind))
        {stored_routine(saved, kind, "* * * * *"), saved, label}
      end

    scheduler = scheduler()
    state = :sys.get_state(scheduler)

    for {config, _saved, _label} <- cases do
      timer = state.timers[{"routine", config["id"]}]
      assert is_reference(timer.ref)
      assert is_integer(Process.read_timer(timer.ref))
    end

    for {config, saved, label} <- cases do
      assert {:ok, run} =
               wait_for(
                 fn ->
                   case Enum.find(Runs.list_recent(limit: 100), &(&1.routine_id == config["id"])) do
                     nil -> :retry
                     run -> {:ok, run}
                   end
                 end,
                 65_000
               )

      completed = assert_native_run(run, saved, ctx.tmp_dir, label)
      assert_scheduler_terminal(scheduler, config, completed)

      assert :sys.get_state(scheduler).timers[{"routine", config["id"]}].token !=
               state.timers[{"routine", config["id"]}].token

      if config["kind"] == "dream", do: assert(completed.summary == @dream_output)
    end
  end

  defp response("dream"), do: @dream_output
  defp response("schedule"), do: "producer complete"

  defp stored_routine(saved, kind, schedule) do
    assert {:ok, config} =
             ConfigStore.put(:routine, %{
               "id" => Ecto.UUID.generate(),
               "name" => "native-#{kind}-#{Ecto.UUID.generate()}",
               "kind" => kind,
               "enabled" => true,
               "schedule" => schedule,
               "agent_name" => saved.name,
               "tool_profile" => "native_agent",
               "prompt" => "Perform the native effect",
               "max_runtime_ms" => 15_000
             })

    on_exit(fn ->
      ConfigStore.delete(:routine, config["id"])
      LocalScheduler.reload()
    end)

    assert {:ok, ^config} = ConfigStore.get(:routine, config["id"])
    config
  end

  defp scheduler do
    assert :ok = LocalScheduler.reload()
    LocalScheduler
  end

  defp assert_scheduler_terminal(scheduler, config, run) do
    assert run.kind == config["kind"]
    assert run.routine_id == config["id"]

    assert {:ok, persisted} =
             wait_for(fn ->
               case ConfigStore.get(:routine, config["id"]) do
                 {:ok, %{"last_status" => "completed", "last_run_at" => at} = config}
                 when is_binary(at) ->
                   {:ok, config}

                 _ ->
                   :retry
               end
             end)

    assert persisted["tool_profile"] == "native_agent"
    assert persisted["agent_name"] == run.assistant_name
    assert is_binary(persisted["next_run_at"])

    assert [%{last_status: "completed"}] =
             Enum.filter(LocalScheduler.status(scheduler), &(&1.id == config["id"]))

    assert {:ok, _} =
             wait_for_status(Daemon, fn status ->
               status.active_count == 0 and status.queued_count == 0
             end)
  end

  defp native_fixture(root, label, response) do
    fixture = Gaoxy.Test.open()
    provider = "native-producer-#{Ecto.UUID.generate()}"
    owner = self()

    assert :ok =
             Synapsis.Provider.Registry.register(provider, %{
               type: "openai",
               api_key: "test-key",
               base_url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
             })

    assert {:ok, saved} =
             Synapsis.AgentConfigs.create(%{
               name: provider,
               provider: provider,
               model: "producer-model",
               tools: ["exec_command"],
               tool_contract_version: 1,
               config: %{"workspace_path" => root}
             })

    Gaoxy.Test.stub(fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      following? = Enum.any?(request["messages"], &(&1["role"] == "tool"))
      send(owner, {:producer_request, label, following?, request})

      chunks =
        if following? do
          [Provider.text_chunk(response), Provider.finish_chunk("stop")]
        else
          [
            Provider.tool_call_chunk("exec_command", "producer-call", %{
              "cmd" => "printf effect >> #{label}.txt",
              "login" => false,
              "yield_time_ms" => 1000
            }),
            Provider.finish_chunk("tool_calls")
          ]
        end

      Provider.send_sse(conn, chunks)
    end)

    on_exit(fn ->
      for run <- Runs.list_recent(limit: 100),
          run.assistant_name == saved.name,
          is_binary(run.session_id),
          do: Synapsis.Sessions.delete(run.session_id)

      Synapsis.AgentConfigs.delete(saved)
      Synapsis.Provider.Registry.unregister(provider)
    end)

    saved
  end

  defp assert_native_run(run, saved, root, label) do
    assert run.tool_profile == "native_agent"
    assert run.assistant_name == saved.name
    assert run.capability_snapshot["agent_id"] == saved.id
    assert run.capability_snapshot["agent_name"] == saved.name
    assert run.capability_snapshot["tool_names"] == ["exec_command"]
    assert {:ok, completed} = wait_for_run(run.id, "completed")
    assert completed.capability_snapshot == run.capability_snapshot
    assert completed.finished_at
    assert_receive {:producer_request, ^label, false, first}, 5_000
    assert Enum.map(first["tools"], & &1["function"]["name"]) == ["exec_command"]
    assert_receive {:producer_request, ^label, true, following}, 5_000
    assert File.read!(Path.join(root, "#{label}.txt")) == "effect"

    assert [%ToolResult{is_error: false} = result] =
             for(
               message <- Synapsis.Sessions.get_messages(completed.session_id),
               %ToolResult{} = part <- message.parts,
               do: part
             )

    assert %{"role" => "tool", "tool_call_id" => result.tool_use_id, "content" => result.content} in following[
             "messages"
           ]

    assert {:ok, turns} = Store.list_turns(completed.session_id)

    assert Enum.any?(
             for(turn <- turns, part <- turn.parts, do: part),
             &(&1[:type] == "tool_result" and &1[:content] == result.content)
           )

    assert {:ok, durable} = Runs.fetch(completed.id)
    assert durable == completed
    completed
  end
end
