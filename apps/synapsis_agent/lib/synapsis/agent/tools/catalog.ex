defmodule Synapsis.Agent.Tools.Catalog do
  @moduledoc """
  Composes admitted native bundles and trusted host descriptors under an explicit
  target authority ceiling. Selection is a list of exact names or `:none`.

  Descriptors retain their native bindings and schemas. Provider definitions and
  the final admission bundle are produced exclusively by Backplane's strict
  catalog admission; this module never executes a backend.
  """

  alias Backplane.AgentRuntime.{Error, ToolCatalog, ToolRegistry}

  @spec compose([map()], [map()], map(), :none | [String.t()]) ::
          {:ok, map()} | {:error, Error.t()}
  def compose(native_bundles, host_descriptors, ceiling, selection)
      when is_list(native_bundles) and is_list(host_descriptors) and is_map(ceiling) do
    with :ok <- validate_ceiling(ceiling),
         {:ok, native} <- native_descriptors(native_bundles, ceiling),
         {:ok, candidates} <- index_candidates(native ++ host_descriptors),
         {:ok, names} <- selected_names(selection),
         :ok <- available_selection(names, candidates),
         {:ok, authority} <- selected_authority(names, ceiling) do
      ToolCatalog.admit_batch(Enum.map(names, &Map.fetch!(candidates, &1)),
        mode: :strict,
        authority: authority,
        run_id: ceiling.run_id
      )
    end
  end

  def compose(_, _, _, _), do: validation("catalog requires bundles, descriptors and authority")

  defp validate_ceiling(ceiling) do
    grants = Map.get(ceiling, :grants)

    if valid_name?(ceiling[:caller]) and valid_name?(ceiling[:run_id]) and is_list(grants) and
         Enum.all?(grants, &valid_name?/1) and length(grants) == length(Enum.uniq(grants)) and
         is_map(Map.get(ceiling, :tool_revisions, %{})) do
      :ok
    else
      validation("catalog authority requires caller, run id, exact grants and valid revisions")
    end
  end

  defp native_descriptors(bundles, ceiling) do
    Enum.reduce_while(bundles, {:ok, []}, fn
      %{registry: %ToolRegistry{tools: tools}, authority: authority}, {:ok, descriptors}
      when is_map(tools) and is_map(authority) ->
        if authority[:caller] == ceiling.caller and authority[:run_id] == ceiling.run_id do
          native = tools |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
          {:cont, {:ok, descriptors ++ native}}
        else
          {:halt,
           {:error, Error.new(:forbidden, "native bundle belongs to another caller or run")}}
        end

      _, _ ->
        {:halt, validation("native bundles require an admitted registry and authority")}
    end)
  end

  defp index_candidates(descriptors) do
    Enum.reduce_while(descriptors, {:ok, %{}}, fn
      %{tool_name: name} = descriptor, {:ok, candidates} when is_binary(name) and name != "" ->
        if Map.has_key?(candidates, name) do
          {:halt, validation("catalog contains duplicate tool names")}
        else
          {:cont, {:ok, Map.put(candidates, name, descriptor)}}
        end

      _, _ ->
        {:halt, validation("catalog descriptors require an exact tool name")}
    end)
  end

  defp selected_names(:none), do: {:ok, []}

  defp selected_names(names) when is_list(names) do
    if Enum.all?(names, &valid_name?/1) and length(names) == length(Enum.uniq(names)),
      do: {:ok, names},
      else: validation("catalog selection must contain unique exact tool names")
  end

  defp selected_names(_), do: validation("catalog selection must be an explicit list or :none")

  defp available_selection(names, candidates) do
    case Enum.reject(names, &Map.has_key?(candidates, &1)) do
      [] ->
        :ok

      missing ->
        {:error,
         Error.new(:unsupported_capability, "selected tools are unavailable",
           details: %{tools: missing}
         )}
    end
  end

  defp selected_authority(names, ceiling) do
    revisions = Map.get(ceiling, :tool_revisions, %{})

    selected_revisions =
      Map.new(names, &{&1, Map.get(revisions, &1, Map.get(ceiling, :tool_revision))})

    if Enum.all?(names, &(&1 in ceiling.grants)) and
         Enum.all?(selected_revisions, fn {_, revision} ->
           is_integer(revision) and revision > 0
         end) do
      {:ok, ceiling |> Map.put(:grants, names) |> Map.put(:tool_revisions, selected_revisions)}
    else
      {:error, Error.new(:forbidden, "selected tools exceed the target authority ceiling")}
    end
  end

  defp valid_name?(value), do: is_binary(value) and value != ""
  defp validation(message), do: {:error, Error.new(:validation, message)}
end
