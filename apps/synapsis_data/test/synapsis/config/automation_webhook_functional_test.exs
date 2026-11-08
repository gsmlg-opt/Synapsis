defmodule Synapsis.Config.AutomationWebhookFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Config.Store

  @moduletag :tmp_dir
  @table :synapsis_config_routine
  @server {:via, Registry, {Synapsis.Config.Store.Registry, :routine}}

  setup %{tmp_dir: directory} do
    previous = System.get_env("SYNAPSIS_CONFIG_DIR")
    entries = :ets.tab2list(@table)
    load_error = :sys.get_state(@server).load_error

    on_exit(fn ->
      if previous,
        do: System.put_env("SYNAPSIS_CONFIG_DIR", previous),
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

  test "webhook creation and cold TOML reload preserve delivery and creator origin" do
    input = attrs(%{"mode" => "webhook", "to" => "http://localhost:4051/finished"})
    assert {:ok, saved} = Store.put(:routine, input)
    assert saved["delivery"] == input["delivery"]
    assert saved["automation_origin"] == input["automation_origin"]
    assert saved["prompt"] == input["prompt"]
    assert_cold_reload(saved)
  end

  test "to-only and mode-only edits compose with stored delivery and explicit null clears after none" do
    assert {:ok, saved} =
             Store.put(
               :routine,
               attrs(%{"mode" => "webhook", "to" => "http://localhost:4051/first"})
             )

    assert {:ok, retargeted} =
             Store.merge_existing(:routine, saved["id"], %{
               "delivery" => %{"to" => "http://localhost:4052/second"}
             })

    assert retargeted["delivery"] == %{
             "mode" => "webhook",
             "to" => "http://localhost:4052/second"
           }

    assert {:ok, suppressed} =
             Store.merge_existing(:routine, saved["id"], %{"delivery" => %{"mode" => "none"}})

    assert suppressed["delivery"] == Map.put(retargeted["delivery"], "mode", "none")

    assert {:ok, restored} =
             Store.merge_existing(:routine, saved["id"], %{"delivery" => %{"mode" => "webhook"}})

    assert restored["delivery"] == retargeted["delivery"]
    assert restored["automation_origin"] == saved["automation_origin"]
    assert_cold_reload(restored)

    assert {:ok, cleared} =
             Store.merge_existing(:routine, saved["id"], %{
               "delivery" => %{"mode" => "none", "to" => nil}
             })

    assert cleared["delivery"] == %{"mode" => "none"}
    assert cleared["automation_origin"] == saved["automation_origin"]
    assert_cold_reload(cleared)
  end

  test "ordinary announce and none configurations retain their positive behavior" do
    for mode <- ["announce", "none"] do
      assert {:ok, saved} = Store.put(:routine, attrs(%{"mode" => mode}))
      assert saved["delivery"] == %{"mode" => mode}
      assert_cold_reload(saved)
    end
  end

  defp assert_cold_reload(saved) do
    encoded = File.read!(Store.file_path(:routine))
    :ets.delete(@table, saved["id"])
    assert :ok = Store.reload(:routine)
    assert {:ok, ^saved} = Store.get(:routine, saved["id"])
    assert File.read!(Store.file_path(:routine)) == encoded
  end

  defp attrs(delivery) do
    %{
      "id" => Ecto.UUID.generate(),
      "kind" => "schedule",
      "automation_contract_version" => 1,
      "automation_origin" => %{
        "agent_id" => Ecto.UUID.generate(),
        "session_id" => Ecto.UUID.generate()
      },
      "name" => "Webhook foundation",
      "prompt" => "  Complete the authored work\nexact bytes  \n",
      "enabled" => false,
      "schedule" => %{"kind" => "every", "everyMs" => 600_000},
      "agent_name" => "main",
      "delivery" => delivery
    }
  end
end
