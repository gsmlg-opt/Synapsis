defmodule Synapsis.Agent.Tools.CatalogBinding do
  @moduledoc """
  Checks original issued descriptors against Conversation's pinned catalog.

  Descriptor contexts retain their construction revision. Only a native pinned
  snapshot can bind that context to a later invocation revision. Without one,
  direct callers retain the strict construction scope and each adapter's own
  documented native metadata allowance.
  """

  def host(context, operation, backend, revision, native_keys),
    do: host(context, operation, backend, revision, native_keys, context)

  @doc "Keeps pinned operations intact and preserves legacy execute-only metadata stripping."
  def classification_operation(%{backend_context: enriched} = operation, context) do
    if Map.has_key?(enriched, :catalog_snapshot),
      do: operation,
      else: %{operation | backend_context: context}
  end

  def host(context, operation, backend, revision, native_keys, identity)
      when is_map(context) and is_map(operation) and is_map(identity) do
    enriched = operation[:backend_context]

    with true <- is_map(enriched) and not is_struct(enriched),
         true <- Map.keys(enriched) -- (Map.keys(context) ++ native_keys) == [],
         true <- Map.drop(enriched, native_keys) === context,
         true <- operation[:tool_revision] === revision do
      case Map.fetch(enriched, :catalog_snapshot) do
        {:ok, catalog} ->
          with {:ok, descriptor} <- pinned_descriptor(catalog, operation),
               true <-
                 descriptor[:backend] === backend and
                   descriptor[:backend_context] === context,
               :ok <- stable_scope(identity, operation) do
            :ok
          else
            _ -> {:error, :scope_mismatch}
          end

        :error ->
          if enriched === context,
            do: construction_scope(identity, operation),
            else: {:error, :scope_mismatch}
      end
    else
      _ -> {:error, :scope_mismatch}
    end
  end

  def host(_, _, _, _, _, _), do: {:error, :scope_mismatch}

  def descriptor(descriptor, identity, operation)
      when is_map(descriptor) and is_map(identity) and is_map(operation) do
    with true <-
           operation[:tool_name] === descriptor[:tool_name] and
             operation[:tool_revision] === descriptor[:tool_revision],
         :ok <- stable_scope(identity, operation) do
      case snapshot(operation) do
        {:ok, catalog} ->
          with {:ok, pinned} <- pinned_descriptor(catalog, operation),
               true <- pinned === descriptor do
            :ok
          else
            _ -> {:error, :scope_mismatch}
          end

        :error ->
          construction_scope(identity, operation)
      end
    else
      _ -> {:error, :scope_mismatch}
    end
  end

  def descriptor(_, _, _), do: {:error, :scope_mismatch}

  defp snapshot(%{backend_context: context}) when is_map(context),
    do: Map.fetch(context, :catalog_snapshot)

  defp snapshot(_), do: :error

  defp pinned_descriptor(
         %{revision: revision, registry: %{tools: tools}, authority: authority},
         operation
       )
       when is_integer(revision) and revision > 0 and is_map(tools) and is_map(authority) do
    with true <-
           operation[:catalog_revision] === revision and
             authority[:run_id] === operation[:run_id] and
             (not Map.has_key?(operation, :caller) or operation.caller === authority[:caller]),
         {:ok, descriptor} <- Map.fetch(tools, operation[:tool_name]),
         true <-
           is_map(descriptor) and descriptor[:tool_name] === operation[:tool_name] and
             descriptor[:tool_revision] === operation[:tool_revision] do
      {:ok, descriptor}
    else
      _ -> {:error, :scope_mismatch}
    end
  end

  defp pinned_descriptor(_, _), do: {:error, :scope_mismatch}

  defp stable_scope(identity, operation) do
    if Enum.all?([:run_id, :incarnation], fn key ->
         Map.has_key?(identity, key) and operation[key] === identity[key]
       end),
       do: :ok,
       else: {:error, :scope_mismatch}
  end

  defp construction_scope(identity, operation) do
    with :ok <- stable_scope(identity, operation),
         true <-
           Map.has_key?(identity, :catalog_revision) and
             operation[:catalog_revision] === identity.catalog_revision do
      :ok
    else
      _ -> {:error, :scope_mismatch}
    end
  end
end
