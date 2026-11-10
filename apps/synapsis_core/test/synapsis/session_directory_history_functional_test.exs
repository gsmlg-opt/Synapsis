defmodule Synapsis.SessionDirectoryHistoryTestSupport do
  import ExUnit.Assertions

  alias Concord.KV
  alias Synapsis.{Message, Part.Text}
  alias Synapsis.Session.{ReadSnapshot, Store}

  @observed [
    {ReadSnapshot, :capture, 2},
    {ReadSnapshot, :tail_index, 2},
    {ReadSnapshot, :read_page, 2},
    {ReadSnapshot, :validate_many, 1},
    {KV, :get, 2},
    {KV, :list, 1},
    {Message, :list_by_session, 1},
    {Store, :list_turns, 1},
    {:erlang, :open_port, 2},
    {:erlang, :port_command, 3}
  ]

  def fixture do
    Path.expand(
      "../../../../packages/tool-host/test/fixtures/session-history-protocol.json",
      __DIR__
    )
    |> File.read!()
    |> Jason.decode!()
  end

  def message(role, text) do
    %Message{
      id: Ecto.UUID.generate(),
      inserted_at: ~U[2026-11-06 00:00:00.000000Z],
      role: role,
      parts: [%Text{content: text}]
    }
  end

  def persist(turns, extra \\ %{}) do
    id = Map.get(extra, :id, Ecto.UUID.generate())
    meta = Map.merge(%{id: id, title: "History 雪 😀", agent: "archive"}, extra)
    assert :ok = Store.put_meta(id, meta)

    for chunk <- Enum.chunk_every(turns, 500) do
      puts =
        Enum.map(chunk, fn {index, message} ->
          {Store.turn_key(id, index), Message.encode(message)}
        end)

      assert {:ok, _} = Concord.Turso.put_many(puts, timeout: 5_000)
    end

    ExUnit.Callbacks.on_exit(fn -> Store.delete_session(id) end)
    id
  end

  def capture(id, deadline, offset \\ 0) do
    assert {:ok, handle} = ReadSnapshot.capture(id, deadline: deadline, max_bytes: 1_048_576)

    %{
      row: %{id: id, title: handle.meta.title, agent: handle.meta.agent},
      offset: offset,
      handle: handle,
      enrich?: false
    }
  end

  def node_executable do
    System.get_env("SYNAPSIS_FILESYSTEM_NODE") || System.find_executable("node") ||
      System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")
  end

  def calls(events, module, function) do
    for {:call, ^module, ^function, args} <- events, do: args
  end

  def returned(events, module, function) do
    for {:return, ^module, ^function, value} <- events, do: value
  end

  def incoming(events) do
    Enum.flat_map(events, fn
      {:port_data, _port, {:eol, body}} ->
        case Jason.decode(body) do
          {:ok, value} -> [value]
          _ -> []
        end

      _ ->
        []
    end)
  end

  def outgoing(events) do
    for [_port, data, _opts] <- calls(events, :erlang, :port_command),
        line <- String.split(IO.iodata_to_binary(data), "\n", trim: true),
        do: Jason.decode!(line)
  end

  def assert_fixed_reads(events, entry) do
    assert calls(events, ReadSnapshot, :capture) == []
    assert calls(events, Message, :list_by_session) == []
    assert calls(events, Store, :list_turns) == []

    for [handle, opts] <- calls(events, ReadSnapshot, :read_page) do
      assert handle == entry.handle
      assert opts[:limit] in 1..100
      assert opts[:max_bytes] == 1_048_576
      assert handle.deadline == entry.handle.deadline
      assert handle.owner == entry.handle.owner
    end

    for [key, opts] <- calls(events, KV, :get),
        String.starts_with?(key, Store.turns_prefix(entry.row.id)) do
      assert opts[:revision] == entry.handle.revision
    end
  end

  def javascript_fragments(row, messages \\ nil) do
    script = ~S"""
    let text = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', chunk => {
      text += chunk;
      if (!text.includes('\n')) return;
      const input = JSON.parse(text.slice(0, text.indexOf('\n')));
      const row = input.row;
      if ('messages' in input) row.messages = input.messages;
      const json = JSON.stringify(row, null, 2).split('\n').map(line => '    ' + line).join('\n');
      process.stdout.write(JSON.stringify({json, utf8Bytes: Buffer.byteLength(json, 'utf8')}));
      process.stdin.destroy();
    });
    """

    port =
      Port.open({:spawn_executable, node_executable()}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: ["-e", script]
      ])

    input = if is_nil(messages), do: %{row: row}, else: %{row: row, messages: messages}
    assert Port.command(port, Jason.encode!(input) <> "\n")
    collect_json(port, "")
  end

  defp collect_json(port, output) do
    receive do
      {^port, {:data, chunk}} -> collect_json(port, output <> chunk)
      {^port, {:exit_status, 0}} -> Jason.decode!(output)
    after
      5_000 ->
        if Port.info(port), do: Port.close(port)
        flunk("ordinary JSON.stringify child did not finish")
    end
  end

  def observe(fun) do
    for {module, _, _} <- @observed, do: Code.ensure_loaded!(module)
    owner = self()
    observer = spawn(fn -> collect(owner, [], []) end)
    monitor = Process.monitor(observer)
    for mfa <- @observed, do: :erlang.trace_pattern(mfa, [{:_, [], [{:return_trace}]}], [:local])
    :erlang.trace(self(), true, [:call, :procs, :receive, :set_on_spawn, {:tracer, observer}])

    try do
      result = fun.()
      delivered = :erlang.trace_delivered(:all)
      assert_receive {:trace_delivered, :all, ^delivered}, 5_000
      send(observer, :snapshot)
      assert_receive {:observed, ^observer, events}, 5_000
      {result, events}
    after
      :erlang.trace(self(), false, [:call, :procs, :receive, :set_on_spawn])
      for mfa <- @observed, do: :erlang.trace_pattern(mfa, false, [:local])
      send(observer, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^observer, :normal}, 5_000
    end
  end

  defp collect(owner, events, children) do
    receive do
      {:trace, _, :call, {module, function, args}} ->
        collect(owner, [{:call, module, function, args} | events], children)

      {:trace, _, :return_from, {module, function, _}, result} ->
        collect(owner, [{:return, module, function, result} | events], children)

      {:trace, _, :receive, {port, {:exit_status, status}}} when is_port(port) ->
        collect(owner, [{:port_exit, port, status} | events], children)

      {:trace, _, :receive, {port, {:data, data}}} when is_port(port) ->
        collect(owner, [{:port_data, port, data} | events], children)

      {:trace, _, :spawn, child, _} ->
        collect(owner, events, [child | children])

      :snapshot ->
        send(owner, {:observed, self(), Enum.reverse(events)})
        collect(owner, events, children)

      :stop ->
        for child <- children do
          try do
            :erlang.trace(child, false, [:call, :procs, :receive, :set_on_spawn])
          rescue
            ArgumentError -> :ok
          end
        end

      _ ->
        collect(owner, events, children)
    end
  end
