defmodule Synapsis.MCPSelection do
  @moduledoc "Persistent MCP selection resolved against the current runtime catalog."

  import Kernel, except: [apply: 2]
  alias Synapsis.Tool.Registry

  def names(%{"default" => default, "sources" => sources}, catalog)
      when default in ["all", "selected"] and is_map(sources) do
    catalog
    |> Enum.filter(fn tool ->
      case Map.get(sources, tool.mcp_config_id, %{"mode" => default}) do
        %{"mode" => "all"} ->
          true

        %{"mode" => "selected", "tools" => tools} when is_list(tools) ->
          tool.mcp_tool_name in tools

        _rule ->
          false
      end
    end)
    |> Enum.map(& &1.name)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def names(_invalid_policy, _catalog), do: []

  def apply(agent, catalog \\ catalog()) do
    case Map.fetch(agent, :mcp_selection) do
      {:ok, policy} ->
        builtins = Enum.reject(agent[:tools] || [], &mcp_name?/1)
        Map.put(agent, :tools, Enum.uniq(builtins ++ names(policy, catalog)))

      :error ->
        agent
    end
  end

  def catalog do
    Registry.list_for_query_loop()
    |> Enum.flat_map(fn
      %{registration: {:process, _pid, opts}} = tool ->
        case {opts[:mcp_config_id], opts[:mcp_tool_name]} do
          {id, raw} when is_binary(id) and is_binary(raw) ->
            [Map.merge(tool, %{mcp_config_id: id, mcp_tool_name: raw})]

          _unidentified ->
            []
        end

      _builtin ->
        []
    end)
  rescue
    ArgumentError -> []
  end

  def from_legacy(tool_names, sources) do
    selections =
      Map.new(sources, fn source ->
        prefix = "mcp:" <> source.name <> ":"

        tools =
          tool_names
          |> Enum.filter(&String.starts_with?(&1, prefix))
          |> Enum.map(&String.replace_prefix(&1, prefix, ""))
          |> Enum.uniq()
          |> Enum.sort()

        {source.id, %{"mode" => "selected", "tools" => tools}}
      end)
      |> Map.reject(fn {_id, rule} -> rule["tools"] == [] end)

    %{"default" => "selected", "sources" => selections}
  end

  @doc "Run only from supervised turn preparation or an asynchronous UI action."
  def refresh do
    case Application.get_env(:synapsis_core, :mcp_refresh) do
      {module, function, args} -> Kernel.apply(module, function, args)
      nil -> %{}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  def refresh_agent(agent) do
    result = refresh()
    catalog = if match?({:error, _}, result), do: [], else: catalog()

    catalog =
      Enum.reject(catalog, fn tool ->
        is_map(result) and match?({:error, _}, Map.get(result, tool.mcp_config_id))
      end)

    resolve_agent(agent, catalog)
  end

  def refresh_required?(agent) do
    Map.has_key?(agent, :mcp_selection) or
      (is_list(agent[:tools]) and Enum.any?(agent.tools, &mcp_name?/1))
  end

  def resolve_agent(agent, catalog) do
    available_names = MapSet.new(Enum.map(catalog, & &1.name))

    agent =
      agent
      |> apply(catalog)
      |> Map.update(:tools, [], fn tools ->
        Enum.reject(tools, &(mcp_name?(&1) and not MapSet.member?(available_names, &1)))
      end)

    tools = Registry.list_for_query_loop(names: agent.tools)

    agent
    |> Map.put(:resolved_tools, tools)
    |> Map.put(:tool_modules, Map.new(tools, &{&1.name, &1.registration}))
  end

  def mcp_name?("mcp:" <> _name), do: true
  def mcp_name?(_name), do: false
end
