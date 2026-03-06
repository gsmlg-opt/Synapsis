defmodule Synapsis.Agent.Runtime.Graph do
  @moduledoc """
  Graph definition for the agent runtime.

  `nodes` maps node names to modules implementing `Synapsis.Agent.Runtime.Node`.

  `edges` supports:
  - static edge: `%{planner: :executor}`
  - conditional edge: `%{executor: %{success: :end, retry: :executor}}`

  `start` is the entry node.
  """

  @enforce_keys [:nodes, :start]
  defstruct nodes: %{}, edges: %{}, start: nil

  @type node_name :: atom()
  @type selector :: atom()
  @type edge_spec :: node_name() | %{optional(selector()) => node_name()}

  @type t :: %__MODULE__{
          nodes: %{required(node_name()) => module()},
          edges: %{optional(node_name()) => edge_spec()},
          start: node_name()
        }

  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = graph), do: validate(graph)

  def new(attrs) when is_list(attrs) do
    attrs
    |> Enum.into(%{})
    |> new()
  end

  def new(attrs) when is_map(attrs) do
    graph = %__MODULE__{
      nodes: Map.get(attrs, :nodes, %{}),
      edges: Map.get(attrs, :edges, %{}),
      start: Map.get(attrs, :start)
    }

    validate(graph)
  end

  def new(_), do: {:error, :invalid_graph}

  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{} = graph) do
    with :ok <- validate_nodes(graph.nodes),
         :ok <- validate_start(graph.start, graph.nodes),
         :ok <- validate_edges(graph.edges, graph.nodes) do
      {:ok, graph}
    end
  end

  @spec fetch_node(t(), node_name()) :: {:ok, module()} | {:error, term()}
  def fetch_node(%__MODULE__{nodes: nodes}, node) when is_atom(node) do
    case Map.fetch(nodes, node) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_node, node}}
    end
  end

  def fetch_node(_graph, node), do: {:error, {:invalid_node, node}}

  @spec resolve_next(t(), node_name(), selector()) ::
          {:ok, node_name() | :end} | {:error, term()}
  def resolve_next(%__MODULE__{} = graph, current_node, selector)
      when is_atom(current_node) and is_atom(selector) do
    case Map.get(graph.edges, current_node) do
      nil ->
        resolve_direct_destination(graph, current_node, selector)

      destination when is_atom(destination) ->
        ensure_destination(graph, current_node, destination)

      branches when is_map(branches) ->
        case Map.fetch(branches, selector) do
          {:ok, destination} -> ensure_destination(graph, current_node, destination)
          :error -> resolve_direct_destination(graph, current_node, selector)
        end

      invalid ->
        {:error, {:invalid_edge, current_node, invalid}}
    end
  end

  def resolve_next(_graph, current_node, selector) do
    {:error, {:invalid_selector, current_node, selector}}
  end

  defp validate_nodes(nodes) when is_map(nodes) and map_size(nodes) > 0 do
    Enum.reduce_while(nodes, :ok, fn
      {name, module}, :ok when is_atom(name) and is_atom(module) ->
        cond do
          not Code.ensure_loaded?(module) ->
            {:halt, {:error, {:node_module_not_loaded, name, module}}}

          not function_exported?(module, :run, 2) ->
            {:halt, {:error, {:invalid_node_module, name, module}}}

          true ->
            {:cont, :ok}
        end

      {name, module}, :ok ->
        {:halt, {:error, {:invalid_node, name, module}}}
    end)
  end

  defp validate_nodes(_), do: {:error, :invalid_nodes}

  defp validate_start(start, nodes) when is_atom(start) do
    if Map.has_key?(nodes, start) do
      :ok
    else
      {:error, {:unknown_start_node, start}}
    end
  end

  defp validate_start(start, _nodes), do: {:error, {:invalid_start_node, start}}

  defp validate_edges(edges, nodes) when is_map(edges) do
    Enum.reduce_while(edges, :ok, fn
      {from, spec}, :ok ->
        cond do
          not Map.has_key?(nodes, from) ->
            {:halt, {:error, {:unknown_edge_source, from}}}

          is_atom(spec) ->
            case validate_destination(spec, nodes) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          is_map(spec) ->
            case validate_conditional_edges(from, spec, nodes) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          true ->
            {:halt, {:error, {:invalid_edge, from, spec}}}
        end
    end)
  end

  defp validate_edges(_edges, _nodes), do: {:error, :invalid_edges}

  defp validate_conditional_edges(from, branches, nodes) when map_size(branches) > 0 do
    Enum.reduce_while(branches, :ok, fn
      {selector, destination}, :ok when is_atom(selector) and is_atom(destination) ->
        case validate_destination(destination, nodes) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {selector, destination}, :ok ->
        {:halt, {:error, {:invalid_conditional_edge, from, selector, destination}}}
    end)
  end

  defp validate_conditional_edges(from, _branches, _nodes),
    do: {:error, {:empty_conditional_edges, from}}

  defp validate_destination(:end, _nodes), do: :ok

  defp validate_destination(destination, nodes) when is_atom(destination) do
    if Map.has_key?(nodes, destination) do
      :ok
    else
      {:error, {:unknown_edge_destination, destination}}
    end
  end

  defp validate_destination(destination, _nodes),
    do: {:error, {:invalid_destination, destination}}

  defp resolve_direct_destination(graph, current_node, selector) do
    case ensure_destination(graph, current_node, selector) do
      {:ok, destination} ->
        {:ok, destination}

      {:error, _reason} ->
        {:error, {:unknown_edge_selector, current_node, selector}}
    end
  end

  defp ensure_destination(_graph, _current_node, :end), do: {:ok, :end}

  defp ensure_destination(%__MODULE__{nodes: nodes}, _current_node, destination)
       when is_atom(destination) do
    if Map.has_key?(nodes, destination) do
      {:ok, destination}
    else
      {:error, {:unknown_edge_destination, destination}}
    end
  end

  defp ensure_destination(_graph, current_node, destination) do
    {:error, {:invalid_destination, current_node, destination}}
  end
end
