defmodule Synapsis.Agent.ToolDispatcher do
  @moduledoc """
  Handles tool permission checks, async dispatch, and result collection.

  Extracted from Session.Worker.process_tool_uses/1 and execute_tool_async/2.
  """

  alias Synapsis.Session.Monitor
  require Logger

  @type dispatch_result ::
          {:approved, Synapsis.Part.ToolUse.t()}
          | {:requires_approval, Synapsis.Part.ToolUse.t()}
          | {:denied, Synapsis.Part.ToolUse.t()}

  @doc """
  Check permissions for each tool use and classify them.
  Returns `{classified_tools, updated_monitor}`.
  """
  @spec classify(
          [Synapsis.Part.ToolUse.t()],
          Synapsis.Session.t(),
          Monitor.t()
        ) :: {[dispatch_result()], Monitor.t()}
  def classify(tool_uses, session, monitor) do
    monitor =
      Enum.reduce(tool_uses, monitor, fn tu, mon ->
        {_signal, mon} = Monitor.record_tool_call(mon, tu.tool, tu.input)
        mon
      end)

    classified =
      Enum.map(tool_uses, fn tool_use ->
        permission = Synapsis.Tool.Permission.check(tool_use.tool, session)

        case permission do
          :approved -> {:approved, tool_use}
          :requires_approval -> {:requires_approval, tool_use}
          :denied -> {:denied, tool_use}
        end
      end)

    {classified, monitor}
  end

  @doc """
  Execute a single tool asynchronously. Sends `{:tool_result, tool_use_id, output, is_error}`
  back to `caller_pid` when done.
  """
  @spec execute_async(
          Synapsis.Part.ToolUse.t(),
          pid(),
          map()
        ) :: Task.t()
  def execute_async(tool_use, caller_pid, opts) do
    project_path = opts[:project_path]
    effective_path = opts[:effective_path] || project_path
    session_id = opts[:session_id]
    agent_id = opts[:agent_id] || "default"
    project_id = opts[:project_id]
    tool_call_hashes = opts[:tool_call_hashes] || MapSet.new()

    call_hash = :erlang.phash2({tool_use.tool, tool_use.input})
    is_duplicate = MapSet.member?(tool_call_hashes, call_hash)

    # Auto-checkpoint before write operations (only on main tree)
    worktree_path = opts[:worktree_path]

    if is_nil(worktree_path) and tool_use.tool in ["file_edit", "file_write", "bash"] and
         Synapsis.Git.is_repo?(project_path) do
      Synapsis.Git.checkpoint(project_path, "synapsis pre-#{tool_use.tool}")
    end

    Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn ->
      result =
        Synapsis.Tool.Executor.execute(tool_use.tool, tool_use.input, %{
          project_path: effective_path,
          session_id: session_id,
          working_dir: effective_path,
          agent_id: agent_id,
          agent_scope: :project,
          project_id: project_id
        })

      case result do
        {:ok, output} ->
          final_output =
            if is_duplicate do
              output <>
                "\n\nWarning: This exact tool call was already made in this conversation turn. The same approach may not work. Try a different approach."
            else
              output
            end

          send(caller_pid, {:tool_result, tool_use.tool_use_id, final_output, false})

        {:error, reason} ->
          error_msg = if is_binary(reason), do: reason, else: "Tool execution failed"
          send(caller_pid, {:tool_result, tool_use.tool_use_id, error_msg, true})
      end
    end)
  end

  @doc """
  Dispatch all tool uses: execute approved, request approval, deny denied.
  Returns updated tool_call_hashes.
  """
  @spec dispatch_all(
          [{:approved | :requires_approval | :denied, Synapsis.Part.ToolUse.t()}],
          pid(),
          String.t(),
          map()
        ) :: MapSet.t()
  def dispatch_all(classified_tools, caller_pid, session_id, opts) do
    hashes = opts[:tool_call_hashes] || MapSet.new()

    new_hashes =
      Enum.reduce(classified_tools, hashes, fn {_, tu}, acc ->
        MapSet.put(acc, :erlang.phash2({tu.tool, tu.input}))
      end)

    for {classification, tool_use} <- classified_tools do
      case classification do
        :approved ->
          execute_async(tool_use, caller_pid, Map.put(opts, :tool_call_hashes, new_hashes))

        :requires_approval ->
          Phoenix.PubSub.broadcast(
            Synapsis.PubSub,
            "session:#{session_id}",
            {"permission_request",
             %{
               tool: tool_use.tool,
               tool_use_id: tool_use.tool_use_id,
               input: tool_use.input
             }}
          )

        :denied ->
          send(
            caller_pid,
            {:tool_result, tool_use.tool_use_id, "Tool denied by permission policy.", true}
          )
      end
    end

    new_hashes
  end
end
