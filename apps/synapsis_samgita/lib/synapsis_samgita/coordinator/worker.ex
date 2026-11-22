defmodule SynapsisSamgita.Coordinator.Worker do
  @moduledoc false
  alias Synapsis.Samgita.{Coordination, Devices, Executions, Inbox}
  alias SynapsisSamgita.{API, Inbound}
  alias SynapsisSamgita.Coordinator.Planner

  def run(entry, opts \\ []) do
    token = Ecto.UUID.generate()

    with {:ok, entry} <-
           Coordination.update(entry["id"], fn current ->
             if current["phase"] in ~w(queued planning planned dispatching recovering),
               do: {:ok, Map.put(current, "owner_token", token)},
               else: {:error, :already_processed}
           end),
         {:ok, device} <- Devices.get(entry["device_id"]),
         {:ok, conn} <- connection(entry, opts),
         {:ok, context} <- api(opts).project_context(conn, entry["project_id"]),
         :ok <- authorized(context, conn.agent_id) do
      case entry["event"]["type"] do
        "manual.triggered" -> decompose(entry, device, context, opts)
        "attempt.reported" -> reported(entry, conn, opts)
      end
    else
      {:error, :already_processed} ->
        :ok

      {:error, reason} ->
        Coordination.owned(entry["id"], token, fn current ->
          {:ok, Map.merge(current, %{"phase" => "blocked", "last_error" => reason_text(reason)})}
        end)
    end
  end

  def authorized(context, agent_id) do
    member = Enum.find(context["memberships"] || [], &(&1["agent_id"] == agent_id))
    routing = context["event_routing"] || %{}

    if member && member["enabled"] == true && "manager" in (member["roles"] || []) &&
         routing["agent_id"] == agent_id && routing["purpose"] == "responsible" &&
         routing["enabled"] == true && "task.create" in (context["allowed_operations"] || []),
       do: :ok,
       else: {:error, :responsible_manager_required}
  end

  defp decompose(%{"phase" => "planning"} = entry, _, _, _),
    do: put(entry, %{"phase" => "recovery_required", "last_error" => "planning_interrupted"})

  defp decompose(%{"phase" => "queued"} = entry, device, context, opts) do
    candidates = candidates(device, context)
    planner = Keyword.get(opts, :planner, Planner)

    with true <- device["source_kind"] == "agent" and candidates != [],
         {:ok, entry} <- put(entry, %{"phase" => "planning"}),
         {:ok, plan} <-
           planner.plan(device, entry["event"], candidates,
             owner: opts[:owner],
             on_session: fn handle ->
               case put(entry, %{"planning_session" => handle}) do
                 {:ok, _} -> :ok
                 error -> error
               end
             end
           ),
         :ok <- validate_plan(plan, candidates),
         {:ok, entry} <- put(entry, %{"phase" => "planned", "plan" => plan}) do
      dispatch(entry, opts)
    else
      false ->
        put(entry, %{"phase" => "blocked", "last_error" => "no_registered_executor_or_planner"})

      {:error, reason} ->
        put(entry, %{"phase" => "blocked", "last_error" => reason_text(reason)})
    end
  end

  defp decompose(entry, _, _, opts), do: dispatch(entry, opts)

  defp candidates(device, context) do
    registered =
      Devices.list()
      |> Enum.filter(
        &(&1["base_url"] == device["base_url"] && &1["enabled"] == true && !&1["forgotten"] &&
            is_binary(&1["agent_id"]))
      )
      |> Enum.map(& &1["agent_id"])

    (context["memberships"] || [])
    |> Enum.filter(
      &(&1["enabled"] == true && "worker" in (&1["roles"] || []) && &1["agent_id"] in registered)
    )
    |> Enum.map(& &1["agent_id"])
    |> Enum.uniq()
  end

  def validate_plan(%{"title" => title, "tasks" => tasks}, candidates)
      when is_binary(title) and is_list(tasks) and length(tasks) in 1..10 do
    if text?(title, 200) and
         Enum.all?(tasks, fn
           %{
             "title" => title,
             "description" => description,
             "assignee_agent_id" => assignee,
             "required_capabilities" => capabilities
           }
           when is_list(capabilities) ->
             text?(title, 200) and text?(description, 20_000) and assignee in candidates and
               Enum.all?(capabilities, &(&1 == "project_events.v1"))

           _ ->
             false
         end),
       do: :ok,
       else: {:error, :invalid_plan}
  end

  def validate_plan(_, _), do: {:error, :invalid_plan}

  defp text?(value, max),
    do: is_binary(value) and String.trim(value) != "" and byte_size(value) <= max

  defp dispatch(entry, opts) do
    with {:ok, entry} <- put(entry, %{"phase" => "dispatching"}),
         {:ok, root, entry} <- root(entry, opts),
         {:ok, entry} <- children(entry, root["id"], opts),
         {:ok, entry} <- finish_dispatch(entry) do
      Inbox.mark_processed(
        entry["event_id"],
        "Task tree assigned; execution results require human review.",
        nil,
        entry["device_id"]
      )

      {:ok, entry}
    else
      {:error, reason} ->
        put(entry, %{"phase" => "recovery_required", "last_error" => reason_text(reason)})
    end
  end

  defp finish_dispatch(entry) do
    Coordination.owned(entry["id"], entry["owner_token"], fn current ->
      children = current["children"]

      ready =
        map_size(children) == length(current["plan"]["tasks"]) and
          Enum.all?(children, fn {_, child} -> child["task_state"] == "awaiting_review" end)

      {:ok,
       Map.merge(current, %{
         "phase" => if(ready, do: "awaiting_human_review", else: "awaiting_results"),
         "last_error" => nil
       })}
    end)
  end

  defp root(entry, opts) do
    parent = entry["event"]["task_ref"] || get_in(entry, ["event", "payload", "data", "task_id"])

    if is_binary(parent) do
      with {:ok, conn} <- connection(entry, opts),
           {:ok, task} <- api(opts).get_task(conn, entry["project_id"], parent),
           {:ok, entry} <- put(entry, %{"root_task_id" => task["id"]}),
           do: {:ok, task, entry}
    else
      with {:ok, task, entry} <-
             command(entry, "root", "create", %{"title" => entry["plan"]["title"]}, opts),
           {:ok, entry} <- put(entry, %{"root_task_id" => task["id"]}),
           do: {:ok, task, entry}
    end
  end

  defp children(entry, parent, opts) do
    entry["plan"]["tasks"]
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, entry}, fn {task, index}, {:ok, entry} ->
      key = "child-#{index}"

      attrs =
        task
        |> Map.take(~w(title description required_capabilities))
        |> Map.put("parent_task_id", parent)

      with {:ok, created, entry} <- command(entry, key <> ":create", "create", attrs, opts),
           {:ok, entry} <-
             put_child(entry, key, %{
               "task_id" => created["id"],
               "title" => task["title"],
               "assignee_agent_id" => task["assignee_agent_id"]
             }),
           {:ok, assigned, entry} <-
             command(
               entry,
               key <> ":assign",
               "assign",
               %{
                 "task_id" => created["id"],
                 "expected_version" => created["version"],
                 "assignee_agent_id" => task["assignee_agent_id"]
               },
               opts
             ),
           {:ok, entry} <-
             put_child(entry, key, %{
               "task_state" => assigned["state"],
               "task_version" => assigned["version"]
             }) do
        {:cont, {:ok, entry}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp command(entry, name, operation, payload, opts) do
    with {:ok, entry} <- reserve(entry, name, operation, payload) do
      command = entry["commands"][name]

      case command["status"] do
        "confirmed" ->
          {:ok, command["result"], entry}

        "requested" ->
          reconcile(entry, name, command, opts)

        "ready" ->
          with {:ok, conn} <- current_authority(entry, opts),
               {:ok, entry} <-
                 update_command(entry, name, %{
                   "status" => "requested",
                   "connection_id" => conn.connection_id
                 }) do
            case send_command(api(opts), conn, entry, command) do
              {:ok, result} -> confirm(entry, name, result)
              {:error, _} -> reconcile(entry, name, entry["commands"][name], opts)
            end
          end
      end
    end
  end

  defp reserve(entry, name, operation, payload) do
    id = Ecto.UUID.generate()

    Coordination.owned(entry["id"], entry["owner_token"], fn current ->
      command = %{
        "command_id" => id,
        "operation" => operation,
        "payload" => payload,
        "status" => "ready"
      }

      {:ok, Map.update!(current, "commands", &Map.put_new(&1, name, command))}
    end)
  end

  defp send_command(api, conn, entry, %{"operation" => "create"} = command),
    do:
      api.create_task(conn, entry["project_id"], command["payload"],
        command_id: command["command_id"]
      )

  defp send_command(api, conn, entry, %{"operation" => "assign", "payload" => payload} = command),
    do:
      api.assign_task(
        conn,
        entry["project_id"],
        payload["task_id"],
        payload["expected_version"],
        payload["assignee_agent_id"],
        command_id: command["command_id"]
      )

  defp reconcile(entry, name, %{"operation" => "create"} = command, opts) do
    with {:ok, conn} <- connection(entry, opts),
         {:ok, %{"resource_id" => id}} <-
           receipt(api(opts), conn, entry["project_id"], command["command_id"], "task.created"),
         {:ok, task} <- api(opts).get_task(conn, entry["project_id"], id) do
      confirm(entry, name, task)
    else
      _ -> {:error, :create_outcome_unconfirmed}
    end
  end

  defp reconcile(entry, name, %{"operation" => "assign", "payload" => payload} = command, opts) do
    with {:ok, conn} <- connection(entry, opts),
         {:ok, %{"resource_id" => id}} <-
           receipt(api(opts), conn, entry["project_id"], command["command_id"], "task.assigned"),
         true <- id == payload["task_id"],
         {:ok, %{"assignee_agent_id" => assignee} = task} <-
           api(opts).get_task(conn, entry["project_id"], payload["task_id"]),
         true <- assignee == payload["assignee_agent_id"] do
      confirm(entry, name, task)
    else
      _ -> {:error, :assignment_outcome_unconfirmed}
    end
  end

  defp receipt(api, conn, project_id, command_id, type) do
    receipt(
      api,
      conn,
      project_id,
      command_id,
      type,
      0,
      System.monotonic_time(:millisecond) + 20_000
    )
  end

  defp receipt(api, conn, project_id, command_id, type, after_sequence, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    with true <- remaining > 0,
         {:ok, events} when is_list(events) <-
           api.list_events(
             Map.put(conn, :receive_timeout, min(remaining, 10_000)),
             project_id,
             after_sequence
           ) do
      case Enum.find(events, &(&1["command_id"] == command_id && &1["type"] == type)) do
        %{} = event ->
          {:ok, event}

        nil ->
          next_sequence =
            events
            |> Enum.map(& &1["sequence"])
            |> Enum.filter(&is_integer/1)
            |> Enum.max(fn -> after_sequence end)

          if length(events) == 100 and next_sequence > after_sequence,
            do: receipt(api, conn, project_id, command_id, type, next_sequence, deadline),
            else: {:error, :receipt_not_observed}
      end
    else
      _ -> {:error, :receipt_not_observed}
    end
  end

  defp confirm(entry, name, result) do
    with {:ok, entry} <-
           update_command(entry, name, %{"status" => "confirmed", "result" => result}),
         do: {:ok, result, entry}
  end

  defp update_command(entry, name, fields),
    do:
      Coordination.owned(entry["id"], entry["owner_token"], fn current ->
        {:ok, update_in(current, ["commands", name], &Map.merge(&1, fields))}
      end)

  defp put_child(entry, name, fields) do
    Coordination.owned(entry["id"], entry["owner_token"], fn current ->
      child = current["children"][name] || %{}

      if is_integer(child["task_version"]) and is_integer(fields["task_version"]) and
           child["task_version"] > fields["task_version"],
         do: {:ok, current},
         else: {:ok, put_in(current, ["children", name], Map.merge(child, fields))}
    end)
  end

  defp put(entry, fields),
    do: Coordination.owned(entry["id"], entry["owner_token"], &{:ok, Map.merge(&1, fields)})

  defp current_authority(entry, opts) do
    with true <- is_nil(opts[:owner]) or Process.alive?(opts[:owner]),
         {:ok, current} <- Coordination.get(entry["id"]),
         true <- current["owner_token"] == entry["owner_token"],
         {:ok, conn} <- connection(entry, opts),
         {:ok, context} <- api(opts).project_context(conn, entry["project_id"]),
         :ok <- authorized(context, conn.agent_id) do
      {:ok, conn}
    else
      {:error, _} = error -> error
      _ -> {:error, :ownership_lost}
    end
  end

  defp reported(entry, conn, opts) do
    event = entry["event"]
    payload = event["payload"] || %{}
    attempt_id = payload["resource_id"]
    task_id = event["task_ref"]
    data = payload["data"] || %{}

    with true <-
           payload["resource_type"] == "attempt" and is_binary(attempt_id) and is_binary(task_id),
         {:ok, task} <- api(opts).get_task(conn, entry["project_id"], task_id),
         entries when is_list(entries) <- Coordination.list(entry["device_id"]) do
      refs = Enum.filter(task["artifact_references"] || [], &(&1["attempt_id"] == attempt_id))
      result = local_result(entry, task_id, attempt_id)

      fields = %{
        "attempt_id" => attempt_id,
        "attempt_state" => data["state"],
        "report_sequence" => payload["sequence"],
        "task_state" => task["state"],
        "task_version" => task["version"],
        "artifact_references" => refs,
        "result" => result,
        "evidence_scope" =>
          if(result,
            do: "local_execution_report",
            else:
              if(refs == [], do: "event_and_task_state_only", else: "task_artifact_references")
          )
      }

      case update_reports(entries, entry["project_id"], task_id, fields) do
        :ok ->
          put(entry, %{"phase" => "completed"})

        {:error, _} ->
          put(entry, %{"phase" => "recovering", "last_error" => "report_projection_unconfirmed"})
      end
    else
      _ ->
        put(entry, %{"phase" => "recovering", "last_error" => "report_observation_unavailable"})
    end
  end

  defp update_reports(entries, project_id, task_id, fields) do
    targets =
      for parent <- entries,
          parent["project_id"] == project_id,
          {key, child} <- parent["children"],
          child["task_id"] == task_id,
          do: {parent, key}

    Enum.reduce_while(targets, :ok, fn {parent, key}, :ok ->
      result =
        Coordination.update(parent["id"], fn current ->
          old = get_in(current, ["children", key])

          if stale_report?(old, fields),
            do: {:ok, current},
            else:
              {:ok,
               current
               |> put_in(["children", key], Map.merge(old, fields))
               |> Map.put("phase", review_phase(current, key, fields))}
        end)

      case result do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp stale_report?(old, fields) do
    previous = old["report_sequence"]
    incoming = fields["report_sequence"]

    older_task =
      is_integer(old["task_version"]) and is_integer(fields["task_version"]) and
        fields["task_version"] < old["task_version"]

    older_event = is_integer(previous) and (!is_integer(incoming) or incoming <= previous)
    older_task or older_event
  end

  defp review_phase(current, key, fields) do
    children = Map.put(current["children"], key, Map.merge(current["children"][key], fields))

    if map_size(children) == length(current["plan"]["tasks"]) and
         Enum.all?(children, fn {_, child} -> child["task_state"] == "awaiting_review" end),
       do: "awaiting_human_review",
       else: current["phase"]
  end

  defp local_result(entry, task_id, attempt_id) do
    with {:ok, manager} <- Devices.get(entry["device_id"]),
         executions when is_list(executions) <- Executions.list() do
      Enum.find_value(executions, fn execution ->
        with true <-
               execution["project_id"] == entry["project_id"] and execution["task_id"] == task_id and
                 execution["attempt_id"] == attempt_id,
             {:ok, device} <- Devices.get(execution["device_id"]),
             true <- device["base_url"] == manager["base_url"],
             do: get_in(execution, ["report", "result"]),
             else: (_ -> nil)
      end)
    else
      _ -> nil
    end
  end

  defp connection(entry, opts),
    do:
      if(is_function(opts[:connection], 0),
        do: opts[:connection].(),
        else: Inbound.api_conn(entry["device_id"])
      )

  defp api(opts), do: Keyword.get(opts, :api, API)
  defp reason_text(%{code: code}), do: code
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(_), do: "coordination_failed"
end
