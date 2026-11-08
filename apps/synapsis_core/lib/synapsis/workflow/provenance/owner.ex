defmodule Synapsis.Workflow.Provenance.Owner do
  @moduledoc """
  Application-lifetime, volatile owner of private workflow provenance.

  Each lease retains a complete active heap. Normal release retains only nodes
  reachable from remembered roots; restart starts a fresh empty incarnation.
  This process performs no execution, filesystem IO or durable persistence.
  """

  use GenServer

  alias Synapsis.Workflow.Provenance

  defmodule Binding do
    @moduledoc false
    @enforce_keys [:server, :incarnation, :graph, :lease, :seq]
    defstruct [:server, :incarnation, :graph, :lease, :seq]
  end

  def start_link(options \\ []) do
    case Keyword.get(options, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, :ok)
      name -> GenServer.start_link(__MODULE__, :ok, name: name)
    end
  end

  def open(server, owner_pid, heap, timeout_ms)
      when is_pid(owner_pid) and is_integer(timeout_ms) and timeout_ms > 0 do
    case GenServer.whereis(server) do
      nil -> {:error, :owner_unavailable}
      pid -> GenServer.call(pid, {:open, owner_pid, heap}, timeout_ms)
    end
  end

  def publish(%Binding{} = binding, delta, actions, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0,
      do: GenServer.call(binding.server, {:publish, binding, delta, actions}, timeout_ms)

  def provenance_of(%Binding{} = binding, root, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0,
      do: GenServer.call(binding.server, {:provenance_of, binding, root}, timeout_ms)

  def release(%Binding{} = binding, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0,
      do: GenServer.call(binding.server, {:release, binding}, timeout_ms)

  def retire(%Binding{} = binding, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0,
      do: GenServer.call(binding.server, {:retire, binding}, timeout_ms)

  @impl true
  def init(:ok) do
    {:ok,
     %{
       incarnation: make_ref(),
       next_call: 1,
       graphs: %{},
       calls: %{},
       leases: %{},
       remembered: %{},
       insertion_order: []
     }}
  end

  @impl true
  def handle_call({:open, owner_pid, heap}, _from, state) do
    graph = make_ref()
    lease = make_ref()
    monitor = Process.monitor(owner_pid)
    public = %{nodes: heap["nodes"], next_id: heap["next_id"], marks: %{}}
    active = %{graph: graph, owner_pid: owner_pid, monitor: monitor, seq: 0}

    state = %{
      state
      | graphs: Map.put(state.graphs, graph, public),
        leases: Map.put(state.leases, lease, active)
    }

    binding = %Binding{
      server: self(),
      incarnation: state.incarnation,
      graph: graph,
      lease: lease,
      seq: 0
    }

    {:reply, {:ok, binding}, state}
  end

  def handle_call({:publish, binding, delta, actions}, _from, state) do
    if current?(state, binding) do
      graph = state.graphs[binding.graph]
      graph = %{graph | nodes: Map.merge(graph.nodes, delta.upsert), next_id: delta.next_id}
      state = put_in(state, [:graphs, binding.graph], graph)
      state = Enum.reduce(actions, state, &Provenance.apply_action(&2, binding.graph, &1))
      next = %{binding | seq: binding.seq + 1}
      state = put_in(state, [:leases, binding.lease, :seq], next.seq)
      {:reply, {:ok, next}, Provenance.sweep(state)}
    else
      {:reply, {:error, :stale_binding}, state}
    end
  end

  def handle_call({:provenance_of, binding, root}, _from, state) do
    if current?(state, binding),
      do: {:reply, {:ok, Provenance.of(state, binding.graph, root)}, state},
      else: {:reply, {:error, :stale_binding}, state}
  end

  def handle_call({:release, binding}, _from, state) do
    if current?(state, binding) do
      Process.demonitor(state.leases[binding.lease].monitor, [:flush])
      state = %{state | leases: Map.delete(state.leases, binding.lease)}
      {:reply, :ok, Provenance.sweep(state)}
    else
      {:reply, {:error, :stale_binding}, state}
    end
  end

  # Retirement grants no publication authority and returns no refreshed binding.
  # The original lease identity remains useful after a callback advanced its seq.
  def handle_call({:retire, %Binding{} = binding}, _from, state) do
    identity? = binding.server == self() and binding.incarnation == state.incarnation

    case {identity?, state.leases[binding.lease]} do
      {true, %{graph: graph, monitor: monitor}} when graph == binding.graph ->
        Process.demonitor(monitor, [:flush])
        state = %{state | leases: Map.delete(state.leases, binding.lease)}
        {:reply, :ok, Provenance.sweep(state)}

      {true, nil} ->
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :stale_binding}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    leases = Map.reject(state.leases, fn {_lease, active} -> active.monitor == monitor end)
    {:noreply, Provenance.sweep(%{state | leases: leases})}
  end

  defp current?(state, %Binding{} = binding) do
    binding.server == self() and binding.incarnation == state.incarnation and
      case state.leases[binding.lease] do
        %{graph: graph, seq: seq} -> graph == binding.graph and seq == binding.seq
        nil -> false
      end
  end
end
