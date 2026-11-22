defmodule SynapsisServer.NativeRuntimeHealthFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

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

    assert %HTTP.Response{status: status, headers: response_headers} =
             response =
             HTTP.fetch("http://127.0.0.1:#{port}/api/health",
               headers: [{"accept", "application/json"}],
               timeout: @timeout
             )
             |> HTTP.Promise.await()

    headers = HTTP.Headers.to_list(response_headers)
    body = HTTP.Response.read_all(response)

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
           } = payload = Formata.JSON.decode!(IO.iodata_to_binary(body))

    refute Map.has_key?(payload, "tool_registry")
  end
end
