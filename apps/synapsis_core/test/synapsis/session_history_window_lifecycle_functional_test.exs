defmodule Synapsis.SessionHistoryWindowLifecycleTrace do
  @moduledoc false
  import ExUnit.Assertions

  alias Synapsis.Session.ReadSnapshot
  alias Synapsis.SessionDirectory.Projection.PortSession
  alias Synapsis.SessionHistory

  @observed [
    {SessionHistory, :read_rendered, 3},
    {ReadSnapshot, :capture, 2},
    {ReadSnapshot, :read_pending, 2},
    {ReadSnapshot, :ordinal_window, 2},
    {ReadSnapshot, :tail_index, 2},
    {ReadSnapshot, :read_page, 2},
    {ReadSnapshot, :validate_many, 1},
    {Concord.KV, :get, 2},
    {Concord.KV, :list, 1},
    {PortSession, :run, 3},
    {Synapsis.Message, :list_by_session, 1},
    {Synapsis.Session.Store, :list_turns, 1},
    {:erlang, :open_port, 2},
    {:erlang, :port_command, 3}
  ]

  def observe(fun) do
    for {module, _, _} <- @observed, do: Code.ensure_loaded!(module)
    observer = spawn(fn -> collect([], []) end)
    monitor = Process.monitor(observer)
    for mfa <- @observed, do: :erlang.trace_pattern(mfa, [{:_, [], [{:return_trace}]}], [:local])
    :erlang.trace(:all, true, [:call, :monotonic_timestamp, {:tracer, observer}])

    try do
      result = fun.()
      barrier = :erlang.trace_delivered(:all)
      assert_receive {:trace_delivered, :all, ^barrier}, 5_000
      send(observer, {:snapshot, self()})
      assert_receive {:window291_events, ^observer, events}, 5_000
      {result, Enum.sort_by(events, & &1.at)}
    after
      :erlang.trace(:all, false, [:call, :monotonic_timestamp])
      for mfa <- @observed, do: :erlang.trace_pattern(mfa, false, [:local])
      send(observer, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^observer, :normal}, 5_000
    end
  end

  def calls(events, module, function),
    do:
      Enum.filter(events, &(&1.kind == :call and &1.module == module and &1.function == function))

  def returns(events, module, function),
    do:
      Enum.filter(
        events,
        &(&1.kind == :return and &1.module == module and &1.function == function)
      )

  defp collect(events, receivers) do
    receive do
      {:trace_ts, pid, :call, {module, function, args}, at} ->
        receivers =
          if {module, function} in [{SessionHistory, :read_rendered}, {PortSession, :run}] do
            :erlang.trace(pid, true, [:receive, :monotonic_timestamp, {:tracer, self()}])
            [pid | receivers]
          else
            receivers
          end

        collect(
          [
            %{kind: :call, module: module, function: function, args: args, pid: pid, at: at}
            | events
          ],
          receivers
        )

      {:trace_ts, pid, :return_from, {module, function, _arity}, result, at} ->
        collect(
          [
            %{kind: :return, module: module, function: function, result: result, pid: pid, at: at}
            | events
          ],
          receivers
        )

      {:trace_ts, pid, :receive, {port, {:data, data}}, at} when is_port(port) ->
        collect(
          [%{kind: :port_data, pid: pid, port: port, data: data, at: at} | events],
          receivers
        )

      {:trace_ts, pid, :receive, {port, {:exit_status, status}}, at} when is_port(port) ->
        collect(
          [%{kind: :port_exit, pid: pid, port: port, status: status, at: at} | events],
          receivers
        )

      {:trace_ts, _pid, :receive, _other, _at} ->
        collect(events, receivers)

      {:snapshot, owner} ->
        send(owner, {:window291_events, self(), events})
        collect(events, receivers)

      :stop ->
        for pid <- Enum.uniq(receivers) do
          try do
            :erlang.trace(pid, false, [:receive, :monotonic_timestamp])
          rescue
            ArgumentError -> :ok
          end
        end

        :ok
    end
  end
end

