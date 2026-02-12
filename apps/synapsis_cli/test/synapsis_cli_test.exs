defmodule SynapsisCliTest do
  use ExUnit.Case
  doctest SynapsisCli

  test "greets the world" do
    assert SynapsisCli.hello() == :world
  end
end
