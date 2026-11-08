defmodule Synapsis.RoutineCadenceFunctionalTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.Config.Store
  alias Synapsis.RoutineSchedule

  @types [:agent, :routine]
  @due "2026-01-01T00:00:00Z"

  setup do
    directory = Path.join(System.tmp_dir!(), "synapsis-routine-cadence-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    previous = System.get_env("SYNAPSIS_CONFIG_DIR")

    snapshots =
      for type <- @types do
        table = :"synapsis_config_#{type}"
        server = {:via, Registry, {Synapsis.Config.Store.Registry, type}}
        {table, :ets.tab2list(table), server, :sys.get_state(server).load_error}
      end

    System.put_env("SYNAPSIS_CONFIG_DIR", directory)

    for type <- @types do
      File.write!(Store.file_path(type), "")
      assert :ok = Store.reload(type)
    end

    on_exit(fn ->
      if previous,
        do: System.put_env("SYNAPSIS_CONFIG_DIR", previous),
        else: System.delete_env("SYNAPSIS_CONFIG_DIR")

      for {table, entries, server, load_error} <- snapshots do
        :ets.delete_all_objects(table)
        :ets.insert(table, entries)
        :sys.replace_state(server, &%{&1 | load_error: load_error})
      end

      File.rm_rf!(directory)
    end)

    assert {:ok, _} = Store.put(:agent, %{id: Ecto.UUID.generate(), name: "main", enabled: true})
    :ok
  end

  test "cron normalization retains explicit zero and ordinary numeric stagger windows" do
    for {value, expected} <- [{0, 0}, {1, 1}, {1250.9, 1250}, {" 300000 ", 300_000}] do
      assert {:ok, schedule} =
               RoutineSchedule.normalize(%{
                 "kind" => "cron",
                 "expr" => "0 * * * *",
                 "staggerMs" => value
               })

      assert schedule["staggerMs"] == expected
    end
  end

  test "versioned creation materializes top-of-hour defaults while legacy schedules retain their cadence" do
    for expr <- ["0 * * * *", "0 */2 * * *", "0 9,* * * *"] do
      assert {:ok, saved} = Store.put(:routine, attrs(cron(expr)))
      assert saved["schedule"]["staggerMs"] == 300_000
      assert :ok = Store.reload(:routine)
      assert {:ok, ^saved} = Store.get(:routine, saved["id"])
    end

    for expr <- ["5 * * * *", "0 9 * * *"] do
      assert {:ok, saved} = Store.put(:routine, attrs(cron(expr)))
      refute Map.has_key?(saved["schedule"], "staggerMs")
    end

    for schedule <- ["0 * * * *", cron("0 * * * *")] do
      assert {:ok, saved} =
               Store.put(:routine, attrs(schedule) |> Map.delete("automation_contract_version"))

      assert saved["schedule"] == schedule
      assert :ok = Store.reload(:routine)
      assert {:ok, ^saved} = Store.get(:routine, saved["id"])
    end
  end

  test "same interval resave preserves a distinct anchor, already-due slot and schedule ownership" do
    assert {:ok, saved} =
             Store.put(
               :routine,
               attrs(%{"kind" => "every", "everyMs" => 15_000, "anchorMs" => 1_000}, %{
                 "createdAtMs" => 500
               })
             )

    assert {:ok, due} = Store.merge_existing(:routine, saved["id"], %{"next_run_at" => @due})

    assert {:ok, resaved} =
             Store.merge_existing(:routine, saved["id"], %{
               "schedule" => %{"kind" => "every", "everyMs" => 15_000}
             })

    assert resaved == due
    assert :ok = Store.reload(:routine)
    assert {:ok, ^resaved} = Store.get(:routine, saved["id"])
  end

  test "changed interval anchors to edit time and preserves latest unrelated fields" do
    assert {:ok, saved} =
             Store.put(
               :routine,
               attrs(%{"kind" => "every", "everyMs" => 15_000}, %{"createdAtMs" => 500})
             )

    assert {:ok, latest} =
             Store.merge_existing(:routine, saved["id"], %{
               "name" => "Latest name",
               "prompt" => "Latest authored prompt\n",
               "metadata" => %{"unknown" => "preserved"},
               "next_run_at" => @due
             })

    before_edit = System.system_time(:millisecond)

    assert {:ok, changed} =
             Store.merge_existing(:routine, saved["id"], %{
               "schedule" => %{"kind" => "every", "everyMs" => 25_000}
             })

    after_edit = System.system_time(:millisecond)
    assert changed["schedule"]["anchorMs"] in before_edit..after_edit
    assert changed["createdAtMs"] == 500
    assert changed["name"] == latest["name"]
    assert changed["prompt"] == latest["prompt"]
    assert changed["metadata"] == latest["metadata"]
    assert changed["schedule_generation"] != latest["schedule_generation"]
    refute Map.has_key?(changed, "next_run_at")
    assert :ok = Store.reload(:routine)
    assert {:ok, ^changed} = Store.get(:routine, saved["id"])
  end

  test "an explicit interval anchor wins and the legacy edit keeps the creation-time anchor" do
    assert {:ok, saved} = Store.put(:routine, attrs(%{"kind" => "every", "everyMs" => 15_000}))

    assert {:ok, changed} =
             Store.merge_existing(:routine, saved["id"], %{
               "schedule" => %{"kind" => "every", "everyMs" => 25_000, "anchorMs" => 42}
             })

    assert changed["schedule"]["anchorMs"] == 42
    assert changed["createdAtMs"] == saved["createdAtMs"]

    assert {:ok, legacy} =
             Store.put(
               :routine,
               attrs(%{"kind" => "every", "everyMs" => 15_000}, %{"createdAtMs" => 500})
               |> Map.delete("automation_contract_version")
             )

    assert {:ok, legacy_changed} =
             Store.merge_existing(:routine, legacy["id"], %{
               "schedule" => %{"kind" => "every", "everyMs" => 25_000}
             })

    assert legacy_changed["schedule"]["anchorMs"] == 500
  end

  test "cron resave retains explicit zero and latest timezone without consuming its due slot" do
    assert {:ok, saved} =
             Store.put(:routine, attrs(Map.merge(cron("0 * * * *"), %{"staggerMs" => 0})))

    assert {:ok, latest} =
             Store.merge_existing(:routine, saved["id"], %{
               "schedule" => Map.put(saved["schedule"], "tz", "Asia/Kathmandu"),
               "prompt" => "Latest cron prompt"
             })

    assert {:ok, due} = Store.merge_existing(:routine, latest["id"], %{"next_run_at" => @due})

    assert {:ok, resaved} =
             Store.merge_existing(:routine, latest["id"], %{"schedule" => cron("0 * * * *")})

    assert resaved == due
    assert :ok = Store.reload(:routine)
    assert {:ok, ^resaved} = Store.get(:routine, saved["id"])
  end

  test "cron replacement inherits timezone, derives a new default and allows explicit timezone clearing" do
    assert {:ok, saved} =
             Store.put(:routine, attrs(Map.put(cron("5 * * * *"), "tz", "Asia/Kathmandu")))

    assert {:ok, changed} =
             Store.merge_existing(:routine, saved["id"], %{"schedule" => cron("0 */2 * * *")})

    assert changed["schedule"] == %{
             "kind" => "cron",
             "expr" => "0 */2 * * *",
             "tz" => "Asia/Kathmandu",
             "staggerMs" => 300_000
           }

    assert changed["schedule_generation"] != saved["schedule_generation"]

    assert {:ok, cleared} =
             Store.merge_existing(:routine, saved["id"], %{
               "schedule" => Map.put(cron("0 */2 * * *"), "tz", nil)
             })

    refute Map.has_key?(cleared["schedule"], "tz")
    assert cleared["schedule"]["staggerMs"] == 300_000
    assert :ok = Store.reload(:routine)
    assert {:ok, ^cleared} = Store.get(:routine, saved["id"])
  end

  test "non-schedule edits preserve schedule generation and due occurrence across TOML reload" do
    assert {:ok, saved} =
             Store.put(:routine, attrs(Map.put(cron("0 * * * *"), "staggerMs", 1_250)))

    assert {:ok, due} = Store.merge_existing(:routine, saved["id"], %{"next_run_at" => @due})

    assert {:ok, renamed} =
             Store.merge_existing(:routine, saved["id"], %{
               "name" => "Renamed without consuming the occurrence",
               "prompt" => "New prompt"
             })

    assert Map.drop(renamed, ["name", "prompt"]) == Map.drop(due, ["name", "prompt"])
    assert :ok = Store.reload(:routine)
    assert {:ok, ^renamed} = Store.get(:routine, saved["id"])
  end

  test "a retained omitted cron stagger survives cached and cold reload without rewriting its identity" do
    assert {:ok, legacy} =
             Store.put(
               :routine,
               attrs(cron("0 * * * *")) |> Map.delete("automation_contract_version")
             )

    assert {:ok, upgraded} =
             Store.merge_existing(:routine, legacy["id"], %{
               "automation_contract_version" => 1,
               "schedule" => cron("0 * * * *"),
               "next_run_at" => @due
             })

    refute Map.has_key?(upgraded["schedule"], "staggerMs")
    assert upgraded["schedule_generation"] == legacy["schedule_generation"]
    encoded = File.read!(Store.file_path(:routine))
    assert :ok = Store.reload(:routine)
    assert {:ok, ^upgraded} = Store.get(:routine, legacy["id"])
    assert File.read!(Store.file_path(:routine)) == encoded

    :ets.delete(:synapsis_config_routine, legacy["id"])
    assert :ok = Store.reload(:routine)
    assert {:ok, ^upgraded} = Store.get(:routine, legacy["id"])
    assert File.read!(Store.file_path(:routine)) == encoded

    edited =
      String.replace(
        encoded,
        ~s("schedule"."expr" = "0 * * * *"),
        ~s("schedule"."expr" = "0 */2 * * *")
      )

    assert edited != encoded
    File.write!(Store.file_path(:routine), edited)
    :ets.delete(:synapsis_config_routine, legacy["id"])
    assert :ok = Store.reload(:routine)
    assert {:ok, changed} = Store.get(:routine, legacy["id"])
    assert changed["schedule"] == Map.put(cron("0 */2 * * *"), "staggerMs", 300_000)
    assert changed["schedule_generation"] != upgraded["schedule_generation"]
    refute Map.has_key?(changed, "next_run_at")
    normalized = File.read!(Store.file_path(:routine))
    assert :ok = Store.reload(:routine)
    assert {:ok, ^changed} = Store.get(:routine, legacy["id"])
    assert File.read!(Store.file_path(:routine)) == normalized
  end

  defp cron(expr), do: %{"kind" => "cron", "expr" => expr}

  defp attrs(schedule, extra \\ %{}) do
    Map.merge(
      %{
        "id" => Ecto.UUID.generate(),
        "name" => "Versioned automation cadence",
        "kind" => "schedule",
        "enabled" => true,
        "automation_contract_version" => 1,
        "schedule" => schedule,
        "prompt" => "Complete the scheduled work",
        "agent_name" => "main"
      },
      extra
    )
  end
end
