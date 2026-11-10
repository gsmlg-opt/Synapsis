defmodule Synapsis.Memory.StandingIntents.MatchingFunctionalTest do
  use ExUnit.Case, async: true
  @moduletag :functional

  alias Synapsis.Memory.StandingIntents.Model

  # Independent ordinary literals from OpenClaw 488631c, frozen before implementation.
  @first %{
    "id" => "00000000-0000-4000-8000-000000000301",
    "description" => "  Review <b>café 雪 😀</b>.\nKeep **release** notes.  ",
    "triggerKeywords" => ["release notes"],
    "triggerEmbedding" => nil,
    "scope" => "conversation",
    "channelScope" => "Room:CAFÉ 雪 😀",
    "senderScope" => "ÁLICE:雪 😀",
    "creatorSender" => "Alice",
    "status" => "armed",
    "expiresAt" => 1_800_086_400_000,
    "maxFires" => 3,
    "fireCount" => 0,
    "cooldownSeconds" => 86_400,
    "lastFiredAt" => nil,
    "createdAt" => 1_800_000_000_000,
    "sourceSessionId" => "provenance-301-a"
  }

  @second %{
    "id" => "00000000-0000-4000-8000-000000000302",
    "description" => "Send the next update 🚀.\nUse <em>plain source text</em>.",
    "triggerKeywords" => ["next update"],
    "triggerEmbedding" => nil,
    "scope" => "channel",
    "channelScope" => "slack",
    "senderScope" => "Alice",
    "creatorSender" => "Alice",
    "status" => "armed",
    "expiresAt" => 1_800_172_800_000,
    "maxFires" => 3,
    "fireCount" => 0,
    "cooldownSeconds" => 86_400,
    "lastFiredAt" => nil,
    "createdAt" => 1_800_086_400_000,
    "sourceSessionId" => "provenance-301-b"
  }

  test "tokenization retains multilingual letters numbers underscore hyphen and duplicate tokens" do
    assert Model.tokenize("RELEASE release Café 雪 １２3 user_name phase-2 ΟΣ ΟΣΑ") ==
             ["release", "release", "café", "雪", "１２3", "user_name", "phase-2", "ος", "οσα"]
  end

  test "match preparation preserves first token order and complete encoded scope identities" do
    assert Model.prepare_match(%{
             prompt: "RELEASE release Café 雪 １２3 user_name phase-2 ΟΣ ΟΣΑ",
             channel: "  Room:CAFÉ 雪 😀  ",
             provider: "  TÉLÉGRAM  ",
             account_id: "  账户-雪  ",
             sender_id: "  ÁLICE:雪 😀  ",
             now_ms: 1_800_000_000_000
           }) == %{
             prompt_tokens: ["release", "café", "雪", "１２3", "user_name", "phase-2", "ος", "οσα"],
             fts_query: %{
               kind: :any,
               clauses: [
                 %{kind: :phrase, text: "release"},
                 %{kind: :phrase, text: "café"},
                 %{kind: :phrase, text: "雪"},
                 %{kind: :phrase, text: "１２3"},
                 %{kind: :phrase, text: "user_name"},
                 %{kind: :phrase, text: "phase-2"},
                 %{kind: :phrase, text: "ος"},
                 %{kind: :phrase, text: "οσα"}
               ]
             },
             channel_scopes: [
               ~s(["v1","channel","télégram","账户-雪","télégram"]),
               ~s(["v1","conversation","télégram","账户-雪","Room:CAFÉ 雪 😀"])
             ],
             sender_scope: ~s(["v1","télégram","账户-雪","ÁLICE:雪 😀"]),
             now_ms: 1_800_000_000_000
           }
  end

  test "ordinary prompt preparation represents omitted optional identities and clock as nil" do
    assert Model.prepare_match(%{prompt: "Daily notes"}) == %{
             prompt_tokens: ["daily", "notes"],
             fts_query: %{
               kind: :any,
               clauses: [%{kind: :phrase, text: "daily"}, %{kind: :phrase, text: "notes"}]
             },
             channel_scopes: [],
             sender_scope: nil,
             now_ms: nil
           }
  end

  test "provider preparation uses the default account for an ordinary channel scope" do
    assert Model.prepare_match(%{prompt: "Daily notes", provider: " Slack "}) == %{
             prompt_tokens: ["daily", "notes"],
             fts_query: %{
               kind: :any,
               clauses: [%{kind: :phrase, text: "daily"}, %{kind: :phrase, text: "notes"}]
             },
             channel_scopes: [~s(["v1","channel","slack","default","slack"])],
             sender_scope: nil,
             now_ms: nil
           }
  end

  test "all tokens in a stored keyword match independently of prompt order" do
    assert Model.trigger_matches?(
             %{"triggerKeywords" => ~s(["Release notes"])},
             ["notes", "today", "release"]
           ) == true
  end

  test "one complete synonym matches among alternative stored keywords" do
    assert Model.trigger_matches?(
             %{"triggerKeywords" => ~s(["shipping review","Café 雪"])},
             ["雪", "café", "today"]
           ) == true
  end

  test "one ordinary public intent fits and renders exact raw multiline context" do
    assert Model.context_fits?([@first]) == true

    assert Model.build_context([@first]) ==
             "<standing_intents>\nStanding intent (created 2027-01-15):   Review <b>café 雪 😀</b>.\nKeep **release** notes.  \n</standing_intents>"
  end

  test "two ordinary public intents retain order and UTC creation dates in exact context" do
    assert Model.context_fits?([@first, @second]) == true

    assert Model.build_context([@first, @second]) ==
             "<standing_intents>\nStanding intent (created 2027-01-15):   Review <b>café 雪 😀</b>.\nKeep **release** notes.  \nStanding intent (created 2027-01-16): Send the next update 🚀.\nUse <em>plain source text</em>.\n</standing_intents>"
  end

  test "a user webchat turn is eligible with a session id" do
    assert Model.eligible_turn?(%{
             trigger: "user",
             session_id: "session-301-webchat",
             message_provider: " WebChat "
           }) == true
  end

  test "a provider user turn is eligible with a session key and channel id" do
    assert Model.eligible_turn?(%{
             trigger: "user",
             session_key: "agent:301:channel",
             message_provider: " Slack ",
             channel_id: " channel-301 "
           }) == true
  end

  test "a provider user turn is eligible with a session id and chat id" do
    assert Model.eligible_turn?(%{
             trigger: "user",
             session_id: "session-301-chat",
             message_provider: " Telegram ",
             chat_id: " chat-301 "
           }) == true
  end
end
