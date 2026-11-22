defmodule SynapsisLocalAgents.SigmaTest do
  use ExUnit.Case, async: false

  alias Synapsis.LocalAgentConfigs
  alias SynapsisLocalAgents.{Event, Sigma}
  alias SynapsisLocalAgents.Test.SigmaHost

  @repository "/home/me/repo"

  setup do
    Synapsis.DataCase.clear_config_store(:local_agent)
    Synapsis.DataCase.clear_coord("coord/local_agents/threads/")
    on_exit(fn -> Synapsis.DataCase.clear_coord("coord/local_agents/threads/") end)
    Process.flag(:trap_exit, true)
    :ok
  end

  defp replies(method, params) do
    case method do
      "thread/start" ->
        {:ok, %{"thread_id" => "th-1", "thread" => %{"messages" => []}}}

      "thread/resume" ->
        {:ok, %{"thread_id" => params["thread_id"], "thread" => %{}}}

      "turn/start" ->
        {:ok, %{"thread_id" => params["thread_id"], "turn_id" => "tu-1", "status" => "running"}}

      "turn/interrupt" ->
        {:ok, Map.put(params, "status", "requested")}

      "thread/read" ->
        {:ok, %{"thread_id" => params["thread_id"], "thread" => history()}}
    end
  end

  defp history do
    %{
      "messages" => [
        %{"id" => "m1", "role" => "user", "text" => "hello"},
        %{"id" => "m2", "role" => "assistant", "text" => "hi", "tools" => ["read"]},
        %{"id" => "m3", "role" => "assistant", "text" => ""}
      ],
      "messages_truncated" => false
    }
  end

  defp sigma(url) do
    {:ok, config} =
      LocalAgentConfigs.create(%{name: "Sigma", kind: "sigma", url: url, repository: @repository})

    config
  end

  defp connected(replies \\ &replies/2) do
    {:ok, token} = LocalAgentConfigs.rotate_token(sigma("ws://127.0.0.1:1/app-server").id)
    {listener, url} = SigmaHost.start(token, replies)
    [config] = LocalAgentConfigs.list()
    {:ok, config} = LocalAgentConfigs.update(config, %{url: url})

    {:ok, pid} = Sigma.start_link(config, self())
    assert_receive {:host_socket, socket}, 2_000
    assert_receive {:local_agent_event, %Event{type: :status, data: %{state: :running}}}, 2_000
    %{pid: pid, socket: socket, config: config, listener: listener}
  end

  test "connects with the agent token and stops when it is rejected" do
    %{pid: pid} = connected()
    assert Process.alive?(pid)

    config = sigma("ws://127.0.0.1:1/app-server")
    {:ok, token} = LocalAgentConfigs.rotate_token(config.id)
    {_listener, url} = SigmaHost.start(token <> "-other", &replies/2)
    {:ok, config} = LocalAgentConfigs.update(config, %{url: url})

    {:ok, pid} = Sigma.start_link(config, self())
    assert_receive {:EXIT, ^pid, {:sigma_connect_failed, "unauthorized"}}, 5_000
  end

  test "a thread is started in the configured repository and listed", %{} do
    %{pid: pid, config: config} = connected()

    assert {:ok, %{id: "th-1"}} = Sigma.start_thread(pid)

    assert_receive {:host_request, "thread/start",
                    %{"metadata" => %{"repository" => @repository}}, %{"command_id" => _}, _}

    assert {:ok, [%{id: "th-1"}]} = Sigma.list_threads(pid)
    assert {:ok, [%{id: "th-1"}]} = Synapsis.LocalAgentThreads.list(config.id, 10)
  end

  test "thread history becomes one turn of user and agent items" do
    %{pid: pid} = connected()

    assert {:ok, %{id: "th-1", turns: [%{items: items}]}} = Sigma.read_thread(pid, "th-1")

    assert [
             %{id: "m1", role: :user, text: "hello"},
             %{id: "m2", role: :agent, text: "hi\n\n(tools: read)"}
           ] = items
  end

  test "turns and streamed items become domain events", %{} do
    %{pid: pid, socket: socket} = connected()

    assert {:ok, %{turn_id: "tu-1"}} = Sigma.start_turn(pid, "th-1", "do it")

    assert_receive {:host_request, "turn/start",
                    %{"input" => [%{"type" => "text", "text" => "do it"}]}, _, _}

    ids = %{"thread_id" => "th-1", "turn_id" => "tu-1"}

    for {message, cursor} <-
          Enum.with_index(
            [
              SigmaHost.notification("turn/started", ids),
              SigmaHost.notification(
                "item/delta",
                Map.merge(ids, %{"item_id" => "m9", "delta" => "Hel"})
              ),
              SigmaHost.notification(
                "item/completed",
                Map.merge(ids, %{
                  "item_id" => "m9",
                  "item" => %{
                    "type" => "message",
                    "role" => "assistant",
                    "content" => [%{"type" => "text", "text" => "Hello"}]
                  }
                })
              ),
              SigmaHost.notification(
                "item/completed",
                Map.merge(ids, %{
                  "item_id" => "c1",
                  "item" => %{"type" => "tool", "name" => "bash"}
                })
              ),
              SigmaHost.notification("turn/completed", Map.put(ids, "status", "interrupted"))
            ],
            1
          ),
        do:
          send(
            socket,
            {:protocol_notification,
             Map.merge(message, %{"stream_id" => "tu-1", "cursor" => cursor})}
          )

    assert_receive {:local_agent_event,
                    %Event{type: :turn_started, thread_id: "th-1", turn_id: "tu-1"}}

    assert_receive {:local_agent_event,
                    %Event{type: :item_delta, item_id: "m9", data: %{delta: "Hel"}}}

    assert_receive {:local_agent_event,
                    %Event{
                      type: :item_completed,
                      item_id: "m9",
                      data: %{item: %{type: "agentMessage", text: "Hello"}}
                    }}

    assert_receive {:local_agent_event,
                    %Event{type: :item_completed, data: %{item: %{type: "tool", text: "bash"}}}}

    assert_receive {:local_agent_event,
                    %Event{type: :turn_completed, data: %{status: "interrupted"}}}

    assert :ok = Sigma.interrupt_turn(pid, "th-1", "tu-1")
  end

  test "a closed connection is reconnected, followed threads resumed and the request retried" do
    %{pid: pid, socket: socket} = connected()
    assert {:ok, %{id: "th-1"}} = Sigma.resume_thread(pid, "th-1")
    assert_receive {:host_request, "thread/resume", _, _, ^socket}

    ref = Process.monitor(socket)
    send(socket, :protocol_close)
    assert_receive {:DOWN, ^ref, :process, ^socket, _}, 2_000

    assert {:ok, %{turn_id: "tu-1"}} = Sigma.start_turn(pid, "th-1", "again")
    assert_receive {:host_socket, socket2}, 2_000
    assert_receive {:host_request, "turn/start", _, _, ^socket2}, 2_000
    assert_receive {:host_request, "thread/resume", %{"thread_id" => "th-1"}, _, ^socket2}, 2_000
    assert Process.alive?(pid)
  end

  test "an unreachable Sigma stops the adapter on the next request" do
    %{pid: pid, socket: socket, listener: listener} = connected()

    ref = Process.monitor(socket)
    Supervisor.stop(listener)
    assert_receive {:DOWN, ^ref, :process, ^socket, _}, 2_000

    assert {:error, _} = Sigma.start_turn(pid, "th-1", "again")
    assert_receive {:EXIT, ^pid, {:sigma_disconnected, _}}, 15_000
  end

  test "stop disconnects normally" do
    %{pid: pid, socket: socket} = connected()
    ref = Process.monitor(socket)

    assert :ok = Sigma.stop(pid)
    assert_receive {:EXIT, ^pid, :normal}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^socket, _}, 2_000
  end
end
