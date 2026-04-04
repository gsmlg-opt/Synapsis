defmodule Synapsis.Agent.ToolScopingTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.ToolScoping

  describe "categories_for_role/1" do
    test "assistant includes :workflow" do
      assert :workflow in ToolScoping.categories_for_role(:assistant)
    end

    test "assistant includes :planning" do
      assert :planning in ToolScoping.categories_for_role(:assistant)
    end

    test "assistant does not include :filesystem" do
      refute :filesystem in ToolScoping.categories_for_role(:assistant)
    end

    test "assistant does not include :execution" do
      refute :execution in ToolScoping.categories_for_role(:assistant)
    end

    test "build includes :filesystem" do
      assert :filesystem in ToolScoping.categories_for_role(:build)
    end

    test "build includes :execution" do
      assert :execution in ToolScoping.categories_for_role(:build)
    end

    test "build does not include :workflow" do
      refute :workflow in ToolScoping.categories_for_role(:build)
    end

    test "both roles include :web" do
      assert :web in ToolScoping.categories_for_role(:assistant)
      assert :web in ToolScoping.categories_for_role(:build)
    end

    test "returns a list of atoms" do
      assert is_list(ToolScoping.categories_for_role(:assistant))
      assert is_list(ToolScoping.categories_for_role(:build))
    end
  end
end
