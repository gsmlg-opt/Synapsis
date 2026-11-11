defmodule Synapsis.AgentConfigs do
  @moduledoc """
  Context for managing persisted agent configurations.

  ADR-006 C4: agent configs persist in the file-backed `Config.Store`
  (`agents.toml`) instead of Postgres. Records round-trip as `%AgentConfig{}`
  structs; the `config` map is JSON-encoded for flat TOML storage.
  """
  alias Synapsis.{AgentConfig, Config.Store}

  @store_type :agent

  # MVP defaults (docs/design.md §3). web::fetch and synapsis::web_search are
  # omitted because they require per-agent host/provider configuration.
  @build_tools ~w(
    synapsis::read synapsis::write synapsis::edit synapsis::ls
    apply_patch exec_command write_stdin view_image synapsis::process
    synapsis::todo_read synapsis::todo_write
    spawn_agent send_message followup_task interrupt_agent list_agents wait_agent
    synapsis::skill synapsis::skills_search synapsis::skills_read
    synapsis::ask_user clock::sleep
    synapsis::memory_save synapsis::memory_source_search synapsis::memory_update
    synapsis::workspace_memory_search synapsis::workspace_memory_get
    synapsis::session_summarize
    synapsis::automations synapsis::automations_create synapsis::automations_update
    synapsis::automations_remove synapsis::automations_manage synapsis::automations_wake
  )

  @doc "List all agent configs, ordered by name."
  def list do
    @store_type |> Store.list() |> Enum.map(&to_struct/1) |> Enum.sort_by(& &1.name)
  end

  @doc "List only enabled agent configs."
  def list_enabled, do: Enum.filter(list(), & &1.enabled)

  @doc """
  Read a bounded directory of enabled configured Agents, independently of sessions
  or native child-agent spawning permissions. IDs are persisted config UUIDs;
  names are configured Agent names. Only optional display labels are included.

  Options are `:limit` (1..100), an opaque `:cursor`, and an absolute monotonic
  millisecond `:deadline` capped at five seconds. Pages observe current config;
  removing or disabling the cursor anchor makes that cursor stale. Store errors
  never fall back to defaults or an empty directory.
  """
  def directory(requester, opts \\ []) do
    with true <- directory_name?(requester),
         {:ok, options} <- directory_options(opts),
         {:ok, cursor} <- directory_cursor(options.cursor, requester),
         :ok <- directory_remaining(options.deadline),
         {:ok, snapshot} <- Store.agent_directory_snapshot(requester, options.deadline),
         :ok <- directory_remaining(options.deadline),
         agents = Enum.sort_by(snapshot.agents, &{&1.name, &1.id}),
         {:ok, remaining} <- directory_after_cursor(agents, cursor),
         {page, rest} = Enum.split(remaining, options.limit),
         result = %{
           requester: snapshot.requester,
           agents: page,
           count: length(page),
           has_more: rest != [],
           next_cursor: directory_next_cursor(page, rest, requester)
         },
         :ok <- directory_remaining(options.deadline),
         {:ok, encoded} <- Jason.encode(result),
         :ok <- directory_remaining(options.deadline) do
      if byte_size(encoded) <= 65_536,
        do: {:ok, result},
        else: {:error, :output_too_large}
    else
      false -> {:error, :invalid_input}
      {:error, %Jason.EncodeError{}} -> {:error, :invalid_config}
      {:error, _} = error -> error
    end
  end

  defp directory_options(opts) do
    valid =
      is_list(opts) and Keyword.keyword?(opts) and
        Keyword.keys(opts) -- [:limit, :cursor, :deadline] == [] and
        length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
        is_integer(Keyword.get(opts, :limit, 100)) and
        Keyword.get(opts, :limit, 100) in 1..100 and
        is_integer(Keyword.get(opts, :deadline, System.monotonic_time(:millisecond)))

    if valid do
      ceiling = System.monotonic_time(:millisecond) + 5_000

      {:ok,
       %{
         limit: Keyword.get(opts, :limit, 100),
         cursor: Keyword.get(opts, :cursor),
         deadline: min(Keyword.get(opts, :deadline, ceiling), ceiling)
       }}
    else
      {:error, :invalid_input}
    end
  end

  defp directory_cursor(nil, _requester), do: {:ok, nil}

  defp directory_cursor(cursor, requester)
       when is_binary(cursor) and byte_size(cursor) in 1..4_096 do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, [1, ^requester, name, id]} <- Jason.decode(json),
         true <- directory_name?(name),
         {:ok, ^id} <- Ecto.UUID.cast(id),
         true <- directory_encode_cursor(requester, name, id) == cursor do
      {:ok, {name, id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp directory_cursor(_, _), do: {:error, :invalid_cursor}

  defp directory_after_cursor(agents, nil), do: {:ok, agents}

  defp directory_after_cursor(agents, {name, id}) do
    case Enum.drop_while(agents, &(&1.name != name or &1.id != id)) do
      [_anchor | remaining] -> {:ok, remaining}
      [] -> {:error, :stale_cursor}
    end
  end

  defp directory_next_cursor(_page, [], _requester), do: nil

  defp directory_next_cursor(page, _rest, requester) do
    last = List.last(page)
    directory_encode_cursor(requester, last.name, last.id)
  end

  defp directory_encode_cursor(requester, name, id),
    do: [1, requester, name, id] |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp directory_name?(name),
    do:
      is_binary(name) and byte_size(name) in 1..256 and
        String.valid?(name) and Regex.match?(~r/\A[a-z0-9][a-z0-9_-]*\z/, name)

  defp directory_remaining(deadline),
    do:
      if(System.monotonic_time(:millisecond) < deadline,
        do: :ok,
        else: {:error, :timeout}
      )

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
    Store.with_write_lock(fn ->
      with {:ok, current} <- Store.get(@store_type, agent_config.id) do
        current
        |> to_struct()
        |> AgentConfig.update_changeset(Map.drop(attrs, [:id, "id"]))
        |> persist_update(agent_config.id)
      end
    end)
  end

  @doc "Delete an agent config."
  def delete(%AgentConfig{} = agent_config) do
    if protected?(agent_config) do
      {:error, :protected}
    else
      with :ok <- Store.delete(@store_type, agent_config.id) do
        {:ok, agent_config}
      end
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
        tool_contract_version: 1,
        reasoning_effort: "medium",
        read_only: false,
        max_tokens: 8192,
        model_tier: "default",
        permission_mode: "yolo",
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

  @doc "Seed missing defaults and preserve saved agents. Called on application startup."
  def seed_defaults do
    for attrs <- default_attrs() do
      case get_by_name(attrs.name) do
        nil -> create(attrs)
        existing -> ensure_default(existing)
      end
    end

    :ok
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

  defp persist_update(%Ecto.Changeset{valid?: true} = changeset, id) do
    changes =
      changeset.changes
      |> Map.delete(:id)
      |> Map.new(fn
        {:config, config} -> {"config", Jason.encode!(config || %{})}
        {key, value} when key in [:tools, :toolset_ids] -> {Atom.to_string(key), value || []}
        {key, value} -> {Atom.to_string(key), value}
      end)

    with {:ok, merged} <- Store.merge_existing(@store_type, id, changes) do
      {:ok, to_struct(merged)}
    end
  end

  defp persist_update(%Ecto.Changeset{} = changeset, _id), do: {:error, changeset}

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
      "tool_contract_version" => r.tool_contract_version,
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
