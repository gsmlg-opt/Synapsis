defmodule Synapsis.Agent.WorktreeCleanupTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.WorktreeCleanup

  describe "WorktreeCleanup" do
    test "module is defined" do
      assert Code.ensure_loaded?(WorktreeCleanup)
    end

    test "implements Oban.Worker perform/1 via behaviour" do
      # Oban.Worker defines the behaviour; our module must have a perform/1 defined.
      # We verify this by checking the module's exported functions via module info.
      fns = WorktreeCleanup.__info__(:functions)
      assert {:perform, 1} in fns
    end
  end
end
