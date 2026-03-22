defmodule Synapsis.Tool.EnterPlanModeTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.EnterPlanMode

  test "declares none permission and session category" do
    assert EnterPlanMode.permission_level() == :none
    assert EnterPlanMode.category() == :session
    assert EnterPlanMode.name() == "enter_plan_mode"
    assert is_binary(EnterPlanMode.description())
  end

  test "returns correct parameters schema" do
    params = EnterPlanMode.parameters()
    assert is_map(params)
  end
end
