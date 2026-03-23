defmodule Synapsis.AgentMessagesTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.{AgentMessage, AgentMessages}

  @valid_attrs %{
    ref: "test-ref-001",
    from_agent_id: "agent-a",
    to_agent_id: "agent-b",
    type: "notification",
    payload: %{"content" => "hello"}
  }

  describe "create/1" do
    test "creates a message with valid attrs" do
      assert {:ok, %AgentMessage{} = msg} = AgentMessages.create(@valid_attrs)
      assert msg.ref == "test-ref-001"
      assert msg.from_agent_id == "agent-a"
      assert msg.to_agent_id == "agent-b"
      assert msg.type == "notification"
      assert msg.status == "delivered"
    end

    test "fails without required fields" do
      assert {:error, changeset} = AgentMessages.create(%{})
      errors = errors_on(changeset)
      assert errors[:ref]
      assert errors[:from_agent_id]
      assert errors[:to_agent_id]
    end

    test "validates type inclusion" do
      attrs = Map.put(@valid_attrs, :type, "invalid_type")
      assert {:error, changeset} = AgentMessages.create(attrs)
      assert errors_on(changeset)[:type]
    end
  end

  describe "get/1 and get_by_ref/1" do
    test "retrieves by ID" do
      {:ok, msg} = AgentMessages.create(@valid_attrs)
      assert AgentMessages.get(msg.id).id == msg.id
    end

    test "retrieves by ref" do
      {:ok, msg} = AgentMessages.create(@valid_attrs)
      assert AgentMessages.get_by_ref("test-ref-001").id == msg.id
    end

    test "returns nil for missing" do
      assert is_nil(AgentMessages.get(Ecto.UUID.generate()))
      assert is_nil(AgentMessages.get_by_ref("nonexistent"))
    end
  end

  describe "unread/2" do
    test "returns unread messages for agent" do
      {:ok, _} = AgentMessages.create(@valid_attrs)
      {:ok, _} = AgentMessages.create(%{@valid_attrs | ref: "ref-002"})

      messages = AgentMessages.unread("agent-b")
      assert length(messages) == 2
    end

    test "excludes read messages" do
      {:ok, msg} = AgentMessages.create(@valid_attrs)
      AgentMessages.mark_read(msg)

      messages = AgentMessages.unread("agent-b")
      assert Enum.empty?(messages)
    end

    test "respects limit" do
      for i <- 1..5 do
        AgentMessages.create(%{@valid_attrs | ref: "ref-#{i}"})
      end

      messages = AgentMessages.unread("agent-b", limit: 3)
      assert length(messages) == 3
    end
  end

  describe "history/2" do
    test "returns messages involving agent" do
      {:ok, _} = AgentMessages.create(@valid_attrs)

      {:ok, _} =
        AgentMessages.create(%{
          @valid_attrs
          | ref: "ref-reverse",
            from_agent_id: "agent-b",
            to_agent_id: "agent-a"
        })

      messages = AgentMessages.history("agent-b")
      assert length(messages) == 2
    end
  end

  describe "thread/2" do
    test "returns messages in a thread by ref" do
      {:ok, original} = AgentMessages.create(@valid_attrs)

      {:ok, _reply} =
        AgentMessages.create(%{
          ref: "reply-ref",
          from_agent_id: "agent-b",
          to_agent_id: "agent-a",
          type: "response",
          in_reply_to: original.id,
          payload: %{"content" => "reply"}
        })

      messages = AgentMessages.thread("test-ref-001")
      assert length(messages) >= 1
    end
  end

  describe "mark_read/1" do
    test "updates status to read" do
      {:ok, msg} = AgentMessages.create(@valid_attrs)
      assert msg.status == "delivered"

      {:ok, updated} = AgentMessages.mark_read(msg)
      assert updated.status == "read"
    end
  end

  describe "mark_all_read/1" do
    test "marks all unread for agent" do
      for i <- 1..3 do
        AgentMessages.create(%{@valid_attrs | ref: "bulk-#{i}"})
      end

      {count, _} = AgentMessages.mark_all_read("agent-b")
      assert count == 3

      assert Enum.empty?(AgentMessages.unread("agent-b"))
    end
  end

  describe "expire_stale/0" do
    test "expires messages past their TTL" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, _} =
        AgentMessages.create(Map.merge(@valid_attrs, %{ref: "expired-ref", expires_at: past}))

      {count, _} = AgentMessages.expire_stale()
      assert count == 1

      msg = AgentMessages.get_by_ref("expired-ref")
      assert msg.status == "expired"
    end
  end
end
