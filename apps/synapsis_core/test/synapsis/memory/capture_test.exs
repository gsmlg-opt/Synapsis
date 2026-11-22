defmodule Synapsis.Memory.CaptureTest do
  use ExUnit.Case, async: false
  alias Synapsis.Config.Store, as: Config
  alias Synapsis.Memory.{Capture, HostAgent, Settings}
  alias Synapsis.Session.Store

  @moduletag :tmp_dir
  @server __MODULE__.Server

  setup %{tmp_dir: root} do
    Store.ensure_started()
    previous = Config.get(:memory, "default")
    fixture = Gaoxy.Test.open()

    source = %{
      id: "backplane-host",
      endpoint: String.trim_trailing(Gaoxy.Test.url(fixture), "/"),
      agent_id: "synapsis"
    }

    config = %{
      "backend" => "workspace",
      "host_agent" => %{
        "enabled" => true,
        "endpoint" => source.endpoint,
        "agent_id" => "synapsis"
      }
    }

    assert {:ok, _} = Settings.save(config)
    context = %{session_id: Ecto.UUID.generate(), cwd: root, agent_id: "selected-agent"}
    start_supervised!({Capture, name: @server})

    on_exit(fn ->
      Store.delete_session(context.session_id)

      case previous do
        {:ok, entry} -> Config.put(:memory, entry)
        {:error, :not_found} -> Config.delete(:memory, "default")
      end
    end)

    %{fixture: fixture, context: context, source: source, config: config}
  end

  test "four hooks preserve exact supported payloads, identity, UTC time and trusted cwd", ctx do
    test = self()

    hooks = [
      {"session-start", %{}},
      {"user-prompt-submit", %{"message_id" => "accepted-message", "content" => "Use Concord"}},
      {"post-tool-use",
       %{
         "tool_call_id" => "run:tool",
         "tool_name" => "synapsis::read",
         "is_error" => false,
         "result" => %{"content" => "public result"}
       }},
      {"session-end", %{"reason" => "normal"}}
    ]

    for {hook, payload} <- hooks do
      Gaoxy.Test.expect_once(
        ctx.fixture,
        "POST",
        "/capture/v1/hooks/synapsis/" <> hook,
        fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          event = Formata.JSON.decode!(body)

          logical =
            case hook do
              "user-prompt-submit" -> payload["message_id"]
              "post-tool-use" -> payload["tool_call_id"]
              _ -> "session"
            end

          suffix =
            "memory_capture_" <>
              Base.url_encode64(:crypto.hash(:sha256, hook <> ":" <> logical), padding: false)

          assert {:ok, %{value: %{"state" => "reserved", "event" => ^event}}} =
                   Store.value_snapshot(ctx.context.session_id, suffix)

          send(test, {:captured, hook, event, conn.req_headers})
          reply(conn, event)
        end
      )

      assert :ok = Capture.emit(ctx.context, hook, payload, @server)
      assert_receive {:captured, ^hook, event, headers}, 2_000
      assert event["schema_version"] == "1.0"
      assert Ecto.UUID.cast(event["event_id"]) == {:ok, event["event_id"]}
      assert event["session_id"] == ctx.context.session_id
      assert event["cwd"] == ctx.context.cwd
      assert event["agent_id"] == ctx.context.agent_id
      assert {:ok, _, 0} = DateTime.from_iso8601(event["timestamp"])
      assert event["payload"] == payload
      refute Enum.any?(headers, fn {name, _} -> name in ~w(authorization cookie x-api-key) end)
      settle()
    end
  end

  test "durable reservation prevents duplicate prompt sends across capture-process restart",
       ctx do
    test = self()

    Gaoxy.Test.expect_once(
      ctx.fixture,
      "POST",
      "/capture/v1/hooks/synapsis/user-prompt-submit",
      fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        event = Formata.JSON.decode!(body)
        send(test, {:captured, event})
        reply(conn, event)
      end
    )

    payload = %{"message_id" => "durably-accepted", "content" => "one logical prompt"}
    Capture.emit(ctx.context, "user-prompt-submit", payload, @server)
    assert_receive {:captured, original}, 2_000
    settle()
    assert length(Gaoxy.Test.requests(ctx.fixture).entries) == 1
    stop_supervised!(Capture)
    start_supervised!({Capture, name: @server})
    Capture.emit(ctx.context, "user-prompt-submit", payload, @server)
    settle()
    assert length(Gaoxy.Test.requests(ctx.fixture).entries) == 1

    suffix =
      "memory_capture_" <>
        Base.url_encode64(:crypto.hash(:sha256, "user-prompt-submit:durably-accepted"),
          padding: false
        )

    assert {:ok, %{value: %{"state" => "reserved", "event" => ^original}}} =
             Store.value_snapshot(ctx.context.session_id, suffix)
  end

  test "an unavailable host is never retried even when the same event arrives again", ctx do
    Gaoxy.Test.expect_once(
      ctx.fixture,
      "POST",
      "/capture/v1/hooks/synapsis/session-start",
      &Plug.Conn.resp(&1, 503, "unavailable")
    )

    Capture.emit(ctx.context, "session-start", %{}, @server)
    settle()
    Capture.emit(ctx.context, "session-start", %{}, @server)
    settle()
    assert length(Gaoxy.Test.requests(ctx.fixture).entries) == 1
    assert Process.alive?(Process.whereis(@server))
  end

  test "disabled sources, invalid context and oversized results are dropped without HTTP", ctx do
    assert {:ok, _} = Settings.save(put_in(ctx.config, ["host_agent", "enabled"], false))
    Capture.emit(ctx.context, "session-start", %{}, @server)
    settle()
    Capture.emit(%{ctx.context | cwd: "relative"}, "session-start", %{}, @server)

    Capture.emit(
      ctx.context,
      "post-tool-use",
      %{
        "tool_call_id" => "call",
        "tool_name" => "read",
        "is_error" => false,
        "result" => String.duplicate("x", 65_537)
      },
      @server
    )

    assert :ets.lookup(@server, :slots) == [{:slots, 0}]
    assert Gaoxy.Test.requests(ctx.fixture).entries == []
  end

  test "admission and task concurrency stay bounded while the host does not answer", ctx do
    test = self()

    Gaoxy.Test.stub(
      ctx.fixture,
      "POST",
      "/capture/v1/hooks/synapsis/user-prompt-submit",
      fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        event = Formata.JSON.decode!(body)
        send(test, {:waiting, self()})

        receive do
          :release -> reply(conn, event)
        after
          2_500 -> reply(conn, event)
        end
      end
    )

    for n <- 1..100 do
      assert :ok =
               Capture.emit(
                 ctx.context,
                 "user-prompt-submit",
                 %{"message_id" => "message-#{n}", "content" => "bounded"},
                 @server
               )
    end

    state = :sys.get_state(@server)
    assert map_size(state.tasks) <= 4
    assert :queue.len(state.queue) <= 32
    [{:slots, count}] = :ets.lookup(@server, :slots)
    assert count <= 32

    handlers =
      for _ <- 1..map_size(state.tasks) do
        assert_receive {:waiting, handler}, 2_000
        handler
      end

    assert {:ok, _} = Settings.save(put_in(ctx.config, ["host_agent", "enabled"], false))
    for handler <- handlers, do: send(handler, :release)
    settle()
    assert length(Gaoxy.Test.requests(ctx.fixture).entries) == length(handlers)
    assert :ets.lookup(@server, :slots) == [{:slots, 0}]
  end

  test "capture HTTP respects the total deadline and rejects attempts above two seconds", ctx do
    test = self()

    Gaoxy.Test.expect_once(
      ctx.fixture,
      "POST",
      "/capture/v1/hooks/synapsis/session-start",
      fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        send(test, {:waiting, self()})

        receive do
          :release -> conn
        after
          2_000 -> conn
        end
      end
    )

    envelope = %{"event_id" => Ecto.UUID.generate()}

    task =
      Task.async(fn -> HostAgent.capture(ctx.source, "session-start", envelope, timeout: 100) end)

    assert_receive {:waiting, handler}, 1_000
    assert {:error, :timeout} = Task.await(task, 1_000)
    send(handler, :release)

    assert {:error, :invalid_input} =
             HostAgent.capture(ctx.source, "session-start", envelope, timeout: 2_001)

    assert length(Gaoxy.Test.requests(ctx.fixture).entries) == 1
  end

  defp reply(conn, event),
    do: Plug.Conn.resp(conn, 202, Formata.JSON.encode!(%{ok: true, event_id: event["event_id"]}))

  defp settle do
    state = :sys.get_state(@server)

    for {_ref, %{task: task}} <- state.tasks do
      ref = Process.monitor(task.pid)
      assert_receive {:DOWN, ^ref, :process, _, _}, 3_000
    end

    state = :sys.get_state(@server)
    if map_size(state.tasks) > 0 or not :queue.is_empty(state.queue), do: settle(), else: :ok
  end
end
