defmodule Synapsis.Tool.Task do
  @moduledoc "Launch a sub-agent to handle a task autonomously."
  use Synapsis.Tool

  # SessionBridge lives in synapsis_agent (higher-layer dependency)
  @compile {:no_warn_undefined, Synapsis.Agent.SessionBridge}
  @compile {:no_warn_undefined,
            [
              Synapsis.Agent.QueryLoop,
              Synapsis.Agent.QueryLoop.State,
              Synapsis.Agent.QueryLoop.Context
            ]}

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

    if context[:query_context] do
      execute_via_query_loop(prompt, input, context)
    else
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
            execute_foreground(project_id, prompt, spawn_opts, session_id)

          "background" ->
            execute_background(project_id, prompt, spawn_opts)

          _ ->
            {:error, "Invalid mode: #{mode}. Use 'foreground' or 'background'."}
        end
      end
    end
  end

  defp execute_via_query_loop(prompt, input, context) do
    query_ctx = context[:query_context]

    unless Synapsis.Agent.QueryLoop.can_fork?(query_ctx) do
      {:error, "Maximum subagent depth (#{query_ctx.depth}) reached"}
    else
      tool_names =
        case input["tools"] do
          nil -> :read_only
          list when is_list(list) -> list
          _ -> :read_only
        end

      child_ctx =
        Synapsis.Agent.QueryLoop.fork(query_ctx,
          system_prompt: build_subagent_prompt(prompt),
          subscriber: self(),
          tool_names: tool_names,
          model: input["model"]
        )

      child_state =
        struct!(Synapsis.Agent.QueryLoop.State,
          messages: [%{role: "user", content: prompt}],
          max_turns: 50
        )

      # Run synchronously — the parent loop is blocked on this tool call
      case Synapsis.Agent.QueryLoop.run(child_state, child_ctx) do
        {:ok, :completed, final_state} ->
          summary = extract_subagent_response(final_state.messages)
          {:ok, summary}

        {:ok, reason, _state} ->
          {:error, "Subagent terminated: #{reason}"}
      end
    end
  end

  defp build_subagent_prompt(task) do
    """
    You are a subagent for Synapsis. Given the task below, use available tools to complete it.
    Complete the task fully. When done, respond with a concise report.

    Your strengths:
    - Searching for code, configurations, and patterns across codebases
    - Analyzing multiple files to understand system architecture
    - Performing multi-step research tasks

    Guidelines:
    - Search broadly when you don't know where something lives
    - Be thorough: check multiple locations, consider different naming conventions
    - NEVER create files unless absolutely necessary

    Task: #{task}
    """
  end

  defp extract_subagent_response(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(&(&1.role == "assistant"))
    |> case do
      %{content: content} when is_binary(content) ->
        content

      %{content: blocks} when is_list(blocks) ->
        blocks
        |> Enum.filter(&(is_map(&1) and &1[:type] == "text"))
        |> Enum.map_join("\n", & &1[:text])

      _ ->
        "Subagent completed without response."
    end
  end

  defp execute_foreground(project_id, prompt, opts, parent_session_id) do
    ref = opts.notify_ref

    case Synapsis.Agent.SessionBridge.spawn_coding_session(project_id, prompt, opts) do
      {:ok, sub_session_id} ->
        Logger.info("sub_agent_foreground_started",
          sub_session_id: sub_session_id,
          ref: ref
        )

        Phoenix.PubSub.broadcast(
          Synapsis.PubSub,
          "session:#{parent_session_id}",
          {"code_agent_spawned", %{sub_session_id: sub_session_id, prompt: prompt, ref: ref}}
        )

        relay_pid = start_event_relay(sub_session_id, parent_session_id)

        result =
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
              {:error,
               "Sub-agent task timed out after #{div(@foreground_timeout, 60_000)} minutes"}
          end

        Process.exit(relay_pid, :kill)
        result

      {:error, _reason} ->
        {:error, "Failed to spawn sub-agent"}
    end
  end

  # Relay sub-session PubSub events to the parent session topic tagged with sub_session_id.
  # This lets the parent LiveView track Code Agent activity without subscribing directly.
  defp start_event_relay(sub_session_id, parent_session_id) do
    spawn(fn ->
      Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{sub_session_id}")
      relay_events(sub_session_id, parent_session_id)
    end)
  end

  @relayed_events ~w[text_delta tool_use tool_result reasoning done]

  defp relay_events(sub_session_id, parent_session_id) do
    receive do
      {event, payload} when event in @relayed_events ->
        Phoenix.PubSub.broadcast(
          Synapsis.PubSub,
          "session:#{parent_session_id}",
          {"code_agent_event", %{sub_session_id: sub_session_id, event: event, payload: payload}}
        )

        if event != "done", do: relay_events(sub_session_id, parent_session_id)

      _ ->
        relay_events(sub_session_id, parent_session_id)
    after
      @foreground_timeout -> :ok
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

        {:error, _reason} ->
          send(caller, {:background_task_done, ref, {:error, "Failed to spawn sub-agent"}})
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
    |> Enum.map(& &1.content)
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
