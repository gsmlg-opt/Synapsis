defmodule Synapsis.Session.MCPRefreshTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Session.Worker
  alias Synapsis.Tool.Registry, as: ToolRegistry

  @moduletag :tmp_dir

  def execute_runtime(_pid, _name, _arguments, _context, _opts), do: {:ok, "unused tool"}

  # The callback runs inside the worker's supervised preparation task. Each
  # response represents a complete discovery outcome, without real MCP traffic.
  def refresh(owner) do
    send(owner, {:refresh_waiting, self()})

    receive do
      {:discovered, name, tool_owner, source, field} ->
        register(name, tool_owner, source, field)
        %{source => :ok}

      {:failed, source} ->
        %{source => {:error, :offline}}
    after
      5_000 -> {:error, :test_refresh_timeout}
    end
  end

  setup %{tmp_dir: tmp_dir} = ctx do
    owner = self()
    previous = Application.get_env(:synapsis_core, :mcp_refresh)
    Application.put_env(:synapsis_core, :mcp_refresh, {__MODULE__, :refresh, [owner]})
    source = Ecto.UUID.generate()
    name = "mcp:refresh_#{source}:read"
    config = if ctx[:native], do: %{}, else: %{"subagents" => false}
    harness = SessionHarness.setup_session!(tmp_dir: tmp_dir, session_config: config)

    {:ok, _} =
      Synapsis.AgentConfigs.update(harness.agent_config, %{
        config:
          Map.put(harness.agent_config.config, "mcp_selection", %{
            "default" => "selected",
            "sources" => %{source => %{"mode" => "all"}}
          })
      })

    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    pid = GenServer.whereis({:via, Registry, {Synapsis.Session.Registry, harness.session.id}})

    if ctx[:assistant] do
      :sys.replace_state(pid, fn {state, data} ->
        {state, %{data | execution_mode: :query_loop}}
      end)
    end

    Bypass.stub(harness.provider.bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:provider_request, Jason.decode!(body), self()})
      receive do: (:respond -> :ok), after: (5_000 -> :ok)

      DeterministicProvider.send_sse(conn, [
        DeterministicProvider.text_chunk("answer"),
        DeterministicProvider.finish_chunk("stop")
      ])
    end)

    on_exit(fn ->
      SessionHarness.cleanup!(harness)
      ToolRegistry.unregister(name)

      if previous,
        do: Application.put_env(:synapsis_core, :mcp_refresh, previous),
        else: Application.delete_env(:synapsis_core, :mcp_refresh)
    end)

    %{id: harness.session.id, pid: pid, source: source, name: name, owner: owner}
  end

  for {mode, tags} <- [{"native", [native: true]}, {"graph", []}] do
    @tag tags
    test "#{mode} turn preparation stays responsive and binds fresh schemas every turn", ctx do
      for field <- ["first", "second"] do
        assert :ok = Worker.send_message(ctx.id, "turn #{field}")
        assert_receive {:refresh_waiting, refresh}, 5_000

        assert Task.await(Task.async(fn -> Worker.snapshot(ctx.id) end), 1_000).session.id ==
                 ctx.id

        send(refresh, {:discovered, ctx.name, ctx.owner, ctx.source, field})
        assert_receive {:provider_request, request, handler}, 5_000

        assert Enum.any?(
                 request["tools"] || [],
                 &(&1["function"]["parameters"]["properties"][field] == %{"type" => "string"})
               )

        {_status, data} = :sys.get_state(ctx.pid)
        selected = Enum.find(data.agent.resolved_tools, &(&1.name == ctx.name))
        assert selected.registration == data.agent.tool_modules[ctx.name]
        assert selected.parameters["properties"] == %{field => %{"type" => "string"}}
        send(handler, :respond)
        assert_receive {:run_event, %{type: "session.completed"}}, 10_000
      end

      assert :ok = Worker.send_message(ctx.id, "offline turn")
      assert_receive {:refresh_waiting, refresh}, 5_000
      send(refresh, {:failed, ctx.source})
      assert_receive {:provider_request, request, handler}, 5_000

      refute Enum.any?(
               request["tools"] || [],
               &(&1["function"]["description"] == "MCP refresh regression")
             )

      {_status, data} = :sys.get_state(ctx.pid)
      refute ctx.name in data.agent.tools
      refute Map.has_key?(data.agent.tool_modules, ctx.name)
      assert {:ok, _last_registration} = ToolRegistry.lookup(ctx.name)
      send(handler, :respond)
      assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    end
  end

  for {mode, tags} <- [{"graph", []}, {"assistant", [assistant: true]}] do
    @tag tags
    test "stopping a #{mode} worker cancels its pending discovery task", ctx do
      assert :ok = Worker.send_message(ctx.id, "stop during discovery")
      assert_receive {:refresh_waiting, refresh}, 5_000
      monitor = Process.monitor(refresh)
      assert :ok = Synapsis.Session.DynamicSupervisor.stop_session(ctx.id)
      assert_receive {:DOWN, ^monitor, :process, ^refresh, _reason}, 1_000
      refute_received {:provider_request, _, _}
    end
  end

  for {mode, tags} <- [{"native", [native: true]}, {"graph", []}] do
    @tag tags
    test "cancelling #{mode} discovery prevents late results from starting a request", ctx do
      assert :ok = Worker.send_message(ctx.id, "cancel during discovery")
      assert_receive {:refresh_waiting, refresh}, 5_000
      monitor = Process.monitor(refresh)
      assert :ok = Worker.cancel(ctx.id)
      assert_receive {:DOWN, ^monitor, :process, ^refresh, _reason}, 1_000
      assert :waiting = Worker.get_status(ctx.id)
      refute_received {:provider_request, _, _}
    end
  end

  defp register(name, owner, source, field) do
    :ok =
      ToolRegistry.register_process(name, owner,
        description: "MCP refresh regression",
        permission_level: :read,
        runtime_dispatch: __MODULE__,
        mcp_config_id: source,
        mcp_tool_name: "read",
        trust_annotations: true,
        parameters: %{"type" => "object", "properties" => %{field => %{"type" => "string"}}}
      )
  end
end
