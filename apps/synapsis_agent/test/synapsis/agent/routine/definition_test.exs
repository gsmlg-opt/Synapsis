defmodule Synapsis.Agent.Routine.DefinitionTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.Routine.Definition

  test "from_heartbeat adapts TOML-shaped maps with defaults" do
    assert {:ok, defn} =
             Definition.from_heartbeat(%{
               "id" => "hb-1",
               "name" => "pulse",
               "schedule" => "*/5 * * * *",
               "prompt" => "check in"
             })

    assert defn.kind == :heartbeat
    assert defn.timezone == "Etc/UTC"
    assert defn.misfire_policy == :skip
    assert defn.no_overlap == true
    assert defn.tool_profile == "heartbeat"
    assert defn.enabled == true
    assert defn.prompt == "check in"
  end

  test "from_heartbeat rejects missing schedule" do
    assert {:error, :missing_schedule} =
             Definition.from_heartbeat(%{"id" => "x", "name" => "y"})
  end

  test "to_heartbeat_config preserves worker fields" do
    {:ok, defn} =
      Definition.from_heartbeat(%{
        id: "hb-2",
        name: "n",
        schedule: "0 * * * *",
        agent_name: "ops",
        keep_history: true
      })

    cfg = Definition.to_heartbeat_config(defn)
    assert cfg.id == "hb-2"
    assert cfg.agent_name == "ops"
    assert cfg.keep_history == true
  end
end
