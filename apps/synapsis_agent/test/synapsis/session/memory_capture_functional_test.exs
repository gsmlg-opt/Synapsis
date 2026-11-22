defmodule Synapsis.Session.MemoryCaptureFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional
  @moduletag :tmp_dir

  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Config.Store, as: Config
  alias Synapsis.Memory.Settings
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Worker}

  setup do
    previous = Config.get(:memory, "default")
    fixture = Gaoxy.Test.open()

    assert {:ok, _} =
             Settings.save(%{
               "backend" => "workspace",
               "host_agent" => %{
                 "enabled" => true,
                 "endpoint" => String.trim_trailing(Gaoxy.Test.url(fixture), "/"),
                 "agent_id" => "synapsis"
               }
             })

    on_exit(fn ->
      case previous do
        {:ok, entry} -> Config.put(:memory, entry)
        {:error, :not_found} -> Config.delete(:memory, "default")
      end
    end)

    %{fixture: fixture}
  end

  test "real Worker emits start prompt public tool result and normal end", %{
    tmp_dir: root,
    fixture: fixture
  } do
    test = self()

    for hook <- ~w(session-start user-prompt-submit post-tool-use session-end) do
      Gaoxy.Test.expect_once(fixture, "POST", "/capture/v1/hooks/synapsis/" <> hook, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        event = Formata.JSON.decode!(body)
        send(test, {:capture, hook, event})
        Plug.Conn.resp(conn, 202, Formata.JSON.encode!(%{ok: true, event_id: event["event_id"]}))
      end)
    end

    h =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        tool_name: "clock::curr_time"
      )

    on_exit(fn -> SessionHarness.cleanup!(h) end)

    Gaoxy.Test.stub(h.provider.fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Formata.JSON.decode!(body)

      if Enum.any?(request["input"], &(&1["type"] == "function_call_output")) do
        DeterministicProvider.send_sse(conn, [
          DeterministicProvider.text_chunk("Capture complete"),
          DeterministicProvider.finish_chunk("stop")
        ])
      else
        DeterministicProvider.send_sse(conn, [
          DeterministicProvider.tool_call_chunk(
            ToolName.encode("clock::curr_time"),
            "capture-clock",
            %{}
          ),
          DeterministicProvider.finish_chunk("tool_calls")
        ])
      end
    end)

    id = h.session.id
    SessionHarness.ensure_running!(id)
    SessionHarness.subscribe!(id)
    assert_receive {:capture, "session-start", start}, 3_000
    assert start["session_id"] == id
    assert start["cwd"] == root
    assert start["agent_id"] == h.agent_config.id
    assert :ok = Worker.send_message(id, "Read the clock")
    assert_receive {:capture, "user-prompt-submit", prompt}, 3_000
    assert prompt["payload"]["content"] == "Read the clock"
    assert is_binary(prompt["payload"]["message_id"])
    assert_receive {:capture, "post-tool-use", tool}, 5_000
    assert tool["payload"]["tool_name"] == "clock::curr_time"
    assert tool["payload"]["tool_call_id"] =~ "capture-clock"
    assert tool["payload"]["is_error"] == false
    assert tool["payload"]["result"]["version"] == 1
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert :ok = DynamicSupervisor.stop_session(id)
    assert_receive {:capture, "session-end", ended}, 3_000
    assert ended["session_id"] == id
    assert ended["payload"]["reason"] in ["normal", "shutdown"]
  end

  test "a stalled capture host cannot block a real Worker turn", %{
    tmp_dir: root,
    fixture: fixture
  } do
    test = self()

    for hook <- ~w(session-start user-prompt-submit session-end) do
      Gaoxy.Test.stub(fixture, "POST", "/capture/v1/hooks/synapsis/" <> hook, fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        send(test, {:capture_waiting, self()})

        receive do
          :release -> conn
        after
          2_500 -> conn
        end
      end)
    end

    h = SessionHarness.setup_session!(tmp_dir: root)
    on_exit(fn -> SessionHarness.cleanup!(h) end)
    id = h.session.id
    SessionHarness.ensure_running!(id)
    SessionHarness.subscribe!(id)
    assert_receive {:capture_waiting, first}, 3_000
    monitor = Process.monitor(first)
    assert :ok = Worker.send_message(id, "Finish while capture cannot answer")
    assert_receive {:run_event, %{type: "session.completed"}}, 5_000
    assert Process.alive?(first)
    send(first, :release)
    Process.demonitor(monitor, [:flush])
  end
end
