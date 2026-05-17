defmodule Synapsis.AgentConfigs do
  @moduledoc "Context for managing persisted agent configurations."

  import Ecto.Query, except: [update: 2]
  alias Synapsis.{AgentConfig, Repo}

  @build_tools ~w(
    file_read file_edit file_write multi_edit file_delete file_move list_dir
    grep glob bash fetch web_search
    todo_read todo_write enter_plan_mode exit_plan_mode
    task skill tool_search ask_user sleep
    memory_save memory_search memory_update session_summarize
    board_read board_update devlog_read devlog_write
    repo_link repo_status repo_sync
    worktree_create worktree_list worktree_remove
    workspace_read workspace_write workspace_list workspace_search
    diagnostics
  )

  @retired_default_agent_names ~w(assistant build plan)

  @doc "List all agent configs, ordered by name."
  def list do
    AgentConfig
    |> order_by(:name)
    |> Repo.all()
  end

  @doc "List only enabled agent configs."
  def list_enabled do
    AgentConfig
    |> where(enabled: true)
    |> order_by(:name)
    |> Repo.all()
  end

  @doc "Get an agent config by name."
  def get_by_name(name) when is_binary(name) do
    Repo.get_by(AgentConfig, name: name)
  end

  @doc "Get an agent config by id."
  def get(id) do
    Repo.get(AgentConfig, id)
  end

  @doc "Create a new agent config."
  def create(attrs) when is_map(attrs) do
    %AgentConfig{}
    |> AgentConfig.changeset(attrs)
    |> Repo.insert()
    |> reload_after_default_normalization()
  end

  @doc "Update an existing agent config."
  def update(%AgentConfig{} = agent_config, attrs) when is_map(attrs) do
    agent_config
    |> AgentConfig.update_changeset(attrs)
    |> Repo.update()
    |> reload_after_default_normalization()
  end

  @doc "Delete an agent config."
  def delete(%AgentConfig{} = agent_config) do
    if protected?(agent_config) do
      {:error, :protected}
    else
      Repo.delete(agent_config)
    end
  end

  @doc "Returns true for default/built-in agent records that should not be removed."
  def protected?(%AgentConfig{} = agent_config) do
    agent_config.is_default || agent_config.name in Enum.map(default_attrs(), & &1.name)
  end

  @doc "Return default agent configuration maps."
  def default_attrs do
    [
      %{
        name: "main",
        label: "Main",
        icon: "robot-outline",
        description: "AI coding assistant with full workspace access, tools, and memory.",
        system_prompt: default_system_prompt(),
        tools: @build_tools,
        reasoning_effort: "medium",
        read_only: false,
        max_tokens: 8192,
        model_tier: "default",
        is_default: true,
        enabled: true
      }
    ]
  end

  @doc "Return a default agent configuration map by name."
  def default_attrs(name) when is_binary(name) do
    Enum.find(default_attrs(), &(&1.name == name))
  end

  @doc "Upsert an agent config by name — insert or update."
  def upsert(name, attrs) when is_binary(name) and is_map(attrs) do
    case get_by_name(name) do
      nil ->
        attrs = Map.put(attrs, :name, name)
        create(attrs)

      existing ->
        update(existing, attrs)
    end
  end

  @doc """
  Seed default agents if they don't exist.
  Called on application startup.
  """
  def seed_defaults do
    purge_retired_default_agents()

    for attrs <- default_attrs() do
      case get_by_name(attrs.name) do
        nil -> create(attrs)
        _existing -> :ok
      end
    end

    normalize_default_flags()

    :ok
  end

  defp purge_retired_default_agents do
    AgentConfig
    |> where([agent], agent.name in ^@retired_default_agent_names)
    |> Repo.delete_all()

    :ok
  end

  defp reload_after_default_normalization({:ok, %AgentConfig{} = agent_config}) do
    normalize_default_flags()
    {:ok, Repo.get!(AgentConfig, agent_config.id)}
  end

  defp reload_after_default_normalization(result), do: result

  defp normalize_default_flags do
    AgentConfig
    |> where([agent], agent.name != "main")
    |> Repo.update_all(set: [is_default: false])

    AgentConfig
    |> where([agent], agent.name == "main")
    |> Repo.update_all(set: [is_default: true])

    :ok
  end

  defp default_system_prompt do
    """
    You are Synapsis, an AI coding assistant. You help developers write, edit, and understand code.
    You have access to tools for reading files, editing files, running shell commands, and searching code.
    Always explain your reasoning before making changes. Be concise and precise.
    """
  end
end
