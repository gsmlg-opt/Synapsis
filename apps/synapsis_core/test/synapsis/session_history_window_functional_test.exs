defmodule Synapsis.SessionHistoryWindowOracle do
  @moduledoc false
  import ExUnit.Assertions

  # These are independent test adapters around the pinned original factory,
  # kernel and preparation. They do not import product history/DTO algorithms.
  def expected(id, input, selected, total, operation \\ "recent", extra \\ %{}, pending \\ nil) do
    args =
      input
      |> Map.drop(["session_id", "message_id", "pending_before", "include_tools"])
      |> Map.put("sessionKey", "agent:main:history291")
      |> copy(input, "message_id", "messageId")
      |> copy(input, "pending_before", "pendingBefore")
      |> copy(input, "include_tools", "includeTools")

    result =
      Map.merge(
        %{
          "messages" => selected,
          "totalMessages" => total,
          "displaySource" => "supplied-history291",
          "readWindow" => %{"source" => "supplied-history291", "latestResetRawSeq" => nil}
        },
        extra
      )

    request = %{
      "id" => "host-positive",
      "args" => args,
      "max" => Map.get(input, "limit", 200),
      "reads" => [%{"operation" => operation, "result" => result}],
      "pendingInputs" => pending || %{"items" => [], "total" => 0},
      "hostId" => id
    }

    script = ~S"""
    import {pathToFileURL} from 'node:url';
    const oraclePath = process.argv[1];
    process.argv.splice(1,1);
    const {computeSessionHistoryWindow} = await import(pathToFileURL(oraclePath).href);
    let data = '';
    for await (const chunk of process.stdin) { data += chunk; if (data.includes('\n')) break; }
    const input = JSON.parse(data.trim());
    const observation = await computeSessionHistoryWindow(input);
    const original = JSON.parse(observation.result.content[0].text);
    const page = Object.fromEntries(Object.entries(original).map(([key,value]) =>
      [key === 'sessionKey' ? 'session_id' : key,key === 'sessionKey' ? input.hostId : value]));
    if (page.pendingInputs) {
      const before = Buffer.byteLength(JSON.stringify(page.pendingInputs),'utf8');
      const kinds = new Map((input.pendingInputs.items ?? []).map(item => [item.id,item.kind]));
      page.pendingInputs.items = page.pendingInputs.items.map(item => ({...item,...(kinds.has(item.id)?{kind:kinds.get(item.id)}:{})}));
      page.bytes += Buffer.byteLength(JSON.stringify(page.pendingInputs),'utf8') - before;
    }
    await new Promise((resolve, reject) => {
      process.stdout.write(JSON.stringify({page,text:JSON.stringify(page,null,2)}), error => error ? reject(error) : resolve());
    });
    process.exit(0);
    """

    oracle =
      Path.expand("../../../../scripts/openclaw/capture-session-history-window.mjs", __DIR__)

    port =
      Port.open({:spawn_executable, node_executable()}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: ["--experimental-vm-modules", "--input-type=module", "-e", script, oracle]
      ])

    assert Port.command(port, Jason.encode!(request) <> "\n")
    collect(port, "")
  end

  def node_executable,
    do:
      System.get_env("SYNAPSIS_FILESYSTEM_NODE") || System.find_executable("node") ||
        System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")

  def message(role, text),
    do: %Synapsis.Message{
      id: Ecto.UUID.generate(),
      role: role,
      inserted_at: ~U[2026-11-06 00:00:00.000000Z],
      parts: [%Synapsis.Part.Text{content: text}]
    }

  def source(message, ordinal, content \\ nil),
    do: %{
      "role" => message.role,
      "timestamp" => DateTime.to_iso8601(message.inserted_at),
      "__openclaw" => %{"id" => message.id, "seq" => ordinal},
      "content" => content || Enum.map(message.parts, &%{"type" => "text", "text" => &1.content})
    }

  def persist(messages) do
    id = Ecto.UUID.generate()

    assert :ok =
             Synapsis.Session.Store.put_meta(id, %{id: id, agent: "archive", title: "History 雪"})

    for chunk <- Enum.chunk_every(Enum.with_index(messages), 500) do
      puts =
        Enum.map(chunk, fn {message, index} ->
          {Synapsis.Session.Store.turn_key(id, index * 7), Synapsis.Message.encode(message)}
        end)

      assert {:ok, _} = Concord.Turso.put_many(puts, timeout: 5_000)
    end

    ExUnit.Callbacks.on_exit(fn -> Synapsis.Session.Store.delete_session(id) end)
    id
  end

  def tool_archive do
    arguments = %{"fraction" => 1.0e-7, "path" => "reports/雪😀.md", "items" => [1, true, nil]}

    public = %{
      "content" => [%{"type" => "text", "text" => "Published report 雪"}],
      "details" => %{"count" => 2, "fraction" => 1.0e-7},
      "structured" => %{"path" => arguments["path"]},
      "is_error" => false
    }

    use = %Synapsis.Part.ToolUse{
      tool: "read_file",
      tool_use_id: "archive-read",
      input: arguments,
      status: :completed
    }

    result = %Synapsis.Part.ToolResult{
      tool_use_id: "archive-read",
      content: "Published report 雪",
      projection: %{"version" => 1, "result" => public}
    }

    messages = [
      message("user", "Read the ordinary report."),
      %{message("assistant", "") | parts: [%Synapsis.Part.Text{content: "Reading."}, use]},
      %{message("tool", "") | parts: [result]},
      %{message("user", "") | parts: [result]},
      message("assistant", "Report complete 😀")
    ]

    call = %{
      "type" => "toolCall",
      "id" => "archive-read",
      "name" => "read_file",
      "arguments" => arguments
    }

    reply =
      public
      |> Map.delete("is_error")
      |> Map.merge(%{"toolCallId" => "archive-read", "isError" => false})

    [first, second, third, fourth, fifth] = messages

    rows = [
      source(first, 1),
      source(second, 2, [%{"type" => "text", "text" => "Reading."}, call]),
      source(third, 3, public["content"]) |> Map.merge(reply) |> Map.put("role", "toolResult"),
      source(fourth, 4, [Map.put(reply, "type", "toolResult")]),
      source(fifth, 5)
    ]

    %{id: persist(messages), messages: messages, rows: rows, arguments: arguments, public: public}
  end

  def pending(input),
    do: %{
      "id" => input.id,
      "state" => input.status,
      "kind" => input.kind,
      "acceptedAt" => input.inserted_at,
      "message" => %{
        "role" => "user",
        "content" => [%{"type" => "text", "text" => input.content}]
      }
    }

  defp copy(args, input, key, target) do
    if Map.has_key?(input, key), do: Map.put(args, target, input[key]), else: args
  end

  defp collect(port, output) do
    receive do
      {^port, {:data, chunk}} ->
        collect(port, output <> chunk)

      {^port, {:exit_status, 0}} ->
        Jason.decode!(output)

      {^port, {:exit_status, status}} ->
        flunk("pinned original history oracle exit #{status}: #{output}")
    after
      30_000 ->
        if Port.info(port), do: Port.close(port)
        flunk("pinned original history oracle did not finish")
    end
  end