end

defmodule Synapsis.SessionDirectoryHistoryFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Concord.KV
  alias Synapsis.Session.{EventReply, ReadSnapshot, Store}
  alias Synapsis.SessionDirectory.History
  alias Synapsis.SessionDirectoryHistoryTestSupport, as: Support

  setup do
    assert :ok = Store.ensure_started()
    :ok
  end

  test "empty candidates skip the helper and common validation" do
    {result, events} =
      Support.observe(fn -> History.read([], 2, node_executable: Support.node_executable()) end)

    assert result == {:ok, %{entries: [], validation_revision: nil}}
    assert Support.calls(events, ReadSnapshot, :tail_index) == []
    assert Support.calls(events, ReadSnapshot, :validate_many) == []
    assert Support.calls(events, :erlang, :open_port) == []
  end

  test "captured targets retain original R and D through ordinary edits and append before one common V" do
    first_message = Support.message("assistant", "Captured answer 雪 😀 \"path\\file\".\u2028")
    first = Support.persist([{0, first_message}])
    deadline = System.monotonic_time(:millisecond) + 5_000
    first_entry = Support.capture(first, deadline, 7)
    second = Support.persist([{91, Support.message("assistant", "Second captured answer.")}])
    second_entry = Support.capture(second, deadline, 8)

    assert :ok = Store.put_meta(first, %{id: first, title: "Edited title", agent: "archive"})

    assert :ok =
             Store.commit_turn(
               first,
               999,
               Synapsis.Message.encode(Support.message("assistant", "Later append.")),
               %{id: first, title: "Edited title", agent: "archive"}
             )

    assert {:ok, committed} = KV.revision(engine: :turso)

    {result, events} =
      Support.observe(fn ->
        History.read([first_entry, second_entry], 2,
          node_executable: Support.node_executable(),
          deadline: deadline
        )
      end)

    assert {:ok, %{entries: [one, two], validation_revision: actual_v}} = result
    assert [one.handle, two.handle] == [first_entry.handle, second_entry.handle]
    assert [one.offset, two.offset] == [7, 8]
    assert [one.row, two.row] == [first_entry.row, second_entry.row]
    assert Support.calls(events, ReadSnapshot, :capture) == []
    assert Support.calls(events, Synapsis.Message, :list_by_session) == []
    assert Support.calls(events, Store, :list_turns) == []
    first_handle = first_entry.handle
    second_handle = second_entry.handle

    assert [[[^first_handle, ^second_handle]]] =
             Support.calls(events, ReadSnapshot, :validate_many)

    assert [{:ok, validation}] = Support.returned(events, ReadSnapshot, :validate_many)
    assert actual_v == validation.revision
    assert actual_v >= committed

    assert validation.targets == [
             %{session_id: first, same_lifecycle: true},
             %{session_id: second, same_lifecycle: true}
           ]

    assert length(Support.calls(events, :erlang, :open_port)) == 1

    validation_index =
      Enum.find_index(events, &match?({:call, ReadSnapshot, :validate_many, _}, &1))

    before_v = Enum.take(events, validation_index)
    assert Enum.any?(before_v, &match?({:port_exit, _, 0}, &1))

    assert Enum.any?(
             Support.incoming(before_v),
             &match?(%{"type" => "closed", "runtime" => %{"workerExitObserved" => true}}, &1)
           )

    refute Enum.any?(
             Enum.drop(events, validation_index + 1),
             &match?({:call, ReadSnapshot, :read_page, _}, &1)
           )

    assert [%{"content" => [%{"text" => text}]}] = one.history_candidate.messages
    assert text == hd(first_message.parts).content

    for entry <- [one, two] do
      for {fragment, messages} <- [
            {entry.history_candidate.enriched, entry.history_candidate.messages},
            {entry.history_candidate.metadata, nil}
          ] do
        expected = Support.javascript_fragments(entry.row, messages)
        assert fragment.kind == "json"
        assert fragment.json == expected["json"]
        assert fragment.utf8_bytes == expected["utf8Bytes"]
        assert fragment.utf8_bytes == byte_size(fragment.json)
      end
    end

    for [handle, opts] <- Support.calls(events, ReadSnapshot, :read_page) do
      assert handle in [first_entry.handle, second_entry.handle]
      assert handle.deadline == deadline
      assert opts[:max_bytes] == 1_048_576
      assert opts[:limit] in 1..100
    end

    for [key, opts] <- Support.calls(events, KV, :get),
        entry <- [first_entry, second_entry],
        String.starts_with?(key, Store.turns_prefix(entry.row.id)) do
      assert opts[:revision] == entry.handle.revision
    end
  end

  test "real EventReply display decisions retain raw positions through source scans and ordinary chunk transfer" do
    stamp = EventReply.stamp("ordinary-history-event")
    hidden = %{Support.message("assistant", "HEARTBEAT_OK") | reply_presentation: stamp}

    turns = [
      {0, Support.message("user", "Write the report.")},
      {7, Support.message("assistant", "The report is ready.")}
    ]

    turns = turns ++ for n <- 2..801, do: {n * 7, %{hidden | id: Ecto.UUID.generate()}}
    id = Support.persist(turns)
    deadline = System.monotonic_time(:millisecond) + 5_000
    entry = Support.capture(id, deadline)

    {result, events} =
      Support.observe(fn ->
        History.read([entry], 2, node_executable: Support.node_executable(), deadline: deadline)
      end)

    assert {:ok, %{entries: [candidate]}} = result
    assert Enum.map(candidate.history_candidate.messages, & &1["role"]) == ["user", "assistant"]

    assert Enum.map(candidate.history_candidate.messages, & &1["content"]) == [
             [%{"type" => "text", "text" => "Write the report."}],
             [%{"type" => "text", "text" => "The report is ready."}]
           ]

    Support.assert_fixed_reads(events, entry)
    reads = Enum.filter(Support.incoming(events), &(&1["type"] == "history_read"))
    assert hd(reads)["operation"] == "recent"
    assert hd(reads)["options"] == Support.fixture()["initialRead"]["options"]
    assert Enum.any?(reads, &(&1["options"]["maxMessages"] == 401))
    frames = Support.outgoing(events)
    assert Enum.any?(frames, &(&1["type"] == "history_transfer_start"))

    for frame <- frames do
      assert byte_size(Jason.encode!(frame)) + 1 <= 65_536

      if frame["type"] == "history_transfer_chunk",
        do: assert(byte_size(Base.decode64!(frame["data"])) <= 32_768)
    end

    assert {:ok, stored} = Store.get_turn(id, 7 * 801)
    assert stored.reply_presentation == stamp
    assert [%{text: "HEARTBEAT_OK"}] = stored.parts
  end
end
