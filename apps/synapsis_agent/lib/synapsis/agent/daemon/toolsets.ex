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
      {:ok, tools} -> {:ok, tools}
      :error -> {:error, :unknown_tool_profile}
    end
  end
end
