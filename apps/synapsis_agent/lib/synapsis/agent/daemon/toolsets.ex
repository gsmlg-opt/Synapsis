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

  @spec resolve(term()) :: {:ok, [String.t()]} | {:error, atom()}
  def resolve("dangerous"), do: {:error, :dangerous_tool_profile}

  def resolve(profile) do
    case Map.fetch(@profiles, profile) do
      {:ok, tools} -> {:ok, tools ++ safe_mcp_tools()}
      :error -> {:error, :unknown_tool_profile}
    end
  end

  defp safe_mcp_tools do
    Synapsis.Tool.Registry.list_for_query_loop()
    |> Enum.filter(fn tool ->
      String.starts_with?(tool.name, "mcp:") and
        tool.permission_level in [:none, :read] and
        non_deferred?(tool.name)
    end)
    |> Enum.map(& &1.name)
    |> Enum.sort()
  rescue
    ArgumentError -> []
  end

  defp non_deferred?(name) do
    case Synapsis.Tool.Registry.lookup(name) do
      {:ok, {_kind, _owner, opts}} -> opts[:deferred] != true
      {:error, :not_found} -> false
    end
  end
end
