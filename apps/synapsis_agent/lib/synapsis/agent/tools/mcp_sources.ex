defmodule Synapsis.Agent.Tools.MCPSources do
  @moduledoc """
  Resolves saved MCP selections against source-owned native snapshots.

  Source UUIDs survive renames. Explicit selected tools and sources fail visibly
  when unavailable; a missing catalog never becomes an empty selection.
  Tool and resource selections are independent; omitted resource UUIDs select none.
  `capture/1` reads local discovery state into separate snapshot maps. `refresh/1`
  refreshes their distinct source union once, discovering tools only when advertised.
  Neither executes tools, lists or reads resources, nor edits saved config.
  """

  alias Backplane.AgentRuntime.Error
  alias Synapsis.{MCP, MCPConfigs}

  @doc "Refresh only selected sources from a supervised turn-preparation task."
  def refresh(%{tool_selection_error: {:toolsets_unavailable, ids}}),
    do: unavailable_toolsets(ids)

  def refresh(%{tool_selection_error: _}), do: invalid()

  def refresh(%{tools: names} = agent) when is_list(names) do
    with true <- Enum.all?(names, &name?/1) and Enum.uniq(names) == names,
         configs = MCPConfigs.list(),
         true <- length(configs) <= 128,
         {:ok, rules} <- rules(agent, configs),
         {:ok, resource_ids} <- resource_source_ids(agent),
         :ok <- refresh_sources(rules, resource_ids) do
      capture(agent)
    else
      false -> invalid()
      error -> error
    end
  end

  def refresh(_), do: invalid()

  defp refresh_sources(rules, resource_ids) do
    ids =
      rules
      |> Enum.reject(fn
        {_id, %{"mode" => "none"}} -> true
        {_id, %{"mode" => "selected", "tools" => []}} -> true
        _ -> false
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.concat(resource_ids)
      |> Enum.uniq()
      |> Enum.sort()

    if ids == [] do
      :ok
    else
      Task.Supervisor.async_stream_nolink(Synapsis.MCP.TaskSupervisor, ids, &MCP.refresh/1,
        max_concurrency: 128,
        ordered: true,
        timeout: 55_000,
        on_timeout: :kill_task
      )
      |> Stream.zip(ids)
      |> Enum.reduce_while(:ok, fn
        {{:ok, :ok}, _id}, :ok -> {:cont, :ok}
        {_, id}, :ok -> {:halt, unavailable(id, "Selected MCP source refresh failed")}
      end)
    end
  catch
    :exit, _ -> {:error, Error.new(:unsupported_capability, "MCP discovery is unavailable")}
  end

  def capture(%{tool_selection_error: {:toolsets_unavailable, ids}}),
    do: unavailable_toolsets(ids)

  def capture(%{tool_selection_error: _}), do: invalid()

  def capture(%{tools: names} = agent) when is_list(names) do
    with true <- Enum.all?(names, &name?/1) and Enum.uniq(names) == names,
         configs = MCPConfigs.list(),
         true <- length(configs) <= 128,
         {:ok, rules} <- rules(agent, configs),
         {:ok, selected, snapshots} <- collect(rules),
         {:ok, resource_ids} <- resource_source_ids(agent),
         {:ok, resource_snapshots} <- collect_resource_sources(resource_ids) do
      builtins = Enum.reject(names, &mcp_name?/1)

      {:ok,
       agent
       |> Map.put(:tools, Enum.sort(Enum.uniq(builtins ++ selected)))
       |> Map.put(:mcp_sources, snapshots)
       |> Map.put(:mcp_resource_source_ids, resource_ids)
       |> Map.put(:mcp_resource_sources, resource_snapshots)}
    else
      false -> invalid()
      error -> error
    end
  end

  def capture(_), do: invalid()

  @doc "Read only the independent explicit resource UUID selection; omission selects none."
  def resource_source_ids(agent) when is_map(agent) do
    ids = Map.get(agent, :mcp_resource_source_ids, [])

    if is_list(ids) and length(ids) <= 128 and Enum.all?(ids, &uuid?/1) and
         Enum.uniq(ids) == ids do
      {:ok, ids}
    else
      invalid_resource_sources()
    end
  end

  def resource_source_ids(_), do: invalid_resource_sources()

  defp invalid_resource_sources,
    do: {:error, Error.new(:validation, "Invalid MCP resource source selection")}

  defp collect_resource_sources(ids) do
    Enum.reduce_while(ids, {:ok, %{}}, fn id, {:ok, snapshots} ->
      case MCP.runtime_snapshot(id) do
        {:ok, %{source_id: ^id} = snapshot} ->
          {:cont, {:ok, Map.put(snapshots, id, snapshot)}}

        _ ->
          {:halt, unavailable(id, "Selected MCP resource source is unavailable")}
      end
    end)
  end

  def revisions(agent, names) when is_map(agent) and is_list(names) do
    Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, revisions} ->
      case revision(agent[:mcp_sources] || %{}, name) do
        {:ok, revision} -> {:cont, {:ok, Map.put(revisions, name, revision)}}
        error -> {:halt, error}
      end
    end)
  end

  def revisions(_, _), do: invalid()

  def mcp_name?("mcp:" <> _), do: true
  def mcp_name?(_), do: false

  defp rules(%{mcp_selection: policy}, configs) do
    with :ok <- policy_valid(policy) do
      defaults =
        Map.new(
          Enum.filter(configs, & &1.enabled),
          &{&1.id, %{"mode" => policy["default"], "tools" => []}}
        )

      {:ok, Map.merge(defaults, policy["sources"])}
    end
  end

  defp rules(%{tools: names}, configs) do
    names
    |> Enum.filter(&mcp_name?/1)
    |> Enum.reduce_while({:ok, %{}}, fn name, {:ok, rules} ->
      case source_tool(name, configs) do
        {:ok, id, raw} ->
          rule = Map.get(rules, id, %{"mode" => "selected", "tools" => []})
          {:cont, {:ok, Map.put(rules, id, Map.update!(rule, "tools", &Enum.uniq(&1 ++ [raw])))}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp policy_valid(%{"default" => default, "sources" => sources} = policy)
       when default in ["all", "selected", "none"] and is_map(sources) do
    if Enum.sort(Map.keys(policy)) == ["default", "sources"] and map_size(sources) <= 128 and
         Enum.all?(sources, fn {id, rule} -> uuid?(id) and rule_valid?(rule) end),
       do: :ok,
       else: invalid()
  end

  defp policy_valid(_), do: invalid()

  defp rule_valid?(%{"mode" => mode} = rule) when mode in ["all", "none"],
    do: Map.keys(rule) == ["mode"]

  defp rule_valid?(%{"mode" => "selected", "tools" => tools} = rule) when is_list(tools),
    do:
      Enum.sort(Map.keys(rule)) == ["mode", "tools"] and length(tools) <= 1024 and
        Enum.all?(tools, &name?/1) and Enum.uniq(tools) == tools

  defp rule_valid?(_), do: false

  defp source_tool("mcp::" <> qualified, _configs) do
    case String.split(qualified, "::", parts: 2) do
      [id, raw] -> if uuid?(id) and name?(raw), do: {:ok, id, raw}, else: invalid()
      _ -> invalid()
    end
  end

  defp source_tool("mcp:" <> qualified, configs) do
    matches = Enum.filter(configs, &String.starts_with?(qualified, &1.name <> ":"))

    case matches do
      [config] ->
        raw = String.replace_prefix(qualified, config.name <> ":", "")
        if name?(raw), do: {:ok, config.id, raw}, else: invalid()

      [] ->
        unavailable(nil, "Selected MCP source no longer exists")

      _ ->
        invalid()
    end
  end

  defp collect(rules) do
    rules
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, [], %{}}, fn {id, rule}, {:ok, names, snapshots} ->
      case source_names(id, rule) do
        {:ok, [], nil} ->
          {:cont, {:ok, names, snapshots}}

        {:ok, selected, snapshot} ->
          {:cont, {:ok, names ++ selected, Map.put(snapshots, id, snapshot)}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp source_names(_id, %{"mode" => "none"}), do: {:ok, [], nil}
  defp source_names(_id, %{"mode" => "selected", "tools" => []}), do: {:ok, [], nil}

  defp source_names(id, rule) do
    with {:ok, snapshot} <- MCP.runtime_snapshot(id),
         raw_names = Enum.map(snapshot.tools, & &1.raw_name),
         selected = if(rule["mode"] == "all", do: raw_names, else: rule["tools"]),
         [] <- selected -- raw_names do
      {:ok, Enum.map(selected, &"mcp::#{id}::#{&1}"), snapshot}
    else
      missing when is_list(missing) ->
        unavailable(id, "Selected MCP tools are unavailable", missing)

      _ ->
        unavailable(id, "Selected MCP source is unavailable")
    end
  end

  defp revision(sources, "mcp::" <> qualified) do
    with [id, raw] <- String.split(qualified, "::", parts: 2),
         %{source_id: ^id, generation: generation, tools: tools} <- sources[id],
         true <- is_integer(generation) and generation > 0,
         true <- Enum.any?(tools, &(&1.raw_name === raw)) do
      {:ok, generation}
    else
      _ -> invalid()
    end
  end

  defp revision(_sources, "synapsis::automations"),
    do: {:ok, Synapsis.Agent.Tools.Automations.revision()}

  defp revision(_sources, "synapsis::automations_create"),
    do: {:ok, Synapsis.Agent.Tools.AutomationConfiguration.revision()}

  defp revision(_sources, name)
       when name in ["synapsis::automations_update", "synapsis::automations_remove"],
       do: {:ok, Synapsis.Agent.Tools.AutomationMutation.revision(name)}

  defp revision(_sources, "synapsis::sessions_list"),
    do: {:ok, Synapsis.Agent.Tools.SessionDirectory.revision()}

  defp revision(_sources, "synapsis::sessions_history"),
    do: {:ok, Synapsis.Agent.Tools.SessionHistory.revision()}

  defp revision(_sources, name)
       when name in ["synapsis::skills_search", "synapsis::skills_read", "synapsis::skill"],
       do: {:ok, 2}

  defp revision(_sources, "web::fetch"), do: {:ok, Synapsis.Agent.Tools.Web.Fetch.revision()}

  defp revision(_sources, "mcp:" <> _), do: invalid()
  defp revision(_sources, name), do: if(name?(name), do: {:ok, 1}, else: invalid())

  defp uuid?(id), do: is_binary(id) and Ecto.UUID.cast(id) == {:ok, id}

  defp name?(name),
    do:
      is_binary(name) and byte_size(name) in 1..4096 and
        String.valid?(name) and String.trim(name) != "" and not String.contains?(name, "\0")

  defp unavailable_toolsets(ids) when is_list(ids) do
    if ids != [] and Enum.all?(ids, &uuid?/1) do
      {:error,
       Error.new(:unsupported_capability, "Selected toolsets are unavailable",
         details: %{toolset_ids: ids}
       )}
    else
      invalid()
    end
  end

  defp unavailable_toolsets(_), do: invalid()

  defp invalid, do: {:error, Error.new(:validation, "Invalid MCP tool selection")}

  defp unavailable(id, message, tools \\ []),
    do:
      {:error,
       Error.new(:unsupported_capability, message, details: %{source_id: id, tools: tools})}
end
