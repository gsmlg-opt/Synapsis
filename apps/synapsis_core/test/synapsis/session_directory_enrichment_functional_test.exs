defmodule Synapsis.SessionDirectoryEnrichmentFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Concord.KV
  alias Concord.Turso
  alias Synapsis.{Message, SessionDirectory}
  alias Synapsis.Part.{Text, ToolResult}
  alias Synapsis.Session.{EventReply, ReadSnapshot, Store}

  @observed [
    {ReadSnapshot, :capture, 2},
    {ReadSnapshot, :read_page, 2},
    {ReadSnapshot, :validate_many, 1},
    {KV, :get, 2},
    {Turso, :get, 2},
    {KV, :list, 1},
    {KV, :revision, 1},
    {:erlang, :open_port, 2},
    {Message, :list_by_session, 1},
    {Store, :list_turns, 1}
  ]

  setup do
    assert :ok = Store.ensure_started()

    %{
      marker: "enrichment-#{Ecto.UUID.generate()}",
      context: %{session_id: Ecto.UUID.generate(), agent_id: "main"}
    }
  end

  test "default and explicit false flags retain metadata shape without transcript or helper work",
       ctx do
    id = persist(ctx.marker, [message("user", "Build the session report.")])
    input = %{"search" => ctx.marker}
    {default, first_trace} = observe(fn -> SessionDirectory.list(input, ctx.context) end)

    {explicit, second_trace} =
      observe(fn ->
        SessionDirectory.list(
          Map.merge(input, %{"include_derived_titles" => false, "include_last_message" => false}),
          ctx.context
        )
      end)

    assert {:ok, page} = default
    assert explicit == default
    assert [%{id: ^id, title: title}] = page.sessions
    assert title == ctx.marker

    assert Enum.sort(Map.keys(hd(page.sessions))) ==
             ~w(agent id inserted_at model provider status title updated_at)a

    for events <- [first_trace, second_trace] do
      assert calls(events, ReadSnapshot, :capture) == []
      assert calls(events, ReadSnapshot, :read_page) == []
      assert calls(events, ReadSnapshot, :validate_many) == []
      assert calls(events, :erlang, :open_port) == []
      assert calls(events, Message, :list_by_session) == []
      assert calls(events, Store, :list_turns) == []
      assert calls(events, Turso, :get) != []

      assert Enum.all?(calls(events, Turso, :get), fn [key, _] ->
               not String.starts_with?(key, Store.turns_prefix(id))
             end)
    end
  end

  test "first eligible authored user derives a title while latest visible Markdown supplies preview",
       ctx do
    imported = %{
      message("user", "Build the forwarded task.")
      | input_provenance: %{
          "kind" => "inter_session",
          "source_session_id" => Ecto.UUID.generate()
        }
    }

    result = %Message{
      role: "user",
      parts: [%ToolResult{tool_use_id: "ordinary-result", content: "Tool receipt"}]
    }

    id =
      persist(ctx.marker, [
        imported,
        result,
        message("user", "/status"),
        message("user", "Hello there. build the session report. Thanks again."),
        message(
          "assistant",
          "# **Session** report\nRead `status` and [details](https://example.test)."
        ),
        result
      ])

    assert {:ok, %{sessions: [row]}} = enriched(ctx, %{})
    assert row.id == id
    assert row.title == ctx.marker
    assert row.derived_title == "Build the session report."
    assert row.last_message_preview == "Session report Read status and details."
    refute Map.has_key?(row, :label)
    refute Map.has_key?(row, :phase)
    refute Map.has_key?(row, :display)
    refute Map.has_key?(row, :source_session_key)
    assert {:ok, raw} = Store.get_turn(id, 0)
    assert raw.input_provenance == imported.input_provenance
    refute Map.has_key?(raw.input_provenance, "sourceSessionKey")
    assert {:ok, original_result} = Store.get_turn(id, 5)
    assert [%{type: "tool_result", content: "Tool receipt"}] = original_result.parts
  end

  test "manual-event display policy and UTF-16 truncation leave raw durable text intact", ctx do
    raw = "HEARTBEAT_OK\n# **Deployment** complete."
    stamp = EventReply.stamp("ordinary-manual-occurrence")

    manual_id =
      persist(ctx.marker <> " manual", [
        message("user", "Review deployment status."),
        %{message("assistant", raw) | reply_presentation: stamp}
      ])

    unicode_id =
      persist(ctx.marker <> " unicode", [
        message("user", String.duplicate("A", 58) <> "😀tail"),
        message("assistant", String.duplicate("A", 236) <> "😀tail")
      ])

    assert {:ok, page} = enriched(ctx, %{})
    rows = Map.new(page.sessions, &{&1.id, &1})
    assert rows[manual_id].last_message_preview == "Deployment complete."
    assert rows[unicode_id].derived_title == String.duplicate("A", 58) <> "…"
    assert rows[unicode_id].last_message_preview == String.duplicate("A", 236) <> "..."
    assert String.valid?(rows[unicode_id].last_message_preview)
    assert {:ok, reloaded} = Store.get_turn(manual_id, 1)
    assert [%{type: "text", text: ^raw}] = reloaded.parts
    assert reloaded.reply_presentation == stamp
  end

  test "a selected page above one hundred retains every row but enriches only its first hundred",
       ctx do
    ids =
      for index <- 0..119 do
        persist(ctx.marker, [message("assistant", "Visible answer #{index}.")], %{
          updated_at: DateTime.add(~U[2026-01-01 00:00:00Z], -index, :second)
        })
      end

    {result, events} =
      observe(fn ->
        SessionDirectory.list(
          %{"search" => ctx.marker, "limit" => 200, "include_last_message" => true},
          ctx.context,
          node_executable: node_executable()
        )
      end)

    assert {:ok, page} = result
    assert page.count == 120
    assert page.limit_applied == 200
    assert page.has_more == false
    assert Enum.map(page.sessions, & &1.id) == ids

    for {row, index} <- Enum.with_index(page.sessions) do
      if index < 100 do
        assert row.last_message_preview == "Visible answer #{index}."
      else
        refute Map.has_key?(row, :last_message_preview)
      end
    end

    assert length(calls(events, ReadSnapshot, :capture)) == 120
    assert length(calls(events, ReadSnapshot, :read_page)) == 100
    assert [[handles]] = calls(events, ReadSnapshot, :validate_many)
    assert Enum.map(handles, & &1.session_id) == ids
    assert length(calls(events, :erlang, :open_port)) == 1
  end

  test "sparse head and tail widen once at fixed R and D then publish after one common V", ctx do
    id = Ecto.UUID.generate()
    meta = %{id: id, title: ctx.marker, agent: "archive"}
    assert :ok = Store.put_meta(id, meta)
    on_exit(fn -> Store.delete_session(id) end)

    for n <- 0..54 do
      turn =
        cond do
          n == 21 ->
            message("user", "Build the sparse session report.")

          n == 32 ->
            message("assistant", "# **Captured** answer.")

          n < 21 ->
            message("system", "Ordinary setup #{n}.")

          true ->
            %Message{
              role: "user",
              parts: [%ToolResult{tool_use_id: "receipt-#{n}", content: "Receipt"}]
            }
        end

      assert :ok = Store.commit_turn(id, n * 7, Message.encode(turn), meta)
    end

    deadline = System.monotonic_time(:millisecond) + 5_000

    mutation = fn ->
      edited = %{meta | title: ctx.marker <> " edited"}

      assert :ok =
               Store.commit_turn(
                 id,
                 999_999,
                 Message.encode(message("assistant", "Later answer.")),
                 edited
               )

      assert {:ok, revision} = KV.revision(engine: :turso)
      revision
    end

    {result, events} =
      observe(
        fn ->
          SessionDirectory.list(
            %{
              "search" => ctx.marker,
              "include_derived_titles" => true,
              "include_last_message" => true
            },
            ctx.context,
            deadline: deadline,
            node_executable: node_executable()
          )
        end,
        mutation
      )

    assert {:ok, %{sessions: [row]}} = result
    assert row.id == id
    assert row.title == ctx.marker
    assert row.derived_title == "Build the sparse session report."
    assert row.last_message_preview == "Captured answer."
    assert [[^id, capture_opts]] = calls(events, ReadSnapshot, :capture)
    assert capture_opts[:deadline] == deadline
    assert capture_opts[:max_bytes] == 1_048_576
    pages = calls(events, ReadSnapshot, :read_page)
    assert length(pages) == 4
    handles = Enum.map(pages, &hd/1)
    assert length(Enum.uniq(handles)) == 1
    [handle] = Enum.uniq(handles)
    assert handle.deadline == deadline

    assert Enum.sort(Enum.map(pages, fn [_handle, opts] -> {opts[:order], opts[:limit]} end)) ==
             [asc: 20, asc: 100, desc: 20, desc: 100]

    assert [[[^handle]]] = calls(events, ReadSnapshot, :validate_many)
    assert [{:mutation, committed}] = Enum.filter(events, &match?({:mutation, _}, &1))

    assert [{:return, ReadSnapshot, :validate_many, {:ok, validation}}] =
             Enum.filter(events, &match?({:return, ReadSnapshot, :validate_many, _}, &1))

    assert validation.revision >= committed
    assert validation.revision > handle.revision
    assert validation.targets == [%{session_id: id, same_lifecycle: true}]
    assert length(calls(events, :erlang, :open_port)) == 1

    validation_index =
      Enum.find_index(events, &match?({:call, ReadSnapshot, :validate_many, _}, &1))

    assert Enum.any?(Enum.take(events, validation_index), &match?({:port_exit, _, 0}, &1))

    refute Enum.any?(Enum.drop(events, validation_index + 1), fn
             {:call, ReadSnapshot, :read_page, _} -> true
             {:call, KV, :get, [key, _]} -> String.starts_with?(key, Store.turns_prefix(id))
             _ -> false
           end)

    for {:call, KV, :get, [key, options]} <- events,
        String.starts_with?(key, Store.turns_prefix(id)) do
      assert options[:revision] == handle.revision
    end
  end

  defp enriched(ctx, input) do
    SessionDirectory.list(
      Map.merge(
        %{
          "search" => ctx.marker,
          "include_derived_titles" => true,
          "include_last_message" => true
        },
        input
      ),
      ctx.context,
      node_executable: node_executable()
    )
  end

  defp persist(title, messages, extra \\ %{}) do
    id = Ecto.UUID.generate()
    meta = Map.merge(%{id: id, title: title, agent: "archive"}, extra)
    assert :ok = Message.persist_list(id, messages, meta)
    on_exit(fn -> Store.delete_session(id) end)
    id
  end

  defp message(role, text), do: %Message{role: role, parts: [%Text{content: text}]}

  defp node_executable,
    do:
      System.get_env("SYNAPSIS_FILESYSTEM_NODE") || System.find_executable("node") ||
        System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")

  defp calls(events, module, function),
    do: for({:call, ^module, ^function, args} <- events, do: args)

  defp observe(fun, mutation \\ nil) do
    for {module, _, _} <- @observed, do: Code.ensure_loaded!(module)
    owner = self()
    observer = spawn(fn -> collect(owner, [], [], mutation) end)
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

  defp collect(owner, events, children, mutation) do
    receive do
      {:trace, _, :call, {module, function, args}} ->
        collect(owner, [{:call, module, function, args} | events], children, mutation)

      {:trace, _, :return_from, {ReadSnapshot, :capture, 2}, {:ok, _handle} = result}
      when is_function(mutation, 0) ->
        committed = mutation.()

        collect(
          owner,
          [{:mutation, committed}, {:return, ReadSnapshot, :capture, result} | events],
          children,
          nil
        )

      {:trace, _, :return_from, {module, function, _}, value} ->
        collect(owner, [{:return, module, function, value} | events], children, mutation)

      {:trace, _, :receive, {port, {:exit_status, status}}} when is_port(port) ->
        collect(owner, [{:port_exit, port, status} | events], children, mutation)

      {:trace, _, :spawn, child, _} ->
        collect(owner, events, [child | children], mutation)

      :snapshot ->
        send(owner, {:observed, self(), Enum.reverse(events)})
        collect(owner, events, children, mutation)

      :stop ->
        for child <- children do
          try do
            :erlang.trace(child, false, [:call, :procs, :receive, :set_on_spawn])
          rescue
            ArgumentError -> :ok
          end
        end

      _ ->
        collect(owner, events, children, mutation)
    end
  end
end
