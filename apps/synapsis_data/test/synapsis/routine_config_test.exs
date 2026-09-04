defmodule Synapsis.RoutineConfigTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.Config.Store

  setup do
    clear_config_store(:routine)
    on_exit(fn -> clear_config_store(:routine) end)
    :ok
  end

  test "persists a minimally validated routine map" do
    attrs = %{
      "id" => Ecto.UUID.generate(),
      "name" => "nightly-reflection",
      "kind" => "dream",
      "enabled" => true,
      "schedule" => "0 2 * * *",
      "prompt" => "Reflect on recent work",
      "tool_profile" => "assistant_dream",
      "no_overlap" => true,
      "max_runtime_ms" => 120_000,
      "last_run_at" => "2026-09-04T01:00:00Z",
      "next_run_at" => "2026-09-05T02:00:00Z",
      "last_status" => "completed",
      "metadata" => %{"owner" => "main"}
    }

    assert {:ok, ^attrs} = Store.put(:routine, attrs)
    assert [^attrs] = Store.list(:routine)
  end

  test "rejects five-field text that is not a cron expression" do
    attrs = %{
      "id" => Ecto.UUID.generate(),
      "name" => "invalid-schedule",
      "kind" => "schedule",
      "enabled" => true,
      "schedule" => "x x x x x",
      "prompt" => "This must not be persisted"
    }

    assert {:error, {:invalid_routine, :schedule}} = Store.put(:routine, attrs)
    assert [] = Store.list(:routine)
  end

  test "rejects invalid routine fields without changing the store" do
    base = %{
      "id" => Ecto.UUID.generate(),
      "name" => "routine",
      "kind" => "heartbeat",
      "enabled" => true,
      "schedule" => "* * * * *",
      "prompt" => "Check status"
    }

    invalid = [
      Map.delete(base, "name"),
      Map.put(base, "kind", "manual"),
      Map.put(base, "enabled", "yes"),
      Map.put(base, "schedule", "every minute"),
      Map.put(base, "prompt", "  "),
      Map.put(base, "tool_profile", 42),
      Map.put(base, "no_overlap", nil),
      Map.put(base, "max_runtime_ms", 0),
      Map.put(base, "last_run_at", "yesterday"),
      Map.put(base, "next_run_at", 123),
      Map.put(base, "last_status", :completed),
      Map.put(base, "metadata", [])
    ]

    for attrs <- invalid do
      assert {:error, {:invalid_routine, _reason}} = Store.put(:routine, attrs)
    end

    assert [] = Store.list(:routine)
  end
end
