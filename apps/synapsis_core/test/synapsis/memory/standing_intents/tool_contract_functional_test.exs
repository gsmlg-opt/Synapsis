defmodule Synapsis.Memory.StandingIntents.ToolContractFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Memory.StandingIntent.Store
  alias Synapsis.Memory.StandingIntents
  alias Synapsis.Memory.StandingIntents.ToolContract

  @now 1_800_000_000_000
  @expiry 1_807_776_000_000
  @id "00000000-0000-4000-8000-000000000302"
  @agent "10000000-0000-4000-8000-000000000302"
  @pin "488631c18fae7cc541ba8fc8beff6cbb0438787b"
  @guidance "The system injects the reminder automatically when it triggers. Do not deliver it early or cancel it unless the user asks."

  @create_text ~S"""
  {
    "intent": {
      "id": "00000000-0000-4000-8000-000000000302",
      "description": "Review <b>café 雪 😀</b>.",
      "triggerKeywords": [
        "release notes",
        "ος"
      ],
      "triggerEmbedding": null,
      "scope": "channel",
      "channelScope": "slack",
      "senderScope": "ÁLICE:雪 😀",
      "creatorSender": "ÁLICE:雪 😀",
      "status": "armed",
      "expiresAt": 1807776000000,
      "maxFires": 3,
      "fireCount": 0,
      "cooldownSeconds": 86400,
      "lastFiredAt": null,
      "createdAt": 1800000000000,
      "sourceSessionId": "  source:302  "
    },
    "message": "Intent is armed for this channel. The system injects the reminder automatically when it triggers. Do not deliver it early or cancel it unless the user asks."
  }
  """
  @create_text String.trim_trailing(@create_text, "\n")

  @list_text ~S"""
  {
    "intents": [
      {
        "id": "00000000-0000-4000-8000-000000000302",
        "description": "Review <b>café 雪 😀</b>.",
        "triggerKeywords": [
          "release notes",
          "ος"
        ],
        "triggerEmbedding": null,
        "scope": "channel",
        "channelScope": "slack",
        "senderScope": "ÁLICE:雪 😀",
        "creatorSender": "ÁLICE:雪 😀",
        "status": "armed",
        "expiresAt": 1807776000000,
        "maxFires": 3,
        "fireCount": 0,
        "cooldownSeconds": 86400,
        "lastFiredAt": null,
        "createdAt": 1800000000000,
        "sourceSessionId": "  source:302  "
      }
    ]
  }
  """
  @list_text String.trim_trailing(@list_text, "\n")

  test "default preparation trims ECMAScript whitespace and preserves keyword order after lowercase deduplication" do
    params = %{
      "action" => "create",
      "description" => "\uFEFF Review <b>café 雪 😀</b>. \u3000",
      "triggerKeywords" => [" Release Notes ", "RELEASE NOTES", " ΟΣ ", "ος"]
    }

    assert prepare(params) == %{
             "action" => "create",
             "agentId" => @agent,
             "scope" => "channel",
             "nowMs" => @now,
             "prepared" => prepared()
           }
  end

  test "conversation preparation preserves complete scope identities and parses an RFC date with scientific snake numbers" do
    params = %{
      "action" => "create",
      "description" => "  Review café.\nKeep notes.  ",
      "triggerKeywords" => [" ΟΣ ", "ΟΣΑ", "ΟΣ"],
      "scope" => "conversation",
      "senderScope" => "sender",
      "expiresAt" => "Tue, 01 Jan 2030 00:00:00 GMT",
      "max_fires" => " +2e0 ",
      "cooldown_seconds" => " +6.0e1 "
    }

    options = %{
      "agentId" => @agent,
      "provider" => " TÉLÉGRAM ",
      "accountId" => " 账户-雪 ",
      "conversationId" => " Room:CAFÉ 雪 😀 ",
      "senderId" => " ÁLICE:雪 😀 ",
      "sourceSessionId" => "  provenance:302  "
    }

    assert prepare(params, options) == %{
             "action" => "create",
             "agentId" => @agent,
             "scope" => "conversation",
             "nowMs" => @now,
             "prepared" => %{
               "description" => "Review café.\nKeep notes.",
               "triggerKeywords" => ["ος", "οσα"],
               "channelScope" => ~s(["v1","conversation","télégram","账户-雪","Room:CAFÉ 雪 😀"]),
               "senderScope" => ~s(["v1","télégram","账户-雪","ÁLICE:雪 😀"]),
               "creatorSender" => "ÁLICE:雪 😀",
               "expiresAt" => 1_893_456_000_000,
               "maxFires" => 2,
               "cooldownSeconds" => 60,
               "sourceSessionId" => "  provenance:302  "
             }
           }
  end

  test "native offset ISO parsing retains the exact instant" do
    params = base_params() |> Map.put("expiresAt", "2030-01-01T08:30:00+08:30")

    assert prepare(params) == %{
             "action" => "create",
             "agentId" => @agent,
             "scope" => "channel",
             "nowMs" => @now,
             "prepared" => %{prepared() | "expiresAt" => 1_893_456_000_000}
           }
  end

  test "anywhere and anyone remain independent while creation records the host sender" do
    params = base_params() |> Map.merge(%{"scope" => "anywhere", "senderScope" => "anyone"})

    assert prepare(params) == %{
             "action" => "create",
             "agentId" => @agent,
             "scope" => "anywhere",
             "nowMs" => @now,
             "prepared" => %{prepared() | "channelScope" => nil, "senderScope" => nil}
           }
  end

  test "blank and null optional number values resolve to source defaults" do
    params = base_params() |> Map.merge(%{"maxFires" => " \t ", "cooldownSeconds" => nil})

    assert prepare(params)["prepared"] == prepared()
  end

  test "a present camel key takes precedence over a snake key even when camel is null" do
    params =
      base_params()
      |> Map.merge(%{
        "maxFires" => nil,
        "max_fires" => 8,
        "cooldownSeconds" => "60.0",
        "cooldown_seconds" => 120
      })

    assert prepare(params)["prepared"] == %{prepared() | "cooldownSeconds" => 60}
  end

  test "ordinary numeric camel options and an omitted host source session retain their representation" do
    params = base_params() |> Map.merge(%{"maxFires" => 4, "cooldownSeconds" => 90})
    options = options() |> Map.delete("sourceSessionId")

    assert prepare(params, options)["prepared"] ==
             prepared()
             |> Map.delete("sourceSessionId")
             |> Map.merge(%{"maxFires" => 4, "cooldownSeconds" => 90})
  end

  test "list preparation preserves the distinction between an omitted and selected status" do
    assert prepare(%{"action" => "list"}) == %{"action" => "list", "agentId" => @agent}

    assert prepare(%{"action" => "list", "status" => "armed"}) == %{
             "action" => "list",
             "agentId" => @agent,
             "status" => "armed"
           }
  end

  test "create result restores every original public field and exact JSON text order" do
    value = public(@id)

    assert run(%{
             "operation" => "format",
             "action" => "create",
             "scope" => "channel",
             "value" => value
           }) == %{
             "content" => [%{"type" => "text", "text" => @create_text}],
             "details" => %{
               "intent" => value,
               "message" => "Intent is armed for this channel. " <> @guidance
             }
           }
  end

  test "all source scope messages retain their complete automatic delivery guidance" do
    for {scope, phrase} <- [{"conversation", "for this conversation"}, {"anywhere", "everywhere"}] do
      value = public(@id) |> Map.put("scope", scope)

      result =
        run(%{"operation" => "format", "action" => "create", "scope" => scope, "value" => value})

      assert result["details"] == %{
               "intent" => value,
               "message" => "Intent is armed #{phrase}. " <> @guidance
             }

      assert result["content"] == [
               %{
                 "type" => "text",
                 "text" =>
                   String.replace(
                     @create_text,
                     "\"scope\": \"channel\"",
                     "\"scope\": \"#{scope}\""
                   )
                   |> String.replace("for this channel", phrase)
               }
             ]
    end
  end

  test "list result retains complete public projections and exact nested JSON indentation" do
    assert run(%{"operation" => "format", "action" => "list", "value" => [public(@id)]}) == %{
             "content" => [%{"type" => "text", "text" => @list_text}],
             "details" => %{"intents" => [public(@id)]}
           }
  end

  test "prepared values flow through the real facade and raw Concord row before create and list formatting" do
    assert :ok = Synapsis.Session.Store.ensure_started()
    agent = Ecto.UUID.generate()
    deadline = deadline()
    context = %{deadline: deadline, assert_live: fn -> :ok end, now_ms: @now}

    assert {:ok, ready, receipt} =
             ToolContract.run(
               %{
                 "operation" => "prepare",
                 "params" => base_params(),
                 "options" => %{options() | "agentId" => agent},
                 "nowMs" => @now
               },
               deadline
             )

    assert_receipt(receipt)

    assert ready == %{
             "action" => "create",
             "agentId" => agent,
             "scope" => "channel",
             "nowMs" => @now,
             "prepared" => prepared()
           }

    assert {:ok, %{value: value, next_due_at: nil}} =
             StandingIntents.create(ready["agentId"], ready["prepared"], context)

    id = value["id"]
    assert {:ok, ^id} = Ecto.UUID.cast(id)
    assert value == public(id)
    assert {:ok, snapshot} = Store.snapshot(agent, deadline)
    assert Store.generation(snapshot) == 1

    assert Store.get(snapshot, id, deadline) ==
             {:ok,
              %{
                "id" => id,
                "description" => "Review <b>café 雪 😀</b>.",
                "triggerKeywords" => ~s(["release notes","ος"]),
                "triggerEmbedding" => nil,
                "channelScope" => ~s(["v1","channel","slack","default","slack"]),
                "senderScope" => ~s(["v1","slack","default","ÁLICE:雪 😀"]),
                "creatorSender" => "ÁLICE:雪 😀",
                "status" => "armed",
                "expiresAt" => @expiry,
                "maxFires" => 3,
                "fireCount" => 0,
                "cooldownSeconds" => 86_400,
                "lastFiredAt" => nil,
                "createdAt" => @now,
                "sourceSessionId" => "  source:302  "
              }}

    assert run(
             %{
               "operation" => "format",
               "action" => "create",
               "scope" => "channel",
               "value" => value
             },
             deadline
           ) == %{
             "content" => [%{"type" => "text", "text" => String.replace(@create_text, @id, id)}],
             "details" => %{
               "intent" => value,
               "message" => "Intent is armed for this channel. " <> @guidance
             }
           }

    assert prepare(
             %{"action" => "list", "status" => "armed"},
             %{options() | "agentId" => agent},
             deadline
           ) == %{"action" => "list", "agentId" => agent, "status" => "armed"}

    assert {:ok, %{value: [^value], next_due_at: @expiry}} =
             StandingIntents.list(agent, [status: "armed"], context)

    assert run(%{"operation" => "format", "action" => "list", "value" => [value]}, deadline) == %{
             "content" => [%{"type" => "text", "text" => String.replace(@list_text, @id, id)}],
             "details" => %{"intents" => [value]}
           }
  end

  defp prepare(params, options \\ options(), deadline \\ deadline()) do
    run(
      %{"operation" => "prepare", "params" => params, "options" => options, "nowMs" => @now},
      deadline
    )
  end

  defp run(request, deadline \\ deadline()) do
    assert {:ok, result, receipt} = ToolContract.run(request, deadline)
    assert_receipt(receipt)
    result
  end

  defp assert_receipt(receipt) do
    assert receipt.reference_commit == @pin
    assert receipt.exit_status == 0
    assert receipt.closed == true
    assert is_integer(receipt.os_pid) and receipt.os_pid > 0
    refute File.exists?("/proc/#{receipt.os_pid}")
    assert Enum.sort(Map.keys(receipt.runtime)) == ~w(arch cldr icu node platform unicode v8)
    assert Enum.all?(Map.values(receipt.runtime), &(is_binary(&1) and byte_size(&1) > 0))
  end

  defp base_params do
    %{
      "action" => "create",
      "description" => " Review <b>café 雪 😀</b>. ",
      "triggerKeywords" => [" Release Notes ", " ΟΣ "]
    }
  end

  defp options do
    %{
      "agentId" => @agent,
      "provider" => " Slack ",
      "senderId" => " ÁLICE:雪 😀 ",
      "sourceSessionId" => "  source:302  "
    }
  end

  defp prepared do
    %{
      "description" => "Review <b>café 雪 😀</b>.",
      "triggerKeywords" => ["release notes", "ος"],
      "channelScope" => ~s(["v1","channel","slack","default","slack"]),
      "senderScope" => ~s(["v1","slack","default","ÁLICE:雪 😀"]),
      "creatorSender" => "ÁLICE:雪 😀",
      "expiresAt" => @expiry,
      "maxFires" => 3,
      "cooldownSeconds" => 86_400,
      "sourceSessionId" => "  source:302  "
    }
  end

  defp public(id) do
    %{
      "id" => id,
      "description" => "Review <b>café 雪 😀</b>.",
      "triggerKeywords" => ["release notes", "ος"],
      "triggerEmbedding" => nil,
      "scope" => "channel",
      "channelScope" => "slack",
      "senderScope" => "ÁLICE:雪 😀",
      "creatorSender" => "ÁLICE:雪 😀",
      "status" => "armed",
      "expiresAt" => @expiry,
      "maxFires" => 3,
      "fireCount" => 0,
      "cooldownSeconds" => 86_400,
      "lastFiredAt" => nil,
      "createdAt" => @now,
      "sourceSessionId" => "  source:302  "
    }
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000
end
