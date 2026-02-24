defmodule Synapsis.Session.CompactorTest do
  use Synapsis.DataCase
  alias Synapsis.{Session, Message, Project}
  alias Synapsis.Session.Compactor

  setup do
    {:ok, project} =
      %Project{}
      |> Project.changeset(%{path: "/tmp/compact-test", slug: "compact-test"})
      |> Repo.insert()

    {:ok, session} =
      %Session{}
      |> Session.changeset(%{
        project_id: project.id,
        provider: "anthropic",
        model: "claude-sonnet-4-20250514"
      })
      |> Repo.insert()

    {:ok, session: session, project: project}
  end

  defp insert_messages(session_id, count, opts \\ []) do
    token_count = Keyword.get(opts, :token_count, 1000)
    content_fn = Keyword.get(opts, :content_fn, fn i -> "Message #{i}" end)

    for i <- 1..count do
      %Message{}
      |> Message.changeset(%{
        session_id: session_id,
        role: if(rem(i, 2) == 0, do: "assistant", else: "user"),
        parts: [%Synapsis.Part.Text{content: content_fn.(i)}],
        token_count: token_count
      })
      |> Repo.insert!()
    end
  end

  defp load_messages(session_id) do
    Message
    |> where([m], m.session_id == ^session_id)
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all()
  end

  describe "maybe_compact/3" do
    test "does nothing when total tokens are under the model limit threshold", %{
      session: session
    } do
      # claude-sonnet-4 context_window = 200k, threshold 80% = 160k
      # 5 * 1000 = 5k total, well under 160k
      insert_messages(session.id, 5, token_count: 1_000)

      assert Compactor.maybe_compact(session.id, "claude-sonnet-4-20250514") == :ok

      # Verify no messages were deleted or added
      assert length(load_messages(session.id)) == 5
    end

    test "does nothing when messages are few even with high tokens per message", %{
      session: session
    } do
      # 3 messages with 30k each = 90k, under 160k threshold
      insert_messages(session.id, 3, token_count: 30_000)

      assert Compactor.maybe_compact(session.id, "claude-sonnet-4-20250514") == :ok
      assert length(load_messages(session.id)) == 3
    end

    test "triggers compaction when total tokens exceed 80% of model limit", %{session: session} do
      # 15 * 12k = 180k > 160k (80% of 200k) -> triggers compaction
      insert_messages(session.id, 15, token_count: 12_000)

      assert Compactor.maybe_compact(session.id, "claude-sonnet-4-20250514") == :compacted

      remaining = load_messages(session.id)
      # 5 old messages compacted into 1 summary + 10 kept = 11
      assert length(remaining) == 11
    end

    test "triggers compaction when extra_tokens push total over threshold", %{session: session} do
      # 15 * 10k = 150k total from messages
      # Without extra_tokens: 150k < 160k threshold -> no compaction
      # With 20k extra_tokens: 170k > 160k threshold -> compaction
      insert_messages(session.id, 15, token_count: 10_000)

      assert Compactor.maybe_compact(session.id, "claude-sonnet-4-20250514") == :ok

      assert Compactor.maybe_compact(session.id, "claude-sonnet-4-20250514", extra_tokens: 20_000) ==
               :compacted
    end

    test "uses default 128k limit for unknown model", %{session: session} do
      # Default limit 128k, threshold 80% = 102.4k
      # 15 * 8k = 120k > 102.4k -> triggers compaction
      insert_messages(session.id, 15, token_count: 8_000)

      assert Compactor.maybe_compact(session.id, "unknown-model-xyz") == :compacted
    end

    test "does nothing for unknown model when under default threshold", %{session: session} do
      # Default limit 128k, threshold 80% = 102.4k
      # 5 * 1k = 5k, well under 102.4k
      insert_messages(session.id, 5, token_count: 1_000)

      assert Compactor.maybe_compact(session.id, "unknown-model-xyz") == :ok
      assert length(load_messages(session.id)) == 5
    end

    test "returns :ok when session has no messages", %{session: session} do
      assert Compactor.maybe_compact(session.id, "claude-sonnet-4-20250514") == :ok
    end
  end

  describe "compact/2" do
    test "compacts old messages and inserts a summary message", %{session: session} do
      insert_messages(session.id, 15,
        token_count: 1000,
        content_fn: fn i -> "Message #{i} content with enough text to count" end
      )

      messages = load_messages(session.id)
      assert length(messages) == 15

      result = Compactor.compact(session.id, messages)
      assert result == :compacted

      remaining = load_messages(session.id)
      # 15 - 10 kept = 5 compacted, replaced by 1 summary => 10 + 1 = 11
      assert length(remaining) == 11
    end

    test "creates a summary message with system role containing compacted content", %{
      session: session
    } do
      insert_messages(session.id, 15, content_fn: fn i -> "Important detail number #{i}" end)

      messages = load_messages(session.id)
      Compactor.compact(session.id, messages)

      remaining = load_messages(session.id)

      summary_msg = Enum.find(remaining, fn m -> m.role == "system" end)
      assert summary_msg != nil

      [%Synapsis.Part.Text{content: summary_text}] = summary_msg.parts
      assert summary_text =~ "[Context Summary -"
      assert summary_text =~ "messages compacted]"
      assert summary_text =~ "[End Summary]"
      # The summary should include content from the compacted messages
      assert summary_text =~ "Important detail number 1"
    end

    test "summary message includes role tags for each compacted message", %{session: session} do
      insert_messages(session.id, 12)
      messages = load_messages(session.id)

      # 12 - 10 kept = 2 messages compacted
      Compactor.compact(session.id, messages)

      remaining = load_messages(session.id)
      summary_msg = Enum.find(remaining, fn m -> m.role == "system" end)
      assert summary_msg != nil

      [%Synapsis.Part.Text{content: summary_text}] = summary_msg.parts
      # First two messages: user (i=1), assistant (i=2)
      assert summary_text =~ "[user]"
      assert summary_text =~ "[assistant]"
      assert summary_text =~ "[Context Summary - 2 messages compacted]"
    end

    test "does nothing when fewer messages than keep_recent threshold", %{session: session} do
      insert_messages(session.id, 5, token_count: 100)

      messages = load_messages(session.id)
      assert Compactor.compact(session.id, messages) == :ok

      # No messages removed, no summary added
      assert length(load_messages(session.id)) == 5
    end

    test "does nothing with exactly keep_recent (10) messages", %{session: session} do
      insert_messages(session.id, 10)

      messages = load_messages(session.id)
      assert Compactor.compact(session.id, messages) == :ok
      assert length(load_messages(session.id)) == 10
    end

    test "does nothing with empty message list", %{session: session} do
      assert Compactor.compact(session.id, []) == :ok
    end

    test "handles ToolUse, ToolResult, Reasoning, and unknown part types", %{session: session} do
      parts_cycle = [
        [
          %Synapsis.Part.ToolUse{
            tool: "bash",
            tool_use_id: "tid1",
            input: %{"cmd" => "ls"},
            status: "done"
          }
        ],
        [%Synapsis.Part.ToolResult{tool_use_id: "tid1", content: "file.txt", is_error: false}],
        [%Synapsis.Part.Reasoning{content: "Thinking step..."}],
        [%Synapsis.Part.Image{media_type: "image/png", data: "abc"}]
      ]

      for i <- 1..15 do
        parts = Enum.at(parts_cycle, rem(i - 1, length(parts_cycle)))

        %Message{}
        |> Message.changeset(%{
          session_id: session.id,
          role: if(rem(i, 2) == 0, do: "assistant", else: "user"),
          parts: parts,
          token_count: 1000
        })
        |> Repo.insert!()
      end

      messages = load_messages(session.id)
      assert Compactor.compact(session.id, messages) == :compacted

      remaining = load_messages(session.id)
      summary_msg = Enum.find(remaining, fn m -> m.role == "system" end)
      assert summary_msg != nil

      [%Synapsis.Part.Text{content: summary_text}] = summary_msg.parts
      # ToolUse should appear in summary
      assert summary_text =~ "[tool_use: bash"
    end

    test "summary has a positive token_count estimate", %{session: session} do
      insert_messages(session.id, 15, content_fn: fn i -> "Content block #{i} with details" end)

      messages = load_messages(session.id)
      Compactor.compact(session.id, messages)

      remaining = load_messages(session.id)
      summary_msg = Enum.find(remaining, fn m -> m.role == "system" end)
      assert summary_msg != nil
      assert summary_msg.token_count > 0
    end

    test "deletes only the compacted messages, not the kept ones", %{session: session} do
      _msgs = insert_messages(session.id, 15)
      messages = load_messages(session.id)

      # The last 10 messages should be kept
      kept_ids =
        messages
        |> Enum.take(-10)
        |> Enum.map(& &1.id)
        |> MapSet.new()

      Compactor.compact(session.id, messages)

      remaining = load_messages(session.id)
      remaining_ids = Enum.map(remaining, & &1.id) |> MapSet.new()

      # All originally kept messages should still exist
      assert MapSet.subset?(kept_ids, remaining_ids)

      # The compacted message IDs (first 5) should no longer exist
      compacted_ids =
        messages
        |> Enum.take(5)
        |> Enum.map(& &1.id)

      for id <- compacted_ids do
        refute MapSet.member?(remaining_ids, id)
      end
    end
  end
end
