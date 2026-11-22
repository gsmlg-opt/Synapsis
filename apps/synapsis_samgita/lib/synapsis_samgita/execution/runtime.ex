defmodule SynapsisSamgita.Execution.Runtime do
  @moduledoc false
  alias Synapsis.{AgentConfigs, Sessions}
  alias SynapsisLocalAgents.Event

  @summary_bytes 4_096

  def prepare(device, task, opts \\ [])

  def prepare(%{"source_kind" => "agent", "source_id" => id}, task, opts) do
    session_opts =
      if opts[:planning] == true,
        do: %{
          title: task["title"],
          config: %{
            "samgita_coordination" => true,
            "subagents" => false,
            "memory_context" => false
          }
        },
        else: %{title: task["title"]}

    with %{name: name, enabled: true} <- AgentConfigs.get(id),
         {:ok, session} <- Sessions.create(name, session_opts) do
      Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}")
      handle = %{"kind" => "agent", "session_id" => session.id}

      case Registry.lookup(Synapsis.Session.Registry, session.id) do
        [{pid, _}] -> {:ok, Map.put(handle, :monitor_ref, Process.monitor(pid))}
        [] -> {:error, :agent_unavailable}
      end
    else
      _ -> {:error, :agent_unavailable}
    end
  end

  def prepare(%{"source_kind" => "local_agent", "source_id" => id}, _task, _opts) do
    with %{state: :running} <- SynapsisLocalAgents.status(id),
         :ok <- SynapsisLocalAgents.subscribe(id),
         {:ok, %{id: thread_id}} <- SynapsisLocalAgents.start_thread(id) do
      case SynapsisLocalAgents.Runner.whereis(id) do
        pid when is_pid(pid) ->
          {:ok,
           %{
             "kind" => "local_agent",
             "source_id" => id,
             "thread_id" => thread_id,
             :monitor_ref => Process.monitor(pid)
           }}

        _ ->
          {:error, :local_agent_unavailable}
      end
    else
      _ -> {:error, :local_agent_unavailable}
    end
  end

  def start(%{"kind" => "agent", "session_id" => session_id} = handle, text) do
    case Sessions.send_message(session_id, text) do
      :ok -> {:ok, handle}
      {:ok, _} -> {:ok, handle}
      error -> error
    end
  end

  def start(
        %{"kind" => "local_agent", "source_id" => id, "thread_id" => thread_id} = handle,
        text
      ) do
    with {:ok, %{turn_id: turn_id}} <- SynapsisLocalAgents.start_turn(id, thread_id, text),
         do: {:ok, Map.put(handle, "turn_id", turn_id)}
  end

  def observe(%{monitor_ref: ref} = handle, {:DOWN, ref, :process, _pid, _reason}),
    do: {:done, "failed", false, result(handle, "process_down")}

  def observe(
        %{"kind" => "local_agent", "source_id" => id, "thread_id" => thread, "turn_id" => turn} =
          handle,
        message
      ) do
    case message do
      {:local_agent_event,
       %Event{
         agent_id: ^id,
         thread_id: ^thread,
         turn_id: ^turn,
         type: :turn_completed,
         data: %{status: "completed"}
       }} ->
        {:done, "succeeded", true, result(handle, "completed")}

      {:local_agent_event,
       %Event{
         agent_id: ^id,
         thread_id: ^thread,
         turn_id: ^turn,
         type: :turn_completed,
         data: %{status: status} = data
       }}
      when status in ["failed", "interrupted"] ->
        {:done, "failed", false, result(handle, status, data[:error])}

      {:local_agent_event, %Event{agent_id: ^id, type: :status, data: %{state: state} = data}}
      when state in [:crashed, :stopped] ->
        {:done, "failed", false, result(handle, Atom.to_string(state), data[:last_error])}

      _ ->
        :pending
    end
  end

  def observe(%{"kind" => "agent"} = handle, {"session_status", %{status: "idle"}}),
    do: observe(handle, {"done", %{}})

  def observe(%{"kind" => "agent", "session_id" => session_id} = handle, {event, _})
      when event in ["done", "error"] do
    case Synapsis.Session.Worker.snapshot(session_id) do
      %{session: %{id: ^session_id}, status: status} = snapshot
      when status in [:idle, "idle", :waiting, "waiting", :error, "error"] ->
        session_terminal(handle, snapshot, event)

      %{session: %{id: ^session_id}} ->
        :pending

      _ ->
        {:done, "failed", false,
         result(handle, "unconfirmed", "Session terminal state could not be verified.")}
    end
  catch
    :exit, _ ->
      {:done, "failed", false,
       result(handle, "unconfirmed", "Session terminal state could not be read.")}
  end

  def observe(%{"kind" => "agent"}, _), do: :pending

  defp session_terminal(handle, snapshot, event) do
    roster = Map.get(snapshot, :subagents, %{})
    handle = put_reference(handle, "run_id", get_in(roster, [:root, :run_id]))

    case {event, snapshot[:status], completion(roster)} do
      {"done", status, {:done, "succeeded", true}}
      when status in [:idle, "idle", :waiting, "waiting"] ->
        {handle, text} = session_output(handle)
        {:done, "succeeded", true, result(handle, "completed", text)}

      _ ->
        cancel(handle)

        reason =
          snapshot[:error] || "Session root or child agents have unresolved execution or cleanup."

        {:done, "failed", false, result(handle, "failed", reason)}
    end
  end

  defp session_output(%{"session_id" => id} = handle) do
    # A terminal UI event is emitted after the turn commit. Read only the final
    # authored assistant message, never reasoning, tools, or another session.
    case List.last(Synapsis.Message.list_recent_by_session(id, 1)) do
      %Synapsis.Message{role: "assistant", id: message_id, parts: parts} ->
        text =
          Enum.map_join(parts, "", fn
            %Synapsis.Part.Text{content: text} when is_binary(text) -> text
            _ -> ""
          end)

        {put_reference(handle, "message_id", message_id), text}

      _ ->
        {handle, nil}
    end
  end

  @doc false
  def result(handle, status, text \\ nil) do
    provided = is_binary(text) and String.trim(text) != ""
    text = if provided, do: text, else: handle["public_output"]

    text =
      if is_binary(text) and String.trim(text) != "",
        do: text,
        else: "Observed runtime terminal status: #{status}. No public text was available."

    {summary, truncated} = bounded(text)

    %{
      "summary" => summary,
      "runtime" =>
        Map.take(handle, ~w(kind session_id source_id thread_id turn_id run_id message_id)),
      "terminal_status" => status,
      "truncated" => truncated or (!provided and Map.get(handle, "output_truncated", false))
    }
  end

  defp put_reference(handle, key, value) when is_binary(value), do: Map.put(handle, key, value)
  defp put_reference(handle, _key, _value), do: handle

  defp bounded(text) when byte_size(text) <= @summary_bytes, do: {text, false}

  defp bounded(text) do
    prefix = binary_part(text, 0, @summary_bytes)

    valid =
      case :unicode.characters_to_binary(prefix) do
        value when is_binary(value) -> value
        {_, value, _} -> value
      end

    {valid, true}
  end

  @doc false
  def completion(roster) do
    settled =
      get_in(roster, [:root, :status]) in [:completed, "completed"] and
        !roster[:recovery_required] and !roster[:error] and
        Enum.all?(Map.get(roster, :agents, []), fn agent ->
          agent[:status] in [:completed, :closed, :shutdown, "completed", "closed", "shutdown"] and
            agent[:cleanup] not in [:uncertain, "uncertain"] and is_nil(agent[:error])
        end)

    if settled, do: {:done, "succeeded", true}, else: {:done, "failed", false}
  end

  def watch(%{"kind" => "agent", "session_id" => id}),
    do: Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{id}")

  def watch(%{"kind" => "local_agent", "source_id" => id}), do: SynapsisLocalAgents.subscribe(id)

  def capture(
        %{"kind" => "local_agent", "source_id" => id, "thread_id" => thread} = handle,
        {:local_agent_event,
         %Event{agent_id: id, thread_id: thread, turn_id: turn, type: :turn_started}}
      ) do
    # The start acknowledgement may race the notification. Once known, a later
    # turn on the same thread cannot replace this execution's identity.
    if is_nil(handle["turn_id"]), do: Map.put(handle, "turn_id", turn), else: handle
  end

  def capture(
        %{"kind" => "local_agent", "source_id" => id, "thread_id" => thread, "turn_id" => turn} =
          handle,
        {:local_agent_event,
         %Event{
           agent_id: id,
           thread_id: thread,
           turn_id: turn,
           type: :item_completed,
           data: %{item: %{type: "agentMessage", text: text}}
         }}
      )
      when is_binary(text) do
    {output, truncated} = bounded(text)
    handle |> Map.put("public_output", output) |> Map.put("output_truncated", truncated)
  end

  def capture(handle, _), do: handle

  def cancel(%{"kind" => "agent", "session_id" => id}), do: Sessions.cancel(id)

  def cancel(%{
        "kind" => "local_agent",
        "source_id" => id,
        "thread_id" => thread,
        "turn_id" => turn
      }),
      do: SynapsisLocalAgents.interrupt_turn(id, thread, turn)

  def cancel(_), do: :ok
end
