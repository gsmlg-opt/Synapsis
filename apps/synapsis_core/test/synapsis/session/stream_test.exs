defmodule Synapsis.Session.StreamTest do
  use ExUnit.Case, async: true

  alias Synapsis.Session.Stream

  describe "start_stream/3" do
    test "returns error for unknown provider" do
      assert {:error, :unknown_provider} =
               Stream.start_stream(%{model: "test"}, %{api_key: "k"}, "totally_unknown_xyz")
    end

    test "returns error for empty string provider" do
      assert {:error, _} =
               Stream.start_stream(%{model: "test"}, %{api_key: "k"}, "")
    end

    test "returns error for nil provider" do
      assert {:error, _} =
               Stream.start_stream(%{model: "test"}, %{api_key: "k"}, nil)
    end
  end

  describe "cancel_stream/2" do
    test "returns :ok for unknown provider (silent failure)" do
      assert :ok = Stream.cancel_stream(:some_ref, "totally_unknown_xyz")
    end

    test "returns :ok for nil provider" do
      assert :ok = Stream.cancel_stream(:some_ref, nil)
    end

    test "returns :ok for empty string provider" do
      assert :ok = Stream.cancel_stream(:some_ref, "")
    end
  end
end
