defmodule Synapsis.Agent.Heartbeat.NativeTimezoneFunctionalTest do
  use Synapsis.Agent.DaemonCase, async: false
  @moduletag :functional

  alias Synapsis.Agent.Routines
  alias Synapsis.Agent.Heartbeat.LocalScheduler
  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Config.Store, as: ConfigStore
  alias Synapsis.Part.ToolResult
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir

  test "same UUID schedules keep their zones and a timezone-only update replaces one timer",
       ctx do
    {saved, counter} = native_fixture(ctx.tmp_dir)
    id = Ecto.UUID.generate()
    stored_config(saved, :routine, id, "Asia/Shanghai", "0 0 1 1 *")
    stored_config(saved, :heartbeat, id, "America/New_York", "0 0 1 1 *")
    scheduler = start_scheduler()
    entries = entries(scheduler, id)

    assert entries["routine"].timezone == "Asia/Shanghai"
    assert entries["heartbeat"].timezone == "America/New_York"
    routine_next = next_local_new_year("Asia/Shanghai")
    heartbeat_next = next_local_new_year("America/New_York")
    assert DateTime.compare(entries["routine"].next_run_at, routine_next) == :eq
    assert DateTime.compare(entries["heartbeat"].next_run_at, heartbeat_next) == :eq
    assert DateTime.compare(routine_next, heartbeat_next) == :lt
    assert_utc_persistence(:routine, id, routine_next)
    assert_utc_persistence(:heartbeat, id, heartbeat_next)

    state = :sys.get_state(scheduler)
    original_timer = state.timers[{"routine", id}]
    heartbeat_timer = state.timers[{"heartbeat", id}]
    assert original_timer.timezone == "Asia/Shanghai"
    assert heartbeat_timer.timezone == "America/New_York"
    assert {:ok, original} = ConfigStore.get(:routine, id)
    assert {:ok, sibling} = ConfigStore.get(:heartbeat, id)

    assert {:ok, updated} =
             Routines.update({"routine", id}, %{"timezone" => "Asia/Kathmandu"},
               scheduler: scheduler
             )

    assert updated["timezone"] == "Asia/Kathmandu"

    assert Map.drop(updated, ["source", "timezone", "next_run_at"]) ==
             Map.drop(original, ["timezone", "next_run_at"])

    assert {:ok, ^sibling} = ConfigStore.get(:heartbeat, id)
    changed = :sys.get_state(scheduler)
    assert changed.timers[{"routine", id}].timezone == "Asia/Kathmandu"
    assert changed.timers[{"routine", id}].ref != original_timer.ref
    assert changed.timers[{"routine", id}].token != original_timer.token
    assert Process.read_timer(original_timer.ref) == false
    assert changed.timers[{"heartbeat", id}] == heartbeat_timer
    expected_next = next_local_new_year("Asia/Kathmandu")
    assert DateTime.compare(entries(scheduler, id)["routine"].next_run_at, expected_next) == :eq
    assert_utc_persistence(:routine, id, expected_next)

    old_scheduler = Process.whereis(scheduler)
    monitor = Process.monitor(old_scheduler)
    assert :ok = stop_supervised(LocalScheduler)
    assert_receive {:DOWN, ^monitor, :process, ^old_scheduler, _}, 5_000
    assert ^scheduler = start_scheduler(scheduler)
    assert Process.whereis(scheduler) != old_scheduler
    restarted = entries(scheduler, id)
    assert restarted["routine"].timezone == "Asia/Kathmandu"
    assert restarted["heartbeat"].timezone == "America/New_York"
    assert DateTime.compare(restarted["routine"].next_run_at, expected_next) == :eq
    assert DateTime.compare(restarted["heartbeat"].next_run_at, heartbeat_next) == :eq
    assert_utc_persistence(:routine, id, expected_next)
    assert_utc_persistence(:heartbeat, id, heartbeat_next)
    assert Agent.get(counter, & &1) == 0
    assert Enum.all?(Runs.list_recent(limit: 100), &(&1.assistant_name != saved.name))
  end

  @tag timeout: 150_000
  test "actual Kathmandu minute timer runs native execution and replays without repeating the effect",
       ctx do
    assert {:ok, _} = wait_for_ready()
    {saved, counter} = native_fixture(ctx.tmp_dir)
    now_seconds = System.system_time(:second)
    next_minute = (div(now_seconds, 60) + 1) * 60
    target_seconds = if next_minute - now_seconds < 10, do: next_minute + 60, else: next_minute
    target = DateTime.from_unix!(target_seconds)
    local_target = target |> DateTime.to_naive() |> NaiveDateTime.add(20_700, :second)

    schedule =
      "#{local_target.minute} #{local_target.hour} #{local_target.day} #{local_target.month} *"

    id = Ecto.UUID.generate()
    stored_config(saved, :heartbeat, id, "Asia/Kathmandu", schedule)
    assert :ok = LocalScheduler.reload()
    entry = entries(LocalScheduler, id)["heartbeat"]

    assert entry.timezone == "Asia/Kathmandu"

    assert DateTime.shift_zone!(target, "Asia/Kathmandu", Tzdata.TimeZoneDatabase)
           |> DateTime.to_naive() == local_target

    assert DateTime.compare(entry.next_run_at, target) == :eq
    initial_timer = :sys.get_state(LocalScheduler).timers[{"heartbeat", id}]
    assert initial_timer.timezone == "Asia/Kathmandu"
    assert is_reference(initial_timer.ref)
    assert is_integer(Process.read_timer(initial_timer.ref))
    assert_utc_persistence(:heartbeat, id, target)

    assert {:ok, run} =
             wait_for(
               fn ->
                 case Enum.find(Runs.list_recent(limit: 100), &(&1.routine_id == id)) do
                   nil -> :retry
                   run -> {:ok, run}
                 end
               end,
               90_000
             )

    completed = assert_native_run(run, saved, ctx.tmp_dir)
    assert completed.metadata["automation_ref"] == %{"source" => "heartbeat", "id" => id}

    assert {:ok, persisted} =
             wait_for(fn ->
               case ConfigStore.get(:heartbeat, id) do
                 {:ok, %{"last_status" => "completed", "last_run_at" => at} = config}
                 when is_binary(at) ->
                   {:ok, config}

                 _ ->
                   :retry
               end
             end)

    {:ok, last_run_at, 0} = DateTime.from_iso8601(persisted["last_run_at"])
    assert DateTime.compare(last_run_at, target) in [:eq, :gt]
    assert persisted["timezone"] == "Asia/Kathmandu"
    assert persisted["schedule"] == schedule
    {:ok, next_run_at, 0} = DateTime.from_iso8601(persisted["next_run_at"])
    assert next_run_at.time_zone == "Etc/UTC"
    assert DateTime.compare(next_run_at, target) == :gt
    timer = :sys.get_state(LocalScheduler).timers[{"heartbeat", id}]
    assert timer.token != initial_timer.token
    assert timer.timezone == "Asia/Kathmandu"
    assert DateTime.compare(timer.next_run_at, next_run_at) == :eq
    assert Agent.get(counter, & &1) == 2
    assert_worker_replay(completed, ctx.tmp_dir)
    assert Agent.get(counter, & &1) == 3
    assert {:ok, ^completed} = Runs.fetch(completed.id)
  end

  defp entries(scheduler, id) do
    LocalScheduler.status(scheduler)
    |> Enum.filter(&(&1.id == id))
    |> Map.new(&{&1.source, &1})
  end

  defp next_local_new_year(timezone) do
    local_now = DateTime.shift_zone!(DateTime.utc_now(), timezone, Tzdata.TimeZoneDatabase)
    naive = NaiveDateTime.new!(local_now.year + 1, 1, 1, 0, 0, 0)

    naive
    |> DateTime.from_naive!(timezone, Tzdata.TimeZoneDatabase)
    |> DateTime.shift_zone!("Etc/UTC", Tzdata.TimeZoneDatabase)
  end

  defp assert_utc_persistence(type, id, expected) do
    assert {:ok, config} =
             wait_for(fn ->
               case ConfigStore.get(type, id) do
                 {:ok, %{"next_run_at" => encoded} = config} ->
                   case DateTime.from_iso8601(encoded) do
                     {:ok, datetime, 0} ->
                       if DateTime.compare(datetime, expected) == :eq,
                         do: {:ok, config},
                         else: :retry

                     _ ->
                       :retry
                   end

                 _ ->
                   :retry
               end
             end)

    {:ok, utc, 0} = DateTime.from_iso8601(config["next_run_at"])
    assert utc.time_zone == "Etc/UTC"
    assert DateTime.compare(utc, expected) == :eq
    config
  end

  defp start_scheduler(name \\ nil) do
    name = name || String.to_atom("timezone_scheduler_#{System.unique_integer([:positive])}")
    start_supervised!({LocalScheduler, name: name, reload_interval_ms: 60_000})
    assert :ok = LocalScheduler.reload(name)
    name
  end

  defp stored_config(saved, type, id, timezone, schedule) do
    assert {:ok, config} =
             ConfigStore.put(type, %{
               "id" => id,
               "name" => "timezone-#{type}-#{id}",
               "kind" => "heartbeat",
               "enabled" => true,
               "schedule" => schedule,
               "timezone" => timezone,
               "agent_name" => saved.name,
               "tool_profile" => "native_agent",
               "prompt" => "Perform the timezone effect",
               "custom_marker" => "preserve",
               "no_overlap" => true,
               "max_runtime_ms" => 30_000
             })

    on_exit(fn ->
      ConfigStore.delete(type, id)
      LocalScheduler.reload()
    end)

    config
  end

  defp native_fixture(root) do
    fixture = Gaoxy.Test.open()
    provider = "timezone-producer-#{Ecto.UUID.generate()}"
    owner = self()
    counter = start_supervised!({Agent, fn -> 0 end})

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
               model: "timezone-model",
               tools: ["exec_command"],
               tool_contract_version: 1,
               config: %{"workspace_path" => root}
             })

    Gaoxy.Test.stub(fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      following? = Enum.any?(request["messages"], &(&1["role"] == "tool"))
      Agent.update(counter, &(&1 + 1))
      send(owner, {:timezone_request, following?, request})

      chunks =
        if following? do
          [
            DeterministicProvider.text_chunk("Timezone complete"),
            DeterministicProvider.finish_chunk("stop")
          ]
        else
          [
            DeterministicProvider.tool_call_chunk("exec_command", "timezone-effect", %{
              "cmd" => "printf effect >> timezone-effect.txt",
              "login" => false,
              "yield_time_ms" => 1000
            }),
            DeterministicProvider.finish_chunk("tool_calls")
          ]
        end

      DeterministicProvider.send_sse(conn, chunks)
    end)

    on_exit(fn ->
      for run <- Runs.list_recent(limit: 100),
          run.assistant_name == saved.name,
          is_binary(run.session_id),
          do: Synapsis.Sessions.delete(run.session_id)

      Synapsis.AgentConfigs.delete(saved)
      Synapsis.Provider.Registry.unregister(provider)
    end)

    {saved, counter}
  end

  defp assert_native_run(run, saved, root) do
    assert run.tool_profile == "native_agent"
    assert run.assistant_name == saved.name
    assert run.capability_snapshot["agent_id"] == saved.id
    assert run.capability_snapshot["tool_names"] == ["exec_command"]
    assert {:ok, completed} = wait_for_run(run.id, "completed")
    assert_receive {:timezone_request, false, first}, 5_000
    assert Enum.map(first["tools"], & &1["function"]["name"]) == ["exec_command"]
    assert_receive {:timezone_request, true, following}, 5_000
    assert File.read!(Path.join(root, "timezone-effect.txt")) == "effect"

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

    assert {:ok, ^completed} = Runs.fetch(completed.id)
    completed
  end

  defp assert_worker_replay(run, root) do
    session_id = run.session_id
    SessionHarness.subscribe!(session_id)
    SessionHarness.ensure_running!(session_id)
    [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, session_id)

    parts =
      for message <- Synapsis.Sessions.get_messages(session_id),
          %ToolResult{} = part <- message.parts,
          do: part

    monitor = Process.monitor(old_worker)
    assert :ok = DynamicSupervisor.stop_session(session_id)
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, _}, 5_000
    SessionHarness.ensure_running!(session_id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, session_id)
    assert new_worker != old_worker
    assert :ok = Worker.send_message(session_id, "Recall the timezone completion")
    assert_receive {:timezone_request, true, replay}, 5_000

    for part <- parts do
      assert %{"role" => "tool", "tool_call_id" => part.tool_use_id, "content" => part.content} in replay[
               "messages"
             ]
    end

    assert_receive {:run_event, %{type: "session.completed"}}, 10_000

    assert for(
             message <- Synapsis.Sessions.get_messages(session_id),
             %ToolResult{} = part <- message.parts,
             do: part
           ) == parts

    assert File.read!(Path.join(root, "timezone-effect.txt")) == "effect"
    assert :ok = DynamicSupervisor.stop_session(session_id)
  end
end
