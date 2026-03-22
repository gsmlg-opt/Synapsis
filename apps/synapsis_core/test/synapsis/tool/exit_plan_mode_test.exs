defmodule Synapsis.Tool.ExitPlanModeTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.ExitPlanMode

  test "declares none permission and session category" do
    assert ExitPlanMode.permission_level() == :none
    assert ExitPlanMode.category() == :session
    assert ExitPlanMode.name() == "exit_plan_mode"
    assert is_binary(ExitPlanMode.description())
  end

  test "parameters schema includes plan" do
    params = ExitPlanMode.parameters()
    assert is_map(params)
    assert get_in(params, ["properties", "plan"])
  end
end
