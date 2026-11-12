defmodule SynapsisLocalAgents.Test.FakeAdapter do
  @moduledoc false
  # Scriptable adapter: reports ready at once, records calls to the test pid
  # stored in :persistent_term {__MODULE__, :observer}, emits/crashes on demand.
  @behaviour SynapsisLocalAgents.Adapter
  use GenServer

  alias SynapsisLocalAgents.Event

  def emit(pid, %Event{} = event), do: GenServer.cast(pid, {:emit, event})
  def crash(pid, reason), do: GenServer.cast(pid, {:crash, reason})
  def crash_on_stop(pid), do: GenServer.call(pid, :crash_on_stop)

  @impl SynapsisLocalAgents.Adapter
  def start_link(config, owner), do: GenServer.start_link(__MODULE__, {config, owner})

  @impl SynapsisLocalAgents.Adapter
  def list_threads(pid), do: GenServer.call(pid, {:call, :list_threads, []})
  @impl SynapsisLocalAgents.Adapter
  def start_thread(pid), do: GenServer.call(pid, {:call, :start_thread, []})
  @impl SynapsisLocalAgents.Adapter
  def read_thread(pid, thread_id), do: GenServer.call(pid, {:call, :read_thread, [thread_id]})
  @impl SynapsisLocalAgents.Adapter
  def resume_thread(pid, thread_id), do: GenServer.call(pid, {:call, :resume_thread, [thread_id]})
  @impl SynapsisLocalAgents.Adapter
  def start_turn(pid, thread_id, text), do: GenServer.call(pid, {:call, :start_turn, [thread_id, text]})
  @impl SynapsisLocalAgents.Adapter
  def steer_turn(pid, thread_id, turn_id, text),
    do: GenServer.call(pid, {:call, :steer_turn, [thread_id, turn_id, text]})

  @impl SynapsisLocalAgents.Adapter
  def interrupt_turn(pid, thread_id, turn_id),
    do: GenServer.call(pid, {:call, :interrupt_turn, [thread_id, turn_id]})

  @impl SynapsisLocalAgents.Adapter
  def stop(pid), do: GenServer.stop(pid, :normal)

  @impl GenServer
  def init({config, owner}) do
    send(owner, {:local_agent_event, %Event{agent_id: config.id, type: :status, data: %{state: :running}}})
    {:ok, %{config: config, owner: owner, crash_on_stop: false}}
  end

  @impl GenServer
  def handle_call(:crash_on_stop, _from, state), do: {:reply, :ok, %{state | crash_on_stop: true}}

  def handle_call({:call, name, args}, _from, state) do
    case :persistent_term.get({__MODULE__, :observer}, nil) do
      nil -> :ok
      pid -> send(pid, {:fake_adapter_call, name, args})
    end

    {:reply, reply(name, args), state}
  end

  @impl GenServer
  def handle_cast({:emit, event}, state) do
    send(state.owner, {:local_agent_event, event})
    {:noreply, state}
  end

  def handle_cast({:crash, reason}, state), do: {:stop, reason, state}

  @impl GenServer
  def terminate(:normal, %{crash_on_stop: true}), do: exit(:crashed_while_stopping)
  def terminate(_reason, _state), do: :ok

  defp reply(:list_threads, _), do: {:ok, [%{id: "th-1", title: "First chat", updated_at: "2026-11-12T00:00:00Z"}]}
  defp reply(:start_thread, _), do: {:ok, %{id: "th-new"}}

  defp reply(:read_thread, [id]) do
    {:ok,
     %{
       id: id,
       turns: [
         %{id: "tu-1", status: "completed",
           items: [%{id: "i-1", role: :user, text: "hello there"}, %{id: "i-2", role: :agent, text: "hi from codex"}]}
       ]
     }}
  end

  defp reply(:resume_thread, [id]), do: {:ok, %{id: id}}
  defp reply(:start_turn, _), do: {:ok, %{turn_id: "tu-2"}}
  defp reply(_, _), do: :ok
end
