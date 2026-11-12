defmodule SynapsisLocalAgents.RunnerTest do
  use ExUnit.Case, async: false

  alias Synapsis.LocalAgentConfigs
  alias SynapsisLocalAgents.Event
  alias SynapsisLocalAgents.Test.FakeAdapter

  setup do
    Synapsis.DataCase.clear_config_store(:local_agent)
    previous = Application.get_env(:synapsis_local_agents, :adapters)
    Application.put_env(:synapsis_local_agents, :adapters, %{"codex" => FakeAdapter})
    :persistent_term.put({FakeAdapter, :observer}, self())
    {:ok, config} = LocalAgentConfigs.create(%{name: "Codex", kind: "codex", executable: "/bin/true"})

    on_exit(fn ->
      SynapsisLocalAgents.stop(config.id)
      :persistent_term.erase({FakeAdapter, :observer})

      if previous,
        do: Application.put_env(:synapsis_local_agents, :adapters, previous),
        else: Application.delete_env(:synapsis_local_agents, :adapters)
    end)

    %{id: config.id}
  end

  test "an agent is stopped until started", %{id: id} do
    assert %{state: :stopped} = SynapsisLocalAgents.status(id)
    assert [%{config: %{id: ^id}, status: %{state: :stopped}}] = SynapsisLocalAgents.list()
    assert {:error, :not_running} = SynapsisLocalAgents.start_turn(id, "th-1", "hi")
  end

  test "start/1 runs the adapter and broadcasts status", %{id: id} do
    SynapsisLocalAgents.subscribe(id)
    SynapsisLocalAgents.subscribe_all()

    assert :ok = SynapsisLocalAgents.start(id)
    assert_receive {:local_agent_event, %Event{agent_id: ^id, type: :status, data: %{state: :running}}}
    assert_receive {:local_agent_event, %Event{type: :status}}
    assert %{state: :running} = SynapsisLocalAgents.status(id)
  end

  test "requests go to the adapter and its events reach subscribers", %{id: id} do
    :ok = SynapsisLocalAgents.start(id)
    SynapsisLocalAgents.subscribe(id)

    assert {:ok, %{turn_id: "tu-2"}} = SynapsisLocalAgents.start_turn(id, "th-1", "hi")
    assert_receive {:fake_adapter_call, :start_turn, ["th-1", "hi"]}

    delta = %Event{agent_id: id, type: :item_delta, thread_id: "th-1", turn_id: "tu-2", data: %{delta: "he"}}
    FakeAdapter.emit(SynapsisLocalAgents.Runner.adapter(id), delta)
    assert_receive {:local_agent_event, ^delta}
  end

  test "an adapter crash is reported and the agent can start again", %{id: id} do
    :ok = SynapsisLocalAgents.start(id)
    SynapsisLocalAgents.subscribe(id)

    FakeAdapter.crash(SynapsisLocalAgents.Runner.adapter(id), {:codex_exited, 1})
    assert_receive {:local_agent_event, %Event{type: :status, data: %{state: :crashed, last_error: error}}}
    assert error =~ "codex_exited"
    assert %{state: :crashed} = SynapsisLocalAgents.status(id)

    assert :ok = SynapsisLocalAgents.start(id)
    assert %{state: :running, last_error: nil} = SynapsisLocalAgents.status(id)
  end

  test "an adapter dying during a request returns an error to the caller", %{id: id} do
    :ok = SynapsisLocalAgents.start(id)
    adapter = SynapsisLocalAgents.Runner.adapter(id)
    :sys.suspend(adapter)
    caller = self()

    spawn(fn -> send(caller, {:result, SynapsisLocalAgents.list_threads(id)}) end)
    Process.sleep(50)
    Process.exit(adapter, :kill)

    assert_receive {:result, {:error, {:adapter_exit, _}}}, 2_000
    assert Process.alive?(self())
  end

  test "stop/1 stops the adapter", %{id: id} do
    :ok = SynapsisLocalAgents.start(id)
    assert :ok = SynapsisLocalAgents.stop(id)
    assert %{state: :stopped} = SynapsisLocalAgents.status(id)
    assert {:error, :not_running} = SynapsisLocalAgents.list_threads(id)
  end

  test "start/1 for an unknown agent fails", _ctx do
    assert {:error, :not_found} = SynapsisLocalAgents.start(Ecto.UUID.generate())
  end
end
