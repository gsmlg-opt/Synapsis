defmodule Synapsis.Agent.Nodes.ReceiveMessageTest do
  use Synapsis.Agent.DataCase, async: true

  alias Synapsis.Agent.Nodes.ReceiveMessage

  describe "run/2" do
    test "waits for input on first call" do
      state = %{session_id: Ecto.UUID.generate()}

      assert {:wait, new_state} = ReceiveMessage.run(state, %{})
      assert new_state[:awaiting_input] == true
    end

    test "proceeds with user input on resume" do
      state = %{session_id: Ecto.UUID.generate(), awaiting_input: true}
      ctx = %{user_input: "hello world"}

      assert {:next, :default, new_state} = ReceiveMessage.run(state, ctx)
      assert new_state.user_input == "hello world"
      assert new_state[:image_parts] == []
      refute Map.has_key?(new_state, :awaiting_input)
    end

    test "passes image_parts from context on resume" do
      state = %{session_id: Ecto.UUID.generate(), awaiting_input: true}
      image_parts = [%{type: :image, data: "base64data"}]
      ctx = %{user_input: "describe this", image_parts: image_parts}

      assert {:next, :default, new_state} = ReceiveMessage.run(state, ctx)
      assert new_state.image_parts == image_parts
    end
  end
end
