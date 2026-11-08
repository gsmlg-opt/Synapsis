defmodule Synapsis.Session.InputContextFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Session.InputContext

  test "captures complete explicit identities without changing their bytes" do
    session_id = Ecto.UUID.generate()

    identity = %{
      provider: " Host/聊天 ",
      account_id: "账户/Aa-01 ",
      conversation_id: " 会话/Δ-02",
      sender_id: "发送者/É-03 "
    }

    assert {:ok, context} = InputContext.capture(session_id, identity)
    assert {:ok, input_id} = Ecto.UUID.cast(context["input_id"])

    assert context == %{
             "version" => 1,
             "trigger" => "user",
             "provider" => identity.provider,
             "account_id" => identity.account_id,
             "conversation_id" => identity.conversation_id,
             "sender_id" => identity.sender_id,
             "source_session_id" => session_id,
             "input_id" => input_id
           }

    assert :ok = InputContext.validate(context, session_id)
  end

  test "captures a fresh input identity for each ordinary prompt" do
    session_id = Ecto.UUID.generate()
    identity = explicit_identity()

    assert {:ok, first} = InputContext.capture(session_id, identity)
    assert {:ok, second} = InputContext.capture(session_id, identity)
    assert {:ok, _} = Ecto.UUID.cast(first["input_id"])
    assert {:ok, _} = Ecto.UUID.cast(second["input_id"])
    assert first["input_id"] != second["input_id"]
    assert Map.delete(first, "input_id") == Map.delete(second, "input_id")
  end

  test "keeps the captured map valid after a JSON round trip" do
    session_id = Ecto.UUID.generate()
    assert {:ok, captured} = InputContext.capture(session_id, explicit_identity())

    decoded = captured |> Jason.encode!() |> Jason.decode!()

    assert decoded == captured
    assert :ok = InputContext.validate(decoded, session_id)
  end

  defp explicit_identity do
    %{
      provider: "fixture-host",
      account_id: "fixture-account",
      conversation_id: "fixture-conversation",
      sender_id: "fixture-human"
    }
  end
end
