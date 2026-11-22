defmodule Synapsis.Agent.MemoryCaptureTest do
  use ExUnit.Case, async: false
  alias Synapsis.Agent.MemoryCapture
  alias Synapsis.Config.Store, as: Config
  alias Synapsis.Memory.{Capture, Settings}
  alias Synapsis.Session.Store

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
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

    session_id = Ecto.UUID.generate()

    data = %{
      session_id: session_id,
      project_path: root,
      agent: %{id: "selected-agent"},
      session: %{agent: "main"}
    }

    on_exit(fn ->
      Store.delete_session(session_id)

      case previous do
        {:ok, entry} -> Config.put(:memory, entry)
        {:error, :not_found} -> Config.delete(:memory, "default")
      end
    end)

    %{fixture: fixture, data: data}
  end

  test "queued acceptance and consumed prompt share one durable capture identity", ctx do
    test = self()

    Gaoxy.Test.expect_once(
      ctx.fixture,
      "POST",
      "/capture/v1/hooks/synapsis/user-prompt-submit",
      fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        event = Jason.decode!(body)
        send(test, {:captured, event})
        Plug.Conn.resp(conn, 202, Jason.encode!(%{ok: true, event_id: event["event_id"]}))
      end
    )

    input = %{id: "accepted-input", kind: "prompt", content: "one durable prompt"}
    MemoryCapture.accepted(ctx.data, input.id, input.content)
    data = Map.put(ctx.data, :pending_inputs, %{current: %{input: input}})

    MemoryCapture.consumed(data, %{
      message: %{id: "different-runtime-message", content: input.content}
    })

    assert_receive {:captured, event}, 2_000
    assert event["payload"] == %{"message_id" => input.id, "content" => input.content}
    settle()
    assert length(Gaoxy.Test.requests(ctx.fixture).entries) == 1
  end

  test "normal end is captured but errors and internal system events are not invented as user events",
       ctx do
    test = self()

    Gaoxy.Test.expect_once(
      ctx.fixture,
      "POST",
      "/capture/v1/hooks/synapsis/session-end",
      fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        event = Jason.decode!(body)
        send(test, {:ended, event})
        Plug.Conn.resp(conn, 202, Jason.encode!(%{ok: true, event_id: event["event_id"]}))
      end
    )

    MemoryCapture.ended(ctx.data, {:error, :crashed})
    internal = Map.put(ctx.data, :pending_inputs, %{current: %{input: %{kind: "system_event"}}})
    MemoryCapture.consumed(internal, %{message: %{id: "internal", content: "internal command"}})
    MemoryCapture.ended(ctx.data, :shutdown)
    assert_receive {:ended, event}, 2_000
    assert event["payload"] == %{"reason" => "shutdown"}
    settle()
    assert length(Gaoxy.Test.requests(ctx.fixture).entries) == 1
  end

  defp settle do
    state = :sys.get_state(Capture)

    for {_ref, %{task: task}} <- state.tasks do
      ref = Process.monitor(task.pid)
      assert_receive {:DOWN, ^ref, :process, _, _}, 3_000
    end

    state = :sys.get_state(Capture)
    if map_size(state.tasks) > 0 or not :queue.is_empty(state.queue), do: settle(), else: :ok
  end
end
