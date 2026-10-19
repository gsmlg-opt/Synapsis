defmodule Synapsis.Session.ModelSelectionTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Session.Worker
  alias Synapsis.{AgentConfigs, Models, Providers, Sessions}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    harness = SessionHarness.setup_session!(tmp_dir: tmp_dir, session_config: %{})
    SessionHarness.subscribe!(harness.session.id)
    Bypass.stub(harness.provider.bypass, "POST", "/v1/chat/completions", &answer/1)
    on_exit(fn -> SessionHarness.cleanup!(harness) end)
    %{harness: harness, id: harness.session.id}
  end

  test "a switched provider/model drives queued turns and survives worker restart", %{
    harness: harness,
    id: id
  } do
    owner = self()

    Bypass.stub(harness.provider.bypass, "POST", "/v1/chat/completions", fn conn ->
      answer(conn)
    end)

    assert :ok = Worker.send_message(id, "original history")
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000

    bypass = Bypass.open()

    {:ok, target} =
      Providers.create(%{
        name: "model-target-#{System.unique_integer([:positive])}",
        type: "openai",
        base_url: "http://localhost:#{bypass.port}",
        api_key_encrypted: "target-key"
      })

    {:ok, model} =
      Models.create(%{provider_id: target.id, model: "selected-model", context_window: 32_768})

    on_exit(fn ->
      Models.delete(model)
      Providers.delete(target.id)
    end)

    Bypass.stub(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      send(owner, {:target_request, request})

      if message_text(List.last(request["messages"])) == "hold switched turn" do
        send(owner, {:target_waiting, self()})
        receive do: (:release -> :ok), after: (5_000 -> :ok)
      end

      answer(conn)
    end)

    assert :ok = Sessions.switch_model(id, target.name, model.model)
    assert Worker.snapshot(id).session.config["model_id"] == model.id
    assert :ok = Worker.send_message(id, "hold switched turn")
    assert_receive {:target_waiting, handler}, 5_000

    assert {:error, :session_busy} =
             Sessions.switch_model(id, harness.provider.name, "characterization-model")

    assert :ok = Worker.send_message(id, "queued switched turn")
    send(handler, :release)
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000

    assert_receive {:target_request, first}
    assert_receive {:target_request, second}
    assert first["model"] == model.model
    assert second["model"] == model.model
    assert Enum.any?(first["messages"], &(message_text(&1) == "original history"))
    assert AgentConfigs.get(harness.agent_config.id).model == "characterization-model"
    assert AgentConfigs.get(harness.agent_config.id).provider == harness.provider.name

    :ok = Synapsis.Session.DynamicSupervisor.stop_session(id)
    :ok = Sessions.ensure_running(id)
    assert Worker.snapshot(id).session.model == model.model
    assert :ok = Worker.send_message(id, "after restart")
    assert_receive {:target_request, %{"model" => "selected-model"}}, 5_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000

    {_status, data} =
      :sys.get_state(GenServer.whereis({:via, Registry, {Synapsis.Session.Registry, id}}))

    assert data.agent.model_context_window == 32_768
  end

  test "a disabled saved model remains recoverable after worker restart", %{
    harness: harness,
    id: id
  } do
    {:ok, target} =
      Providers.create(%{
        name: "disabled-target-#{System.unique_integer([:positive])}",
        type: "openai"
      })

    {:ok, model} =
      Models.create(%{provider_id: target.id, model: "will-disable", context_window: 4_096})

    on_exit(fn ->
      Models.delete(model)
      Providers.delete(target.id)
    end)

    assert :ok = Sessions.switch_model(id, target.name, model.model)
    {:ok, _} = Models.update(model, %{enabled: false})
    :ok = Synapsis.Session.DynamicSupervisor.stop_session(id)
    assert :ok = Sessions.ensure_running(id)
    assert {:error, :model_unavailable} = Worker.send_message(id, "must not be sent")
    assert :ok = Sessions.switch_model(id, harness.provider.name, "characterization-model")
    assert Worker.snapshot(id).session.provider == harness.provider.name
  end

  defp message_text(%{"content" => content}) when is_binary(content), do: content

  defp message_text(%{"content" => parts}) when is_list(parts),
    do: Enum.map_join(parts, &(&1["text"] || ""))

  defp answer(conn),
    do:
      DeterministicProvider.send_sse(conn, [
        DeterministicProvider.text_chunk("answer"),
        DeterministicProvider.finish_chunk("stop")
      ])
end