end

defmodule Synapsis.SessionHistoryWindowFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Session.{PendingInputStore, Store}
  alias Synapsis.SessionHistory
  alias Synapsis.SessionHistoryWindowOracle, as: Oracle

  @moduletag timeout: 120_000

  setup do
    assert :ok = Store.ensure_started()
    :ok
  end

  test "recent tail, explicit zero and older offsets match complete source messages and metadata" do
    messages =
      for n <- 1..6,
          do: Oracle.message(if(rem(n, 2) == 1, do: "user", else: "assistant"), "Row #{n} 雪 😀")

    id = Oracle.persist(messages)
    rows = Enum.with_index(messages, 1) |> Enum.map(fn {m, n} -> Oracle.source(m, n) end)

    for {input, selected, operation} <- [
          {%{}, rows, "recent"},
          {%{"limit" => 2}, rows, "recent"},
          {%{"limit" => 2, "offset" => 0}, rows, "recent"},
          {%{"limit" => 2, "offset" => 2}, Enum.slice(rows, 1, 3), "page"},
          {%{"limit" => 2, "offset" => 4}, Enum.slice(rows, 0, 2), "page"}
        ] do
      assert_rendered(id, input, Oracle.expected(id, input, selected, 6, operation))
    end
  end

  test "anchors center and backfill both edges while ignoring a supplied offset" do
    messages = for n <- 1..6, do: Oracle.message("assistant", "Anchor row #{n} café 😀")
    id = Oracle.persist(messages)
    rows = Enum.with_index(messages, 1) |> Enum.map(fn {m, n} -> Oracle.source(m, n) end)

    for {position, start, count, offset, context} <- [
          {2, 0, 4, 2, true},
          {0, 0, 3, 3, false},
          {5, 2, 4, 0, true}
        ] do
      input = %{"limit" => 3, "offset" => 1, "message_id" => Enum.at(messages, position).id}
      extra = %{"found" => true, "offset" => offset, "hasOverreadContext" => context}
      expected = Oracle.expected(id, input, Enum.slice(rows, start, count), 6, "around", extra)
      assert_rendered(id, input, expected)
      assert_rendered(id, Map.delete(input, "offset"), expected)
    end
  end

  test "default 200 and ordinary limit above 100 use the complete selected suffix" do
    messages = for n <- 1..205, do: Oracle.message("assistant", "Ordinary #{n} 雪")
    id = Oracle.persist(messages)
    rows = Enum.with_index(messages, 1) |> Enum.map(fn {m, n} -> Oracle.source(m, n) end)

    for input <- [%{}, %{"limit" => 121}] do
      expected = Oracle.expected(id, input, rows, 205)
      assert length(expected["page"]["messages"]) == Map.get(input, "limit", 200)
      assert_rendered(id, input, expected)
    end
  end

  test "an exact durable anchor remains readable before the old retained suffix" do
    messages = for n <- 1..8_100, do: Oracle.message("assistant", "Small #{n}")
    id = Oracle.persist(messages)
    first = hd(messages)
    input = %{"limit" => 1, "message_id" => first.id, "offset" => 7}

    expected =
      Oracle.expected(id, input, [Oracle.source(first, 1)], 8_100, "around", %{
        "found" => true,
        "offset" => 8_099,
        "hasOverreadContext" => false
      })

    assert_rendered(id, input, expected)
  end

  test "empty existing and explicit other persisted targets retain their exact identity" do
    id = Oracle.persist([])
    other = Oracle.persist([Oracle.message("user", "Other archive 雪")])
    assert_rendered(id, %{}, Oracle.expected(id, %{}, [], 0))
    input = %{"session_id" => other, "limit" => 1}
    [message] = Synapsis.Message.list_by_session(other)
    expected = Oracle.expected(other, input, [Oracle.source(message, 1)], 1)

    assert {:ok, rendered} =
             SessionHistory.read_rendered(input, %{session_id: id, agent_id: "reader"},
               node_executable: Oracle.node_executable()
             )

    assert rendered == %{text: expected["text"], page: expected["page"]}
  end

  test "source tool inclusion retains actual assistant calls, public tool roles and legacy user identity" do
    archive = Oracle.tool_archive()
    assert {:ok, original} = Store.list_turns(archive.id)

    for input <- [
          %{"limit" => 5, "offset" => 0},
          %{"limit" => 5, "offset" => 0, "include_tools" => true}
        ] do
      expected = Oracle.expected(archive.id, input, archive.rows, 5)
      rendered = assert_rendered(archive.id, input, expected)

      assert Enum.any?(rendered.page["messages"], fn row ->
               row["role"] == "assistant" and
                 Enum.any?(List.wrap(row["content"]), &(&1["type"] == "toolCall"))
             end)

      if input["include_tools"] do
        assert Enum.any?(rendered.page["messages"], &(&1["role"] == "toolResult"))

        assert Enum.any?(
                 rendered.page["messages"],
                 &(&1["role"] == "user" and
                     &1["__openclaw"]["id"] == Enum.at(archive.messages, 3).id)
               )
      end
    end

    assert Store.list_turns(archive.id) == {:ok, original}
  end

  test "real queued and inflight producer inputs keep ISO times, kinds and original before positions" do
    id = Oracle.persist([])
    assert {:ok, consumed} = PendingInputStore.append_prompt(id, "Consumed prompt", [])
    assert {:ok, _} = PendingInputStore.take_next_prompt(id)
    assert :ok = PendingInputStore.mark_consumed(id, consumed.id)
    assert {:ok, first} = PendingInputStore.append_prompt(id, "Next question 雪", [])
    assert {:ok, steer} = PendingInputStore.append_steer(id, "Keep ordinary detail 😀")
    assert {:ok, _} = PendingInputStore.take_next_prompt(id)
    assert {:ok, last} = PendingInputStore.append_prompt(id, "Newest question", [])
    current = PendingInputStore.list(id)
    first = Enum.find(current, &(&1.id == first.id))
    assert first.status == "inflight"
    input = %{"limit" => 2}

    pending = %{
      "items" => Enum.map([last, steer], &Oracle.pending/1),
      "total" => 3,
      "nextBefore" => 3
    }

    expected = Oracle.expected(id, input, [], 0, "recent", %{}, pending)
    assert_rendered(id, input, expected)
    assert expected["page"]["pendingInputs"]["nextBefore"] == 3

    assert {:ok, appended} = PendingInputStore.append_prompt(id, "Appended after cursor", [])
    input = %{"limit" => 2, "pending_before" => 3}
    pending = %{"items" => [Oracle.pending(first)], "total" => 4}
    expected = Oracle.expected(id, input, [], 0, "recent", %{}, pending)
    assert_rendered(id, input, expected)
    assert Enum.map(expected["page"]["pendingInputs"]["items"], & &1["id"]) == [first.id]
    refute appended.id == first.id
    assert :ok = PendingInputStore.mark_consumed(id, first.id)
    pending = %{"items" => [], "total" => 3}
    assert_rendered(id, input, Oracle.expected(id, input, [], 0, "recent", %{}, pending))
  end

  test "a real owned system event is context until acknowledged adoption records its run" do
    id = Oracle.persist([])
    owner = Ecto.UUID.generate()

    assert {:ok, event} =
             PendingInputStore.append_event(id, %{
               content: "Ordinary scheduled context 雪",
               owner_id: owner,
               target_agent_id: "reader",
               mode: "now",
               input_provenance: %{kind: "internal_system", source_tool: "sessions_send"}
             })

    pending = %{"items" => [Oracle.pending(event)], "total" => 1}
    assert_rendered(id, %{}, Oracle.expected(id, %{}, [], 0, "recent", %{}, pending))
    assert {:ok, taken} = PendingInputStore.take_next_turn(id, owner)
    assert taken.id == event.id
    assert :ok = PendingInputStore.start_event(id, event.id, owner, Ecto.UUID.generate())
    assert :ok = PendingInputStore.finish_event(id, event.id, owner, :completed)
    assert_rendered(id, %{}, Oracle.expected(id, %{}, [], 0))
  end

  defp assert_rendered(id, input, expected) do
    assert {:ok, rendered} =
             SessionHistory.read_rendered(input, %{session_id: id, agent_id: "reader"},
               node_executable: Oracle.node_executable(),
               deadline: System.monotonic_time(:millisecond) + 5_000
             )

    assert rendered == %{text: expected["text"], page: expected["page"]}
    assert Jason.decode!(rendered.text) == rendered.page
    rendered
  end
end
