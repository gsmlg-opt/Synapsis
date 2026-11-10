defmodule Synapsis.SessionReadAdoptionFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Concord.Turso
  alias Synapsis.Session.Store
  alias Synapsis.{SessionDirectory, SessionHistory, SessionStatus}

  @budget 4_000

  # Ordinary success observations of the installed public read chain. Source in
  # the three readers composes one absolute deadline; these traces establish the
  # actual options and values at its public boundaries, not an expiry guarantee.
  @reads [
    {Store, :get_meta, 2},
    {Store, :list_turn_page, 2},
    {Store, :list_session_ids, 1},
    {Turso, :get, 2},
    {Turso, :list, 1},
    {Concord, :get, 2}
  ]

  setup do
    assert :ok = Store.ensure_started()
    id = Ecto.UUID.generate()
    %{id: id, context: %{session_id: id, agent_id: "adoption-reader"}}
  end

  test "sparse history preserves Unicode, exclusive cursors and exact public parts", ctx do
    meta = persist(ctx.id, %{title: "History 世界", agent: "adoption-reader"})

    projection = %{
      "version" => 1,
      "result" => %{"content" => "完成 雪", "structured" => %{"count" => 2}}
    }

    call = %{type: "tool_use", id: "call-7", name: "example", input: %{"label" => "雪"}}

    reply = %{
      type: "tool_result",
      tool_use_id: "call-7",
      content: "完成 雪",
      is_error: false,
      projection: projection
    }

    turns = %{
      0 => %{role: "user", parts: [%{type: "text", text: "  Hello\n世界 🧭  "}]},
      7 => %{
        role: "assistant",
        parts: [call, reply, %{type: "file", path: "报告.txt", content: "ordinary body"}]
      },
      91 => %{role: "user", parts: [%{type: "text", text: "Next\n雪"}]}
    }

    for {index, turn} <- turns do
      assert :ok = Store.commit_turn(ctx.id, index, turn, meta)
    end

    file = %{type: "file", path: "报告.txt", omitted: true, reason: "content_not_included"}

    first_expected = %{
      source: "durable",
      session_id: ctx.id,
      has_more: true,
      next_cursor: 7,
      truncated: false,
      turns: [
        %{index: 0, role: "user", parts: turns[0].parts, omitted_tool_parts: 0},
        %{index: 7, role: "assistant", parts: [call, file], omitted_tool_parts: 1}
      ]
    }

    deadline = deadline()

    {result, events} =
      observe(fn -> SessionHistory.read(%{"limit" => 2}, ctx.context, deadline: deadline) end)

    assert result == {:ok, first_expected}
    assert_history_reads(events, ctx.id, meta, turns, deadline, nil, 2, [0, 7], [0, 7, 91])

    deadline = deadline()

    {result, events} =
      observe(fn ->
        SessionHistory.read(
          %{"session_id" => ctx.id, "cursor" => 0, "limit" => 1, "include_tools" => true},
          ctx.context,
          deadline: deadline
        )
      end)

    assert result ==
             {:ok,
              %{
                first_expected
                | turns: [
                    %{
                      index: 7,
                      role: "assistant",
                      parts: [call, reply, file],
                      omitted_tool_parts: 0
                    }
                  ]
              }}

    assert_history_reads(events, ctx.id, meta, turns, deadline, 0, 1, [7], [7, 91])

    deadline = deadline()

    {result, events} =
      observe(fn ->
        SessionHistory.read(
          %{"session_id" => ctx.id, "cursor" => first_expected.next_cursor},
          ctx.context,
          deadline: deadline
        )
      end)

    assert result ==
             {:ok,
              %{
                first_expected
                | has_more: false,
                  next_cursor: nil,
                  turns: [
                    %{index: 91, role: "user", parts: turns[91].parts, omitted_tool_parts: 0}
                  ]
              }}

    assert_history_reads(events, ctx.id, meta, turns, deadline, 7, 20, [91], [91])
  end

  test "directory filters neutral UUID metadata before stable recency and offset pages", ctx do
    tag = "adoption-#{ctx.id} 雪"
    agent = "reader-#{ctx.id}"
    ids = for _ <- 1..6, do: Ecto.UUID.generate()
    [old, tie_a, tie_b, undated, other_agent, other_title] = ids
    tied = Enum.sort([tie_a, tie_b])

    metadata =
      Map.new(
        [
          {old, %{updated_at: "2024-01-01T00:00:00Z"}},
          {tie_a, %{updated_at: ~U[2025-01-01 00:00:00Z]}},
          {tie_b, %{updated_at: "2025-01-01T08:00:00+08:00"}},
          {undated, %{}},
          {other_agent, %{agent: "another-reader", updated_at: ~U[2026-01-01 00:00:00Z]}},
          {other_title, %{title: "Another directory entry", updated_at: ~U[2026-01-01 00:00:00Z]}}
        ],
        fn {id, fields} ->
          base = %{
            title: tag,
            agent: agent,
            provider: "fixture-provider",
            model: "fixture-model",
            status: "idle",
            inserted_at: ~U[2023-01-01 00:00:00Z],
            config: %{"ordinary_setting" => "retained raw metadata"}
          }

          {id, persist(id, Map.merge(base, fields))}
        end
      )

    input = %{"search" => String.upcase(tag), "agent" => agent, "limit" => 2}

    for {offset, selected, more} <- [{0, tied, true}, {2, [old, undated], false}] do
      deadline = deadline()

      {result, events} =
        observe(fn ->
          SessionDirectory.list(Map.put(input, "offset", offset), ctx.context, deadline: deadline)
        end)

      rows =
        Enum.map(selected, fn id ->
          %{
            id: id,
            title: tag,
            agent: agent,
            provider: "fixture-provider",
            model: "fixture-model",
            status: "idle",
            inserted_at: "2023-01-01T00:00:00Z",
            updated_at:
              cond do
                id in tied -> "2025-01-01T00:00:00Z"
                id == old -> "2024-01-01T00:00:00Z"
                true -> nil
              end
          }
        end)

      expected = %{
        source: "durable",
        sessions: rows,
        count: 2,
        has_more: more,
        limit_applied: 2
      }

      expected = if more, do: Map.put(expected, :next_offset, 2), else: expected
      assert result == {:ok, expected}
      assert_directory_reads(events, deadline, metadata)
    end
  end

  test "durable status reads one exact record and normalizes only public timestamps", ctx do
    target = Ecto.UUID.generate()

    meta =
      persist(target, %{
        title: "Stored 世界 🧭",
        agent: "archive",
        provider: "fixture-provider",
        model: "fixture-model",
        status: "idle",
        inserted_at: ~U[2026-10-26 01:00:00.123456Z],
        updated_at: "2026-10-26T09:02:03.654321+08:00",
        config: %{"ordinary_setting" => "durable value"}
      })

    deadline = deadline()

    {result, events} =
      observe(fn ->
        SessionStatus.read(
          %{"session_id" => target, "source" => "durable"},
          ctx.context,
          deadline: deadline
        )
      end)

    assert result ==
             {:ok,
              %{
                source: "durable",
                session: %{
                  id: target,
                  title: "Stored 世界 🧭",
                  agent: "archive",
                  provider: "fixture-provider",
                  model: "fixture-model",
                  status: "idle",
                  inserted_at: "2026-10-26T01:00:00.123456Z",
                  updated_at: "2026-10-26T01:02:03.654321Z"
                }
              }}

    assert [{reader, [^target, opts]}] = calls(events, Store, :get_meta)
    assert reader != self()
    assert opts[:timeout] in 1..@budget
    assert_public_gets(events, reader, [{Store.meta_key(target), meta}])
    assert calls(events, Store, :list_turn_page) == []
    assert calls(events, Store, :list_session_ids) == []
    assert calls(events, Turso, :list) == []
    assert returns(events, Store, :get_meta) == [{reader, {:ok, meta}}]
  end

  defp persist(id, fields) do
    on_exit(fn -> assert :ok = Store.delete_session(id) end)
    meta = Map.put(fields, :id, id)
    assert :ok = Store.put_meta(id, meta)
    meta
  end

  defp assert_history_reads(
         events,
         id,
         meta,
         turns,
         deadline,
         cursor,
         limit,
         selected,
         candidates
       ) do
    assert [{reader, [^id, meta_opts]}] = calls(events, Store, :get_meta)
    assert reader != self()
    assert meta_opts[:timeout] in 1..@budget
    assert [{^reader, [^id, page_opts]}] = calls(events, Store, :list_turn_page)
    expected_opts = [deadline: deadline, limit: limit, max_bytes: 1_048_576]

    expected_opts =
      if is_nil(cursor), do: expected_opts, else: Keyword.put(expected_opts, :cursor, cursor)

    assert Enum.sort(page_opts) == Enum.sort(expected_opts)
    assert calls(events, Store, :list_session_ids) == []

    expected_gets = [
      {Store.meta_key(id), meta} | Enum.map(selected, &{Store.turn_key(id, &1), turns[&1]})
    ]

    assert_public_gets(events, reader, expected_gets)
    assert returns(events, Store, :get_meta) == [{reader, {:ok, meta}}]

    assert [{^reader, {:ok, stored_page}}] = returns(events, Store, :list_turn_page)
    assert stored_page.turns == Enum.map(selected, &%{index: &1, turn: turns[&1]})

    lists = calls(events, Turso, :list)
    assert lists != []

    start =
      if is_nil(cursor), do: Store.turns_prefix(id), else: Store.turn_key(id, cursor) <> <<0>>

    starts = [start | Enum.map(Enum.drop(candidates, -1), &(Store.turn_key(id, &1) <> <<0>>))]

    starts =
      if stored_page.has_more,
        do: starts,
        else: starts ++ [Store.turn_key(id, List.last(candidates)) <> <<0>>]

    assert Enum.map(lists, fn {pid, [opts]} ->
             assert pid == reader
             assert opts[:timeout] in 1..@budget
             assert opts[:keys_only] == true
             assert opts[:queue] == true
             assert opts[:limit] == 1
             {first, last} = opts[:range]
             assert last == Store.session_prefix(id) <> "turns0"
             first
           end) == starts

    keys =
      for {^reader, {:ok, rows, _cursor}} <- returns(events, Turso, :list),
          row <- rows,
          do: row.key

    assert keys == Enum.map(candidates, &Store.turn_key(id, &1))

    public_order =
      for {:call, ^reader, Turso, function, _args} <- events,
          do: function

    assert public_order ==
             [:get] ++
               List.duplicate(:list, length(lists)) ++
               List.duplicate(:get, length(selected))

    core_order =
      for {:call, ^reader, Store, function, _args} <- events,
          do: function

    assert core_order == [:get_meta, :list_turn_page]
  end

  defp assert_directory_reads(events, deadline, metadata) do
    pages = returns(events, Store, :list_session_ids)
    assert [{reader, _} | _] = pages
    assert reader != self()

    expected_order =
      Enum.flat_map(pages, fn {pid, {:ok, page}} ->
        assert pid == reader
        [:list_session_ids | Enum.map(page.session_ids, &{:get_meta, &1})]
      end)

    actual_order =
      for {:call, ^reader, Store, function, args} <- events do
        case {function, args} do
          {:list_session_ids, [_opts]} -> :list_session_ids
          {:get_meta, [id, _opts]} -> {:get_meta, id}
        end
      end

    assert actual_order == expected_order
    page_calls = calls(events, Store, :list_session_ids)
    assert length(page_calls) == length(pages)

    Enum.with_index(page_calls, fn {pid, [opts]}, index ->
      assert pid == reader
      assert opts[:deadline] == deadline
      assert opts[:limit] == 100

      expected_cursor =
        if index > 0 do
          {_, {:ok, previous}} = Enum.at(pages, index - 1)
          previous.next_cursor
        end

      assert opts[:cursor] == expected_cursor
    end)

    reads = calls(events, Store, :get_meta)
    assert reads != []

    for {pid, [_id, opts]} <- reads do
      assert pid == reader
      assert opts[:timeout] in 1..@budget
    end

    values = returns(events, Store, :get_meta)
    assert length(reads) == length(values)

    expected_gets =
      Enum.zip_with(reads, values, fn {_, [id, _opts]}, {pid, {:ok, value}} ->
        assert pid == reader
        if Map.has_key?(metadata, id), do: assert(value == metadata[id])
        {Store.meta_key(id), value}
      end)

    assert MapSet.subset?(
             MapSet.new(Map.keys(metadata)),
             MapSet.new(for {_, [id, _]} <- reads, do: id)
           )

    assert_public_gets(events, reader, expected_gets)
    assert calls(events, Store, :list_turn_page) == []

    for {pid, [opts]} <- calls(events, Turso, :list) do
      assert pid == reader
      assert opts[:timeout] in 1..@budget
      assert opts[:keys_only] == true
      assert opts[:limit] == 1
      {first, last} = opts[:range]
      assert String.starts_with?(first, "sessions/")
      assert last == "sessions0"
    end

    assert calls(events, Turso, :list) != []
  end

  defp assert_public_gets(events, reader, expected) do
    turso = calls(events, Turso, :get)

    assert Enum.map(turso, fn {pid, [key, opts]} ->
             assert pid == reader
             assert opts[:timeout] in 1..@budget
             key
           end) == Enum.map(expected, &elem(&1, 0))

    assert returns(events, Turso, :get) ==
             Enum.map(expected, fn {_, value} -> {reader, {:ok, value}} end)

    public_meta = Enum.filter(turso, fn {_, [key, _]} -> String.ends_with?(key, "/meta") end)
    metadata_reads = calls(events, Store, :get_meta)
    assert length(public_meta) == length(metadata_reads)

    Enum.zip_with(metadata_reads, public_meta, fn {_, [id, opts]}, {pid, [key, forwarded_opts]} ->
      assert pid == reader
      assert key == Store.meta_key(id)
      assert forwarded_opts == opts
    end)

    # The real Turso facade forwards to Concord.get with the same public timeout.
    concord = calls(events, Concord, :get)
    assert length(concord) == length(turso)

    Enum.zip_with(turso, concord, fn {_, [key, opts]}, {pid, [forwarded_key, forwarded_opts]} ->
      assert pid == reader
      assert forwarded_key == key
      assert forwarded_opts[:engine] == Concord.Engine.Turso
      assert forwarded_opts[:timeout] == opts[:timeout]
    end)
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @budget

  defp calls(events, module, function) do
    for {:call, pid, ^module, ^function, args} <- events, do: {pid, args}
  end

  defp returns(events, module, function) do
    for {:return, pid, ^module, ^function, value} <- events, do: {pid, value}
  end

  defp observe(fun) do
    for {module, _, _} <- @reads, do: Code.ensure_loaded!(module)
    owner = self()
    observer = spawn(fn -> collect(owner, [], []) end)
    monitor = Process.monitor(observer)

    on_exit(fn ->
      for mfa <- @reads, do: :erlang.trace_pattern(mfa, false, [:local])
      send(observer, :stop)
    end)

    for mfa <- @reads do
      :erlang.trace_pattern(mfa, [{:_, [], [{:return_trace}]}], [:local])
    end

    :erlang.trace(self(), true, [:call, :procs, :set_on_spawn, {:tracer, observer}])

    try do
      result = fun.()
      delivered = :erlang.trace_delivered(:all)
      assert_receive {:trace_delivered, :all, ^delivered}, 5_000
      send(observer, :snapshot)
      assert_receive {:observed, ^observer, events}, 5_000
      {result, events}
    after
      :erlang.trace(self(), false, [:call, :procs, :set_on_spawn])
      for mfa <- @reads, do: :erlang.trace_pattern(mfa, false, [:local])
      send(observer, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^observer, :normal}, 5_000
    end
  end

  defp collect(owner, events, children) do
    receive do
      {:trace, pid, :call, {module, function, args}} ->
        collect(owner, [{:call, pid, module, function, args} | events], children)

      {:trace, pid, :return_from, {module, function, _arity}, value} ->
        collect(owner, [{:return, pid, module, function, value} | events], children)

      {:trace, _pid, :spawn, child, _mfa} ->
        collect(owner, events, [child | children])

      :snapshot ->
        send(owner, {:observed, self(), Enum.reverse(events)})
        collect(owner, events, children)

      :stop ->
        for child <- children do
          try do
            :erlang.trace(child, false, [:call, :procs, :set_on_spawn])
          rescue
            ArgumentError -> :ok
          end
        end

      _other ->
        collect(owner, events, children)
    end
  end
end
