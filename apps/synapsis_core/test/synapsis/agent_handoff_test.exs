defmodule Synapsis.AgentHandoffTest do
  use ExUnit.Case, async: false

  alias Synapsis.{AgentCommunication, AgentMessages}

  defmodule FailingKV do
    def put(_, _, _), do: {:error, :private_storage_diagnostic}
  end

  setup do
    assert Code.ensure_loaded?(AgentCommunication) and
             function_exported?(AgentCommunication, :persist_handoff, 3),
           "the core handoff persistence stage is not implemented"

    :ok = Synapsis.Session.Store.ensure_started()
    to = "handoff-recipient-#{Ecto.UUID.generate()}"
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent:#{to}")

    %{
      context: %{agent_id: "configured-agent", session_id: Ecto.UUID.generate(), primary: false},
      input: %{"to" => to, "summary" => "Review result", "instructions" => "Continue review"}
    }
  end

  test "persistence keeps the handoff payload and never publishes prematurely", ctx do
    input =
      Map.merge(ctx.input, %{
        "artifacts" => ["@synapsis/agents/configured-agent/reports/result.md"],
        "priority" => "high",
        "constraints" => %{"read_only" => true}
      })

    assert {:ok, message} = AgentCommunication.persist_handoff(input, ctx.context)
    assert {:ok, ^message} = AgentMessages.fetch(message.id)
    assert message.from_agent_id == ctx.context.agent_id
    assert message.to_agent_id == input["to"]
    assert message.session_id == ctx.context.session_id
    assert message.type == "handoff"
    assert message.id != message.ref
    assert Ecto.UUID.cast(message.ref) == {:ok, message.ref}
    assert message.payload == Map.delete(input, "to")
    refute_receive {:agent_envelope, _}, 0

    assert {:ok, receipt} = AgentCommunication.publish_handoff(message, ctx.context)
    assert receipt.status == "persisted"
    assert receipt.message_id == message.id
    assert receipt.mailbox_publication == "published"
    assert_receive {:agent_envelope, envelope}
    assert envelope.type == :handoff
    assert envelope.from == message.from_agent_id
    assert envelope.to == message.to_agent_id
    assert envelope.ref == message.ref
    assert envelope.payload == message.payload
    assert envelope.timestamp == message.inserted_at
  end

  test "optional fields retain defaults without inventing delegation or activation", ctx do
    assert {:ok, message} = AgentCommunication.persist_handoff(ctx.input, ctx.context)

    assert message.payload == %{
             "summary" => ctx.input["summary"],
             "instructions" => ctx.input["instructions"],
             "artifacts" => [],
             "priority" => "normal",
             "constraints" => %{}
           }

    refute_receive {:agent_envelope, _}, 0
  end

  test "closed bounded input rejects forged authority and malformed artifacts before persistence",
       ctx do
    for input <- [
          Map.put(ctx.input, "from", "forged"),
          Map.put(ctx.input, "session_id", Ecto.UUID.generate()),
          Map.put(ctx.input, "path", "/agents/other/handoffs/forged.json"),
          Map.put(ctx.input, "priority", "urgent"),
          Map.put(ctx.input, "summary", String.duplicate("x", 16_385)),
          Map.put(ctx.input, "instructions", String.duplicate("x", 16_385)),
          Map.put(ctx.input, "constraints", %{"value" => String.duplicate("x", 4096)}),
          Map.put(ctx.input, "constraints", %{"value" => self()}),
          Map.put(ctx.input, "artifacts", List.duplicate("@synapsis/shared/report.md", 65)),
          Map.put(
            ctx.input,
            "artifacts",
            List.duplicate("@synapsis/shared/" <> String.duplicate("x", 1000), 64)
          ),
          Map.put(ctx.input, "artifacts", ["@synapsis/shared/" <> String.duplicate("x", 1025)]),
          Map.put(ctx.input, "artifacts", ["@synapsis/../../secret"]),
          Map.put(ctx.input, "artifacts", ["/tmp/private"])
        ] do
      assert {:error, %{code: "invalid_input", effect: "none"}} =
               AgentCommunication.persist_handoff(input, ctx.context, kv: FailingKV)
    end

    assert {:error, %{effect: "none"}} =
             AgentCommunication.persist_handoff(ctx.input, %{
               ctx.context
               | session_id: "/root/run"
             })

    assert {:ok, []} = AgentMessages.query("unread", ctx.input["to"])
    refute_receive {:agent_envelope, _}, 0
  end

  test "an uncertain storage write retains generated identities without publishing", ctx do
    assert {:error, %{code: "storage_failed", effect: "uncertain"} = receipt} =
             AgentCommunication.persist_handoff(ctx.input, ctx.context, kv: FailingKV)

    assert Ecto.UUID.cast(receipt.message_id) == {:ok, receipt.message_id}
    assert Ecto.UUID.cast(receipt.ref) == {:ok, receipt.ref}
    assert receipt.to == ctx.input["to"]
    refute inspect(receipt) =~ "private_storage_diagnostic"
    refute_receive {:agent_envelope, _}, 0
  end

  test "a publication deadline preserves known persistence and never broadcasts late", ctx do
    assert {:ok, message} = AgentCommunication.persist_handoff(ctx.input, ctx.context)

    assert {:error, %{code: "timeout", effect: "completed"} = receipt} =
             AgentCommunication.publish_handoff(message, ctx.context,
               deadline: System.monotonic_time(:millisecond) - 1
             )

    assert receipt.message_id == message.id
    assert receipt.mailbox_publication == "not_published"
    assert {:ok, ^message} = AgentMessages.fetch(message.id)
    refute_receive {:agent_envelope, _}, 0
  end
end
