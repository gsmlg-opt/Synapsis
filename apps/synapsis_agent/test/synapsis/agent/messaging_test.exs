defmodule Synapsis.Agent.MessagingTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.Messaging

  describe "envelope/4" do
    test "builds envelope with all required fields" do
      env = Messaging.envelope("global", "project-1", :delegation, %{task: "code"})

      assert env.from == "global"
      assert env.to == "project-1"
      assert env.type == :delegation
      assert env.payload == %{task: "code"}
      assert is_binary(env.ref)
      assert %DateTime{} = env.timestamp
    end
  end

  describe "delegate/3" do
    test "builds delegation envelope" do
      env = Messaging.delegate("global", "project-1", %{work_id: "w1"})
      assert env.type == :delegation
      assert env.payload.work_id == "w1"
    end
  end

  describe "complete/4" do
    test "builds completion envelope with ref" do
      env = Messaging.complete("session-1", "project-1", "ref-123", %{status: :ok})
      assert env.type == :completion
      assert env.ref == "ref-123"
      assert env.payload.status == :ok
    end
  end

  describe "PubSub delivery" do
    test "send_envelope delivers to subscribed agent" do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"
      Messaging.subscribe(agent_id)

      env = Messaging.envelope("sender", agent_id, :user_message, "hello")
      Messaging.send_envelope(env)

      assert_receive {:agent_envelope, received}
      assert received.from == "sender"
      assert received.to == agent_id
      assert received.type == :user_message
      assert received.payload == "hello"
    end

    test "delegation reaches target agent" do
      target = "project-#{System.unique_integer([:positive])}"
      Messaging.subscribe(target)

      env = Messaging.delegate("global", target, %{command: "mix test"})
      Messaging.send_envelope(env)

      assert_receive {:agent_envelope, %{type: :delegation, payload: %{command: "mix test"}}}
    end

    test "completion notification reaches source agent" do
      source = "project-#{System.unique_integer([:positive])}"
      Messaging.subscribe(source)

      env = Messaging.complete("session-42", source, "ref-x", %{status: :ok})
      Messaging.send_envelope(env)

      assert_receive {:agent_envelope, %{type: :completion, ref: "ref-x"}}
    end
  end
end
