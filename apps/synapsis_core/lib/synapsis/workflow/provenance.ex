defmodule Synapsis.Workflow.Provenance do
  @moduledoc """
  Pure private provenance over live public Value graphs.

  Graph and call identities belong only to the application-lifetime owner.
  Remembered roots retain current graph edges, not write-time copies of marks.
  These internal operations do not produce LLM results or billing evidence.
  """

  alias Synapsis.Workflow.Value

  @capacity 64

  @doc false
  def of(state, graph, root) do
    with %{"type" => "reference", "id" => id} <- root,
         %{marks: marks} <- state.graphs[graph],
         {:ok, call} <- Map.fetch(marks, id) do
      Map.fetch!(state.calls, call)
    else
      _ -> nil
    end
  end

  @doc false
  def apply_action(state, graph, {:mark_item, root, cache_key, replayed})
      when is_boolean(replayed) do
    if object_node(state, graph, root) do
      {state, call} = new_call(state, Value.key_string(cache_key), replayed)
      state = put_mark(state, graph, root, call)

      case object_node(state, graph, root) do
        %{"type" => "object"} ->
          usage = Value.object_get(root, "usage", heap(state, graph))

          if object_node(state, graph, usage),
            do: put_mark(state, graph, usage, call),
            else: state

        _ ->
          state
      end
    else
      state
    end
  end

  def apply_action(state, graph, {:copy_mark, source, target}) do
    with %{"type" => "reference", "id" => id} <- source,
         {:ok, call} <- Map.fetch(state.graphs[graph].marks, id),
         node when not is_nil(node) <- object_node(state, graph, target) do
      put_mark(state, graph, target, call)
    else
      _ -> state
    end
  end

  def apply_action(state, graph, {:mark_replayed, root}) do
    with %{"type" => "reference", "id" => id} <- root,
         {:ok, call} <- Map.fetch(state.graphs[graph].marks, id) do
      update_in(state, [:calls, call], &%{&1 | replayed: true})
    else
      _ -> state
    end
  end

  def apply_action(state, graph, {:remember, path, text, root})
      when is_binary(path) and is_binary(text) do
    order =
      if Map.has_key?(state.remembered, path),
        do: state.insertion_order,
        else: state.insertion_order ++ [path]

    remembered = Map.put(state.remembered, path, %{text: text, root: {graph, root}})

    {order, remembered} =
      if length(order) > @capacity do
        [oldest | rest] = order
        {rest, Map.delete(remembered, oldest)}
      else
        {order, remembered}
      end

    sweep(%{state | remembered: remembered, insertion_order: order})
  end

  def apply_action(state, graph, {:carry_remembered, path, text, target})
      when is_binary(path) and is_binary(text) do
    case state.remembered[path] do
      %{text: ^text, root: {source_graph, source}} ->
        carry(state, source_graph, source, graph, target)

      _ ->
        state
    end
  end

  # Each visited target receives a distinct new call, even when the corresponding
  # source nodes share a call. Target JSON imports are finite fresh trees.
  defp carry(state, source_graph, source, target_graph, target) do
    source_node = object_node(state, source_graph, source)
    target_node = object_node(state, target_graph, target)

    if source_node && target_node do
      state =
        case of(state, source_graph, source) do
          nil ->
            state

          %{cache_key: key} ->
            {state, call} = new_call(state, key, true)
            put_mark(state, target_graph, target, call)
        end

      case {source_node, target_node} do
        {%{"type" => "array", "items" => sources}, %{"type" => "array", "items" => targets}} ->
          Enum.zip(sources, targets)
          |> Enum.reduce(state, fn {source, target}, state ->
            carry(state, source_graph, source, target_graph, target)
          end)

        {%{"type" => "object"}, %{"type" => "object"}} ->
          source_heap = heap(state, source_graph)
          target_heap = heap(state, target_graph)

          source
          |> Value.object_keys(source_heap)
          |> Enum.reduce(state, fn key, state ->
            carry(
              state,
              source_graph,
              Value.object_get(source, key, source_heap),
              target_graph,
              Value.object_get(target, key, target_heap)
            )
          end)

        _ ->
          state
      end
    else
      state
    end
  end

  @doc false
  def sweep(state) do
    active =
      Enum.reduce(state.leases, %{}, fn {_lease, %{graph: graph}}, retained ->
        Map.put(retained, graph, MapSet.new(Map.keys(state.graphs[graph].nodes)))
      end)

    retained =
      Enum.reduce(state.remembered, active, fn {_path, %{root: {graph, root}}}, retained ->
        retained = Map.put_new(retained, graph, MapSet.new())
        retain(state.graphs, graph, [root], retained)
      end)

    graphs =
      Map.new(retained, fn {graph, ids} ->
        original = Map.fetch!(state.graphs, graph)
        keys = MapSet.to_list(ids)

        {graph,
         %{
           original
           | nodes: Map.take(original.nodes, keys),
             marks: Map.take(original.marks, keys)
         }}
      end)

    calls = graphs |> Map.values() |> Enum.flat_map(&Map.values(&1.marks)) |> Enum.uniq()
    %{state | graphs: graphs, calls: Map.take(state.calls, calls)}
  end

  defp retain(_graphs, _graph, [], retained), do: retained

  defp retain(graphs, graph, [%{"type" => "reference", "id" => id} | rest], retained) do
    if MapSet.member?(retained[graph], id) do
      retain(graphs, graph, rest, retained)
    else
      retained = Map.update!(retained, graph, &MapSet.put(&1, id))
      node = Map.fetch!(graphs[graph].nodes, id)

      children =
        case node do
          %{"type" => "array", "items" => items} ->
            items

          %{"type" => "object", "fields" => fields} ->
            Map.values(fields) ++ Map.values(Map.get(node, "fields_utf16le", %{}))
        end

      retain(graphs, graph, children ++ rest, retained)
    end
  end

  defp retain(graphs, graph, [_scalar | rest], retained),
    do: retain(graphs, graph, rest, retained)

  defp new_call(state, key, replayed) do
    call = {state.incarnation, state.next_call}
    calls = Map.put(state.calls, call, %{cache_key: key, replayed: replayed})
    {%{state | calls: calls, next_call: state.next_call + 1}, call}
  end

  defp put_mark(state, graph, %{"type" => "reference", "id" => id}, call),
    do: put_in(state, [:graphs, graph, :marks, id], call)

  defp object_node(state, graph, %{"type" => "reference", "id" => id}),
    do: state.graphs[graph].nodes[id]

  defp object_node(_state, _graph, _scalar), do: nil

  defp heap(state, graph) do
    %{nodes: nodes, next_id: next_id} = state.graphs[graph]
    %{"version" => 1, "nodes" => nodes, "next_id" => next_id}
  end
end