defmodule Synapsis.SessionHistoryWindowLifecycleFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Message
  alias Synapsis.Part.Text
  alias Synapsis.Session.{EventReply, PendingInputStore, ReadSnapshot, Store}
  alias Synapsis.SessionDirectory.Projection.PortSession
  alias Synapsis.{SessionHistory, SessionHistoryWindowLifecycleTrace}

  @moduletag timeout: 60_000

  setup do
    assert :ok = Store.ensure_started()
    :ok
  end

  test "one original owner revision and deadline gates publication after worker closed and actual Node exit zero" do
    messages = [message("user", "Ordinary question 雪"), message("assistant", "Ordinary answer 😀")]
    id = persist(messages)
    assert {:ok, pending} = PendingInputStore.append_prompt(id, "Queued next question", [])
    before = System.monotonic_time(:millisecond)
    deadline = before + 5_000

    {result, events} =
      SessionHistoryWindowLifecycleTrace.observe(fn ->
        SessionHistory.read_rendered(%{"limit" => 2}, %{session_id: id, agent_id: "reader"},
          deadline: deadline,
          node_executable: node_executable()
        )
      end)

    assert {:ok, rendered} = result
    assert Jason.decode!(rendered.text) == rendered.page
    assert rendered.page["session_id"] == id

    assert [
             %{
               "id" => pending_id,
               "acceptedAt" => accepted,
               "state" => "queued",
               "kind" => "prompt"
             }
           ] =
             Enum.map(
               rendered.page["pendingInputs"]["items"],
               &Map.take(&1, ~w(id acceptedAt state kind))
             )

    assert {pending_id, accepted} == {pending.id, pending.inserted_at}
    assert [captured] = returns(events, ReadSnapshot, :capture)
    assert {:ok, snapshot} = captured.result
    assert snapshot.owner == {:concord_turso, Process.whereis(Concord.Turso.DB)}
    assert snapshot.deadline == deadline
    assert [capture] = calls(events, ReadSnapshot, :capture)
    assert [^id, opts] = capture.args
    assert opts[:deadline] == deadline
    assert [validation] = calls(events, ReadSnapshot, :validate_many)
    assert validation.args == [[snapshot]]
    assert [validated] = returns(events, ReadSnapshot, :validate_many)
    assert {:ok, %{revision: revision, targets: [_]}} = validated.result
    assert revision >= snapshot.revision

    for function <- [:read_page, :read_pending, :ordinal_window, :tail_index],
        call <- calls(events, ReadSnapshot, function) do
      assert [^snapshot, options] = call.args
      assert Keyword.keyword?(options)
      assert call.at < validation.at
    end

    assert calls(events, ReadSnapshot, :read_pending) != []
    assert calls(events, ReadSnapshot, :read_page) != []
    assert [helper] = calls(events, PortSession, :run)
    assert [_, ^deadline, _] = helper.args
    assert [opened] = returns(events, :erlang, :open_port)
    port = opened.result
    assert is_port(port)

    assert [closed] =
             Enum.filter(events, fn event ->
               event.kind == :port_data and event.port == port and closed?(event.data)
             end)

    assert [exited] = Enum.filter(events, &(&1.kind == :port_exit and &1.port == port))
    assert exited.status == 0
    assert closed.at < exited.at
    assert exited.at < validation.at
    assert calls(events, Message, :list_by_session) == []
    assert calls(events, Store, :list_turns) == []

    for event <- calls(events, Concord.KV, :get),
        event.at < validation.at,
        [key, options] = event.args,
        String.starts_with?(key, "sessions/" <> id <> "/") do
      assert options[:revision] == snapshot.revision
      assert options[:timeout] in 1..5_000
    end

    participants =
      Enum.uniq(
        Enum.map(
          calls(events, SessionHistory, :read_rendered) ++
            calls(events, PortSession, :run) ++ calls(events, ReadSnapshot, :read_page),
          & &1.pid
        )
      )

    for event <- events,
        event.kind == :call and event.at > validated.at and event.pid in participants do
      refute event.module in [ReadSnapshot, Concord.KV, PortSession, Message, Store]
    end

    assert Port.info(port) == nil
  end

  test "real EventReply sidecars hide and rewrite display while retaining durable raw ranks and next offsets" do
    stamp = EventReply.stamp("ordinary-history291-event")
    first = message("user", "Read the event report.")
    plain = message("assistant", "Earlier ordinary reply.")

    rewritten = %{
      message("assistant", "HEARTBEAT_OK\nReport ready 雪 😀")
      | reply_presentation: stamp
    }

    hidden = %{message("assistant", "HEARTBEAT_OK") | reply_presentation: stamp}
    assert %{hidden: false, text: "Report ready 雪 😀"} = EventReply.project(rewritten)
    assert %{hidden: true, text: ""} = EventReply.project(hidden)
    id = persist([first, plain, rewritten, hidden])
    assert {:ok, original} = Store.list_turns(id)
    input = %{"limit" => 2, "offset" => 0}

    assert {:ok, rendered} =
             SessionHistory.read_rendered(input, %{session_id: id, agent_id: "reader"},
               node_executable: node_executable()
             )

    assert rendered.page["offset"] == 0
    assert rendered.page["nextOffset"] == 3
    assert rendered.page["totalMessages"] == 4
    assert rendered.page["hasMore"] == true

    assert rendered.page["messages"] == [
             source(plain, 2, "Earlier ordinary reply."),
             source(rewritten, 3, "Report ready 雪 😀")
           ]

    assert Jason.decode!(rendered.text) == rendered.page

    assert {:ok, older} =
             SessionHistory.read_rendered(
               %{"limit" => 2, "offset" => 3},
               %{session_id: id, agent_id: "reader"},
               node_executable: node_executable()
             )

    assert older.page["messages"] == [source(first, 1, "Read the event report.")]
    assert older.page["offset"] == 3
    refute Map.has_key?(older.page, "nextOffset")
    assert older.page["totalMessages"] == 4
    assert older.page["hasMore"] == false
    assert Store.list_turns(id) == {:ok, original}
    assert {:ok, raw} = Store.get_turn(id, 14)
    assert raw.reply_presentation == stamp
    assert hd(raw.parts).text == "HEARTBEAT_OK\nReport ready 雪 😀"
    assert {:ok, raw_hidden} = Store.get_turn(id, 21)
    assert hd(raw_hidden.parts).text == "HEARTBEAT_OK"
  end

  defp message(role, text),
    do: %Message{
      id: Ecto.UUID.generate(),
      role: role,
      inserted_at: ~U[2026-11-06 00:00:00.000000Z],
      parts: [%Text{content: text}]
    }

  defp source(message, ordinal, text),
    do: %{
      "role" => message.role,
      "timestamp" => DateTime.to_iso8601(message.inserted_at),
      "__openclaw" => %{"id" => message.id, "seq" => ordinal},
      "content" => [%{"type" => "text", "text" => text}]
    }

  defp persist(messages) do
    id = Ecto.UUID.generate()
    assert :ok = Store.put_meta(id, %{id: id, agent: "archive", title: "Event history 雪"})

    for {message, index} <- Enum.with_index(messages),
        do:
          assert(
            :ok =
              Store.commit_turn(id, index * 7, Message.encode(message), %{
                id: id,
                agent: "archive"
              })
          )

    on_exit(fn -> Store.delete_session(id) end)
    id
  end

  defp closed?({:eol, body}) do
    case Jason.decode(body) do
      {:ok, %{"type" => "closed", "runtime" => %{"workerExitObserved" => true}}} -> true
      _ -> false
    end
  end

  defp closed?(_), do: false

  defp calls(events, module, function),
    do: SessionHistoryWindowLifecycleTrace.calls(events, module, function)

  defp returns(events, module, function),
    do: SessionHistoryWindowLifecycleTrace.returns(events, module, function)

  defp node_executable,
    do:
      System.get_env("SYNAPSIS_FILESYSTEM_NODE") || System.find_executable("node") ||
        System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")
end
