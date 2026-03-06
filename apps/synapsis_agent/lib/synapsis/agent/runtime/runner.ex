defmodule Synapsis.Agent.Runtime.Runner do
  @moduledoc """
  LangGraph-style execution engine backed by a GenServer.

  One runner process executes one graph run:
  `state -> node -> state -> ... -> :end`.
  """

  use GenServer

  alias Synapsis.Agent.Runtime.{CheckpointStore, Event, Graph}

  @type status :: :running | :waiting | :completed | :failed

  @type snapshot :: %{
          run_id: String.t(),
          status: status(),
          node: atom() | :end | nil,
          state: map(),
          ctx: map(),
          error: term() | nil
        }

  @type event_handler ::
          (Event.t() -> term()) | (Event.t(), snapshot() -> term()) | nil

  @type option ::
          {:graph, Graph.t() | map()}
          | {:state, map()}
          | {:ctx, map()}
          | {:node, atom() | :end}
          | {:status, status()}
          | {:run_id, String.t()}
          | {:event_handler, event_handler()}
          | {:timeout, timeout()}

  @genserver_opts [:name, :timeout, :debug, :spawn_opt, :hibernate_after]

  @enforce_keys [:graph, :run_id]
  defstruct [
    :graph,
    :run_id,
    :node,
    :status,
    :workflow_state,
    :ctx,
    :error,
    event_handler: nil,
    awaiters: []
  ]

  @type t :: %__MODULE__{
          graph: Graph.t(),
          run_id: String.t(),
          node: atom() | :end | nil,
          status: status(),
          workflow_state: map(),
          ctx: map(),
          error: term() | nil,
          event_handler: event_handler(),
          awaiters: [GenServer.from()]
        }

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    run_id = Keyword.get_lazy(opts, :run_id, &default_run_id/0)
    opts = Keyword.put(opts, :run_id, run_id)

    start_opts =
      if Keyword.has_key?(opts, :name) do
        opts
      else
        Keyword.put(opts, :name, via(run_id))
      end

    GenServer.start_link(__MODULE__, opts, genserver_opts(start_opts))
  end

  @spec start([option()]) :: GenServer.on_start()
  def start(opts) when is_list(opts) do
    opts = Keyword.put_new_lazy(opts, :run_id, &default_run_id/0)
    GenServer.start(__MODULE__, opts, genserver_opts(opts))
  end

  @spec run(Graph.t() | map(), map(), keyword()) ::
          {:ok, snapshot()} | {:error, term(), snapshot() | nil}
  def run(graph, workflow_state \\ %{}, opts \\ [])
      when is_map(workflow_state) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    run_opts =
      opts
      |> Keyword.drop([:timeout])
      |> Keyword.put_new_lazy(:run_id, &default_run_id/0)
      |> Keyword.merge(graph: graph, state: workflow_state)

    case start(run_opts) do
      {:ok, pid} ->
        snapshot = await(pid, timeout)
        GenServer.stop(pid, :normal)

        if snapshot.status == :failed do
          {:error, snapshot.error, snapshot}
        else
          {:ok, snapshot}
        end

      {:error, reason} ->
        {:error, reason, nil}
    end
  end

  @spec start_from_checkpoint(String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_from_checkpoint(run_id, opts \\ []) when is_binary(run_id) and is_list(opts) do
    with {:ok, checkpoint} <- CheckpointStore.get(run_id),
         {:ok, start_opts} <- restore_opts(checkpoint, opts) do
      start_link(start_opts)
    end
  end

  @spec whereis(String.t()) :: pid() | nil
  def whereis(run_id) when is_binary(run_id) do
    case Registry.lookup(Synapsis.Agent.Runtime.RunRegistry, run_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @spec await(pid() | String.t(), timeout()) :: snapshot() | {:error, term()}
  def await(subject, timeout \\ 5_000)
  def await(pid, timeout) when is_pid(pid), do: GenServer.call(pid, :await, timeout)

  def await(run_id, timeout) when is_binary(run_id) do
    case whereis(run_id) do
      nil ->
        with {:ok, checkpoint} <- CheckpointStore.get(run_id) do
          checkpoint_snapshot(checkpoint)
        end

      pid ->
        await(pid, timeout)
    end
  end

  @spec snapshot(pid() | String.t()) :: snapshot() | {:error, term()}
  def snapshot(pid) when is_pid(pid), do: GenServer.call(pid, :snapshot)

  def snapshot(run_id) when is_binary(run_id) do
    case whereis(run_id) do
      nil ->
        with {:ok, checkpoint} <- CheckpointStore.get(run_id) do
          checkpoint_snapshot(checkpoint)
        end

      pid ->
        snapshot(pid)
    end
  end

  @spec resume(pid() | String.t(), map()) :: :ok | {:error, term()}
  def resume(target, ctx_updates \\ %{})

  def resume(pid, ctx_updates) when is_pid(pid) and is_map(ctx_updates) do
    GenServer.call(pid, {:resume, ctx_updates})
  end

  def resume(run_id, ctx_updates) when is_binary(run_id) and is_map(ctx_updates) do
    with {:ok, pid} <- ensure_waiting_runner(run_id) do
      resume(pid, ctx_updates)
    end
  end

  @impl true
  def init(opts) do
    with {:ok, graph} <- opts |> Keyword.fetch!(:graph) |> Graph.new(),
         {:ok, workflow_state} <- fetch_map(opts, :state, %{}),
         {:ok, ctx} <- fetch_map(opts, :ctx, %{}),
         {:ok, run_id} <- fetch_binary(opts, :run_id),
         {:ok, node} <- fetch_node(opts, graph.start),
         {:ok, status} <- fetch_status(opts, :running),
         {:ok, event_handler} <- normalize_event_handler(Keyword.get(opts, :event_handler)) do
      state =
        %__MODULE__{
          graph: graph,
          run_id: run_id,
          node: node,
          status: status,
          workflow_state: workflow_state,
          ctx: ctx,
          error: nil,
          event_handler: event_handler
        }
        |> emit(:agent_started, %{start_node: node})
        |> persist_checkpoint()

      if status == :running do
        {:ok, state, {:continue, :run}}
      else
        {:ok, state}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:run, %__MODULE__{status: :running} = state) do
    case execute_node(state) do
      {:continue, next_state} -> {:noreply, next_state, {:continue, :run}}
      {:halt, halted_state} -> {:noreply, halted_state}
    end
  end

  def handle_continue(:run, state), do: {:noreply, state}

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, snapshot_from_state(state), state}
  end

  def handle_call(:await, from, %__MODULE__{status: :running} = state) do
    {:noreply, %{state | awaiters: [from | state.awaiters]}}
  end

  def handle_call(:await, _from, state) do
    {:reply, snapshot_from_state(state), state}
  end

  def handle_call({:resume, _ctx_updates}, _from, %__MODULE__{status: :running} = state) do
    {:reply, {:error, :not_waiting}, state}
  end

  def handle_call({:resume, _ctx_updates}, _from, %__MODULE__{status: :completed} = state) do
    {:reply, {:error, :not_waiting}, state}
  end

  def handle_call({:resume, _ctx_updates}, _from, %__MODULE__{status: :failed} = state) do
    {:reply, {:error, :not_waiting}, state}
  end

  def handle_call({:resume, ctx_updates}, _from, %__MODULE__{status: :waiting} = state) do
    next_state =
      state
      |> Map.put(:ctx, Map.merge(state.ctx, ctx_updates))
      |> Map.put(:status, :running)
      |> emit(:agent_resumed, %{node: state.node})
      |> persist_checkpoint()

    {:reply, :ok, next_state, {:continue, :run}}
  end

  defp execute_node(state) do
    case Graph.fetch_node(state.graph, state.node) do
      {:ok, node_module} ->
        state = emit(state, :node_started, %{module: node_module})

        case invoke_node(node_module, state.workflow_state, state.ctx) do
          {:ok, result} -> handle_result(state, node_module, result)
          {:error, reason} -> {:halt, fail(state, reason)}
        end

      {:error, reason} ->
        {:halt, fail(state, reason)}
    end
  end

  defp handle_result(state, node_module, {:next, selector, workflow_state})
       when is_atom(selector) and is_map(workflow_state) do
    case Graph.resolve_next(state.graph, state.node, selector) do
      {:ok, :end} ->
        completed_state =
          state
          |> emit(:node_finished, %{module: node_module, selector: selector, next: :end})
          |> Map.put(:workflow_state, workflow_state)
          |> Map.put(:node, :end)
          |> complete()

        {:halt, completed_state}

      {:ok, next_node} ->
        next_state =
          state
          |> emit(:node_finished, %{module: node_module, selector: selector, next: next_node})
          |> Map.put(:workflow_state, workflow_state)
          |> Map.put(:node, next_node)
          |> persist_checkpoint()

        {:continue, next_state}

      {:error, reason} ->
        {:halt, fail(state, {:invalid_transition, reason})}
    end
  end

  defp handle_result(state, node_module, {:end, workflow_state}) when is_map(workflow_state) do
    completed_state =
      state
      |> emit(:node_finished, %{module: node_module, next: :end})
      |> Map.put(:workflow_state, workflow_state)
      |> Map.put(:node, :end)
      |> complete()

    {:halt, completed_state}
  end

  defp handle_result(state, node_module, {:wait, workflow_state}) when is_map(workflow_state) do
    waiting_state =
      state
      |> emit(:node_finished, %{module: node_module, next: state.node})
      |> Map.put(:workflow_state, workflow_state)
      |> Map.put(:status, :waiting)
      |> emit(:agent_waiting, %{node: state.node})
      |> persist_checkpoint()
      |> flush_awaiters()

    {:halt, waiting_state}
  end

  defp handle_result(state, node_module, result) do
    {:halt, fail(state, {:invalid_node_result, node_module, result})}
  end

  defp invoke_node(module, workflow_state, ctx) do
    try do
      {:ok, module.run(workflow_state, ctx)}
    rescue
      exception ->
        {:error, {:node_crash, module, exception, __STACKTRACE__}}
    catch
      kind, reason ->
        {:error, {:node_throw, module, kind, reason, __STACKTRACE__}}
    end
  end

  defp complete(state) do
    state
    |> Map.put(:status, :completed)
    |> Map.put(:error, nil)
    |> emit(:agent_finished, %{node: :end})
    |> persist_checkpoint()
    |> flush_awaiters()
  end

  defp fail(state, reason) do
    state
    |> Map.put(:status, :failed)
    |> Map.put(:error, reason)
    |> emit(:agent_failed, %{reason: reason})
    |> persist_checkpoint()
    |> flush_awaiters()
  end

  defp flush_awaiters(%__MODULE__{awaiters: []} = state), do: state

  defp flush_awaiters(state) do
    snapshot = snapshot_from_state(state)

    Enum.each(state.awaiters, fn from ->
      GenServer.reply(from, snapshot)
    end)

    %{state | awaiters: []}
  end

  defp emit(%__MODULE__{event_handler: nil} = state, _type, _payload), do: state

  defp emit(state, type, payload) do
    event = %Event{
      run_id: state.run_id,
      type: type,
      timestamp: DateTime.utc_now(),
      node: state.node,
      payload: payload
    }

    dispatch_event(state.event_handler, event, snapshot_from_state(state))
    state
  end

  defp dispatch_event(handler, event, snapshot) when is_function(handler, 1) do
    safe_dispatch(fn -> handler.(event) end)
    snapshot
  end

  defp dispatch_event(handler, event, snapshot) when is_function(handler, 2) do
    safe_dispatch(fn -> handler.(event, snapshot) end)
    snapshot
  end

  defp safe_dispatch(fun) do
    try do
      _ = fun.()
      :ok
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp fetch_map(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_option, key}}
    end
  end

  defp fetch_binary(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_option, key}}
    end
  end

  defp fetch_node(opts, default) do
    case Keyword.get(opts, :node, default) do
      value when is_atom(value) -> {:ok, value}
      _ -> {:error, {:invalid_option, :node}}
    end
  end

  defp fetch_status(opts, default) do
    case Keyword.get(opts, :status, default) do
      value when value in [:running, :waiting, :completed, :failed] -> {:ok, value}
      _ -> {:error, {:invalid_option, :status}}
    end
  end

  defp normalize_event_handler(nil), do: {:ok, nil}
  defp normalize_event_handler(handler) when is_function(handler, 1), do: {:ok, handler}
  defp normalize_event_handler(handler) when is_function(handler, 2), do: {:ok, handler}
  defp normalize_event_handler(_), do: {:error, :invalid_event_handler}

  defp default_run_id do
    "run-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp snapshot_from_state(state) do
    %{
      run_id: state.run_id,
      status: state.status,
      node: state.node,
      state: state.workflow_state,
      ctx: state.ctx,
      error: state.error
    }
  end

  defp checkpoint_snapshot(checkpoint) do
    %{
      run_id: checkpoint.run_id,
      status: checkpoint.status,
      node: checkpoint.node,
      state: checkpoint.state,
      ctx: checkpoint.ctx,
      error: checkpoint.error
    }
  end

  defp restore_opts(checkpoint, opts) do
    cond do
      checkpoint.status in [:completed, :failed] ->
        {:error, {:run_terminal, checkpoint.status}}

      checkpoint.node == :end ->
        {:error, :invalid_checkpoint}

      true ->
        restore_status =
          if checkpoint.status == :waiting do
            :waiting
          else
            :running
          end

        restored =
          opts
          |> Keyword.put_new(:run_id, checkpoint.run_id)
          |> Keyword.put_new(:graph, checkpoint.graph)
          |> Keyword.put_new(:state, checkpoint.state)
          |> Keyword.put_new(:ctx, checkpoint.ctx)
          |> Keyword.put_new(:node, checkpoint.node)
          |> Keyword.put_new(:status, restore_status)

        {:ok, restored}
    end
  end

  defp ensure_waiting_runner(run_id) do
    case whereis(run_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        with {:ok, checkpoint} <- CheckpointStore.get(run_id),
             true <- checkpoint.status == :waiting,
             {:ok, pid} <- start_from_checkpoint(run_id) do
          {:ok, pid}
        else
          false -> {:error, :not_waiting}
          {:error, _} = error -> error
        end
    end
  end

  defp persist_checkpoint(state) do
    _ =
      CheckpointStore.put(%{
        run_id: state.run_id,
        graph: state.graph,
        node: state.node,
        status: state.status,
        state: state.workflow_state,
        ctx: state.ctx,
        error: state.error,
        updated_at: DateTime.utc_now()
      })

    state
  end

  defp via(run_id), do: {:via, Registry, {Synapsis.Agent.Runtime.RunRegistry, run_id}}

  defp genserver_opts(opts) do
    Keyword.take(opts, @genserver_opts)
  end
end
