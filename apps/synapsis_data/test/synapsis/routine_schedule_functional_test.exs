defmodule Synapsis.RoutineScheduleFunctionalTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.Config.Store
  alias Synapsis.RoutineConfigs

  @types [:agent, :routine, :heartbeat]

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "synapsis-typed-schedule-data-#{Ecto.UUID.generate()}")
    File.mkdir_p!(tmp_dir)
    previous = System.get_env("SYNAPSIS_CONFIG_DIR")

    snapshots =
      for type <- @types do
        table = :"synapsis_config_#{type}"
        server = {:via, Registry, {Synapsis.Config.Store.Registry, type}}
        {table, :ets.tab2list(table), server, :sys.get_state(server).load_error}
      end

    System.put_env("SYNAPSIS_CONFIG_DIR", tmp_dir)

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

      File.rm_rf!(tmp_dir)
    end)

    assert {:ok, _} = Store.put(:agent, %{id: Ecto.UUID.generate(), name: "main", enabled: true})
    :ok
  end

  test "legacy cron and typed cron at every persist as ordinary routines including heartbeat kind" do
    schedules = [
      "*/5 * * * *",
      %{"kind" => "cron", "expr" => "0 9 * * *", "tz" => "Asia/Kathmandu"},
      %{"kind" => "at", "at" => "2027-01-01T05:45:00+05:45"},
      %{"kind" => "every", "everyMs" => 1_500, "anchorMs" => 1_793_095_200_000}
    ]

    for schedule <- schedules, kind <- ["schedule", "heartbeat"] do
      attrs = attrs(schedule, %{"kind" => kind})
      assert {:ok, saved} = Store.put(:routine, attrs)

      expected =
        if is_map(schedule) and schedule["kind"] == "at",
          do: %{"kind" => "at", "at" => "2027-01-01T00:00:00Z"},
          else: schedule

      assert saved["schedule"] == expected
      assert saved["kind"] == kind

      if is_map(expected) do
        assert is_integer(saved["createdAtMs"])
      else
        refute Map.has_key?(saved, "createdAtMs")
        refute Map.has_key?(saved, "schedule_generation")
        refute Map.has_key?(saved, "schedule_fingerprint")
      end

      assert {:ok, ^saved} = Store.get(:routine, attrs["id"])
    end
  end

  test "creation anchors an interval once and an ordinary schedule patch uses the creation time" do
    before = System.system_time(:millisecond)
    assert {:ok, created} = Store.put(:routine, attrs(%{"kind" => "every", "everyMs" => 1_500}))
    after_create = System.system_time(:millisecond)
    created_at = created["createdAtMs"]
    assert created_at in before..after_create

    assert created["schedule"] == %{
             "kind" => "every",
             "everyMs" => 1_500,
             "anchorMs" => created_at
           }

    assert {:ok, renamed} = Store.merge_existing(:routine, created["id"], %{"name" => "Renamed"})
    assert renamed["createdAtMs"] == created_at
    assert renamed["schedule"] == created["schedule"]

    assert {:ok, patched} =
             Store.merge_existing(:routine, created["id"], %{
               "schedule" => %{"kind" => "every", "everyMs" => 2_500}
             })

    assert patched["createdAtMs"] == created_at

    assert patched["schedule"] == %{
             "kind" => "every",
             "everyMs" => 2_500,
             "anchorMs" => created_at
           }

    assert :ok = Store.reload(:routine)
    assert {:ok, ^patched} = Store.get(:routine, created["id"])
  end

  test "real TOML reload preserves normalized maps and the eight-field directory keeps source identity" do
    id = Ecto.UUID.generate()
    schedule = %{"kind" => "every", "everyMs" => 2_500}

    assert {:ok, saved} =
             Store.put(
               :routine,
               attrs(schedule, %{
                 "id" => id,
                 "kind" => "heartbeat",
                 "metadata" => %{"owner" => "main"},
                 "config" => %{"note" => "routine detail"}
               })
             )

    assert {:ok, _} =
             Store.put(:heartbeat, attrs("0 9 * * *", %{"id" => id, "kind" => "heartbeat"}))

    encoded = File.read!(Store.file_path(:routine))
    assert encoded =~ "everyMs"
    assert encoded =~ "anchorMs"
    assert :ok = Store.reload(:routine)
    assert :ok = Store.reload(:heartbeat)
    assert {:ok, ^saved} = Store.get(:routine, id)
    assert {:ok, %{routines: entries, count: 2}} = RoutineConfigs.directory("main")

    assert Enum.sort(Enum.map(entries, &{&1.source, &1.id})) == [
             {"heartbeat", id},
             {"routine", id}
           ]

    for entry <- entries do
      assert Enum.sort(Map.keys(entry)) ==
               [:agent_name, :enabled, :id, :kind, :name, :schedule, :source, :timezone]

      assert {:ok, %{routine: ^entry}} = RoutineConfigs.get_visible("main", entry.source, id)
    end

    typed = Enum.find(entries, &(&1.source == "routine"))
    assert typed.schedule == saved["schedule"]
    assert Enum.sort(Map.keys(typed.schedule)) == ["anchorMs", "everyMs", "kind"]
    assert typed.kind == "heartbeat"
    assert typed.timezone == "Etc/UTC"
    assert typed.agent_name == "main"
  end

  test "file cadence edits replace ownership and stale slots with or without a cached row" do
    for cached? <- [true, false] do
      assert {:ok, saved} =
               Store.put(:routine, attrs(%{"kind" => "every", "everyMs" => 1_500}))

      assert {:ok, scheduled} =
               Store.merge_existing(:routine, saved["id"], %{
                 "next_run_at" => "2027-01-01T00:00:00Z"
               })

      path = Store.file_path(:routine)
      before = File.read!(path)

      after_edit =
        String.replace(before, ~s("schedule"."everyMs" = 1500), ~s("schedule"."everyMs" = 2500))

      assert after_edit != before
      File.write!(path, after_edit)
      unless cached?, do: :ets.delete(:synapsis_config_routine, saved["id"])
      assert :ok = Store.reload(:routine)
      assert {:ok, changed} = Store.get(:routine, saved["id"])
      assert changed["schedule"]["everyMs"] == 2_500
      assert changed["schedule"]["anchorMs"] == saved["createdAtMs"]
      assert changed["createdAtMs"] == saved["createdAtMs"]
      assert changed["schedule_generation"] != scheduled["schedule_generation"]
      refute Map.has_key?(changed, "next_run_at")
      assert :ok = Store.reload(:routine)
      assert {:ok, ^changed} = Store.get(:routine, saved["id"])
      assert :ok = Store.delete(:routine, saved["id"])
    end
  end

  defp attrs(schedule, extra \\ %{}) do
    Map.merge(
      %{
        "id" => Ecto.UUID.generate(),
        "name" => "Typed schedule",
        "kind" => "schedule",
        "enabled" => true,
        "schedule" => schedule,
        "prompt" => "Complete the scheduled work",
        "agent_name" => "main"
      },
      extra
    )
  end
end
