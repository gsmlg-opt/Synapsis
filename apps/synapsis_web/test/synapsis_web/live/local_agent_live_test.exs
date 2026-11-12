defmodule SynapsisWeb.LocalAgentLiveTest do
  use SynapsisWeb.ConnCase
  import SynapsisWeb.ReactFormHelpers

  alias Synapsis.LocalAgentConfigs
  alias SynapsisLocalAgents.Event
  alias SynapsisWeb.LocalAgentFakeAdapter, as: Fake

  setup do
    Synapsis.DataCase.clear_config_store(:local_agent)
    previous = Application.get_env(:synapsis_local_agents, :adapters)
    Application.put_env(:synapsis_local_agents, :adapters, %{"codex" => Fake})
    :persistent_term.put({Fake, :observer}, self())

    {:ok, config} =
      LocalAgentConfigs.create(%{name: "Codex", kind: "codex", executable: "/bin/true"})

    on_exit(fn ->
      SynapsisLocalAgents.stop(config.id)
      :persistent_term.erase({Fake, :observer})
      :persistent_term.erase({Fake, :hold_boot})

      if previous,
        do: Application.put_env(:synapsis_local_agents, :adapters, previous),
        else: Application.delete_env(:synapsis_local_agents, :adapters)
    end)

    %{id: config.id}
  end

  # Emit through the fake adapter and wait until the Runner has rebroadcast it.
  defp emit(id, attrs) do
    adapter = SynapsisLocalAgents.Runner.adapter(id)
    Fake.emit(adapter, struct!(Event, attrs))
    :sys.get_state(adapter)
    :sys.get_state(SynapsisLocalAgents.Runner.whereis(id))
  end

  test "lists agents with status and starts one", %{conn: conn, id: id} do
    {:ok, view, _html} = live(conn, ~p"/local-agents")
    assert has_element?(view, "h1", "Local Agents")
    assert has_element?(view, "header.appbar a[href='/local-agents']")
    assert has_element?(view, "#local-agent-#{id}", "Codex")
    assert has_element?(view, "#local-agent-#{id} [data-role=status]", "stopped")

    SynapsisLocalAgents.subscribe_all()
    render_click(element(view, "[phx-click='start_agent'][phx-value-id='#{id}']"))
    assert_receive {:local_agent_event, %Event{type: :status, data: %{state: :running}}}
    assert has_element?(view, "#local-agent-#{id} [data-role=status]", "running")
  end

  test "shows threads and opens a new session", %{conn: conn, id: id} do
    :ok = SynapsisLocalAgents.start(id)
    {:ok, view, _html} = live(conn, ~p"/local-agents/#{id}")
    render_async(view)
    assert has_element?(view, "[data-role=thread-list]", "First chat")

    render_click(element(view, "[phx-click='new_thread']"))
    render_async(view)
    assert_patch(view, ~p"/local-agents/#{id}/threads/th-new")
  end

  test "opening a thread renders its history", %{conn: conn, id: id} do
    :ok = SynapsisLocalAgents.start(id)
    {:ok, view, _html} = live(conn, ~p"/local-agents/#{id}/threads/th-1")
    render_async(view)

    assert_receive {:fake_adapter_call, :resume_thread, ["th-1"]}
    assert has_element?(view, "[data-role=agent-stream]", "hello there")
    assert has_element?(view, "[data-role=agent-stream]", "hi from codex")
  end

  test "sends a message, streams the reply, and can interrupt", %{conn: conn, id: id} do
    :ok = SynapsisLocalAgents.start(id)
    {:ok, view, _html} = live(conn, ~p"/local-agents/#{id}/threads/th-1")
    render_async(view)

    react_form_submit(view, "local-agent-message-form", %{"text" => "write a poem"})
    render_async(view)
    assert_receive {:fake_adapter_call, :start_turn, ["th-1", "write a poem"]}
    assert has_element?(view, "[data-role=agent-stream]", "write a poem")

    emit(id, type: :turn_started, thread_id: "th-1", turn_id: "tu-2")

    emit(id,
      type: :item_delta,
      thread_id: "th-1",
      turn_id: "tu-2",
      item_id: "i-9",
      data: %{delta: "Roses "}
    )

    emit(id,
      type: :item_delta,
      thread_id: "th-1",
      turn_id: "tu-2",
      item_id: "i-9",
      data: %{delta: "are red"}
    )

    emit(id,
      type: :item_delta,
      thread_id: "other",
      turn_id: "x",
      item_id: "i-x",
      data: %{delta: "NOT HERE"}
    )

    html = render(view)
    assert html =~ "Roses are red"
    refute html =~ "NOT HERE"

    render_click(element(view, "[phx-click='interrupt_turn']"))
    render_async(view)
    assert_receive {:fake_adapter_call, :interrupt_turn, ["th-1", "tu-2"]}

    emit(id,
      type: :turn_completed,
      thread_id: "th-1",
      turn_id: "tu-2",
      data: %{status: "interrupted"}
    )

    assert has_element?(view, "[data-role=turn-status]", "interrupted")
    refute has_element?(view, "[phx-click='interrupt_turn']")
  end

  test "a failed turn shows the agent's reason", %{conn: conn, id: id} do
    :ok = SynapsisLocalAgents.start(id)
    {:ok, view, _html} = live(conn, ~p"/local-agents/#{id}/threads/th-1")
    render_async(view)

    emit(id,
      type: :turn_completed,
      thread_id: "th-1",
      turn_id: "tu-2",
      data: %{status: "failed", error: "Missing BP_TOKEN"}
    )

    assert has_element?(view, "[data-role=turn-status]", "failed")
    assert has_element?(view, "[data-role=turn-error]", "Missing BP_TOKEN")
  end

  test "a crash is shown and the agent can be stopped", %{conn: conn, id: id} do
    :ok = SynapsisLocalAgents.start(id)
    {:ok, view, _html} = live(conn, ~p"/local-agents")
    SynapsisLocalAgents.subscribe_all()

    Fake.crash(SynapsisLocalAgents.Runner.adapter(id), {:codex_exited, 7})
    assert_receive {:local_agent_event, %Event{type: :status, data: %{state: :crashed}}}
    assert has_element?(view, "#local-agent-#{id} [data-role=status]", "crashed")
    assert has_element?(view, "#local-agent-#{id}", "codex_exited")

    render_click(element(view, "[phx-click='start_agent'][phx-value-id='#{id}']"))
    render_click(element(view, "[phx-click='stop_agent'][phx-value-id='#{id}']"))
    assert has_element?(view, "#local-agent-#{id} [data-role=status]", "stopped")
  end

  test "the page stays up while the runner is busy", %{conn: conn, id: id} do
    :ok = SynapsisLocalAgents.start(id)
    {:ok, view, _html} = live(conn, ~p"/local-agents")
    runner = SynapsisLocalAgents.Runner.whereis(id)
    :sys.suspend(runner)
    on_exit(fn -> if Process.alive?(runner), do: :sys.resume(runner) end)

    render_click(element(view, "[phx-click='stop_agent'][phx-value-id='#{id}']"))
    assert Process.alive?(view.pid)
    {:ok, _view, html} = live(conn, ~p"/local-agents")
    assert html =~ "busy"

    :sys.resume(runner)
    render_async(view, 5_000)
    assert Process.alive?(view.pid)
  end
end
