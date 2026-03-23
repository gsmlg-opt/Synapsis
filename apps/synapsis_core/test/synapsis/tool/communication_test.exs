defmodule Synapsis.Tool.CommunicationTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.Tool.{AgentSend, AgentAsk, AgentReply, AgentHandoff, AgentDiscover, AgentInbox}

  @context %{
    session_id: nil,
    agent_id: "agent-sender",
    project_id: nil
  }

  describe "AgentSend" do
    test "sends a fire-and-forget message and persists it" do
      Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent:agent-target")

      input = %{"to" => "agent-target", "content" => "hello agent"}
      {:ok, json} = AgentSend.execute(input, @context)
      result = Jason.decode!(json)

      assert result["status"] == "sent"
      assert result["to"] == "agent-target"
      assert is_binary(result["message_id"])
      assert is_binary(result["ref"])

      assert_receive {:agent_envelope, envelope}
      assert envelope.from == "agent-sender"
      assert envelope.to == "agent-target"
      assert envelope.type == :notification

      # Verify persistence
      msg = Synapsis.AgentMessages.get(result["message_id"])
      assert msg.from_agent_id == "agent-sender"
      assert msg.to_agent_id == "agent-target"
    end

    test "has correct permission_level and category" do
      assert AgentSend.permission_level() == :none
      assert AgentSend.category() == :communication
    end
  end

  describe "AgentAsk" do
    test "blocks sub-agents from using agent_ask" do
      input = %{"to" => "some-agent", "question" => "what?"}
      context = Map.put(@context, :parent_agent, self())

      {:error, msg} = AgentAsk.execute(input, context)
      assert msg =~ "deadlock prevention"
    end

    test "times out when no reply received" do
      input = %{"to" => "no-reply-agent", "question" => "hello?", "timeout_ms" => 100}

      {:error, msg} = AgentAsk.execute(input, @context)
      assert msg =~ "timed out"
    end

    test "receives reply within timeout" do
      target = "reply-agent-#{System.unique_integer([:positive])}"
      input = %{"to" => target, "question" => "what is 2+2?", "timeout_ms" => 5000}

      # Spawn a process to send the reply after a short delay
      test_pid = self()

      spawn(fn ->
        Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent:#{target}")

        receive do
          {:agent_envelope, %{ref: ref}} ->
            # Simulate agent_reply
            Phoenix.PubSub.broadcast(
              Synapsis.PubSub,
              "agent_reply:#{ref}",
              {:agent_reply, ref, %{"content" => "4", "status" => "success"}}
            )
        after
          4000 -> send(test_pid, :reply_timeout)
        end
      end)

      {:ok, json} = AgentAsk.execute(input, @context)
      result = Jason.decode!(json)

      assert result["status"] == "received"
      assert result["response"]["content"] == "4"
    end

    test "has correct permission_level and category" do
      assert AgentAsk.permission_level() == :none
      assert AgentAsk.category() == :communication
    end
  end

  describe "AgentReply" do
    test "replies to an existing request" do
      # Create a request message first
      {:ok, request} =
        Synapsis.AgentMessages.create(%{
          ref: "ask-ref-#{System.unique_integer([:positive])}",
          from_agent_id: "requester",
          to_agent_id: "responder",
          type: "request",
          payload: %{"question" => "hello?"}
        })

      # Subscribe to reply topics
      Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent_reply:#{request.ref}")
      Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent:requester")

      input = %{"ref" => request.ref, "content" => "hi back!"}
      context = %{@context | agent_id: "responder"}

      {:ok, json} = AgentReply.execute(input, context)
      result = Jason.decode!(json)

      assert result["status"] == "sent"
      assert result["in_reply_to"] == request.ref

      # Verify the blocking reply message
      assert_receive {:agent_reply, _, response}
      assert response["content"] == "hi back!"

      # Verify the agent envelope delivery
      assert_receive {:agent_envelope, envelope}
      assert envelope.type == :response
    end

    test "returns error for nonexistent ref" do
      input = %{"ref" => "nonexistent-ref", "content" => "reply"}
      {:error, msg} = AgentReply.execute(input, @context)
      assert msg =~ "No request found"
    end

    test "has correct permission_level and category" do
      assert AgentReply.permission_level() == :none
      assert AgentReply.category() == :communication
    end
  end

  describe "AgentHandoff" do
    test "creates handoff with persistence and broadcast" do
      target = "project-agent-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent:#{target}")

      input = %{
        "to" => target,
        "summary" => "Implement auth feature",
        "instructions" => "Use OAuth2 with JWT tokens",
        "artifacts" => ["@synapsis/plans/auth.md"],
        "priority" => "high"
      }

      {:ok, json} = AgentHandoff.execute(input, @context)
      result = Jason.decode!(json)

      assert result["status"] == "delegated"
      assert result["to"] == target
      assert is_binary(result["ref"])

      assert_receive {:agent_envelope, envelope}
      assert envelope.type == :handoff
      assert envelope.payload["summary"] == "Implement auth feature"
    end

    test "has correct permission_level, category, and side_effects" do
      assert AgentHandoff.permission_level() == :none
      assert AgentHandoff.category() == :communication
      assert :workspace_changed in AgentHandoff.side_effects()
    end
  end

  describe "AgentDiscover" do
    test "list action returns agents (may be empty)" do
      {:ok, json} = AgentDiscover.execute(%{"action" => "list"}, @context)
      result = Jason.decode!(json)
      assert is_list(result["agents"])
      assert is_integer(result["count"])
    end

    test "get action returns not found for missing agent" do
      {:ok, json} =
        AgentDiscover.execute(
          %{"action" => "get", "agent_id" => "nonexistent"},
          @context
        )

      result = Jason.decode!(json)
      assert result["found"] == false
    end

    test "get action requires agent_id" do
      {:error, msg} = AgentDiscover.execute(%{"action" => "get"}, @context)
      assert msg =~ "agent_id is required"
    end

    test "find_by_project requires project_id" do
      {:error, msg} = AgentDiscover.execute(%{"action" => "find_by_project"}, @context)
      assert msg =~ "project_id is required"
    end

    test "has correct permission_level and category" do
      assert AgentDiscover.permission_level() == :none
      assert AgentDiscover.category() == :communication
    end
  end

  describe "AgentInbox" do
    test "unread returns and marks messages as read" do
      {:ok, _} =
        Synapsis.AgentMessages.create(%{
          ref: "inbox-ref-#{System.unique_integer([:positive])}",
          from_agent_id: "other-agent",
          to_agent_id: "agent-sender",
          type: "notification",
          payload: %{"content" => "check this"}
        })

      input = %{"action" => "unread"}
      {:ok, json} = AgentInbox.execute(input, @context)
      result = Jason.decode!(json)

      assert result["count"] >= 1
      assert is_list(result["messages"])
      first = hd(result["messages"])
      assert first["from"] == "other-agent"

      # Second call should return empty (messages marked as read)
      {:ok, json2} = AgentInbox.execute(input, @context)
      result2 = Jason.decode!(json2)
      assert result2["count"] == 0
    end

    test "history returns sent and received messages" do
      {:ok, _} =
        Synapsis.AgentMessages.create(%{
          ref: "hist-ref-#{System.unique_integer([:positive])}",
          from_agent_id: "agent-sender",
          to_agent_id: "other-agent",
          type: "notification",
          payload: %{"content" => "outgoing"}
        })

      input = %{"action" => "history"}
      {:ok, json} = AgentInbox.execute(input, @context)
      result = Jason.decode!(json)

      assert result["count"] >= 1
    end

    test "thread requires ref" do
      {:error, msg} = AgentInbox.execute(%{"action" => "thread"}, @context)
      assert msg =~ "ref is required"
    end

    test "returns error without agent context" do
      {:error, msg} = AgentInbox.execute(%{"action" => "unread"}, %{})
      assert msg =~ "No agent context"
    end

    test "has correct permission_level and category" do
      assert AgentInbox.permission_level() == :none
      assert AgentInbox.category() == :communication
    end
  end
end
