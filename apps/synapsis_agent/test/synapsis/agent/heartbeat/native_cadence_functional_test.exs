defmodule Synapsis.Agent.Heartbeat.NativeCadenceFunctionalTest do
  use Synapsis.Agent.DaemonCase, async: false
  @moduletag :functional

  alias Synapsis.Agent.Routines
  alias Synapsis.Agent.Heartbeat.{CronSchedule, LocalScheduler}
  alias Synapsis.Agent.TestSupport.DeterministicProvider
  alias Synapsis.Config.Store, as: ConfigStore
  alias Synapsis.Part.ToolResult

  @moduletag :tmp_dir

  setup do
    assert {:ok, _} = wait_for_ready()
    :ok
  end

  test "versioned default reaches the sole scheduler and unchanged edits retain its timer", ctx do
    fixture = fixture(ctx.tmp_dir)
    schedule = %{"kind" => "cron", "expr" => "0 * * * *", "tz" => "Asia/Kathmandu"}
    config = put_routine(fixture, Ecto.UUID.generate(), schedule)
    assert config["schedule"]["staggerMs"] == 300_000
    assert :ok = LocalScheduler.reload()
    timer = timer(config)
    assert timer.timezone == "Asia/Kathmandu"

    <<word::unsigned-big-32, _::binary>> = :crypto.hash(:sha256, config["id"])
    offset = rem(word, 300_000)
    shifted = DateTime.add(DateTime.utc_now(), -offset, :millisecond)
    assert {:ok, base} = CronSchedule.next_after("0 * * * *", "Asia/Kathmandu", shifted)
    assert DateTime.compare(timer.next_run_at, DateTime.add(base, offset, :millisecond)) == :eq

    assert {:ok, renamed} =
             Routines.update({"routine", config["id"]}, %{"name" => "Renamed cadence"})

    assert renamed["schedule_generation"] == config["schedule_generation"]
    assert timer(config) == timer

    assert {:ok, saved} =
             Routines.update({"routine", config["id"]}, %{
               "schedule" => %{"kind" => "cron", "expr" => "0 * * * *"}
             })

    assert saved["schedule"] == config["schedule"]
    assert timer(config) == timer
    assert :ok = ConfigStore.reload(:routine)
    assert :ok = LocalScheduler.reload()
    assert timer(config) == timer

    assert {:ok, exact} =
             Routines.update({"routine", config["id"]}, %{
               "schedule" => %{"kind" => "cron", "expr" => "0 * * * *", "staggerMs" => 0}
             })

    assert exact["schedule"]["staggerMs"] == 0
    assert exact["schedule"]["tz"] == "Asia/Kathmandu"

    assert {:ok, exact_at} =
             CronSchedule.next_after("0 * * * *", "Asia/Kathmandu", DateTime.utc_now())

    assert DateTime.compare(timer(config).next_run_at, exact_at) == :eq
    assert timer(config).token != timer.token
    assert Agent.get(fixture.log, & &1) == []
  end

  test "a staggered timer runs a detached native Worker and advances the same shifted cadence",
       ctx do
    fixture = fixture(ctx.tmp_dir)
    id = "11111111-1111-4111-8111-111111111111"
    now_ms = System.system_time(:millisecond)
    target_ms = now_ms + 5_000
    minute_ms = div(now_ms, 60_000) * 60_000
    offset = target_ms - minute_ms
    <<word::unsigned-big-32, _::binary>> = :crypto.hash(:sha256, id)
    # Choose a valid window whose stable source hash places the next slot five seconds away.
    assert word > offset * 2
    window = word - offset

    schedule = %{
      "kind" => "cron",
      "expr" => "* * * * *",
      "tz" => "Etc/UTC",
      "staggerMs" => window
    }

    config = put_routine(fixture, id, schedule)
    assert config["schedule"] == schedule
    assert :ok = LocalScheduler.reload()
    target = DateTime.from_unix!(target_ms, :millisecond)
    assert DateTime.compare(timer(config).next_run_at, target) == :eq

    assert {:ok, run} =
             wait_for(
               fn ->
                 case Enum.find(Runs.list_recent(limit: 100), &(&1.routine_id == id)) do
                   nil -> :retry
                   run -> {:ok, run}
                 end
               end,
               10_000
             )

    assert {:ok, completed} = wait_for_run(run.id, "completed")
    assert DateTime.compare(completed.scheduled_for, target) == :eq
    assert DateTime.compare(completed.started_at, target) in [:eq, :gt]
    assert completed.capability_snapshot["agent_id"] == fixture.agent.id
    assert completed.capability_snapshot["tool_names"] == ["exec_command"]
    assert File.read!(Path.join(ctx.tmp_dir, "cadence-effect.txt")) == "effect"

    assert {:ok, persisted} =
             wait_for(fn ->
               case ConfigStore.get(:routine, id) do
                 {:ok, %{"last_status" => "completed", "next_run_at" => at} = saved}
                 when is_binary(at) ->
                   {:ok, saved}

                 _ ->
                   :retry
               end
             end)

    assert {:ok, next, _} = DateTime.from_iso8601(persisted["next_run_at"])
    assert DateTime.diff(next, target, :millisecond) == 60_000
    assert DateTime.compare(timer(config).next_run_at, next) == :eq
    assert persisted["schedule_generation"] == config["schedule_generation"]

    assert [%ToolResult{is_error: false} = result] =
             for(
               message <- Synapsis.Sessions.get_messages(completed.session_id),
               %ToolResult{} = part <- message.parts,
               do: part
             )

    requests = Agent.get(fixture.log, & &1)
    assert length(requests) == 2

    assert %{"role" => "tool", "tool_call_id" => result.tool_use_id, "content" => result.content} in List.last(
             requests
           )["messages"]

    assert {:ok, turns} = Synapsis.Session.Store.list_turns(completed.session_id)

    assert Enum.any?(
             for(turn <- turns, part <- turn.parts, do: part),
             &(&1[:type] == "tool_result" and &1[:content] == result.content)
           )

    assert {:ok, ^completed} = Runs.fetch(run.id)
    assert :ok = ConfigStore.reload(:routine)
    assert :ok = LocalScheduler.reload()
    assert DateTime.compare(timer(config).next_run_at, next) == :eq
    assert {:ok, _} = Routines.update({"routine", id}, %{"enabled" => false})
  end

  defp timer(config), do: :sys.get_state(LocalScheduler).timers[{"routine", config["id"]}]

  defp put_routine(fixture, id, schedule) do
    assert {:ok, config} =
             ConfigStore.put(:routine, %{
               "id" => id,
               "name" => "Versioned cadence",
               "kind" => "schedule",
               "enabled" => true,
               "automation_contract_version" => 1,
               "schedule" => schedule,
               "agent_name" => fixture.agent.name,
               "tool_profile" => "native_agent",
               "prompt" => "Perform the cadence effect",
               "no_overlap" => true,
               "max_runtime_ms" => 30_000
             })

    config
  end

  defp fixture(root) do
    http = Gaoxy.Test.open()
    provider = "cadence-#{Ecto.UUID.generate()}"
    log = start_supervised!({Agent, fn -> [] end})

    assert :ok =
             Synapsis.Provider.Registry.register(provider, %{
               type: "openai",
               api_key: "test-key",
               base_url: String.trim_trailing(Gaoxy.Test.url(http), "/")
             })

    assert {:ok, agent} =
             Synapsis.AgentConfigs.create(%{
               name: provider,
               provider: provider,
               model: "cadence-model",
               tools: ["exec_command"],
               tool_contract_version: 1,
               config: %{"workspace_path" => root}
             })

    Gaoxy.Test.stub(http, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      Agent.update(log, &(&1 ++ [request]))

      chunks =
        if Enum.any?(request["messages"], &(&1["role"] == "tool")) do
          [
            DeterministicProvider.text_chunk("Cadence complete"),
            DeterministicProvider.finish_chunk("stop")
          ]
        else
          [
            DeterministicProvider.tool_call_chunk("exec_command", "cadence-effect", %{
              "cmd" => "printf effect >> cadence-effect.txt",
              "login" => false,
              "yield_time_ms" => 1000
            }),
            DeterministicProvider.finish_chunk("tool_calls")
          ]
        end

      DeterministicProvider.send_sse(conn, chunks)
    end)

    on_exit(fn ->
      for config <- ConfigStore.list(:routine),
          config["agent_name"] == agent.name,
          do: ConfigStore.delete(:routine, config["id"])

      LocalScheduler.reload()

      for run <- Runs.list_recent(limit: 100),
          run.assistant_name == agent.name,
          is_binary(run.session_id),
          do: Synapsis.Sessions.delete(run.session_id)

      Synapsis.AgentConfigs.delete(agent)
      Synapsis.Provider.Registry.unregister(provider)
    end)

    %{agent: agent, log: log}
  end
end
