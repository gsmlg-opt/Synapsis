defmodule Synapsis.AgentMessagesTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.{AgentMessage, AgentMessages}

  setup do
    clear_coord("coord/agent_messages/")
    :ok
  end

  @valid_attrs %{
    ref: "test-ref-001",
    from_agent_id: "agent-a",
    to_agent_id: "agent-b",
    type: "notification",
    payload: %{"content" => "hello"}
  }

  defmodule UnavailableKV do
    def put(_, _, _), do: {:error, :storage_unavailable}
    def get(_, _), do: {:error, :storage_unavailable}
    def prefix_scan(_, _), do: {:error, :storage_unavailable}
    def put_many(_, _), do: {:error, :storage_unavailable}
  end

  defmodule FailedBatchKV do
    def get(key, opts), do: Concord.Turso.get(key, opts)
    def prefix_scan(prefix, opts), do: Concord.Turso.prefix_scan(prefix, opts)
    def put_many(_, _), do: {:error, :batch_failed}
  end

  describe "explicit storage and mail-domain operations" do
    test "create and fetch propagate storage failures" do
      assert {:error, {:storage, :storage_unavailable}} =
               AgentMessages.create(@valid_attrs, kv: UnavailableKV)

      assert {:error, {:storage, :storage_unavailable}} =
               AgentMessages.fetch(Ecto.UUID.generate(), kv: UnavailableKV)

      assert {:error, {:storage, :storage_unavailable}} =
               AgentMessages.fetch_by_ref("missing", kv: UnavailableKV)

      assert {:error, {:storage, :storage_unavailable}} =
               AgentMessages.query("history", "agent-b", kv: UnavailableKV)
    end

    test "type and since filters precede limit and thread follows message UUIDs" do
      {:ok, original} = AgentMessages.create(%{@valid_attrs | type: "request"})

      {:ok, response} =
        AgentMessages.create(
          %{@valid_attrs | ref: "reply", type: "response"}
          |> Map.put(:in_reply_to, original.id)
        )

      {:ok, _} = AgentMessages.create(%{@valid_attrs | ref: "noise"})
      assert {:ok, [found]} = AgentMessages.query("history", "agent-b", type: "request", limit: 1)
      assert found.id == original.id

      assert {:ok, []} =
               AgentMessages.query("history", "agent-b",
                 since: DateTime.add(DateTime.utc_now(), 60, :second)
               )

      assert {:ok, thread} = AgentMessages.query("thread", "agent-b", ref: original.ref)
      assert Enum.map(thread, & &1.id) == [original.id, response.id]

      assert {:error, :not_participant} =
               AgentMessages.query("thread", "stranger", ref: original.ref)
    end

    test "atomic reply failure neither acknowledges request nor saves response" do
      {:ok, request} =
        AgentMessages.create(
          %{@valid_attrs | type: "request"}
          |> Map.put(:expires_at, DateTime.add(DateTime.utc_now(), 60, :second))
        )

      attrs = %{
        ref: "response-ref",
        from_agent_id: "agent-b",
        session_id: Ecto.UUID.generate(),
        payload: %{"content" => "reply"}
      }

      assert {:error, {:storage, :batch_failed}} =
               AgentMessages.reply(request.ref, "agent-b", attrs, kv: FailedBatchKV)

      assert {:ok, %{status: "delivered"}} = AgentMessages.fetch(request.id)
      assert {:error, :not_found} = AgentMessages.fetch_by_ref("response-ref")
    end

    test "response and acknowledgement commit together and expiration cannot overwrite acknowledgement" do
      {:ok, request} =
        AgentMessages.create(
          %{@valid_attrs | type: "request"}
          |> Map.put(:expires_at, DateTime.add(DateTime.utc_now(), 60, :second))
        )

      attrs = %{
        ref: "response-ref",
        from_agent_id: "agent-b",
        session_id: Ecto.UUID.generate(),
        payload: %{"content" => "reply"}
      }

      assert {:ok, %{response: response, request: acknowledged}} =
               AgentMessages.reply(request.ref, "agent-b", attrs)

      assert response.in_reply_to == request.id
      assert response.to_agent_id == request.from_agent_id
      assert acknowledged.status == "acknowledged"
      assert {:ok, %{status: "acknowledged"}} = AgentMessages.expire_request(request.id)
      assert {:error, :request_closed} = AgentMessages.reply(request.ref, "agent-b", attrs)
    end

    test "stale mark_read and status updates cannot reopen an acknowledged request" do
      {:ok, request} =
        AgentMessages.create(
          %{@valid_attrs | type: "request"}
          |> Map.put(:expires_at, DateTime.add(DateTime.utc_now(), 60, :second))
        )

      attrs = %{
        ref: "first-response-ref",
        from_agent_id: "agent-b",
        session_id: Ecto.UUID.generate(),
        payload: %{"content" => "first reply"}
      }

      assert {:ok, %{response: response, request: acknowledged}} =
               AgentMessages.reply(request.ref, "agent-b", attrs)

      assert {:ok, unchanged} = AgentMessages.mark_read(request)
      assert unchanged == acknowledged

      for status <- ~w(delivered read expired) do
        assert {:ok, ^acknowledged} = AgentMessages.update_status(request, status)
      end

      assert {:error, :request_closed} =
               AgentMessages.reply(request.ref, "agent-b", %{attrs | ref: "second-response-ref"})

      assert {:ok, %{status: "acknowledged"}} = AgentMessages.fetch(request.id)
      assert {:error, :not_found} = AgentMessages.fetch_by_ref("second-response-ref")
      assert {:ok, thread} = AgentMessages.query("thread", "agent-b", ref: request.ref)
      assert Enum.map(thread, & &1.id) == [request.id, response.id]
    end

    test "stale mark_read and status updates cannot reopen owner-expired requests" do
      for {suffix, expires_at} <- [
            {"without-ttl", nil},
            {"future-ttl", DateTime.add(DateTime.utc_now(), 60, :second)}
          ] do
        {:ok, request} =
          AgentMessages.create(
            %{@valid_attrs | ref: "request-#{suffix}", type: "request"}
            |> Map.put(:expires_at, expires_at)
          )

        assert {:ok, expired} = AgentMessages.expire_request(request.id)
        assert expired.status == "expired"
        assert {:ok, unchanged} = AgentMessages.mark_read(request)
        assert unchanged == expired

        for status <- ~w(delivered read acknowledged) do
          assert {:ok, ^expired} = AgentMessages.update_status(request, status)
        end

        attrs = %{
          ref: "late-response-#{suffix}",
          from_agent_id: "agent-b",
          session_id: Ecto.UUID.generate(),
          payload: %{"content" => "late reply"}
        }

        assert {:error, :request_expired} = AgentMessages.reply(request.ref, "agent-b", attrs)
        assert {:ok, %{status: "expired"}} = AgentMessages.fetch(request.id)
        assert {:error, :not_found} = AgentMessages.fetch_by_ref(attrs.ref)
      end
    end

    test "status and bulk update failures propagate and invalid status is rejected" do
      {:ok, request} = AgentMessages.create(@valid_attrs)
      assert {:error, :invalid_status} = AgentMessages.update_status(request, "invented")

      assert {:error, {:storage, :storage_unavailable}} =
               AgentMessages.mark_messages_read([request], kv: UnavailableKV)

      assert {:error, {:storage, :storage_unavailable}} =
               AgentMessages.expire_request(request.id, kv: UnavailableKV)

      assert {:ok, %{status: "delivered"}} = AgentMessages.fetch(request.id)
    end

    test "expired deadline refuses writes" do
      assert {:error, :timeout} =
               AgentMessages.create(@valid_attrs,
                 deadline: System.monotonic_time(:millisecond) - 1
               )

      assert {:error, :not_found} = AgentMessages.fetch_by_ref(@valid_attrs.ref)
    end
  end

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

      assert :ok = AgentMessages.mark_all_read("agent-b")
      assert Enum.empty?(AgentMessages.unread("agent-b"))
    end
  end

  describe "expire_stale/0" do
    test "expires messages past their TTL" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, _} =
        AgentMessages.create(Map.merge(@valid_attrs, %{ref: "expired-ref", expires_at: past}))

      assert :ok = AgentMessages.expire_stale()

      msg = AgentMessages.get_by_ref("expired-ref")
      assert msg.status == "expired"
    end
  end
end
