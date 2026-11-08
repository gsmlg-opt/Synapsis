defmodule Synapsis.Session.OperatorInputContextFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Session.InputContext

  test "captures each ordinary operator origin with distinct portable input identities" do
    session_id = Ecto.UUID.generate()
    requester = " 操作者/É-聊天 "

    contexts =
      for origin <- ~w(rest channel liveview) do
        assert {:ok, context} =
                 InputContext.capture_operator(session_id, %{
                   requester_id: requester,
                   origin: origin
                 })

        assert {:ok, input_id} = Ecto.UUID.cast(context["input_id"])

        assert context == %{
                 "version" => 1,
                 "kind" => "operator",
                 "trigger" => "user",
                 "requester_id" => requester,
                 "origin" => origin,
                 "source_session_id" => session_id,
                 "input_id" => input_id
               }

        assert :ok = InputContext.validate(context, session_id)
        assert Jason.decode!(Jason.encode!(context)) == context
        assert :ok = InputContext.validate(Jason.decode!(Jason.encode!(context)), session_id)
        context
      end

    assert length(Enum.uniq_by(contexts, & &1["input_id"])) == 3

    assert {:ok, next} =
             InputContext.capture_operator(session_id, %{requester_id: requester, origin: "rest"})

    assert {:ok, _} = Ecto.UUID.cast(next["input_id"])
    assert next["input_id"] != hd(contexts)["input_id"]
    assert Map.delete(next, "input_id") == Map.delete(hd(contexts), "input_id")
  end

  test "retains the existing complete messaging variant and exact identity bytes" do
    id = Ecto.UUID.generate()

    identity = %{
      provider: " Host/聊天 ",
      account_id: "账户/Aa-01 ",
      conversation_id: " 会话/Δ-02",
      sender_id: "发送者/É-03 "
    }

    assert {:ok, context} = InputContext.capture(id, identity)
    assert {:ok, input_id} = Ecto.UUID.cast(context["input_id"])

    assert context == %{
             "version" => 1,
             "trigger" => "user",
             "provider" => " Host/聊天 ",
             "account_id" => "账户/Aa-01 ",
             "conversation_id" => " 会话/Δ-02",
             "sender_id" => "发送者/É-03 ",
             "source_session_id" => id,
             "input_id" => input_id
           }

    assert :ok = InputContext.validate(context, id)
    assert Jason.decode!(Jason.encode!(context)) == context
  end
end
