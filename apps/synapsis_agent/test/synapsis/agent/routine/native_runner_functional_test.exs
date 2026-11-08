defmodule Synapsis.Agent.Routine.NativeRunnerFunctionalTest do
  use Synapsis.Agent.DaemonCase, async: false

  alias Synapsis.Agent.Routine.{Definition, Occurrence, Runner, State}
  alias Synapsis.Agent.TestSupport.DeterministicProvider, as: Provider
  alias Synapsis.Part.ToolResult
  alias Synapsis.Session.Store

  @moduletag :tmp_dir

  setup ctx do
    previous_root = System.get_env("SYNAPSIS_WORKSPACE_ROOT")
    System.put_env("SYNAPSIS_WORKSPACE_ROOT", ctx.tmp_dir)

    on_exit(fn ->
      if previous_root,
        do: System.put_env("SYNAPSIS_WORKSPACE_ROOT", previous_root),
        else: System.delete_env("SYNAPSIS_WORKSPACE_ROOT")
    end)

    :ok
  end

  test "stored native heartbeat occurrence completes once through the default Daemon", ctx do
    assert {:ok, _} = wait_for_ready()
    saved = native_fixture(ctx.tmp_dir, "runner")

    assert {:ok, config} =
             Synapsis.Heartbeats.create(%{
               name: "native-runner-#{Ecto.UUID.generate()}",
               agent_name: saved.name,
               enabled: true,
               prompt: "Perform the occurrence effect",
               tool_profile: "native_agent",
               keep_history: true,
               schedule: "0 0 1 1 *",
               max_runtime_ms: 15_000
             })

    on_exit(fn -> Synapsis.Heartbeats.delete(config) end)
    persisted = Synapsis.Heartbeats.get(config.id)
    assert {:ok, definition} = Definition.from_heartbeat(Map.from_struct(persisted))
    assert definition.tool_profile == "native_agent"
    occurrence = Occurrence.build(definition.id, DateTime.utc_now())
    assert {:ok, occurrence} = Occurrence.create_if_absent(occurrence)

    on_exit(fn ->
      Synapsis.DataCase.clear_coord("coord/routine_occurrences/#{definition.id}/")
      Synapsis.DataCase.clear_coord("coord/routines/#{definition.id}/")
    end)

    result = Runner.execute(definition, occurrence, await_ms: 15_000)
    terminal = Occurrence.get(definition.id, occurrence.occurrence_key)
    assert Runs.get(terminal.run_id).tool_profile == "native_agent"
    assert result == :ok
    assert terminal.status == "completed"
    assert terminal.outcome == "completed"
    assert terminal.finished_at
    run = assert_native_run(Runs.get(terminal.run_id), saved, ctx.tmp_dir, "runner")
    assert run.kind == "heartbeat"
    assert run.heartbeat_id == definition.id
    assert run.routine_id == definition.id
    assert run.idempotency_key == occurrence.occurrence_key
    assert run.metadata["occurrence_key"] == occurrence.occurrence_key
    assert State.get_or_new(definition.id).last_run_id == run.id

    assert {:ok, same} = Occurrence.create_if_absent(occurrence)
    assert same == terminal
    assert Occurrence.get(definition.id, occurrence.occurrence_key) == terminal
    assert [^run] = Enum.filter(Runs.list_recent(limit: 100), &(&1.routine_id == definition.id))
    assert File.read!(Path.join(ctx.tmp_dir, "runner.txt")) == "effect"
  end

  defp native_fixture(root, label, response \\ "producer complete") do
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
