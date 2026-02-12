defmodule SynapsisCoreTest do
  use ExUnit.Case
  doctest SynapsisCore

  test "greets the world" do
    assert SynapsisCore.hello() == :world
  end
end
