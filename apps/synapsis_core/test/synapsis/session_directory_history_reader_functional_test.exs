defmodule Synapsis.SessionDirectoryHistoryReaderFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Message
  alias Synapsis.Part.{Reasoning, Text, ToolResult, ToolUse}
  alias Synapsis.Session.{EventReply, ReadSnapshot, Store}
  alias Synapsis.SessionDirectory.History.Reader
  alias Synapsis.SessionDirectoryHistoryTestSupport, as: Support

  setup do
    assert :ok = Store.ensure_started()
    :ok
  end

  test "literal shared protocol messages retain real UUIDs, roles, timestamps and sparse indices" do
    fixture = Support.fixture()

    turns =
      Enum.map(fixture["readResult"]["rows"], fn row ->
        source = row["message"]
        {:ok, timestamp, 0} = DateTime.from_iso8601(source["timestamp"])

        message = %Message{
          id: source["__openclaw"]["id"],
          inserted_at: timestamp,
          role: source["role"],
          parts: Enum.map(source["content"], &%Text{content: &1["text"]})
        }

        {row["index"], message}
      end)

    id =
      Support.persist(turns, %{
        id: fixture["historyStart"]["target"]["sessionId"],
        title: "Ordinary history"
      })

    entry = Support.capture(id, System.monotonic_time(:millisecond) + 5_000)

    {result, events} =
      Support.observe(fn ->
        with {:ok, view} <- Reader.open(entry, 2, "t1"),
             do: Reader.read(view, fixture["initialRead"])
      end)

    assert {:ok, reply} = result

    assert Map.take(reply, ~w(type protocol historyProtocol id readId slot totalTurns)) ==
             Map.take(
               fixture["readResult"],
               ~w(type protocol historyProtocol id readId slot totalTurns)
             )

    assert is_binary(reply["viewId"]) and reply["viewId"] != ""
    assert reply["rows"] == fixture["readResult"]["rows"]
    assert [[handle, index_opts]] = Support.calls(events, ReadSnapshot, :tail_index)
    assert handle == entry.handle
    assert index_opts[:retain] == 20 * 2 + 20 + 8_000 + 1
    assert index_opts[:max_bytes] == 1_048_576
    Support.assert_fixed_reads(events, entry)
    assert Support.calls(events, ReadSnapshot, :validate_many) == []
    assert Support.calls(events, :erlang, :open_port) == []
  end

  test "a complete 401-record logical page resolves dense ranks across sparse physical pages at original R and D" do
    turns = for n <- 0..429, do: {n * 7, Support.message("assistant", "Original row #{n} 雪.")}
    id = Support.persist(turns, %{turn_count: 900_000})
    deadline = System.monotonic_time(:millisecond) + 5_000
    entry = Support.capture(id, deadline)

    assert :ok =
             Store.commit_turn(
               id,
               99_999,
               Message.encode(Support.message("assistant", "Later append.")),
               %{id: id, title: "Edited", agent: "archive"}
             )

    {result, events} =
      Support.observe(fn ->
        with {:ok, view} <- Reader.open(entry, 20, "t1"),
             {:ok, recent} <-
               Reader.read(
                 view,
                 request("recent", %{
                   "maxMessages" => 61,
                   "maxLines" => 61,
                   "maxBytes" => 1_048_576,
                   "allowResetArchiveFallback" => true,
                   "captureReadWindow" => true,
                   "readOnly" => true
                 })
               ),
             {:ok, page} <-
               Reader.read(
                 view,
                 request("page", %{
                   "beforeSeq" => 431,
                   "offset" => 29,
                   "maxMessages" => 401,
                   "maxBytes" => 1_048_576,
                   "allowOversizedFirst" => true,
                   "allowResetArchiveFallback" => true,
                   "expectedReadWindow" => %{
                     "source" => recent["viewId"],
                     "latestResetRawSeq" => nil
                   },
                   "readOnly" => true
                 })
               ) do
          {:ok, recent, page}
        end
      end)

    assert {:ok, recent, page} = result
    assert recent["totalTurns"] == 430
    assert page["totalTurns"] == 430
    assert page["viewId"] == recent["viewId"]
    assert Enum.map(recent["rows"], & &1["ordinal"]) == Enum.to_list(370..430)
    assert Enum.map(page["rows"], & &1["ordinal"]) == Enum.to_list(1..401)
    assert Enum.map(page["rows"], & &1["index"]) == Enum.map(0..400, &(&1 * 7))
    assert Enum.map(page["rows"], & &1["message"]["__openclaw"]["seq"]) == Enum.to_list(1..401)

    assert Enum.map(page["rows"], & &1["message"]["__openclaw"]["id"]) ==
             Enum.map(Enum.take(turns, 401), fn {_, message} -> message.id end)

    assert List.last(page["rows"])["message"]["content"] == [
             %{"type" => "text", "text" => "Original row 400 雪."}
           ]

    pages = Support.calls(events, ReadSnapshot, :read_page)
    assert length(pages) == 6

    assert Enum.map(pages, fn [_, opts] -> opts[:limit] end) |> Enum.sort() == [
             1,
             61,
             100,
             100,
             100,
             100
           ]

    assert [[_, index_opts]] = Support.calls(events, ReadSnapshot, :tail_index)
    assert index_opts[:retain] == 20 * 20 + 20 + 8_000 + 1
    Support.assert_fixed_reads(events, entry)

    values =
      for [key, _opts] <- Support.calls(events, Concord.KV, :get),
          String.starts_with?(key, Store.turns_prefix(id)),
          do: key

    assert length(values) == 61 + 401
    assert Support.calls(events, ReadSnapshot, :validate_many) == []
  end

  test "actual roles, tool arguments and public result data survive raw mapping with genuine indexed EventReply sidecars" do
    public_result = %{
      "content" => [
        %{"type" => "text", "text" => "Report line one."},
        %{"type" => "text", "text" => "Report line two."}
      ],
      "details" => %{"path" => "report.md", "lines" => 2},
      "is_error" => false
    }

    result_part = %ToolResult{
      tool_use_id: "read-report",
      content: "Legacy report",
      projection: %{"version" => 1, "result" => public_result}
    }

    call_part = %ToolUse{
      tool_use_id: "read-report",
      tool: "read_file",
      input: %{"path" => "report.md", "offset" => 2},
      status: :completed
    }

    assistant = %{Support.message("assistant", "") | parts: [call_part]}
    actual_tool = %{Support.message("tool", "") | parts: [result_part]}
    legacy_user = %{Support.message("user", "") | parts: [result_part]}
    stamp = EventReply.stamp("ordinary-indexed-display")

    display = %{
      Support.message("assistant", "")
      | parts: [
          %Reasoning{content: "Read the report."},
          call_part,
          %Text{content: "HEARTBEAT_OK\nReport displayed."}
        ],
        reply_presentation: stamp
    }

    hidden = %{Support.message("assistant", "HEARTBEAT_OK") | reply_presentation: stamp}

    turns = [
      {0, Support.message("user", "Read the report.")},
      {7, assistant},
      {91, actual_tool},
      {120, legacy_user},
      {200, display},
      {999, hidden}
    ]

    id = Support.persist(turns)
    entry = Support.capture(id, System.monotonic_time(:millisecond) + 5_000)

    assert {:ok, view} = Reader.open(entry, 2, "t1")
    assert {:ok, reply} = Reader.read(view, Support.fixture()["initialRead"])
    assert Enum.map(reply["rows"], & &1["ordinal"]) == Enum.to_list(1..6)

    assert Enum.map(reply["rows"], & &1["message"]["role"]) == [
             "user",
             "assistant",
             "toolResult",
             "user",
             "assistant",
             "assistant"
           ]

    [_user, call, tool, legacy, displayed, quiet] = reply["rows"]

    assert [
             %{
               "type" => "toolCall",
               "id" => "read-report",
               "name" => "read_file",
               "arguments" => arguments
             }
           ] = call["message"]["content"]

    assert arguments == call_part.input
    assert tool["message"]["__openclaw"]["id"] == actual_tool.id

    assert [
             %{
               "type" => "toolResult",
               "toolCallId" => "read-report",
               "content" => content,
               "details" => details,
               "isError" => false
             }
           ] = legacy["message"]["content"]

    assert content == public_result["content"]
    assert details == public_result["details"]

    assert displayed["message"]["content"] |> Enum.at(2) == %{
             "type" => "text",
             "text" => "HEARTBEAT_OK\nReport displayed."
           }

    assert displayed["eventReply"] == %{
             "version" => 1,
             "policy" => "manual_event_message",
             "hidden" => false,
             "textOverrides" => [%{"blockIndex" => 2, "text" => "Report displayed."}]
           }

    assert quiet["eventReply"] == %{
             "version" => 1,
             "policy" => "manual_event_message",
             "hidden" => true,
             "textOverrides" => [%{"blockIndex" => 0, "text" => ""}]
           }

    assert quiet["message"]["content"] == [%{"type" => "text", "text" => "HEARTBEAT_OK"}]
    refute Map.has_key?(legacy, "eventReply")

    for row <- reply["rows"] do
      refute Map.has_key?(row["message"], "eventReply")
      refute Map.has_key?(row["message"], "display")
      refute Map.has_key?(row["message"], "phase")
      refute Map.has_key?(row["message"], "openclawDisplayContent")
    end

    assert {:ok, stored} = Store.get_turn(id, 200)
    assert Enum.at(stored.parts, 2).text == "HEARTBEAT_OK\nReport displayed."
  end

  defp request(operation, options) do
    %{
      "type" => "history_read",
      "protocol" => 1,
      "historyProtocol" => 1,
      "id" => "h1",
      "readId" => "read-#{operation}",
      "slot" => "t1",
      "operation" => operation,
      "options" => options
    }
  end
end
