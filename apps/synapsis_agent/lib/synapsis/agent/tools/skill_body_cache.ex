defmodule Synapsis.Agent.Tools.SkillBodyCache do
  @moduledoc "A native-resource-owned derived body view for one immutable assigned catalog."
  use GenServer

  alias Backplane.AgentRuntime.Codex.ResourceRegistry

  def start(binding, catalog_id) when is_reference(catalog_id) do
    with {:ok, supervisor} <- ResourceRegistry.worker_supervisor(binding.resource_registry),
         {:ok, pid} <-
           DynamicSupervisor.start_child(
             supervisor,
             Supervisor.child_spec({__MODULE__, catalog_id: catalog_id},
               restart: :temporary,
               shutdown: 1_000
             )
           ) do
      case ResourceRegistry.register(
             binding.resource_registry,
             binding.owner_id,
             :skill_body_cache,
             pid,
             incarnation: binding.incarnation,
             owner_pid: binding.owner_pid,
             cleanup: fn -> DynamicSupervisor.terminate_child(supervisor, pid) end
           ) do
        {:ok, handle} ->
          {:ok, %{pid: pid, binding: binding, handle: handle, catalog_id: catalog_id}}

        error ->
          DynamicSupervisor.terminate_child(supervisor, pid)
          error
      end
    end
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def claim(resource, catalog_id), do: GenServer.call(resource.pid, {:claim, catalog_id})

  def await(resource, ref, timeout),
    do: GenServer.call(resource.pid, {:await, ref}, timeout)

  def complete(resource, claim, view),
    do: GenServer.call(resource.pid, {:complete, claim, view})

  def abandon(resource, claim), do: GenServer.call(resource.pid, {:abandon, claim})
  def release(nil), do: :ok

  def release(%{binding: binding, handle: handle}) do
    case ResourceRegistry.release(binding.resource_registry, handle, binding.owner_id) do
      {:ok, :ok} -> :ok
      other -> other
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       catalog_id: Keyword.fetch!(opts, :catalog_id),
       phase: :empty,
       owner: nil,
       monitor: nil,
       claim: nil,
       view: nil,
       waiters: []
     }}
  end

  @impl true
  def handle_call({:claim, catalog_id}, {owner, _}, %{catalog_id: catalog_id} = state) do
    case state.phase do
      :empty ->
        claim = make_ref()

        {:reply, {:owner, claim},
         %{state | phase: :building, owner: owner, monitor: Process.monitor(owner), claim: claim}}

      :building ->
        {:reply, {:join, state.claim}, state}

      :ready ->
        {:reply, {:ready, state.view}, state}
    end
  end

  def handle_call({:await, ref}, from, %{claim: ref, phase: :building} = state) do
    if length(state.waiters) < 128,
      do: {:noreply, %{state | waiters: [from | state.waiters]}},
      else: {:reply, {:error, :worker_limit}, state}
  end

  def handle_call({:await, ref}, _from, %{claim: ref, phase: :ready} = state),
    do: {:reply, {:ok, state.view}, state}

  def handle_call(
        {:complete, claim, view},
        {owner, _},
        %{phase: :building, claim: claim, owner: owner} = state
      ) do
    if valid_view?(view) do
      Process.demonitor(state.monitor, [:flush])
      Enum.each(state.waiters, &GenServer.reply(&1, {:ok, view}))
      {:reply, :ok, %{state | phase: :ready, owner: nil, monitor: nil, waiters: [], view: view}}
    else
      {:reply, {:error, :invalid_body_view}, state}
    end
  end

  def handle_call(
        {:abandon, claim},
        {owner, _},
        %{phase: :building, claim: claim, owner: owner} = state
      ) do
    {:reply, :ok, abandon_build(state)}
  end

  def handle_call(_, _from, state), do: {:reply, {:error, :stale_body_cache}, state}

  @impl true
  def handle_info(
        {:DOWN, monitor, :process, owner, _},
        %{phase: :building, monitor: monitor, owner: owner} = state
      ),
      do: {:noreply, abandon_build(state)}

  def handle_info(_, state), do: {:noreply, state}

  defp abandon_build(state) do
    Process.demonitor(state.monitor, [:flush])
    Enum.each(state.waiters, &GenServer.reply(&1, {:error, :body_build_abandoned}))
    %{state | phase: :empty, owner: nil, monitor: nil, claim: nil, waiters: [], view: nil}
  end

  defp valid_view?(
         %{
           snapshot: snapshot,
           index: index,
           coverage: %{bodyIndexed: indexed, metadataOnly: metadata, truncatedBodies: truncated}
         } = view
       ) do
    Synapsis.SkillReader.valid_snapshot?(snapshot) and is_map(index) and
      is_integer(indexed) and indexed >= 0 and is_integer(metadata) and metadata >= 0 and
      indexed + metadata <= 128 and is_integer(truncated) and truncated >= 0 and
      truncated <= indexed and pure?(view)
  end

  defp valid_view?(_), do: false
  defp pure?(value) when is_function(value) or is_pid(value) or is_port(value), do: false

  defp pure?(value) when is_map(value),
    do: value |> Map.to_list() |> Enum.all?(fn {k, v} -> pure?(k) and pure?(v) end)

  defp pure?(value) when is_list(value), do: Enum.all?(value, &pure?/1)
  defp pure?(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.all?(&pure?/1)
  defp pure?(_), do: true
end
