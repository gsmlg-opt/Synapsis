defmodule Synapsis.Agent.Daemon.Toolsets do
  @moduledoc false

  @basic ~w(
    file_read list_dir grep glob memory_search todo_read session_summarize skill tool_search
    agent_status agent_discover agent_inbox
  )
  @workspace @basic ++
               ~w(memory_save memory_update todo_write file_write file_edit multi_edit file_move)
  @coding @workspace ++ ~w(bash task)
  @dream @basic ++ ~w(memory_save memory_update)

  @profiles %{
    "assistant_basic" => @basic,
    "assistant_workspace" => @workspace,
    "assistant_coding" => @coding,
    "assistant_dream" => @dream,
    "assistant_dream_todo" => @dream ++ ["todo_write"],
    "read_only" => @basic,
    "reflect" => @workspace,
    "heartbeat" => @workspace,
    "coding" => @coding,
    "maintenance" => @coding
  }

  @builtin_modules %{
    "file_read" => Synapsis.Tool.FileRead,
    "list_dir" => Synapsis.Tool.ListDir,
    "grep" => Synapsis.Tool.Grep,
    "glob" => Synapsis.Tool.Glob,
    "memory_search" => Synapsis.Tool.MemorySearch,
    "todo_read" => Synapsis.Tool.TodoRead,
    "session_summarize" => Synapsis.Tool.SessionSummarize,
    "skill" => Synapsis.Tool.Skill,
    "tool_search" => Synapsis.Tool.ToolSearch,
    "agent_status" => Synapsis.Tool.AgentStatus,
    "agent_discover" => Synapsis.Tool.AgentDiscover,
    "agent_inbox" => Synapsis.Tool.AgentInbox,
    "memory_save" => Synapsis.Tool.MemorySave,
    "memory_update" => Synapsis.Tool.MemoryUpdate,
    "todo_write" => Synapsis.Tool.TodoWrite,
    "file_write" => Synapsis.Tool.FileWrite,
    "file_edit" => Synapsis.Tool.FileEdit,
    "multi_edit" => Synapsis.Tool.MultiEdit,
    "file_move" => Synapsis.Tool.FileMove,
    "bash" => Synapsis.Tool.Bash,
    "task" => Synapsis.Tool.Task
  }

  @spec resolve(term()) :: {:ok, [String.t()]} | {:error, atom()}
  def resolve("dangerous"), do: {:error, :dangerous_tool_profile}

  def resolve(profile) do
    case Map.fetch(@profiles, profile) do
      {:ok, tools} -> {:ok, tools ++ safe_mcp_tools()}
      :error -> {:error, :unknown_tool_profile}
    end
  end

  @doc false
  @spec resolve_for_query_loop(term()) :: {:ok, [map()]} | {:error, atom()}
  def resolve_for_query_loop(profile) do
    with {:ok, names} <- resolve(profile) do
      tools_by_name =
        Synapsis.Tool.Registry.list_for_query_loop(names: names)
        |> Map.new(&{&1.name, &1})

      tools =
        Enum.flat_map(names, fn name ->
          case Map.get(tools_by_name, name) do
            %{registration: registration} = tool ->
              if approved_registration?(name, registration), do: [tool], else: []

            _missing_or_unbound ->
              []
          end
        end)

      {:ok, tools}
    end
  end

  defp safe_mcp_tools do
    Synapsis.Tool.Registry.list_for_query_loop()
    |> Enum.filter(fn tool ->
      String.starts_with?(tool.name, "mcp:") and
        tool.permission_level in [:none, :read] and
        trusted_non_deferred?(tool.name)
    end)
    |> Enum.map(& &1.name)
    |> Enum.sort()
  rescue
    ArgumentError -> []
  end

  defp trusted_non_deferred?(name) do
    case Synapsis.Tool.Registry.lookup(name) do
      {:ok, {_kind, _owner, opts}} ->
        opts[:trust_annotations] == true and opts[:deferred] != true

      {:error, :not_found} ->
        false
    end
  end

  defp approved_registration?(name, {:module, module, _opts}) do
    Map.get(@builtin_modules, name) == module
  end

  defp approved_registration?("mcp:" <> _rest, {:process, _pid, opts}) do
    opts[:permission_level] in [:none, :read] and opts[:trust_annotations] == true and
      opts[:deferred] != true
  end

  defp approved_registration?(_name, _registration), do: false
end
