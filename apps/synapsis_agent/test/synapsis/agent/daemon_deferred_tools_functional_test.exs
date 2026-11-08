defmodule Synapsis.Agent.DaemonDeferredToolsFunctionalTest do
  use Synapsis.Agent.DaemonCase, async: false

  alias Synapsis.Agent.Daemon.NativeSelection
  alias Synapsis.Agent.TestSupport.DeterministicProvider, as: Provider
  alias Synapsis.Provider.ToolName
  @moduletag :tmp_dir
  @clock "clock::curr_time"

  test "queued native discovery retains captured deferral after live config edits", ctx do
    {daemon, _} = start_test_daemon()
    {blocker, blocking_fixture} = native_agent(ctx.tmp_dir, [])
    owner = self()

    Gaoxy.Test.stub(blocking_fixture, "POST", "/v1/chat/completions", fn conn ->
      send(owner, {:queue_held, self()})

      receive do
        :release ->
          Provider.send_sse(conn, [Provider.text_chunk("released"), Provider.finish_chunk("stop")])
      after
        10_000 -> raise "queue fixture timed out"
      end
    end)

    assert {:ok, first} = Daemon.submit(daemon, "Hold queue", native_opts(blocker))
    assert_receive {:queue_held, handler}, 5_000

    {saved, fixture} =
      native_agent(ctx.tmp_dir, [@clock], %{
        config: %{
          "workspace_path" => ctx.tmp_dir,
          "deferred_tool_names" => [@clock],
          "retained" => "value"
        }
      })

    install_discovery_provider(fixture)
    assert {:ok, queued} = Daemon.submit(daemon, "Use frozen discovery", native_opts(saved))
    assert queued.status == "queued"
    assert queued.capability_snapshot["tool_names"] == [@clock]
    assert queued.capability_snapshot["sources"]["agent"]["deferred_tool_names"] == [@clock]

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(saved, %{
               config: Map.put(saved.config, "deferred_tool_names", [])
             })

    send(handler, :release)
    assert {:ok, _} = wait_for_run(first.id, "completed")
    assert {:ok, completed} = wait_for_run(queued.id, "completed")
    assert_receive {:deferred_request, 0, first_request}, 5_000
    assert tool_names(first_request) == ["tool_search"]
    assert_receive {:deferred_request, 1, published_request}, 5_000
    assert tool_names(published_request) == Enum.sort(["tool_search", ToolName.encode(@clock)])
    assert_receive {:deferred_request, 2, last_request}, 5_000

    assert Enum.any?(
             last_request["messages"],
             &(&1["role"] == "tool" and &1["tool_call_id"] == "clock")
           )

    assert completed.capability_snapshot == queued.capability_snapshot
    assert Synapsis.AgentConfigs.get(saved.id).config["deferred_tool_names"] == []
    assert Synapsis.AgentConfigs.get(saved.id).tools == [@clock]
  end

  test "older frozen source without deferred field keeps the complete initial catalog", ctx do
    {saved, _} = native_agent(ctx.tmp_dir, [@clock])
    attrs = %{assistant_name: saved.name, tool_profile: "native_agent"}
    assert {:ok, captured} = NativeSelection.capture(attrs)
    source = Map.delete(captured.capability_snapshot["sources"]["agent"], "deferred_tool_names")
    legacy = put_in(captured.capability_snapshot, ["sources", "agent"], source)
    assert {:ok, snapshot} = NativeSelection.snapshot(%{captured | capability_snapshot: legacy})

    assert {:ok, run} =
             Runs.create(
               Map.merge(attrs, %{
                 kind: "manual",
                 prompt: "Legacy frozen source",
                 capability_snapshot: snapshot
               })
             )

    assert {:ok, session} =
             Synapsis.Sessions.create(saved.name, %{
               config: %{"daemon_run_id" => run.id, "daemon_run_tool_contract_version" => 1}
             })

    on_exit(fn -> Synapsis.Sessions.delete(session.id) end)
    assert {:ok, resolved} = Synapsis.Agent.Resolver.resolve_configured(saved.name)
    overlay = NativeSelection.overlay(Map.put(resolved, :deferred_tool_names, [@clock]), session)
    assert overlay.deferred_tool_names == []
    assert {:ok, plan} = Synapsis.Agent.Tools.Discovery.plan(overlay, overlay.tools)
    assert plan.initial == [@clock]
    assert plan.runtime == [@clock]
    canonical = "mcp::#{Ecto.UUID.generate()}::read::raw"

    exact =
      snapshot
      |> Map.put("tool_names", [canonical])
      |> put_in(["sources", "agent", "tool_names"], [canonical])
      |> put_in(["sources", "agent", "deferred_tool_names"], [canonical])

    assert {:ok, ^exact} = NativeSelection.snapshot(%{captured | capability_snapshot: exact})
  end

  defp install_discovery_provider(fixture) do
    owner = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    Gaoxy.Test.stub(fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      index = Agent.get_and_update(counter, &{&1, &1 + 1})
      send(owner, {:deferred_request, index, request})

      case index do
        0 ->
          Provider.send_sse(conn, [
            Provider.tool_call_chunk("tool_search", "discover", %{
              "query" => "clock",
              "limit" => 1
            }),
            Provider.finish_chunk("tool_calls")
          ])

        1 ->
          Provider.send_sse(conn, [
            Provider.tool_call_chunk(ToolName.encode(@clock), "clock", %{}),
            Provider.finish_chunk("tool_calls")
          ])

        _ ->
          Provider.send_sse(conn, [
            Provider.text_chunk("discovery complete"),
            Provider.finish_chunk("stop")
          ])
      end
    end)
  end

  defp tool_names(request),
    do: Enum.sort(Enum.map(request["tools"] || [], & &1["function"]["name"]))

  def native_agent(root, tools, extra \\ %{}) do
    fixture = Gaoxy.Test.open()
    suffix = Ecto.UUID.generate()
    provider = "native-daemon-#{suffix}"

    assert :ok =
             Synapsis.Provider.Registry.register(provider, %{
               type: "openai",
               api_key: "test-key",
               base_url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
             })

    assert {:ok, saved} =
             Synapsis.AgentConfigs.create(
               Map.merge(
                 %{
                   name: "native-daemon-#{suffix}",
                   provider: provider,
                   model: "native-daemon-model",
                   tools: tools,
                   tool_contract_version: 1,
                   permission_mode: "yolo",
                   config: %{"workspace_path" => root}
                 },
                 extra
               )
             )

    on_exit(fn ->
      for run <- Runs.list_recent(limit: 100),
          run.assistant_name == saved.name,
          is_binary(run.session_id),
          do: Synapsis.Sessions.delete(run.session_id)

      Synapsis.AgentConfigs.delete(saved)
      Synapsis.Provider.Registry.unregister(provider)
    end)

    {saved, fixture}
  end

  def native_opts(saved), do: %{assistant_name: saved.name, tool_profile: "native_agent"}
end
