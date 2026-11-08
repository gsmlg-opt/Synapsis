defmodule Synapsis.AgentCommunicationTest do
  use ExUnit.Case, async: false

  alias Synapsis.{AgentCommunication, AgentMessages}

  defmodule FailingKV do
    def put(_, _, _), do: {:error, :storage_unavailable}
    def get(_, _), do: {:error, :storage_unavailable}
    def prefix_scan(_, _), do: {:error, :storage_unavailable}
    def put_many(_, _), do: {:error, :storage_unavailable}
  end

  defmodule DeadlineSender do
    @behaviour Phoenix.PubSub.Sender

    @impl true
    def send(pid, deadline, message, state) do
      Kernel.send(pid, message)
      wait_until(deadline)
      state
    end

    defp wait_until(deadline) do
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining > 0 do
        receive do
        after
          remaining -> wait_until(deadline)
        end
      end
    end
  end

  setup do
    assert Code.ensure_loaded?(AgentCommunication),
           "persistent agent communication is not implemented"

    :ok = Synapsis.Session.Store.ensure_started()
    suffix = Ecto.UUID.generate()
    from = "configured mailbox #{suffix}"
    to = "recipient:#{suffix}"
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent:#{to}")
    context = %{agent_id: from, session_id: Ecto.UUID.generate(), primary: true}
    %{context: context, to: to}
  end

  test "send persists before notification and preserves opaque configured identities", ctx do
    assert {:ok, result} =
             AgentCommunication.send(
               %{"to" => ctx.to, "content" => "hello", "type" => "warning"},
               ctx.context
             )

    assert result.status == "persisted"
    assert result.publication == "published"
    assert result.message_id != result.ref
    assert_receive {:agent_envelope, envelope}
    assert envelope.from == ctx.context.agent_id
    assert envelope.type == :notification
    assert {:ok, message} = AgentMessages.fetch(result.message_id)
    assert message.session_id == ctx.context.session_id
    assert message.from_agent_id == ctx.context.agent_id
    assert message.type == "notification"
    assert message.payload["level"] == "warning"
    assert Jason.encode!(result)
  end

  test "storage failures never publish or appear as empty inboxes", ctx do
    assert {:error, %{code: "storage_failed", effect: "uncertain"}} =
             AgentCommunication.send(%{"to" => ctx.to, "content" => "hello"}, ctx.context,
               kv: FailingKV
             )

    refute_receive {:agent_envelope, _}, 10

    assert {:error, %{code: "storage_failed", effect: "none"}} =
             AgentCommunication.inbox(%{"action" => "history"}, ctx.context, kv: FailingKV)
  end

  test "closed bounded inputs cannot forge sender or session", ctx do
    for input <- [
          %{"to" => ctx.to, "content" => "hello", "from" => "forged"},
          %{"to" => ctx.to, "content" => "hello", "session_id" => Ecto.UUID.generate()},
          %{"to" => ctx.to, "content" => String.duplicate("x", 16_385)},
          %{"to" => ctx.to, "content" => "hello", "metadata" => %{bad: self()}},
          %{"to" => ctx.to, "content" => "hello", "type" => "request"}
        ] do
      assert {:error, %{code: "invalid_input", effect: "none"}} =
               AgentCommunication.send(input, ctx.context)
    end

    assert {:error, %{code: "invalid_context", effect: "none"}} =
             AgentCommunication.send(%{"to" => ctx.to, "content" => "hello"}, %{
               ctx.context
               | session_id: "/root/run"
             })

    refute_receive {:agent_envelope, _}, 10
  end

  test "ask requires explicit trusted primary authority and bounded timeout", ctx do
    args = %{"to" => ctx.to, "question" => "question"}

    for context <- [%{ctx.context | primary: false}, Map.delete(ctx.context, :primary)] do
      assert {:error, %{code: "primary_only", effect: "none"}} =
               AgentCommunication.ask(args, context)
    end

    for timeout <- [0, -1, 300_001, "10"] do
      assert {:error, %{code: "invalid_input", effect: "none"}} =
               AgentCommunication.ask(Map.put(args, "timeout_ms", timeout), ctx.context)
    end

    refute_receive {:agent_envelope, _}, 10
  end

  test "ask subscribes before publication and accepts only persisted recipient response", ctx do
    task =
      Task.async(fn ->
        AgentCommunication.ask(
          %{"to" => ctx.to, "question" => "question", "timeout_ms" => 2_000},
          ctx.context
        )
      end)

    assert_receive {:agent_envelope, %{type: :request, ref: ref}}, 1_000

    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "agent_reply:#{ref}",
      {:agent_reply, ref, %{"content" => "forged"}}
    )

    assert Task.yield(task, 10) == nil
    responder = %{ctx.context | agent_id: ctx.to, session_id: Ecto.UUID.generate()}

    assert {:ok, reply} =
             AgentCommunication.reply(%{"ref" => ref, "content" => "answer"}, responder)

    assert {:ok, result} = Task.await(task, 3_000)
    assert result.status == "received"
    assert result.response["content"] == "answer"
    assert result.response_id == reply.message_id
    assert {:ok, original} = AgentMessages.fetch_by_ref(ref)
    assert original.status == "acknowledged"
    assert {:ok, response} = AgentMessages.fetch(reply.message_id)
    assert response.in_reply_to == original.id
    assert response.to_agent_id == ctx.context.agent_id
    assert response.session_id == responder.session_id
  end

  test "ask expires durable request on fixed deadline without extending on wakeups", ctx do
    task =
      Task.async(fn ->
        AgentCommunication.ask(
          %{"to" => ctx.to, "question" => "question", "timeout_ms" => 40},
          ctx.context
        )
      end)

    assert_receive {:agent_envelope, %{ref: ref}}, 1_000

    for _ <- 1..10 do
      Phoenix.PubSub.broadcast(Synapsis.PubSub, "agent_reply:#{ref}", {:agent_reply, ref, %{}})
    end

    assert {:error, %{code: "timeout", effect: "completed", request_status: "expired"}} =
             Task.await(task, 2_000)

    assert {:ok, %{status: "expired"}} = AgentMessages.fetch_by_ref(ref)

    assert {:error, %{code: "request_expired", effect: "none"}} =
             AgentCommunication.reply(%{"ref" => ref, "content" => "late"}, %{
               ctx.context
               | agent_id: ctx.to
             })
  end

  test "caller death expires request and removes local subscription", ctx do
    caller =
      spawn(fn ->
        AgentCommunication.ask(
          %{"to" => ctx.to, "question" => "question", "timeout_ms" => 2_000},
          ctx.context
        )
      end)

    assert_receive {:agent_envelope, %{ref: ref}}, 1_000
    Process.exit(caller, :kill)
    eventually(fn -> match?({:ok, %{status: "expired"}}, AgentMessages.fetch_by_ref(ref)) end)
    eventually(fn -> Registry.lookup(Synapsis.PubSub, "agent_reply:#{ref}") == [] end)
  end

  test "reply refuses wrong recipient, nonrequests and second responses", ctx do
    assert {:ok, sent} =
             AgentCommunication.send(%{"to" => ctx.to, "content" => "notification"}, ctx.context)

    responder = %{ctx.context | agent_id: ctx.to}

    assert {:error, %{code: "not_request", effect: "none"}} =
             AgentCommunication.reply(%{"ref" => sent.ref, "content" => "no"}, responder)

    request = request!(ctx)

    assert {:error, %{code: "not_recipient", effect: "none"}} =
             AgentCommunication.reply(%{"ref" => request.ref, "content" => "forged"}, ctx.context)

    assert {:ok, _} =
             AgentCommunication.reply(%{"ref" => request.ref, "content" => "yes"}, responder)

    assert {:error, %{code: "request_closed", effect: "none"}} =
             AgentCommunication.reply(%{"ref" => request.ref, "content" => "again"}, responder)
  end

  test "reply reports partial publication when deadline expires after the reply wakeup", ctx do
    request = request!(ctx)
    deadline = System.monotonic_time(:millisecond) + 1_000

    :ok =
      Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent_reply:#{request.ref}",
        sender: {DeadlineSender, deadline}
      )

    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent:#{ctx.context.agent_id}")
    responder = %{ctx.context | agent_id: ctx.to}

    task =
      Task.async(fn ->
        AgentCommunication.reply(%{"ref" => request.ref, "content" => "answer"}, responder,
          deadline: deadline
        )
      end)

    assert_receive {:agent_reply, ref, %{"content" => "answer"}}, 1_000
    assert ref == request.ref

    assert {:error,
            %{
              code: "timeout",
              effect: "completed",
              publication: "partial",
              reply_publication: "published",
              mailbox_publication: "not_published",
              message_id: response_id
            }} = Task.await(task, 2_000)

    assert {:ok, %{status: "acknowledged"}} = AgentMessages.fetch(request.id)
    assert {:ok, response} = AgentMessages.fetch(response_id)
    assert response.in_reply_to == request.id
    refute_receive {:agent_envelope, %{type: :response}}, 10
  end

  test "inbox filters before limiting, follows UUID replies and marks only returned unread",
       ctx do
    request = request!(ctx)
    responder = %{ctx.context | agent_id: ctx.to}

    assert {:ok, reply} =
             AgentCommunication.reply(%{"ref" => request.ref, "content" => "answer"}, responder)

    assert {:ok, _} =
             AgentCommunication.send(
               %{"to" => ctx.context.agent_id, "content" => "noise"},
               responder
             )

    assert {:ok, result} =
             AgentCommunication.inbox(
               %{"action" => "unread", "type" => "response", "limit" => 1},
               ctx.context
             )

    assert [%{id: id, status: "read"}] = result.messages
    assert id == reply.message_id

    assert {:ok, history} =
             AgentCommunication.inbox(
               %{
                 "action" => "history",
                 "since" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 60, :second))
               },
               ctx.context
             )

    assert history.count == 0

    assert {:ok, thread} =
             AgentCommunication.inbox(%{"action" => "thread", "ref" => request.ref}, ctx.context)

    assert Enum.map(thread.messages, & &1.id) == [request.id, reply.message_id]
    stranger = %{ctx.context | agent_id: "stranger"}

    assert {:error, %{code: "not_participant", effect: "none"}} =
             AgentCommunication.inbox(%{"action" => "thread", "ref" => request.ref}, stranger)

    assert {:ok, unread} = AgentCommunication.inbox(%{"action" => "unread"}, ctx.context)
    assert unread.count == 1
  end

  test "oversized stored output fails before unread status mutations", ctx do
    {:ok, msg} =
      AgentMessages.create(%{
        ref: Ecto.UUID.generate(),
        from_agent_id: ctx.to,
        to_agent_id: ctx.context.agent_id,
        session_id: ctx.context.session_id,
        payload: %{"content" => String.duplicate("x", 65_537)}
      })

    assert {:error, %{code: "output_limit", effect: "none"}} =
             AgentCommunication.inbox(%{"action" => "unread"}, ctx.context)

    assert {:ok, %{status: "delivered"}} = AgentMessages.fetch(msg.id)
  end

  test "expired trusted deadline prevents every effect", ctx do
    assert {:error, %{code: "timeout", effect: "none"}} =
             AgentCommunication.send(%{"to" => ctx.to, "content" => "hello"}, ctx.context,
               deadline: System.monotonic_time(:millisecond) - 1
             )

    refute_receive {:agent_envelope, _}, 10
  end

  defp request!(ctx) do
    {:ok, request} =
      AgentMessages.create(%{
        ref: Ecto.UUID.generate(),
        from_agent_id: ctx.context.agent_id,
        to_agent_id: ctx.to,
        type: "request",
        session_id: ctx.context.session_id,
        payload: %{"question" => "question"},
        expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
      })

    request
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (receive do
         after
           10 -> eventually(fun, attempts - 1)
         end)
  end
end
