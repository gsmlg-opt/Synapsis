defmodule Synapsis.Agent.Daemon.Toolsets do
  @moduledoc false

  @basic ~w(
    synapsis::read synapsis::ls synapsis::memory_source_search synapsis::todo_read
    synapsis::session_summarize synapsis::skill synapsis::agent_status
    synapsis::agent_discover synapsis::agent_inbox
  )
  @workspace @basic ++
               ~w(synapsis::memory_save synapsis::memory_update synapsis::todo_write
                  synapsis::write synapsis::edit apply_patch)
  @coding @workspace ++
            ~w(exec_command write_stdin spawn_agent send_message followup_task
               interrupt_agent list_agents wait_agent)
  @dream @basic ++ ~w(synapsis::memory_save synapsis::memory_update)

  @profiles %{
    "assistant_basic" => @basic,
    "assistant_workspace" => @workspace,
    "assistant_coding" => @coding,
    "assistant_dream" => @dream,
    "assistant_dream_todo" => @dream ++ ["synapsis::todo_write"],
    "read_only" => @basic,
    "reflect" => @workspace,
    "heartbeat" => @workspace,
    "coding" => @coding,
    "maintenance" => @coding
  }

  @spec profile?(term()) :: boolean()
  def profile?(profile), do: Map.has_key?(@profiles, profile)

  @spec resolve(term()) :: {:ok, [String.t()]} | {:error, atom()}
  def resolve("dangerous"), do: {:error, :dangerous_tool_profile}

  def resolve(profile) do
    case Map.fetch(@profiles, profile) do
      {:ok, tools} -> {:ok, tools}
      :error -> {:error, :unknown_tool_profile}
    end
  end
end
