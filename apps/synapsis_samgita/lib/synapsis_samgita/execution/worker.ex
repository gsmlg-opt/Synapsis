defmodule SynapsisSamgita.Execution.Worker do
  @moduledoc false
  alias Synapsis.Samgita.Executions
  alias SynapsisSamgita.{API, Events, Inbound}
  alias SynapsisSamgita.Execution.{Runtime, Guard}

  @renew_ms 45_000

  def run(entry, device, opts \\ []) do
    token = Ecto.UUID.generate()
    owner = Keyword.get(opts, :owner, self())
    runtime = Keyword.get(opts, :runtime, Runtime)

    case Executions.start(entry["id"], token) do
      {:ok, entry} ->
        {:ok, guard} =
          DynamicSupervisor.start_child(
            SynapsisSamgita.DeviceSupervisor,
            {Guard, id: entry["id"], token: token, owner: owner, worker: self(), runtime: runtime}
          )

        monitor = Process.monitor(guard)

        Process.put({__MODULE__, :lease}, %{
          token: token,
          owner: owner,
          guard: guard,
          monitor: monitor
        })

        try do
          perform(entry, device, opts)
        after
          Guard.release(guard)
          Process.demonitor(monitor, [:flush])
          Process.delete({__MODULE__, :lease})
          DynamicSupervisor.terminate_child(SynapsisSamgita.DeviceSupervisor, guard)
        end

      {:error, :already_started} ->
        :ok

      error ->
        error
    end
  end

  defp perform(entry, device, opts) do
    api = Keyword.get(opts, :api, API)
    runtime = Keyword.get(opts, :runtime, Runtime)
    Events.subscribe_devices()

    with {:ok, conn} <- connection(device, opts),
         {:ok, task} <- api.get_task(conn, entry["project_id"], entry["task_id"]),
         :ok <- assigned(task, conn),
         {:ok, entry} <- checkpoint(entry, "session_requested"),
         {:ok, session} <-
           api.create_session(conn, entry["project_id"], entry["id"],
             command_id: entry["commands"]["session"]
           ),
         {:ok, entry} <- checkpoint(entry, "claim_requested", %{"session_id" => session["id"]}),
         {:ok, attempt} <-
           api.claim(conn, entry["project_id"], entry["task_id"], task["version"], session["id"],
             command_id: entry["commands"]["claim"]
           ),
         {:ok, entry} <-
           checkpoint(entry, "start_requested", %{
             "attempt_id" => attempt["id"],
             "attempt_version" => attempt["version"],
             "connection_id" => conn.connection_id
           }),
         {:ok, proof} <- proof(api, conn, entry),
         {:ok, attempt} <-
           api.start(conn, entry["project_id"], attempt["id"], attempt["version"], proof,
             command_id: entry["commands"]["start"]
           ),
         {:ok, entry} <-
           checkpoint(entry, "runtime_preparing", %{"attempt_version" => attempt["version"]}),
         {:ok, handle} <- runtime.prepare(device, task),
         :ok <- attach(handle),
         {:ok, entry} <-
           checkpoint(entry, "runtime_dispatching", %{
             "runtime" => Map.delete(handle, :monitor_ref)
           }),
         :ok <- attach(handle),
         {:ok, handle} <- runtime.start(handle, prompt(task)),
         :ok <- attach(handle),
         {:ok, entry} <-
           checkpoint(entry, "running", %{"runtime" => Map.delete(handle, :monitor_ref)}),
         {:ok, entry} <- checkpoint(entry, "progress_requested"),
         {:ok, proof} <- proof(api, conn, entry),
         {:ok, attempt} <-
           api.progress(
             conn,
             entry["project_id"],
             entry["attempt_id"],
             entry["attempt_version"],
             proof,
             "Execution started",
             command_id: entry["commands"]["progress"]
           ),
         {:ok, entry} <- checkpoint(entry, "running", %{"attempt_version" => attempt["version"]}) do
      wait(
        entry,
        device,
        conn,
        handle,
        api,
        runtime,
        Keyword.get(opts, :renew_ms, @renew_ms),
        System.monotonic_time(:millisecond) + Keyword.get(opts, :renew_ms, @renew_ms)
      )
    else
      {:error, :not_assigned} -> checkpoint(entry, "ignored", %{"last_error" => "not_assigned"})
      _ -> fail_execution(entry, device, opts, api, runtime)
    end
  end

  defp fail_execution(entry, device, opts, api, runtime) do
    with {:ok, current} <- Executions.get(entry["id"]),
         true <-
           current["phase"] in ~w(runtime_preparing runtime_dispatching running progress_requested),
         {:ok, conn} <- connection(device, opts),
         true <- conn.connection_id == current["connection_id"] do
      if handle = current["runtime"], do: runtime.cancel(handle)
      finish(current, conn, api, "failed", false)
    else
      _ ->
        checkpoint(entry, "recovery_required", %{"last_error" => "execution_outcome_unconfirmed"})
    end
  end

  defp wait(entry, device, conn, handle, api, runtime, interval, deadline) do
    device_id = device["id"]
    connection_id = conn.connection_id

    token = lease().token
    monitor = lease().monitor

    receive do
      {:execution_owner_lost, ^token} ->
        {:error, :owner_lost}

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        runtime.cancel(handle)
        Executions.revoke(entry["id"], "execution_guard_lost")

      {:samgita_device_status, %{device_id: ^device_id, state: phase, connection_id: connection}}
      when phase != :connected or connection != connection_id ->
        runtime.cancel(handle)
        checkpoint(entry, "recovery_required", %{"last_error" => "lease_or_connection_lost"})

      message ->
        handle =
          if function_exported?(runtime, :capture, 2),
            do: runtime.capture(handle, message),
            else: handle

        case runtime.observe(handle, message) do
          {:done, outcome, resolved, result} ->
            finish(entry, conn, api, outcome, resolved, result)

          {:done, outcome, resolved} ->
            finish(entry, conn, api, outcome, resolved)

          :pending ->
            wait(entry, device, conn, handle, api, runtime, interval, deadline)
        end
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        with {:ok, %{connection_id: connection}} <- Inbound.api_conn(device["id"]),
             true <- connection == conn.connection_id,
             {:ok, proof} <- proof(api, conn, entry),
             command_id = Ecto.UUID.generate(),
             {:ok, entry} <-
               checkpoint(entry, "renew_requested", %{"renew_command_id" => command_id}),
             {:ok, attempt} <-
               api.renew(
                 conn,
                 entry["project_id"],
                 entry["attempt_id"],
                 entry["attempt_version"],
                 proof,
                 command_id: command_id
               ),
             {:ok, entry} <-
               checkpoint(entry, "running", %{"attempt_version" => attempt["version"]}) do
          wait(
            entry,
            device,
            conn,
            handle,
            api,
            runtime,
            interval,
            System.monotonic_time(:millisecond) + interval
          )
        else
          _ ->
            runtime.cancel(handle)
            checkpoint(entry, "recovery_required", %{"last_error" => "lease_or_connection_lost"})
        end
    end
  end

  defp finish(entry, conn, api, outcome, resolved, result \\ nil) do
    report = %{
      "command_id" => entry["commands"]["report"],
      "expected_version" => entry["attempt_version"],
      "outcome" => outcome,
      "effects_resolved" => resolved,
      "result" => result || Runtime.result(entry["runtime"] || %{}, outcome)
    }

    # Persist the exact non-secret report envelope before sending. A lost
    # response preserves both identity and evidence for reconciliation; it does
    # not authorize a second execution or a replacement report command.
    with {:ok, entry} <-
           checkpoint(entry, "report_requested", %{
             "outcome" => outcome,
             "effects_resolved" => resolved,
             "report" => report
           }),
         {:ok, proof} <- proof(api, conn, entry),
         report = entry["report"],
         {:ok, attempt} <-
           api.report(
             conn,
             entry["project_id"],
             entry["attempt_id"],
             report["expected_version"],
             proof,
             report["outcome"],
             report["effects_resolved"],
             report["result"],
             command_id: report["command_id"]
           ) do
      checkpoint(entry, if(resolved, do: "completed", else: "recovery_required"), %{
        "attempt_version" => attempt["version"],
        "server_state" => attempt["state"]
      })
    else
      _ -> checkpoint(entry, "recovery_required", %{"last_error" => "report_outcome_unconfirmed"})
    end
  end

  defp proof(api, conn, entry) do
    with {:ok, proof} <- api.proof(conn, entry["project_id"], entry["attempt_id"]),
         :ok <- ensure_owner(),
         :ok <- Executions.save_proof(entry["id"], proof, lease().token),
         do: {:ok, proof}
  end

  defp checkpoint(entry, phase, fields \\ %{}) do
    with :ok <- ensure_owner(),
         do: Executions.update_owned(entry["id"], lease().token, phase, fields)
  end

  defp lease, do: Process.get({__MODULE__, :lease})

  defp ensure_owner do
    if Process.alive?(lease().owner) and Process.alive?(lease().guard),
      do: :ok,
      else: {:error, :owner_lost}
  end

  defp attach(handle), do: Guard.attach(lease().guard, handle)

  defp connection(device, opts),
    do: Keyword.get_lazy(opts, :connection, fn -> Inbound.api_conn(device["id"]) end)

  defp assigned(%{"assignee_agent_id" => id, "state" => state}, %{agent_id: id})
       when state in ["ready", "assigned", "open"],
       do: :ok

  defp assigned(_, _), do: {:error, :not_assigned}

  defp prompt(task),
    do: Enum.join(Enum.filter([task["title"], task["description"]], &is_binary/1), "\n\n")
end
