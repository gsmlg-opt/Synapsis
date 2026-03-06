defmodule Synapsis.Agent.Runtime.CheckpointStore do
  @moduledoc """
  DB-backed checkpoint storage for runtime runs.
  Delegates to `Synapsis.AgentCheckpoints` for persistence.
  Handles Graph serialization/deserialization for JSONB storage.
  """

  alias Synapsis.Agent.Runtime.{Checkpoint, Graph}

  @spec put(map() | Checkpoint.t()) :: :ok | {:error, term()}
  def put(%Checkpoint{} = checkpoint) do
    put(Map.from_struct(checkpoint))
  end

  def put(attrs) when is_map(attrs) do
    attrs
    |> serialize_for_db()
    |> Synapsis.AgentCheckpoints.put()
  end

  @spec get(String.t()) :: {:ok, Checkpoint.t()} | {:error, :not_found}
  def get(run_id) when is_binary(run_id) do
    case Synapsis.AgentCheckpoints.get(run_id) do
      {:ok, row} -> {:ok, to_checkpoint(row)}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @spec delete(String.t()) :: :ok
  def delete(run_id) when is_binary(run_id) do
    Synapsis.AgentCheckpoints.delete(run_id)
  end

  @spec list(keyword()) :: [Checkpoint.t()]
  def list(filters \\ []) do
    filters
    |> Synapsis.AgentCheckpoints.list()
    |> Enum.map(&to_checkpoint/1)
  end

  @spec clear() :: :ok
  def clear do
    Synapsis.AgentCheckpoints.clear()
  end

  # --- Serialization ---

  defp serialize_for_db(attrs) do
    attrs
    |> Map.new(fn
      {:graph, %Graph{} = g} -> {:graph, serialize_graph(g)}
      {:graph, g} when is_map(g) -> {:graph, g}
      {k, v} -> {k, v}
    end)
  end

  defp serialize_graph(%Graph{} = graph) do
    %{
      "nodes" => serialize_nodes(graph.nodes),
      "edges" => serialize_edges(graph.edges),
      "start" => Atom.to_string(graph.start)
    }
  end

  defp serialize_nodes(nodes) when is_map(nodes) do
    Map.new(nodes, fn {name, module} ->
      {Atom.to_string(name), Atom.to_string(module)}
    end)
  end

  defp serialize_edges(edges) when is_map(edges) do
    Map.new(edges, fn
      {from, :end} ->
        {Atom.to_string(from), "end"}

      {from, dest} when is_atom(dest) ->
        {Atom.to_string(from), Atom.to_string(dest)}

      {from, branches} when is_map(branches) ->
        serialized =
          Map.new(branches, fn {sel, dest} ->
            {Atom.to_string(sel), Atom.to_string(dest)}
          end)

        {Atom.to_string(from), serialized}
    end)
  end

  # --- Deserialization ---

  defp to_checkpoint(%Synapsis.AgentCheckpoint{} = row) do
    %Checkpoint{
      run_id: row.run_id,
      graph: deserialize_graph(row.graph),
      node: safe_to_existing_atom(row.node),
      status: String.to_existing_atom(row.status),
      state: deserialize_map_keys(row.state || %{}),
      ctx: deserialize_map_keys(row.ctx || %{}),
      error: deserialize_error(row.error),
      updated_at: row.updated_at
    }
  end

  defp deserialize_graph(data) when is_map(data) do
    %Graph{
      nodes: deserialize_nodes(data["nodes"] || %{}),
      edges: deserialize_edges(data["edges"] || %{}),
      start: safe_to_existing_atom(data["start"])
    }
  end

  defp deserialize_nodes(nodes) when is_map(nodes) do
    Map.new(nodes, fn {name, module} ->
      {String.to_existing_atom(name), String.to_existing_atom(module)}
    end)
  end

  defp deserialize_edges(edges) when is_map(edges) do
    Map.new(edges, fn
      {from, dest} when is_binary(dest) ->
        {String.to_existing_atom(from), safe_to_existing_atom(dest)}

      {from, branches} when is_map(branches) ->
        deserialized =
          Map.new(branches, fn {sel, dest} ->
            {String.to_existing_atom(sel), safe_to_existing_atom(dest)}
          end)

        {String.to_existing_atom(from), deserialized}
    end)
  end

  defp deserialize_map_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) ->
        atom_key = try_to_existing_atom(k)
        {atom_key, v}

      {k, v} ->
        {k, v}
    end)
  end

  defp deserialize_error(nil), do: nil
  defp deserialize_error(%{"type" => "term", "value" => value}), do: value
  defp deserialize_error(error) when is_map(error), do: error

  defp safe_to_existing_atom(nil), do: nil
  defp safe_to_existing_atom("end"), do: :end
  defp safe_to_existing_atom(str) when is_binary(str), do: String.to_existing_atom(str)
  defp safe_to_existing_atom(atom) when is_atom(atom), do: atom

  defp try_to_existing_atom(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> str
  end
end
