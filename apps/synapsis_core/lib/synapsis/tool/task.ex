defmodule Synapsis.Tool.Task do
  @moduledoc "Launch a sub-agent to handle a task autonomously."
  use Synapsis.Tool

  # SessionBridge lives in synapsis_agent (higher-layer dependency)
  @compile {:no_warn_undefined, Synapsis.Agent.SessionBridge}

  require Logger

  @foreground_timeout :timer.minutes(10)
  @background_timeout :timer.minutes(30)

  @impl true
  def name, do: "task"

  @impl true
  def description,
    do:
      "Launch a sub-agent to handle a complex task. Runs in foreground (blocking) or background."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "prompt" => %{"type" => "string", "description" => "Task description for the sub-agent"},
        "tools" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Tool names available to sub-agent (default: read-only tools)"
        },
        "mode" => %{
          "type" => "string",
          "enum" => ["foreground", "background"],
          "description" => "foreground blocks until complete, background returns immediately"
        },
        "model" => %{"type" => "string", "description" => "Optional model override for sub-agent"}
      },
      "required" => ["prompt"]
    }
  end

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :orchestration

  @impl true
  def enabled?, do: true

  @impl true
  def execute(input, context) do
    prompt = input["prompt"]
    mode = input["mode"] || "foreground"
    model = input["model"]

    session_id = context[:session_id]
    project_id = context[:project_id]

    cond do
      is_nil(session_id) ->
        {:error, "No session context available for sub-agent"}

      is_nil(project_id) ->
        {:error, "No project context available for sub-agent"}

      true ->
        spawn_opts =
          %{
            agent: "build",
            notify_pid: self(),
            notify_ref: Ecto.UUID.generate()
          }
          |> maybe_put(:model, model)

        case mode do
          "foreground" ->
            execute_foreground(project_id, prompt, spawn_opts)

          "background" ->
            execute_background(project_id, prompt, spawn_opts)

          _ ->
            {:error, "Invalid mode: #{mode}. Use 'foreground' or 'background'."}
        end
    end
  end

  defp execute_foreground(project_id, prompt, opts) do
    ref = opts.notify_ref

    case Synapsis.Agent.SessionBridge.spawn_coding_session(project_id, prompt, opts) do
      {:ok, sub_session_id} ->
        Logger.info("sub_agent_foreground_started",
          sub_session_id: sub_session_id,
          ref: ref
        )

        receive do
          {:coding_session_completed, ^ref, ^sub_session_id} ->
            result = collect_session_result(sub_session_id)
            {:ok, result}

          {:coding_session_failed, ^ref, ^sub_session_id} ->
            {:error, "Sub-agent task failed for session #{sub_session_id}"}

          {:coding_session_timeout, ^ref, ^sub_session_id} ->
            {:error, "Sub-agent task timed out for session #{sub_session_id}"}
        after
          @foreground_timeout ->
            {:error, "Sub-agent task timed out after #{div(@foreground_timeout, 60_000)} minutes"}
        end

      {:error, reason} ->
        {:error, "Failed to spawn sub-agent: #{inspect(reason)}"}
    end
  end

  defp execute_background(project_id, prompt, opts) do
    ref = opts.notify_ref
    caller = self()

    Task.Supervisor.start_child(Synapsis.Tool.TaskSupervisor, fn ->
      case Synapsis.Agent.SessionBridge.spawn_coding_session(project_id, prompt, opts) do
        {:ok, sub_session_id} ->
          Logger.info("sub_agent_background_started",
            sub_session_id: sub_session_id,
            ref: ref
          )

          receive do
            {:coding_session_completed, ^ref, ^sub_session_id} ->
              result = collect_session_result(sub_session_id)

              Phoenix.PubSub.broadcast(
                Synapsis.PubSub,
                "session:#{sub_session_id}",
                {"background_task_completed", %{ref: ref, result: result}}
              )

              send(caller, {:background_task_done, ref, {:ok, result}})

            {:coding_session_failed, ^ref, ^sub_session_id} ->
              send(caller, {:background_task_done, ref, {:error, "Sub-agent task failed"}})

            {:coding_session_timeout, ^ref, ^sub_session_id} ->
              send(caller, {:background_task_done, ref, {:error, "Sub-agent task timed out"}})
          after
            @background_timeout ->
              send(
                caller,
                {:background_task_done, ref, {:error, "Sub-agent task timed out"}}
              )
          end

        {:error, reason} ->
          send(caller, {:background_task_done, ref, {:error, inspect(reason)}})
      end
    end)

    {:ok,
     Jason.encode!(%{
       "task_id" => ref,
       "status" => "running",
       "prompt" => String.slice(prompt, 0..100)
     })}
  end

  defp collect_session_result(session_id) do
    case Synapsis.Sessions.get(session_id) do
      {:ok, session} ->
        last_assistant =
          session.messages
          |> Enum.filter(&(&1.role == "assistant"))
          |> List.last()

        case last_assistant do
          nil -> "Sub-agent completed with no output."
          msg -> extract_text(msg)
        end

      {:error, _} ->
        "Sub-agent completed (session #{session_id})."
    end
  end

  defp extract_text(%{parts: parts}) when is_list(parts) do
    parts
    |> Enum.filter(fn
      %Synapsis.Part.Text{} -> true
      _ -> false
    end)
    |> Enum.map(& &1.text)
    |> Enum.join("\n")
    |> case do
      "" -> "Sub-agent completed with no text output."
      text -> text
    end
  end

  defp extract_text(_), do: "Sub-agent completed."

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
