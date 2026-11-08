defmodule Synapsis.Agent.Tools.Discovery do
  @moduledoc "Native discovery over an explicit subset of the already selected catalog."

  alias Backplane.AgentRuntime.{Codex, Error, InputSchema, ToolCatalog}

  alias Backplane.AgentRuntime.Codex.{
    Backend,
    Contract,
    DynamicRuntime,
    ResourceRegistry,
    Session
  }

  alias Synapsis.Agent.Tools.{Catalog, CatalogBinding}

  @search "tool_search"

  def plan(agent, selected, ceiling \\ nil) do
    deferred = Map.get(agent, :deferred_tool_names, [])

    if is_list(deferred) and Enum.all?(deferred, &exact_name?/1) and
         Enum.uniq(deferred) == deferred and @search not in deferred and
         Enum.all?(deferred, &(&1 in selected)) do
      selected = if ceiling, do: Enum.filter(selected, &(&1 in ceiling.grants)), else: selected
      deferred = Enum.filter(deferred, &(&1 in selected))
      runtime = if deferred == [], do: selected, else: selected ++ [@search]

      if deferred == [] or is_nil(ceiling) or @search in ceiling.grants do
        {:ok,
         %{selected: selected, deferred: deferred, runtime: runtime, initial: runtime -- deferred}}
      else
        invalid("discovery is unavailable in the inherited catalog")
      end
    else
      invalid("deferred tools must be unique exact selected tool names")
    end
  end

  def prepare(bundle, %{deferred: []}, _binding, _ceiling),
    do: {:ok, bundle, bundle, nil}

  def prepare(bundle, plan, binding, ceiling) do
    with {:ok, candidates} <- candidates(bundle.registry.tools, plan.deferred),
         {:ok, record} <- start_runtime(candidates, binding) do
      result =
        with {:ok, search} <-
               Codex.profile(
                 :dynamic,
                 %{dynamic_runtime: record.pid, session_binding: binding},
                 %{
                   ceiling
                   | grants: [@search],
                     tool_revisions: Map.take(ceiling.tool_revisions, [@search])
                 },
                 tools: [@search]
               ),
             descriptors =
               Enum.map(plan.selected, fn name ->
                 case Enum.find(candidates, &(&1.tool_name == name)) do
                   nil -> Map.fetch!(bundle.registry.tools, name)
                   contract -> Contract.descriptor(contract)
                 end
               end) ++ Map.values(search.registry.tools),
             {:ok, issued} <-
               ToolCatalog.admit_batch(descriptors,
                 mode: :strict,
                 authority: %{
                   ceiling
                   | grants: plan.runtime,
                     tool_revisions: Map.take(ceiling.tool_revisions, plan.runtime)
                 }
               ),
             {:ok, initial} <- Catalog.compose([issued], [], ceiling, plan.initial) do
          {:ok, issued, initial, record}
        end

      case result do
        {:ok, _, _, _} ->
          result

        error ->
          release(record)
          error
      end
    end
  end

  def classify(
        %{
          tool_name: @search,
          backend: Backend,
          backend_context: %{family: :dynamic, runtime: runtime, session_binding: binding}
        } = descriptor,
        identity,
        invocation
      ) do
    with true <- is_pid(runtime) and Process.alive?(runtime),
         :ok <- CatalogBinding.descriptor(descriptor, identity, invocation),
         {:ok, _} <- Session.validate(binding, invocation),
         {:ok, _} <- InputSchema.validate(descriptor.schema, invocation.arguments) do
      {:ok, %{action: "tools.discover", resource: "catalog:session:" <> identity.session_id}}
    else
      false -> invalid("discovery runtime is unavailable")
      error -> error
    end
  end

  def release(nil), do: :ok

  def release(%{binding: binding, handle: handle}) do
    case ResourceRegistry.release(binding.resource_registry, handle, binding.owner_id) do
      {:ok, :ok} -> :ok
      other -> other
    end
  end

  defp candidates(descriptors, names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, found} ->
      descriptor = Map.fetch!(descriptors, name)

      with {:ok, {namespace, local}} <- Contract.split_name(name),
           {:ok, contract} <-
             Contract.new(
               %{
                 namespace: namespace,
                 name: local,
                 tool_revision: descriptor.tool_revision,
                 description: Map.get(descriptor, :description, ""),
                 schema: descriptor.schema,
                 backend: descriptor.backend,
                 backend_context: descriptor.backend_context,
                 safety: descriptor.safety,
                 input_kind: Map.get(descriptor, :codex_input_kind, :function),
                 format: Map.get(descriptor, :codex_format),
                 output_schema: Map.get(descriptor, :codex_output_schema),
                 exposure: Map.get(descriptor, :codex_exposure, :direct),
                 source: Map.get(descriptor, :codex_source, %{})
               }
               |> copy_binding(descriptor)
             ) do
        {:cont, {:ok, found ++ [contract]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp copy_binding(attrs, descriptor) do
    case Map.fetch(descriptor, :collaboration_binding) do
      {:ok, binding} -> Map.put(attrs, :collaboration_binding, binding)
      :error -> attrs
    end
  end

  defp start_runtime(candidates, binding) do
    with {:ok, supervisor} <- ResourceRegistry.worker_supervisor(binding.resource_registry),
         {:ok, pid} <-
           DynamicSupervisor.start_child(
             supervisor,
             Supervisor.child_spec(
               {DynamicRuntime, candidates: candidates, max_results: max(8, length(candidates))},
               restart: :temporary,
               shutdown: 1_000
             )
           ) do
      case ResourceRegistry.register(
             binding.resource_registry,
             binding.owner_id,
             :tool_discovery,
             pid,
             incarnation: binding.incarnation,
             owner_pid: binding.owner_pid,
             cleanup: fn -> DynamicSupervisor.terminate_child(supervisor, pid) end
           ) do
        {:ok, handle} ->
          {:ok, %{pid: pid, handle: handle, binding: binding}}

        error ->
          DynamicSupervisor.terminate_child(supervisor, pid)
          error
      end
    end
  end

  defp exact_name?(name),
    do:
      is_binary(name) and String.valid?(name) and String.trim(name) != "" and
        not String.contains?(name, <<0>>)

  defp invalid(message), do: {:error, Error.new(:validation, message)}
end
