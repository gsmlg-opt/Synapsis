defmodule SynapsisSamgita.Execution.Guard do
  @moduledoc "Owns the execution lease independently of a blocked worker and cancels its exact runtime on owner loss."
  use GenServer, restart: :temporary
  alias Synapsis.Samgita.Executions

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def attach(pid, handle), do: GenServer.call(pid, {:attach, handle}, 5_000)
  def release(pid), do: GenServer.call(pid, :release, 45_000)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)
    worker = Keyword.fetch!(opts, :worker)

    {:ok,
     %{
       id: opts[:id],
       token: opts[:token],
       worker: worker,
       owner: owner,
       owner_ref: Process.monitor(owner),
       worker_ref: Process.monitor(worker),
       runtime: opts[:runtime],
       handle: nil,
       lost: false,
       released: false
     }}
  end

  @impl true
  def handle_call(:release, _from, state) do
    case Executions.get(state.id) do
      {:ok, %{"phase" => phase}} when phase in ["completed", "failed", "ignored"] ->
        :ok

      _ ->
        Executions.revoke(state.id, "execution_interrupted")
        cancel(state)
    end

    {:reply, :ok, %{state | released: true}}
  end

  def handle_call({:attach, handle}, _from, state) do
    if function_exported?(state.runtime, :watch, 1), do: state.runtime.watch(handle)
    state = %{state | handle: handle}

    if state.lost or not Process.alive?(state.owner) do
      state = lose(state)
      cancel(state)
      {:reply, {:error, :owner_lost}, state}
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    state = lose(state)
    cancel(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{worker_ref: ref} = state) do
    state = lose(state)
    cancel(state)
    {:stop, :normal, state}
  end

  def handle_info(message, state) do
    handle =
      if state.handle && function_exported?(state.runtime, :capture, 2),
        do: state.runtime.capture(state.handle, message),
        else: state.handle

    state = %{state | handle: handle}
    if state.lost, do: cancel(state)
    {:noreply, state}
  end

  defp lose(%{lost: true} = state), do: state

  defp lose(state) do
    Executions.revoke(state.id, "execution_owner_lost")
    send(state.worker, {:execution_owner_lost, state.token})
    %{state | lost: true}
  end

  defp cancel(%{handle: nil}), do: :ok

  defp cancel(state) do
    state.runtime.cancel(state.handle)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def terminate(_reason, %{released: true}), do: :ok

  def terminate(_reason, state) do
    lose(state)
    cancel(state)
    :ok
  end
end
