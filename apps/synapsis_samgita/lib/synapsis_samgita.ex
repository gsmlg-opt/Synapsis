defmodule SynapsisSamgita do
  @moduledoc """
  Facade for the Samgita integration: connection, assigned Tasks and the
  operator-driven claim → start → progress → report flow.
  """

  alias SynapsisSamgita.{API, Attempt, Connection, Events}

  defdelegate connect, to: Connection
  defdelegate disconnect, to: Connection
  defdelegate status, to: Connection
  def subscribe, do: Events.subscribe_status()
  def subscribe_attempts, do: Events.subscribe_attempts()

  def list_attempts, do: Connection.attempts()

  def list_projects do
    with {:ok, conn} <- Connection.api_conn(), do: API.list_projects(conn)
  end

  def list_tasks(project_id) do
    with {:ok, conn} <- Connection.api_conn() do
      API.list_tasks(conn, project_id, Connection.status().agent_id)
    end
  end

  @doc "Open a session, claim `task`, and supervise the resulting attempt."
  def claim(project_id, %{"id" => task_id, "version" => version}) do
    external_id = "synapsis-#{task_id}-#{Ecto.UUID.generate()}"

    with {:ok, conn} <- Connection.api_conn(),
         {:ok, session} <- API.create_session(conn, project_id, external_id),
         {:ok, attempt} <- API.claim(conn, project_id, task_id, version, session["id"]),
         {:ok, pid} <-
           DynamicSupervisor.start_child(
             SynapsisSamgita.AttemptSupervisor,
             {Attempt,
              conn: conn,
              project_id: project_id,
              attempt: Map.put_new(attempt, "task_id", task_id)}
           ) do
      {:ok, Attempt.view(pid)}
    end
  end

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
