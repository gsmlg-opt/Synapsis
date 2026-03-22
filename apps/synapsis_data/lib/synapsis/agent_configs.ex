defmodule Synapsis.AgentConfigs do
  @moduledoc "Context for managing persisted agent configurations."

  import Ecto.Query, except: [update: 2]
  alias Synapsis.{AgentConfig, Repo}

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
  end

  @doc "Update an existing agent config."
  def update(%AgentConfig{} = agent_config, attrs) when is_map(attrs) do
    agent_config
    |> AgentConfig.update_changeset(attrs)
    |> Repo.update()
  end

  @doc "Delete an agent config."
  def delete(%AgentConfig{} = agent_config) do
    Repo.delete(agent_config)
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
    defaults = [
      %{
        name: "build",
        label: "Build",
        icon: "hammer-wrench",
        description: "Workspace-driven coding assistant with identity, tools, and memory.",
        system_prompt: """
        You are Synapsis, an AI coding assistant. You help developers write, edit, and understand code.
        You have access to tools for reading files, editing files, running shell commands, and searching code.
        Always explain your reasoning before making changes. Be concise and precise.
        """,
        tools: [
          "file_read",
          "file_edit",
          "file_write",
          "bash",
          "grep",
          "glob",
          "diagnostics",
          "fetch"
        ],
        reasoning_effort: "medium",
        read_only: false,
        max_tokens: 8192,
        model_tier: "default",
        is_default: true,
        enabled: true
      },
      %{
        name: "plan",
        label: "Plan",
        icon: "clipboard-text-outline",
        description: "Planning assistant that analyzes codebases and creates implementation plans.",
        system_prompt:
          "You are a planning assistant. Analyze the codebase and create implementation plans. Do NOT make changes.",
        tools: ["file_read", "grep", "glob", "diagnostics"],
        reasoning_effort: "high",
        read_only: true,
        max_tokens: 8192,
        model_tier: "expert",
        is_default: false,
        enabled: true
      }
    ]

    for attrs <- defaults do
      case get_by_name(attrs.name) do
        nil -> create(attrs)
        _existing -> :ok
      end
    end

    :ok
  end
end
