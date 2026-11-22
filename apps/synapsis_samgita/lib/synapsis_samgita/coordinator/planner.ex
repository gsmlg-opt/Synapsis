defmodule SynapsisSamgita.Coordinator.Planner do
  @moduledoc false
  alias SynapsisSamgita.Execution.Runtime

  def plan(device, event, candidates, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 120_000)

    prompt = """
    Decompose this explicit Samgita project request into a small task tree.
    Return JSON only: {"title":"project work", "tasks":[{"title":"...",
    "description":"...", "assignee_agent_id":"...", "required_capabilities":[]}]}
    Produce between 1 and 10 concrete tasks. Choose only an assignee from the
    registered project worker identities below. This is planning only; do not
    execute work, call tools, or claim that any work has completed.
    This first coordination flow supports tasks requiring no extra capability.
    Request: #{JSON.encode!(event)}
    Available executor IDs: #{JSON.encode!(candidates)}
    """

    with {:ok, handle} <-
           Runtime.prepare(device, %{"title" => "Samgita project decomposition"}, planning: true),
         :ok <- record_session(opts, handle),
         {:ok, handle} <- Runtime.start(handle, prompt) do
      caller = self()

      guard =
        Task.Supervisor.async_nolink(SynapsisSamgita.TaskSupervisor, fn ->
          ref = Process.monitor(caller)

          receive do
            :finished -> Process.demonitor(ref, [:flush])
            {:DOWN, ^ref, :process, _, _} -> Runtime.cancel(handle)
          after
            timeout + 5_000 -> Runtime.cancel(handle)
          end
        end)

      owner_ref = if is_pid(opts[:owner]), do: Process.monitor(opts[:owner])

      try do
        wait(handle, System.monotonic_time(:millisecond) + timeout, owner_ref)
      after
        send(guard.pid, :finished)
        Process.demonitor(guard.ref, [:flush])
        if owner_ref, do: Process.demonitor(owner_ref, [:flush])
      end
    end
  end

  defp record_session(opts, handle) do
    case opts[:on_session] do
      nil -> :ok
      fun -> fun.(Map.drop(handle, [:monitor_ref]))
    end
  end

  defp wait(handle, deadline, owner_ref) do
    receive do
      {:DOWN, ^owner_ref, :process, _, _} when is_reference(owner_ref) ->
        Runtime.cancel(handle)
        {:error, :coordinator_lost}

      message ->
        case Runtime.observe(handle, message) do
          {:done, "succeeded", true, _result} -> output(handle)
          {:done, _, _, result} -> {:error, {:planning_failed, result["summary"]}}
          :pending -> wait(handle, deadline, owner_ref)
        end
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Runtime.cancel(handle)
        {:error, :planning_timeout}
    end
  end

  defp output(%{"session_id" => id}) do
    case List.last(Synapsis.Message.list_recent_by_session(id, 1)) do
      %Synapsis.Message{role: "assistant", parts: parts} ->
        text =
          Enum.map_join(parts, "", fn
            %Synapsis.Part.Text{content: text} -> text
            _ -> ""
          end)

        if byte_size(text) <= 32_768, do: JSON.decode(text), else: {:error, :plan_too_large}

      _ ->
        {:error, :missing_plan}
    end
  end
end
