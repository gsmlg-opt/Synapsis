defmodule Synapsis.Session.StreamTest do
  use ExUnit.Case, async: true

  alias Synapsis.Session.Stream

  describe "start_stream/3" do
    test "returns error for unknown provider" do
      assert {:error, :unknown_provider} =
               Stream.start_stream(%{model: "test"}, %{api_key: "k"}, "totally_unknown_xyz")
    end
  end

  describe "cancel_stream/2" do
    test "returns :ok for unknown provider (silent failure)" do
      assert :ok = Stream.cancel_stream(:some_ref, "totally_unknown_xyz")
    end
  end
end
