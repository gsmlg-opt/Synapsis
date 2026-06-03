defmodule Synapsis.AgentConfigs do
  @moduledoc """
  Context for managing persisted agent configurations.

  ADR-006 C4: agent configs persist in the file-backed `Config.Store`
  (`agents.toml`) instead of Postgres. Records round-trip as `%AgentConfig{}`
  structs; the `config` map is JSON-encoded for flat TOML storage.
  """
  alias Synapsis.{AgentConfig, Config.Store}

  @store_type :agent

  @build_tools ~w(
    file_read file_edit file_write multi_edit file_delete file_move list_dir
    grep glob bash
    todo_read todo_write enter_plan_mode exit_plan_mode
    task skill tool_search ask_user sleep
    memory_save memory_search memory_update session_summarize
    diagnostics
  )

  @doc "List all agent configs, ordered by name."
  def list do
    @store_type |> Store.list() |> Enum.map(&to_struct/1) |> Enum.sort_by(& &1.name)
  end

  @doc "List only enabled agent configs."
  def list_enabled, do: Enum.filter(list(), & &1.enabled)

  @doc "Get an agent config by name."
  def get_by_name(name) when is_binary(name), do: Enum.find(list(), &(&1.name == name))

  @doc "Get an agent config by id."
  def get(id) do
    case Store.get(@store_type, id) do
      {:ok, map} -> to_struct(map)
      _ -> nil
    end
  end

  @doc "Create a new agent config."
  def create(attrs) when is_map(attrs) do
    %AgentConfig{}
    |> AgentConfig.changeset(attrs)
    |> persist()
  end

  @doc "Update an existing agent config."
  def update(%AgentConfig{} = agent_config, attrs) when is_map(attrs) do
    agent_config
    |> AgentConfig.update_changeset(attrs)
    |> persist()
  end

  @doc "Delete an agent config."
  def delete(%AgentConfig{} = agent_config) do
    if protected?(agent_config) do
      {:error, :protected}
    else
      Store.delete(@store_type, agent_config.id)
      {:ok, agent_config}
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
        permission_mode: "ask",
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
      nil -> create(Map.put(attrs, :name, name))
      existing -> update(existing, attrs)
    end
  end

  # ADR-006 C4: built-in agents formerly shipped as separate "assistant"/"build"/
  # "plan" defaults; they are consolidated into "main" and pruned on seed.
  @retired_builtins ~w(assistant build plan)

  @doc "Seed default agents if they don't exist. Called on application startup."
  def seed_defaults do
    Enum.each(@retired_builtins, &prune_retired/1)

    for attrs <- default_attrs() do
      case get_by_name(attrs.name) do
        nil -> create(attrs)
        existing -> ensure_default(existing)
      end
    end

    :ok
  end

  # Force-remove a retired built-in (bypasses delete/1's protection guard).
  defp prune_retired(name) do
    case get_by_name(name) do
      %AgentConfig{id: id} -> Store.delete(@store_type, id)
      _ -> :ok
    end
  end

  defp ensure_default(%AgentConfig{is_default: true}), do: :ok
  defp ensure_default(%AgentConfig{} = agent), do: update(agent, %{is_default: true})

  # ── internals ──────────────────────────────────────────────────────────────

  defp persist(%Ecto.Changeset{valid?: true} = changeset) do
    record = changeset |> Ecto.Changeset.apply_changes() |> ensure_id()

    case Store.put(@store_type, to_store_map(record)) do
      :ok -> {:ok, record}
      {:ok, _} -> {:ok, record}
      error -> error
    end
  end

  defp persist(%Ecto.Changeset{} = changeset), do: {:error, changeset}

  defp ensure_id(%AgentConfig{id: nil} = record), do: %{record | id: Ecto.UUID.generate()}
  defp ensure_id(record), do: record

  defp to_struct(map) do
    map = decode_config(map)
    %AgentConfig{} |> AgentConfig.changeset(map) |> Ecto.Changeset.apply_changes() |> set_id(map)
  end

  defp set_id(record, map), do: %{record | id: map["id"] || record.id}

  defp decode_config(%{"config" => json} = map) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> Map.put(map, "config", decoded)
      _ -> map
    end
  end

  defp decode_config(map), do: map

  defp to_store_map(%AgentConfig{} = r) do
    %{
      "id" => r.id,
      "name" => r.name,
      "label" => r.label,
      "icon" => r.icon,
      "description" => r.description,
      "provider" => r.provider,
      "model" => r.model,
      "system_prompt" => r.system_prompt,
      "tools" => r.tools || [],
      "reasoning_effort" => r.reasoning_effort,
      "read_only" => r.read_only,
      "max_tokens" => r.max_tokens,
      "model_tier" => r.model_tier,
      "permission_mode" => r.permission_mode,
      "fallback_models" => r.fallback_models,
      "is_default" => r.is_default,
      "enabled" => r.enabled,
      "config" => Jason.encode!(r.config || %{}),
      "toolset_id" => r.toolset_id,
      "toolset_ids" => r.toolset_ids || []
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp default_system_prompt do
    """
    You are Synapsis, an AI coding assistant. You help developers write, edit, and understand code.
    You have access to tools for reading files, editing files, running shell commands, and searching code.
    Always explain your reasoning before making changes. Be concise and precise.
    """
  end
end
