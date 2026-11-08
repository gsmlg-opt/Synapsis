defmodule SynapsisServer.NativeRuntimeHealthFunctionalTest do
  use ExUnit.Case, async: false

  @timeout 5_000

  test "GET /api/health reports live native runtime infrastructure and existing public metadata" do
    for name <- [
          Synapsis.Session.Registry,
          Synapsis.Session.SupervisorRegistry,
          Synapsis.Session.TaskSupervisorRegistry,
          Synapsis.Tool.TaskSupervisor
        ] do
      assert pid = Process.whereis(name)
      assert Process.alive?(pid)
    end

    listener =
      start_supervised!(
        {Gaoxy.HTTP,
         id: __MODULE__,
         plug: {SynapsisServer.Endpoint, []},
         ip: {127, 0, 0, 1},
         port: 0,
         http_limits: %{request_timeout: @timeout}}
      )

    %{local: {:ok, {_address, port}}} = Gaoxy.info(listener, __MODULE__)

    assert {:ok, conn} =
             Mint.HTTP.connect(:http, "127.0.0.1", port,
               mode: :passive,
               protocols: [:http1],
               transport_opts: [timeout: @timeout]
             )

    socket = Mint.HTTP.get_socket(conn)
    on_exit(fn -> :gen_tcp.close(socket) end)

    scheduler_entries =
      Synapsis.Agent.Heartbeat.LocalScheduler.status().entries
      |> Enum.map(fn entry ->
        %{
          "name" => entry.name,
          "schedule" => entry.schedule,
          "next_run_at" => if(entry.next_run_at, do: DateTime.to_iso8601(entry.next_run_at))
        }
      end)

    version = :synapsis_server |> Application.spec(:vsn) |> to_string()

    assert {:ok, conn, ref} =
             Mint.HTTP.request(conn, "GET", "/api/health", [{"accept", "application/json"}], nil)

    {status, headers, body} =
      receive_response(conn, ref, System.monotonic_time(:millisecond) + @timeout, nil, [], [])

    assert status == 200
    assert {"content-type", "application/json; charset=utf-8"} in headers

    assert %{
             "ok" => true,
             "store" => "ok",
             "pubsub" => "ok",
             "scheduler" => "ok",
             "session_registry" => "ok",
             "session_supervisor_registry" => "ok",
             "session_task_supervisor_registry" => "ok",
             "tool_task_supervisor" => "ok",
             "provider_registry" => "ok",
             "session_supervisor" => "ok",
             "agent_supervisor" => "ok",
             "agent_runtime" => "ok",
             "endpoint" => "ok",
             "version" => ^version,
             "scheduler_entries" => ^scheduler_entries
           } = payload = Jason.decode!(IO.iodata_to_binary(body))

    refute Map.has_key?(payload, "tool_registry")
  end

  defp receive_response(conn, ref, deadline, status, headers, body) do
    remaining = deadline - System.monotonic_time(:millisecond)
    assert remaining > 0, "timed out waiting for the health response"
    assert {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, remaining)

    {status, headers, body} =
      Enum.reduce(responses, {status, headers, body}, fn
        {:status, ^ref, value}, {_status, headers, body} -> {value, headers, body}
        {:headers, ^ref, value}, {status, headers, body} -> {status, headers ++ value, body}
        {:data, ^ref, value}, {status, headers, body} -> {status, headers, [body, value]}
        _, acc -> acc
      end)

    if {:done, ref} in responses do
      {status, headers, body}
    else
      receive_response(conn, ref, deadline, status, headers, body)
    end
  end
end
