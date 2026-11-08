defmodule Synapsis.SessionDirectoryInlineHistoryFunctionalTest do
  use ExUnit.Case, async: false

  alias Concord.KV
  alias Synapsis.{Message, SessionDirectory}
  alias Synapsis.Part.{Text, ToolResult, ToolUse}
  alias Synapsis.Session.{EventReply, ReadSnapshot, Store}
  alias Synapsis.SessionDirectory.{History, Result}
  alias Synapsis.SessionDirectory.Projection.PortSession

  @observed [
    {ReadSnapshot, :capture, 2},
    {ReadSnapshot, :tail_index, 2},
    {ReadSnapshot, :read_page, 2},
    {ReadSnapshot, :validate_many, 1},
    {KV, :get, 2},
    {KV, :list, 1},
    {Message, :list_by_session, 1},
    {Store, :list_turns, 1},
    {History, :project, 4},
    {PortSession, :project, 3},
    {PortSession, :history, 3},
    {Result, :fit_rendered, 2},
    {:erlang, :open_port, 2},
    {:erlang, :port_command, 3}
  ]

  setup do
    assert :ok = Store.ensure_started()

    %{
      marker: "inline-history-#{Ecto.UUID.generate()}",
      context: %{session_id: Ecto.UUID.generate(), agent_id: "main"}
    }
  end

  test "default and explicit zero preserve exact legacy JSON without capture or helper work",
       ctx do
    id = persist(ctx.marker, [message("user", "Review the durable report.")])
    input = %{"search" => ctx.marker}
    assert {:ok, legacy} = SessionDirectory.list(input, ctx.context)

    for request <- [input, Map.put(input, "message_limit", 0)] do
      {result, events} = observe(fn -> SessionDirectory.list_rendered(request, ctx.context) end)
      assert {:ok, %{text: text, page: page}} = result
      assert page == legacy
      assert text == Jason.encode!(legacy, pretty: true)
      assert [%{id: ^id}] = page.sessions
      refute Map.has_key?(hd(page.sessions), :messages)

      for {module, function} <- [
            {ReadSnapshot, :capture},
            {ReadSnapshot, :tail_index},
            {ReadSnapshot, :read_page},
            {ReadSnapshot, :validate_many},
            {:erlang, :open_port}
          ],
          do: assert(calls(events, module, function) == [])

      assert calls(events, Message, :list_by_session) == []
      assert calls(events, Store, :list_turns) == []

      for [key, _opts] <- calls(events, KV, :get),
          do: refute(String.starts_with?(key, Store.turns_prefix(id)))
    end
  end

  test "ordinary twenty-one clamps to twenty before actual kernel display and tool postfilter",
       ctx do
    ordinary =
      for index <- 0..19 do
        message(if(rem(index, 2) == 0, do: "user", else: "assistant"), "Report turn #{index}.")
      end

    arguments = %{"path" => "reports/会議.md", "fraction" => 1.0e-7, "large" => 1.0e20}

    call = %{
      message("assistant", "")
      | parts: [
          %Text{content: "Reading the published report."},
          %ToolUse{tool_use_id: "inline-read-report", tool: "read_file", input: arguments}
        ]
    }

    public_result = %{
      "content" => [%{"type" => "text", "text" => "Report body: 完了"}],
      "details" => %{"path" => "reports/会議.md", "lines" => 2}
    }

    receipt = %ToolResult{
      tool_use_id: "inline-read-report",
      content: "Report body: 完了",
      projection: %{"version" => 1, "result" => public_result}
    }

    tool = %{message("tool", "") | parts: [receipt]}
    legacy_user = %{message("user", "") | parts: [receipt]}
    stamp = EventReply.stamp("inline-history-report")

    display = %{
      message("assistant", "HEARTBEAT_OK\nReport displayed.")
      | reply_presentation: stamp
    }

    hidden = %{message("assistant", "HEARTBEAT_OK") | reply_presentation: stamp}
    messages = ordinary ++ [call, tool, legacy_user, display, hidden]
    id = persist(ctx.marker, messages)
    deadline = System.monotonic_time(:millisecond) + 5_000

    {result, events} =
      observe(fn ->
        SessionDirectory.list_rendered(
          %{"search" => ctx.marker, "message_limit" => 21},
          ctx.context,
          deadline: deadline,
          node_executable: node_executable()
        )
      end)

    assert {:ok, %{text: text, page: %{sessions: [row]} = page}} = result
    assert row.id == id
    assert length(row.messages) == 19

    expected = Enum.drop(ordinary, 4) ++ [call, legacy_user, display]
    assert Enum.map(row.messages, & &1["__openclaw"]["id"]) == Enum.map(expected, & &1.id)
    assert Enum.map(row.messages, & &1["role"]) == Enum.map(expected, & &1.role)
    projected_call = Enum.find(row.messages, &(&1["__openclaw"]["id"] == call.id))
    assert [_, block] = projected_call["content"]

    assert block == %{
             "type" => "toolCall",
             "id" => "inline-read-report",
             "name" => "read_file",
             "arguments" => arguments
           }

    projected_receipt = Enum.find(row.messages, &(&1["__openclaw"]["id"] == legacy_user.id))

    assert [
             %{
               "type" => "toolResult",
               "toolCallId" => "inline-read-report",
               "content" => content,
               "isError" => false
             }
           ] = projected_receipt["content"]

    assert content == public_result["content"]

    assert projected_receipt["content"] == [
             %{
               "type" => "toolResult",
               "toolCallId" => "inline-read-report",
               "content" => public_result["content"],
               "isError" => false
             }
           ]

    assert List.last(row.messages)["content"] == [
             %{"type" => "text", "text" => "Report displayed."}
           ]

    assert text =~ ~s("fraction": 1e-7)
    assert text =~ ~s("large": 100000000000000000000)
    assert javascript_pretty(text) == text
    assert Jason.decode!(text) == Jason.decode!(Jason.encode!(page))
    assert byte_size(text) <= 65_536
    assert [[_entries, 20, _broker, _policy]] = calls(events, History, :project)

    assert [%{"type" => "history_start", "limit" => 20}] =
             Enum.filter(outgoing(events), &(&1["type"] == "history_start"))

    assert calls(events, PortSession, :project) == []
    assert_composed_lifecycle(events, [id], deadline)
    assert {:ok, raw_receipt} = Store.get_turn(id, 22 * 7)
    assert raw_receipt.role == "user"
    assert [%{projection: %{"version" => 1, "result" => ^public_result}}] = raw_receipt.parts
    assert {:ok, raw} = Store.get_turn(id, 23 * 7)
    assert raw.reply_presentation == stamp
    assert [%{text: "HEARTBEAT_OK\nReport displayed."}] = raw.parts
  end

  test "two title-preview waves and all selected histories share captures, one helper and common V",
       ctx do
    sparse =
      for index <- 0..54 do
        cond do
          index == 21 ->
            message("user", "Build the sparse session report.")

          index == 32 ->
            message("assistant", "# **Captured** answer.")

          index < 21 ->
            message("system", "Ordinary setup #{index}.")

          true ->
            %{
              message("user", "")
              | parts: [%ToolResult{tool_use_id: "receipt-#{index}", content: "Receipt"}]
            }
        end
      end

    first = persist(ctx.marker, sparse, %{updated_at: ~U[2026-11-06 00:01:00Z]})

    second =
      persist(
        ctx.marker,
        [message("user", "Review the second report."), message("assistant", "Second answer.")],
        %{updated_at: ~U[2026-11-06 00:00:00Z]}
      )

    deadline = System.monotonic_time(:millisecond) + 5_000

    {result, events} =
      observe(fn ->
        SessionDirectory.list_rendered(
          %{
            "search" => ctx.marker,
            "message_limit" => 2,
            "include_derived_titles" => true,
            "include_last_message" => true
          },
          ctx.context,
          deadline: deadline,
          node_executable: node_executable()
        )
      end)

    assert {:ok, %{text: text, page: %{sessions: [one, two]}}} = result
    assert [one.id, two.id] == [first, second]
    assert one.derived_title == "Build the sparse session report."
    assert one.last_message_preview == "Captured answer."
    assert two.derived_title == "Review the second report."
    assert two.last_message_preview == "Second answer."
    assert length(one.messages) <= 2
    assert Enum.map(two.messages, & &1["role"]) == ["user", "assistant"]
    assert javascript_pretty(text) == text
    assert length(calls(events, PortSession, :project)) == 2
    assert length(calls(events, PortSession, :history)) == 2
    assert [[entries, 2, _broker, _policy]] = calls(events, History, :project)
    assert Enum.map(entries, & &1.row.id) == [first, second]

    pages = calls(events, ReadSnapshot, :read_page)

    for pair <- [asc: 20, asc: 100, desc: 20, desc: 100] do
      assert Enum.any?(pages, fn [handle, opts] ->
               handle.session_id == first and {opts[:order], opts[:limit]} == pair
             end)
    end

    assert_composed_lifecycle(events, [first, second], deadline)
  end

  defp assert_composed_lifecycle(events, ids, deadline) do
    assert Enum.map(calls(events, ReadSnapshot, :capture), &hd/1) == ids
    handles = for {:ok, handle} <- returned(events, ReadSnapshot, :capture), do: handle
    assert Enum.map(handles, & &1.session_id) == ids
    assert Enum.all?(handles, &(&1.deadline == deadline))
    assert [[^handles]] = calls(events, ReadSnapshot, :validate_many)
    assert [{:ok, validation}] = returned(events, ReadSnapshot, :validate_many)
    assert validation.revision >= Enum.max(Enum.map(handles, & &1.revision))
    assert validation.targets == Enum.map(ids, &%{session_id: &1, same_lifecycle: true})
    assert length(calls(events, :erlang, :open_port)) == 1
    assert calls(events, Message, :list_by_session) == []
    assert calls(events, Store, :list_turns) == []

    for function <- [:read_page, :tail_index],
        [handle, _] <- calls(events, ReadSnapshot, function),
        do: assert(handle in handles)

    for [handle, opts] <- calls(events, ReadSnapshot, :read_page) do
      assert opts[:max_bytes] == 1_048_576
      assert opts[:limit] in 1..100
      assert handle.deadline == deadline
    end

    for [key, opts] <- calls(events, KV, :get),
        handle <- handles,
        String.starts_with?(key, Store.turns_prefix(handle.session_id)),
        do: assert(opts[:revision] == handle.revision)

    validation_index =
      Enum.find_index(events, &match?({:call, ReadSnapshot, :validate_many, _}, &1))

    before_v = Enum.take(events, validation_index)
    assert Enum.any?(before_v, &match?({:port_exit, _, 0}, &1))

    assert Enum.any?(
             incoming(before_v),
             &match?(%{"type" => "closed", "runtime" => %{"workerExitObserved" => true}}, &1)
           )

    validated_index =
      Enum.find_index(events, &match?({:return, ReadSnapshot, :validate_many, _}, &1))

    after_v = Enum.drop(events, validated_index + 1)
    assert length(calls(after_v, Result, :fit_rendered)) == 1

    for {module, function} <- [
          {ReadSnapshot, :capture},
          {ReadSnapshot, :tail_index},
          {ReadSnapshot, :read_page},
          {KV, :get},
          {KV, :list},
          {:erlang, :open_port},
          {:erlang, :port_command},
          {PortSession, :project},
          {PortSession, :history}
        ],
        do: assert(calls(after_v, module, function) == [])
  end

  defp persist(title, messages, extra \\ %{}) do
    id = Ecto.UUID.generate()
    meta = Map.merge(%{id: id, title: title, agent: "archive"}, extra)
    assert :ok = Store.put_meta(id, meta)
    on_exit(fn -> Store.delete_session(id) end)

    for {message, index} <- Enum.with_index(messages),
        do: assert(:ok = Store.commit_turn(id, index * 7, Message.encode(message), meta))

    id
  end

  defp message(role, text),
    do: %Message{
      id: Ecto.UUID.generate(),
      inserted_at: ~U[2026-11-06 00:00:00.000000Z],
      role: role,
      parts: [%Text{content: text}]
    }

  defp node_executable,
    do:
      System.get_env("SYNAPSIS_FILESYSTEM_NODE") || System.find_executable("node") ||
        System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")

  defp calls(events, module, function),
    do: for({:call, ^module, ^function, args} <- events, do: args)

  defp returned(events, module, function),
    do: for({:return, ^module, ^function, value} <- events, do: value)

  defp incoming(events) do
    Enum.flat_map(events, fn
      {:port_data, _, {:eol, text}} ->
        case Jason.decode(text) do
          {:ok, frame} -> [frame]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp outgoing(events),
    do:
      for(
        [_port, data, _opts] <- calls(events, :erlang, :port_command),
        line <- String.split(IO.iodata_to_binary(data), "\n", trim: true),
        do: Jason.decode!(line)
      )

  defp javascript_pretty(json) do
    script = ~S"""
    let input = '';
    const newline = String.fromCharCode(10);
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', chunk => {
      input += chunk;
      if (!input.includes(newline)) return;
      process.stdout.write(JSON.stringify(JSON.parse(JSON.parse(input.slice(0, input.indexOf(newline)))), null, 2));
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

    try do
      assert Port.command(port, Jason.encode!(json) <> "\n")
      collect_javascript(port, "")
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp collect_javascript(port, output) do
    receive do
      {^port, {:data, chunk}} -> collect_javascript(port, output <> chunk)
      {^port, {:exit_status, 0}} -> output
    after
      5_000 -> flunk("ordinary JSON.stringify oracle did not finish")
    end
  end

  defp observe(fun) do
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

      {:trace, _, :return_from, {module, function, _}, value} ->
        collect(owner, [{:return, module, function, value} | events], children)

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
