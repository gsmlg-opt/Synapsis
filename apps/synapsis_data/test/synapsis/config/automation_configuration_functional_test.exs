defmodule Synapsis.Config.AutomationConfigurationFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Config.Store
  alias Synapsis.Config.Store.Server

  @table :synapsis_config_routine
  @server {:via, Registry, {Synapsis.Config.Store.Registry, :routine}}

  setup do
    directory = Path.join(System.tmp_dir!(), "synapsis-automation-config-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    previous_directory = System.get_env("SYNAPSIS_CONFIG_DIR")
    entries = :ets.tab2list(@table)
    load_error = :sys.get_state(@server).load_error

    on_exit(fn ->
      if previous_directory,
        do: System.put_env("SYNAPSIS_CONFIG_DIR", previous_directory),
        else: System.delete_env("SYNAPSIS_CONFIG_DIR")

      :ets.delete_all_objects(@table)
      :ets.insert(@table, entries)
      :sys.replace_state(@server, &%{&1 | load_error: load_error})
      File.rm_rf!(directory)
    end)

    System.put_env("SYNAPSIS_CONFIG_DIR", directory)
    File.write!(Store.file_path(:routine), "")
    assert :ok = Store.reload(:routine)
    :ok
  end

  test "versioned creation infers a compact name separately from exact authored prompt bytes" do
    for {line, name} <- [
          {"Inspect the daily report", "Inspect the daily report"},
          {"\uFEFFBOM title\uFEFF", "BOM title"},
          {"\u0085NEL title\u0085", "\u0085NEL title\u0085"},
          {String.duplicate("a", 58) <> "😀continued", String.duplicate("a", 58) <> "…"},
          {String.duplicate("界", 59) <> "continued", String.duplicate("界", 59) <> "…"}
        ] do
      prompt = "\n \t\n  " <> line <> "  \nKeep this authored line.  \n"
      input = attrs(%{"prompt" => prompt})

      assert {:ok, saved} = Store.put(:routine, input)
      assert saved["name"] == name
      assert saved["prompt"] == prompt
      assert saved["enabled"] == true
      assert saved["session_target"] == "current"
      assert saved["wake_mode"] == "now"
      assert saved["delivery"] == %{"mode" => "announce"}
      assert saved["tool_profile"] == "native_agent"
      assert saved["automation_origin"] == input["automation_origin"]
      refute Map.has_key?(saved, "deleteAfterRun")
      assert_cold_reload(saved)
    end
  end

  test "one-shot defaults and explicit false and zero survive creation and cold reload" do
    for delete_after_run <- [:omitted, false] do
      input =
        attrs(%{
          "name" => "  One shot  ",
          "enabled" => false,
          "schedule" => %{"kind" => "at", "at" => "2030-01-01T00:00:00Z"},
          "delivery" => %{"mode" => "none", "bestEffort" => false, "threadId" => 0}
        })
        |> Map.delete("automation_origin")

      input =
        if delete_after_run == :omitted,
          do: input,
          else: Map.put(input, "deleteAfterRun", delete_after_run)

      assert {:ok, saved} = Store.put(:routine, input)
      assert saved["name"] == "One shot"
      assert saved["enabled"] == false
      assert saved["session_target"] == "isolated"
      assert saved["delivery"] == input["delivery"]
      assert saved["deleteAfterRun"] == (delete_after_run != false)
      refute Map.has_key?(saved, "automation_origin")
      assert_cold_reload(saved)
    end
  end

  test "delivery patches preserve omitted fields and clear only supplied optional overrides" do
    delivery = %{
      "mode" => "announce",
      "channel" => "local",
      "to" => "original-target",
      "accountId" => "original-account",
      "threadId" => 12,
      "bestEffort" => true,
      "future_field" => "retained"
    }

    assert {:ok, saved} =
             Store.put(
               :routine,
               attrs(%{
                 "delivery" => delivery,
                 "provider" => "fixture",
                 "model" => "fixture-model"
               })
             )

    assert {:ok, patched} =
             Store.merge_existing(:routine, saved["id"], %{
               "delivery" => %{"mode" => "none", "bestEffort" => false, "threadId" => 0}
             })

    assert patched["delivery"] ==
             Map.merge(delivery, %{"mode" => "none", "bestEffort" => false, "threadId" => 0})

    assert {:ok, cleared} =
             Store.merge_existing(:routine, saved["id"], %{
               "provider" => nil,
               "model" => nil,
               "delivery" => %{
                 "channel" => nil,
                 "to" => nil,
                 "accountId" => nil,
                 "threadId" => nil
               }
             })

    refute Map.has_key?(cleared, "provider")
    refute Map.has_key?(cleared, "model")

    assert cleared["delivery"] == %{
             "mode" => "none",
             "bestEffort" => false,
             "future_field" => "retained"
           }

    assert_cold_reload(cleared)
  end

  test "ordinary route name and lifecycle updates retain origin and the due occurrence" do
    assert {:ok, saved} = Store.put(:routine, attrs(%{"name" => "Original"}))
    due_at = "2030-01-01T00:00:00Z"

    assert {:ok, due} = Store.merge_existing(:routine, saved["id"], %{"next_run_at" => due_at})

    assert {:ok, updated} =
             Store.merge_existing(:routine, saved["id"], %{
               "name" => "New display name",
               "prompt" => "New authored prompt\n",
               "agent_name" => "another-route",
               "enabled" => false,
               "last_status" => "completed"
             })

    assert updated["automation_origin"] == saved["automation_origin"]
    assert updated["automation_contract_version"] == 1
    assert updated["schedule"] == saved["schedule"]
    assert updated["schedule_generation"] == saved["schedule_generation"]
    assert updated["next_run_at"] == due["next_run_at"]
    assert updated["future_field"] == saved["future_field"]
    assert_cold_reload(updated)
  end

  test "queued nested patches compose against the latest serialized delivery fields" do
    assert {:ok, saved} =
             Store.put(
               :routine,
               attrs(%{
                 "name" => "Queued patches",
                 "delivery" => %{"mode" => "announce", "to" => "original"}
               })
             )

    first = make_ref()
    second = make_ref()
    :ok = :sys.suspend(@server)

    try do
      pid = GenServer.whereis(@server)

      send(
        pid,
        {:"$gen_call", {self(), first},
         {:merge_existing, saved["id"], %{"delivery" => %{"to" => "latest"}}}}
      )

      send(
        pid,
        {:"$gen_call", {self(), second},
         {:merge_existing, saved["id"], %{"delivery" => %{"mode" => "none"}}}}
      )
    after
      :ok = :sys.resume(@server)
    end

    assert_receive {^first, {:ok, first_saved}}, 5_000
    assert_receive {^second, {:ok, second_saved}}, 5_000
    assert first_saved["delivery"] == %{"mode" => "announce", "to" => "latest"}
    assert second_saved["delivery"] == %{"mode" => "none", "to" => "latest"}
    assert_cold_reload(second_saved)
  end

  test "existing versioned updates retain absent create defaults" do
    assert {:ok, saved} = Store.put(:routine, attrs(%{"name" => "Existing versioned entry"}))
    absent = ~w(delivery session_target wake_mode tool_profile)
    existing = Map.drop(saved, absent)

    :ets.insert(
      @table,
      {saved["id"], Map.new(existing, fn {key, value} -> {String.to_atom(key), value} end)}
    )

    assert {:ok, updated} =
             Store.merge_existing(:routine, saved["id"], %{"name" => "Updated display"})

    assert updated == Map.put(existing, "name", "Updated display")
    assert :ok = Store.reload(:routine)
    assert {:ok, ^updated} = Store.get(:routine, saved["id"])
  end

  test "legacy configurations retain their established fields without versioned defaults" do
    input =
      attrs(%{"name" => "Legacy", "enabled" => false, "schedule" => "5 * * * *"})
      |> Map.drop(~w(automation_contract_version automation_origin))

    assert {:ok, ^input} = Store.put(:routine, input)

    assert {:ok, updated} =
             Server.merge_existing(:routine, input["id"], %{"name" => "Legacy renamed"})

    assert updated == Map.put(input, "name", "Legacy renamed")
    assert_cold_reload(updated)
  end

  defp assert_cold_reload(saved) do
    encoded = File.read!(Store.file_path(:routine))
    :ets.delete(@table, saved["id"])
    assert :ok = Store.reload(:routine)
    assert {:ok, ^saved} = Store.get(:routine, saved["id"])
    assert File.read!(Store.file_path(:routine)) == encoded
  end

  defp attrs(extra) do
    Map.merge(
      %{
        "id" => Ecto.UUID.generate(),
        "kind" => "schedule",
        "automation_contract_version" => 1,
        "automation_origin" => %{
          "agent_id" => Ecto.UUID.generate(),
          "session_id" => Ecto.UUID.generate()
        },
        "schedule" => %{"kind" => "cron", "expr" => "0 * * * *", "staggerMs" => 0},
        "prompt" => "Complete the scheduled work",
        "agent_name" => "main",
        "future_field" => %{"retained" => "ordinary data"}
      },
      extra
    )
  end
end
