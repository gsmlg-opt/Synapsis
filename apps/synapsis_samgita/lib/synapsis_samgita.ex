defmodule SynapsisSamgita do
  @moduledoc """
  Facade for the Samgita integration: connection, assigned Tasks and the
  operator-driven claim → start → progress → report flow.
  """

  require Logger
  alias SynapsisSamgita.{API, Attempt, Connection, Events}

  defdelegate connect, to: Connection
  defdelegate disconnect, to: Connection
  defdelegate status, to: Connection
  defdelegate attempts_active?, to: Connection
  def subscribe, do: Events.subscribe_status()
  def subscribe_attempts, do: Events.subscribe_attempts()

  def list_attempts, do: Connection.attempts()

  def list_projects do
    with {:ok, conn} <- Connection.api_conn(), do: API.list_projects(conn)
  end

  def project_context(project_id) do
    with {:ok, conn} <- Connection.api_conn(), do: API.project_context(conn, project_id)
  end

  def get_task(project_id, task_id) do
    with {:ok, conn} <- Connection.api_conn(), do: API.get_task(conn, project_id, task_id)
  end

  def list_tasks(project_id) do
    with {:ok, conn} <- Connection.api_conn() do
      API.list_tasks(conn, project_id, Connection.status().agent_id)
    end
  end

  @doc "Claim `task` on this connection's session for the project and supervise the attempt."
  def claim(project_id, %{"id" => task_id, "version" => version}) do
    with {:ok, conn} <- Connection.api_conn(),
         {:ok, session_id} <- session_for(conn, project_id, task_id),
         {:ok, attempt} <- claim_on(conn, project_id, task_id, version, session_id) do
      start_attempt(conn, project_id, Map.put_new(attempt, "task_id", task_id))
    end
  end

  defp session_for(conn, project_id, task_id) do
    case Connection.session(project_id) do
      nil ->
        external_id = "synapsis-#{task_id}-#{Ecto.UUID.generate()}"

        with {:ok, %{"id" => id}} <- API.create_session(conn, project_id, external_id) do
          Connection.put_session(project_id, id)
          {:ok, id}
        end

      id ->
        {:ok, id}
    end
  end

  # A session Samgita no longer accepts is dropped so the next claim opens a new one.
  defp claim_on(conn, project_id, task_id, version, session_id) do
    with {:error, %{code: code}} = error when code in ~w(not_found ownership_lost invalid) <-
           API.claim(conn, project_id, task_id, version, session_id) do
      Connection.forget_session(project_id)
      error
    end
  end

  # Samgita has no release: an attempt left without a process lapses at its
  # 30 s start deadline.
  defp start_attempt(conn, project_id, attempt) do
    spec = {Attempt, conn: conn, project_id: project_id, attempt: attempt}

    case DynamicSupervisor.start_child(SynapsisSamgita.AttemptSupervisor, spec) do
      {:ok, pid} ->
        {:ok, Attempt.view(pid)}

      {:error, reason} ->
        Logger.warning("samgita_attempt_unsupervised",
          attempt_id: attempt["id"],
          reason: inspect(reason)
        )

        {:error, %{status: nil, code: "attempt_unsupervised", detail: inspect(reason)}}
    end
  end

  @doc """
  Mark an inbox event processed and, when connected, report it on its Samgita
  delivery so Samgita records it completed (Samgita does not re-poll accepted
  deliveries). The local completion stands even if the report fails.
  """
  def mark_processed(event_id, note) do
    decision_id = Ecto.UUID.generate()

    with {:ok, entry} <- Synapsis.Samgita.Inbox.mark_processed(event_id, note, decision_id) do
      Events.broadcast_inbox_changed(event_id)
      {:ok, %{entry: entry, reported: report_processed(entry, decision_id, note)}}
    end
  end

  @reportable ~w(delivering accepted reconciling)

  defp report_processed(
         %{"event" => %{"event_id" => event_id, "project_ref" => project_id}},
         decision_id,
         note
       )
       when is_binary(project_id) do
    with {:ok, conn} <- Connection.api_conn(),
         {:ok, deliveries} <- API.list_deliveries(conn, project_id),
         %{} = delivery <-
           Enum.find(
             deliveries,
             &(&1["event_id"] == event_id and &1["state"] in @reportable and
                 &1["agent_id"] == Connection.status().agent_id)
           ),
         {:ok, _} <-
           API.report_delivery(
             conn,
             project_id,
             delivery,
             decision_id,
             "completed",
             report_result(note)
           ) do
      true
    else
      nil -> {:error, "no_open_delivery"}
      {:error, %{code: code}} -> {:error, code}
    end
  end

  defp report_processed(_entry, _decision_id, _note), do: {:error, "no_project"}

  # Samgita accepts only allowlisted text fields in a report result.
  defp report_result(""), do: nil
  defp report_result(note), do: %{"summary" => String.slice(note, 0, 2000)}

  def attempt_start(attempt_id), do: with_attempt(attempt_id, &Attempt.start_work/1)

  def attempt_progress(attempt_id, summary),
    do: with_attempt(attempt_id, &Attempt.progress(&1, summary))

  def attempt_report(attempt_id, outcome, effects_resolved, result),
    do: with_attempt(attempt_id, &Attempt.report(&1, outcome, effects_resolved, result))

  defp with_attempt(attempt_id, fun) do
    case Registry.lookup(SynapsisSamgita.AttemptRegistry, attempt_id) do
      [{pid, _}] -> fun.(pid)
      [] -> {:error, %{status: nil, code: "attempt_not_active", detail: nil}}
    end
  end
end
