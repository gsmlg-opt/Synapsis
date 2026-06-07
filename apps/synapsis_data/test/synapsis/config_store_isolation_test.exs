defmodule Synapsis.ConfigStoreIsolationTest do
  use ExUnit.Case, async: false

  alias Synapsis.Config.Store

  test "test environment does not use the real user config directory" do
    refute Path.expand(Store.config_dir()) ==
             Path.join(System.user_home!(), ".config/synapsis")
  end
end
