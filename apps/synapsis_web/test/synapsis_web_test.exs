defmodule SynapsisWebTest do
  use ExUnit.Case
  doctest SynapsisWeb

  test "greets the world" do
    assert SynapsisWeb.hello() == :world
  end
end
