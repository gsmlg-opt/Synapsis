defmodule Synapsis.Memory.StandingIntents.ModelFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Memory.StandingIntents.Model

  @id "00000000-0000-4000-8000-000000000299"
  @now 1_800_000_000_000

  @armed %{
    "id" => @id,
    "description" => "Review the release notes: café 雪 😀.",
    "triggerKeywords" => ~s(["release notes","café 雪"]),
    "triggerEmbedding" => nil,
    "channelScope" => nil,
    "senderScope" => nil,
    "creatorSender" => "Alice",
    "status" => "armed",
    "expiresAt" => 1_800_000_600_000,
    "maxFires" => 2,
    "fireCount" => 0,
    "cooldownSeconds" => 60,
    "lastFiredAt" => nil,
    "createdAt" => @now,
    "sourceSessionId" => "provenance-only-299"
  }

  @fired %{
    "id" => @id,
    "description" => "Review the release notes: café 雪 😀.",
    "triggerKeywords" => ~s(["release notes","café 雪"]),
    "triggerEmbedding" => nil,
    "channelScope" => nil,
    "senderScope" => nil,
    "creatorSender" => "Alice",
    "status" => "fired",
    "expiresAt" => 1_800_000_600_000,
    "maxFires" => 2,
    "fireCount" => 1,
    "cooldownSeconds" => 60,
    "lastFiredAt" => 1_800_000_001_000,
    "createdAt" => @now,
    "sourceSessionId" => "provenance-only-299"
  }

  @rearmed %{
    "id" => @id,
    "description" => "Review the release notes: café 雪 😀.",
    "triggerKeywords" => ~s(["release notes","café 雪"]),
    "triggerEmbedding" => nil,
    "channelScope" => nil,
    "senderScope" => nil,
    "creatorSender" => "Alice",
    "status" => "armed",
    "expiresAt" => 1_800_000_600_000,
    "maxFires" => 2,
    "fireCount" => 1,
    "cooldownSeconds" => 60,
    "lastFiredAt" => 1_800_000_001_000,
    "createdAt" => @now,
    "sourceSessionId" => "provenance-only-299"
  }

  @done %{
    "id" => @id,
    "description" => "Review the release notes: café 雪 😀.",
    "triggerKeywords" => ~s(["release notes","café 雪"]),
    "triggerEmbedding" => nil,
    "channelScope" => nil,
    "senderScope" => nil,
    "creatorSender" => "Alice",
    "status" => "done",
    "expiresAt" => 1_800_000_600_000,
    "maxFires" => 2,
    "fireCount" => 2,
    "cooldownSeconds" => 60,
    "lastFiredAt" => 1_800_000_062_000,
    "createdAt" => @now,
    "sourceSessionId" => "provenance-only-299"
  }

  test "tagged scope strings preserve identities with JavaScript trim and provider lowercase" do
    assert Model.encode_channel_scope("conversation", %{
             provider: "\uFEFF TÉLÉGRAM \u3000",
             account_id: "\u00A0 账户-雪 \uFEFF",
             conversation_id: "\uFEFF Room:CAFÉ 雪 😀 \u3000"
           }) ==
             {:ok, ~s(["v1","conversation","télégram","账户-雪","Room:CAFÉ 雪 😀"])}

    assert Model.encode_channel_scope("channel", %{
             provider: "\uFEFF TÉLÉGRAM \u3000",
             account_id: "\u00A0 \uFEFF",
             conversation_id: "Room:CAFÉ 雪 😀"
           }) == {:ok, ~s(["v1","channel","télégram","default","télégram"])}

    assert Model.encode_sender_scope(%{
             provider: "\uFEFF TÉLÉGRAM \u3000",
             account_id: nil,
             sender_id: "\uFEFF ÁLICE:雪 😀 \u3000"
           }) == {:ok, ~s(["v1","télégram","default","ÁLICE:雪 😀"])}
  end

  test "prepared creation supplies source defaults and projects a complete anywhere intent" do
    assert {:ok, row} =
             Model.new_row(
               @id,
               %{
                 "description" => "  Review café 雪 😀.  ",
                 "triggerKeywords" => ["Release Notes", "café 雪"],
                 "creatorSender" => "\uFEFF Álice 雪 \u3000"
               },
               @now
             )

    assert row == %{
             "id" => @id,
             "description" => "  Review café 雪 😀.  ",
             "triggerKeywords" => ~s(["Release Notes","café 雪"]),
             "triggerEmbedding" => nil,
             "channelScope" => nil,
             "senderScope" => nil,
             "creatorSender" => "Álice 雪",
             "status" => "armed",
             "expiresAt" => 1_807_776_000_000,
             "maxFires" => 3,
             "fireCount" => 0,
             "cooldownSeconds" => 86_400,
             "lastFiredAt" => nil,
             "createdAt" => @now,
             "sourceSessionId" => nil
           }

    assert Model.to_intent(row) == %{
             "id" => @id,
             "description" => "  Review café 雪 😀.  ",
             "triggerKeywords" => ["Release Notes", "café 雪"],
             "triggerEmbedding" => nil,
             "scope" => "anywhere",
             "channelScope" => nil,
             "senderScope" => nil,
             "creatorSender" => "Álice 雪",
             "status" => "armed",
             "expiresAt" => 1_807_776_000_000,
             "maxFires" => 3,
             "fireCount" => 0,
             "cooldownSeconds" => 86_400,
             "lastFiredAt" => nil,
             "createdAt" => @now,
             "sourceSessionId" => nil
           }
  end

  test "custom prepared creation retains encoded scopes and provenance through projection" do
    assert {:ok, row} =
             Model.new_row(
               @id,
               %{
                 "description" => "Review the release notes: café 雪 😀.",
                 "triggerKeywords" => ["release notes", "café 雪"],
                 "channelScope" =>
                   ~s(["v1","conversation","telegram","Account-雪","Room:CAFÉ 雪 😀"]),
                 "senderScope" => ~s(["v1","telegram","Account-雪","ÁLICE:雪 😀"]),
                 "creatorSender" => "  Alice  ",
                 "expiresAt" => 1_800_086_400_000,
                 "maxFires" => 2,
                 "cooldownSeconds" => 60,
                 "sourceSessionId" => "  provenance:雪/299  "
               },
               @now
             )

    assert row == %{
             "id" => @id,
             "description" => "Review the release notes: café 雪 😀.",
             "triggerKeywords" => ~s(["release notes","café 雪"]),
             "triggerEmbedding" => nil,
             "channelScope" => ~s(["v1","conversation","telegram","Account-雪","Room:CAFÉ 雪 😀"]),
             "senderScope" => ~s(["v1","telegram","Account-雪","ÁLICE:雪 😀"]),
             "creatorSender" => "Alice",
             "status" => "armed",
             "expiresAt" => 1_800_086_400_000,
             "maxFires" => 2,
             "fireCount" => 0,
             "cooldownSeconds" => 60,
             "lastFiredAt" => nil,
             "createdAt" => @now,
             "sourceSessionId" => "  provenance:雪/299  "
           }

    assert Model.to_intent(row) == %{
             "id" => @id,
             "description" => "Review the release notes: café 雪 😀.",
             "triggerKeywords" => ["release notes", "café 雪"],
             "triggerEmbedding" => nil,
             "scope" => "conversation",
             "channelScope" => "Room:CAFÉ 雪 😀",
             "senderScope" => "ÁLICE:雪 😀",
             "creatorSender" => "Alice",
             "status" => "armed",
             "expiresAt" => 1_800_086_400_000,
             "maxFires" => 2,
             "fireCount" => 0,
             "cooldownSeconds" => 60,
             "lastFiredAt" => nil,
             "createdAt" => @now,
             "sourceSessionId" => "  provenance:雪/299  "
           }
  end

  test "channel projection exposes its final provider identity with source null fields" do
    row = %{
      "id" => @id,
      "description" => "Review the release notes: café 雪 😀.",
      "triggerKeywords" => ~s(["release notes","café 雪"]),
      "triggerEmbedding" => nil,
      "channelScope" => ~s(["v1","channel","télégram","default","télégram"]),
      "senderScope" => nil,
      "creatorSender" => "Alice",
      "status" => "armed",
      "expiresAt" => 1_800_000_600_000,
      "maxFires" => 2,
      "fireCount" => 0,
      "cooldownSeconds" => 60,
      "lastFiredAt" => nil,
      "createdAt" => @now,
      "sourceSessionId" => "provenance-only-299"
    }

    assert Model.to_intent(row) == %{
             "id" => @id,
             "description" => "Review the release notes: café 雪 😀.",
             "triggerKeywords" => ["release notes", "café 雪"],
             "triggerEmbedding" => nil,
             "scope" => "channel",
             "channelScope" => "télégram",
             "senderScope" => nil,
             "creatorSender" => "Alice",
             "status" => "armed",
             "expiresAt" => 1_800_000_600_000,
             "maxFires" => 2,
             "fireCount" => 0,
             "cooldownSeconds" => 60,
             "lastFiredAt" => nil,
             "createdAt" => @now,
             "sourceSessionId" => "provenance-only-299"
           }
  end

  test "ordinary firing cools down rearms and completes while retaining the whole row" do
    assert Model.maintain(@armed, 1_800_000_000_500) == @armed
    assert Model.fire(@armed, 1_800_000_001_000) == @fired
    assert Model.maintain(@fired, 1_800_000_031_000) == @fired
    assert Model.maintain(@fired, 1_800_000_061_000) == @rearmed
    assert Model.fire(@rearmed, 1_800_000_062_000) == @done
    assert Model.maintain(@done, 1_800_000_123_000) == @done
  end

  test "ordinary expiry affects active statuses and preserves completed or expired rows" do
    expired = %{
      "id" => @id,
      "description" => "Review the release notes: café 雪 😀.",
      "triggerKeywords" => ~s(["release notes","café 雪"]),
      "triggerEmbedding" => nil,
      "channelScope" => nil,
      "senderScope" => nil,
      "creatorSender" => "Alice",
      "status" => "expired",
      "expiresAt" => 1_800_000_600_000,
      "maxFires" => 2,
      "fireCount" => 0,
      "cooldownSeconds" => 60,
      "lastFiredAt" => nil,
      "createdAt" => @now,
      "sourceSessionId" => "provenance-only-299"
    }

    for status <- ["pending", "armed", "fired"] do
      assert Model.maintain(%{@armed | "status" => status}, 1_800_000_600_000) == expired
    end

    assert Model.maintain(expired, 1_800_000_700_000) == expired
    assert Model.maintain(@done, 1_800_000_700_000) == @done
  end

  test "maintained rows report the next ordinary expiry or cooldown and no terminal deadline" do
    assert Model.next_due([]) == :infinity

    armed = Model.maintain(@armed, 1_800_000_001_000)
    fired = Model.maintain(@fired, 1_800_000_001_000)

    assert Model.next_due([armed]) == 1_800_000_600_000
    assert Model.next_due([armed, fired]) == 1_800_000_061_000

    rearmed = Model.maintain(@fired, 1_800_000_061_000)
    assert Model.next_due([rearmed]) == 1_800_000_600_000

    fired_without_timestamp =
      Model.maintain(%{@armed | "status" => "fired"}, 1_800_000_001_000)

    assert Model.next_due([fired_without_timestamp]) == 1_800_000_600_000

    expired = Model.maintain(@armed, 1_800_000_600_000)
    done = Model.maintain(@done, 1_800_000_700_000)
    assert Model.next_due([expired, done]) == :infinity
  end
end
