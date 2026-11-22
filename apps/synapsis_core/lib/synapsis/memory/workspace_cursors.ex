defmodule Synapsis.Memory.WorkspaceCursors do
  @moduledoc false
  use Supervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: __MODULE__.Registry},
        {DynamicSupervisor, strategy: :one_for_one, name: __MODULE__.Supervisor, max_children: 32}
      ],
      strategy: :one_for_all
    )
  end

  def page(binding, nil) do
    token = token()

    case DynamicSupervisor.start_child(
           __MODULE__.Supervisor,
           {__MODULE__.Cursor, {binding, token}}
         ) do
      {:ok, pid} -> call(pid, binding, token)
      {:error, :max_children} -> {:error, :cursor_limit}
      {:error, _} -> {:error, :unavailable}
    end
  end

  def page(binding, token) do
    case Registry.lookup(__MODULE__.Registry, token) do
      [{pid, _}] -> call(pid, binding, token)
      [] -> {:error, :invalid_cursor}
    end
  end

  def cancel(token) do
    case Registry.lookup(__MODULE__.Registry, token) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__.Supervisor, pid)
      [] -> :ok
    end

    :ok
  end

  def token, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

  defp call(pid, binding, token) do
    # During a page the existing WorkspaceReader guardian owns this caller.
    # Killing it must also kill a suspended cursor and close its port.
    Process.link(pid)

    try do
      GenServer.call(pid, {:page, binding, token}, 1_000)
    after
      Process.unlink(pid)
    end
  end
end

defmodule Synapsis.Memory.WorkspaceCursors.Cursor do
  @moduledoc false
  use GenServer, restart: :temporary
  alias Synapsis.Memory.WorkspaceCursors

  @ttl 60_000

  def start_link({binding, token}) do
    GenServer.start_link(__MODULE__, {binding, token},
      name: {:via, Registry, {WorkspaceCursors.Registry, token}},
      spawn_opt: [{:max_heap_size, %{size: 1_000_000, kill: true, error_logger: false}}]
    )
  end

  @impl true
  def init({binding, token}) do
    # Active calls link to their bounded reader; :kill must propagate even if
    # this process is suspended in a filesystem operation.
    Process.flag(:trap_exit, false)
    timer = Process.send_after(self(), :expire, @ttl)
    {:ok, %{binding: binding, token: token, timer: timer, scan: nil}}
  end

  @impl true
  def handle_call({:page, binding, token}, _from, %{binding: binding, token: token} = state) do
    Process.cancel_timer(state.timer)

    case Synapsis.Memory.WorkspaceReader.scan_page(binding, state.scan) do
      {:ok, result, nil} ->
        {:stop, :normal, {:ok, Map.put(result, :next_cursor, nil)}, state}

      {:ok, result, scan} ->
        next = WorkspaceCursors.token()
        Registry.unregister(WorkspaceCursors.Registry, token)
        {:ok, _} = Registry.register(WorkspaceCursors.Registry, next, nil)
        timer = Process.send_after(self(), :expire, @ttl)

        {:reply, {:ok, Map.put(result, :next_cursor, next)},
         %{state | token: next, timer: timer, scan: scan}}

      {:error, _} = error ->
        {:stop, :normal, error, state}
    end
  end

  def handle_call({:page, binding, _token}, _from, state) do
    reason = if binding == state.binding, do: :invalid_cursor, else: :cursor_mismatch
    {:reply, {:error, reason}, state}
  end

  @impl true
  def handle_info(:expire, state), do: {:stop, :normal, state}
  def handle_info({_port, {:exit_status, _status}}, state), do: {:stop, :normal, state}
end
