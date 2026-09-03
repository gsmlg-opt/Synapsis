defmodule Synapsis.Session.ReleaseReadinessTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.DeterministicProvider
  alias Synapsis.Session.{DynamicSupervisor, Read, Snapshot, Worker}

  defmodule GoldenTool do
    use Synapsis.Tool

    @impl true
    def name, do: "release_readiness_echo"

    @impl true
    def description, do: "Returns deterministic release-readiness evidence."

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "string"}},
        "required" => ["value"]
      }
    end

    @impl true
    def permission_level, do: :read

    @impl true
    def execute(%{"value" => value}, _context) do
      counter = Application.fetch_env!(:synapsis_agent, :release_readiness_counter)

      Agent.update(counter, fn state ->
        %{state | tool_executions: state.tool_executions + 1}
      end)

      {:ok, "golden tool result: #{value}"}
    end
  end

  @tag :tmp_dir
  test "a permission-checked tool turn survives a session-tree restart without duplication", %{
    tmp_dir: tmp_dir
  } do
    suffix = System.unique_integer([:positive, :monotonic])
    provider_name = "release_readiness_provider_#{suffix}"
    tool_name = "release_readiness_echo_#{suffix}"
    agent_name = "release_readiness_agent_#{suffix}"
    tool_call_id = "golden-call-1"
    previous_counter = Application.get_env(:synapsis_agent, :release_readiness_counter, :missing)

    {:ok, counter} = Agent.start_link(fn -> %{provider_requests: [], tool_executions: 0} end)
    Application.put_env(:synapsis_agent, :release_readiness_counter, counter)

    on_exit(fn ->
      restore_application_env(:release_readiness_counter, previous_counter)

      if Process.alive?(counter) do
        Agent.stop(counter)
      end
    end)

    bypass = Bypass.open()

    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      request_number =
        Agent.get_and_update(counter, fn state ->
          requests = state.provider_requests ++ [request]
          {length(requests), %{state | provider_requests: requests}}
        end)

      case request_number do
        1 ->
          DeterministicProvider.send_sse(conn, [
            DeterministicProvider.tool_call_chunk(tool_name, tool_call_id, %{
              "value" => "verified"
            }),
            DeterministicProvider.finish_chunk("tool_calls")
          ])

        2 ->
          DeterministicProvider.send_sse(conn, [
            DeterministicProvider.text_chunk("golden path complete"),
            DeterministicProvider.finish_chunk("stop")
          ])

        _unexpected ->
          Plug.Conn.send_resp(conn, 500, "unexpected provider request")
      end
    end)

    :ok =
      Synapsis.Provider.Registry.register(provider_name, %{
        type: "openai",
        api_key: "test-key",
        base_url: "http://localhost:#{bypass.port}"
      })

    on_exit(fn -> Synapsis.Provider.Registry.unregister(provider_name) end)

    :ok = Synapsis.Tool.Registry.register_module(tool_name, GoldenTool)
    on_exit(fn -> Synapsis.Tool.Registry.unregister(tool_name) end)

    assert {:ok, agent_config} =
             Synapsis.AgentConfigs.create(%{
               name: agent_name,
               label: "Release Readiness",
               provider: provider_name,
               model: "golden-model",
               tools: [tool_name],
               permission_mode: "restrict",
               config: %{"workspace_path" => tmp_dir}
             })

    on_exit(fn -> Synapsis.AgentConfigs.delete(agent_config) end)

    assert {:ok, session} =
             Synapsis.Sessions.create(agent_name, %{
               agent: agent_name,
               provider: provider_name,
               model: "golden-model"
             })

    on_exit(fn ->
      DynamicSupervisor.stop_session(session.id)
      Synapsis.Sessions.delete(session.id)
    end)

    assert :ok = Synapsis.Sessions.ensure_running(session.id)
    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}")

    assert :requires_approval =
             Synapsis.Tool.Permission.check(tool_name, %{"value" => "verified"}, %{
               session_id: session.id
             })

    assert :ok = Synapsis.Sessions.send_message(session.id, "run the golden tool")

    assert_receive {"permission_requests",
                    %{
                      tools: [
                        %{
                          tool: ^tool_name,
                          tool_use_id: ^tool_call_id,
                          input: %{"value" => "verified"}
                        }
                      ]
                    }},
                   10_000

    assert :ok = Synapsis.Sessions.approve_tool(session.id, tool_call_id)

    assert_receive {"tool_result",
                    %{
                      tool_use_id: ^tool_call_id,
                      content: "golden tool result: verified",
                      is_error: false
                    }},
                   10_000

    assert_receive {"done", %{}}, 10_000
    assert_receive {"session_status", %{status: "idle"}}, 10_000
    assert :waiting = Worker.get_status(session.id)

    assert {:ok, durable} =
             wait_for(fn ->
               case Snapshot.rehydrate(session.id) do
                 {:ok, %{meta: %{status: "idle"}, turns: turns} = snapshot}
                 when length(turns) == 4 ->
                   {:ok, snapshot}

                 _other ->
                   :retry
               end
             end)

    assert length(durable.turns) == 4
    messages_before_restart = Synapsis.Sessions.get_messages(session.id)
    assert_golden_transcript(messages_before_restart, tool_name, tool_call_id)
    assert_counters(counter)

    assert :ok = DynamicSupervisor.stop_session(session.id)
    refute Read.live?(session.id)

    assert {:durable, %{turns: turns_while_stopped}} = Read.live_snapshot(session.id)
    assert length(turns_while_stopped) == 4

    assert :ok = Synapsis.Sessions.ensure_running(session.id)

    assert {:ok, true} =
             wait_for(fn -> if Read.live?(session.id), do: {:ok, true}, else: :retry end)

    assert :waiting = Worker.get_status(session.id)

    messages_after_restart = Synapsis.Sessions.get_messages(session.id)
    assert messages_after_restart == messages_before_restart
    assert_golden_transcript(messages_after_restart, tool_name, tool_call_id)
    assert_counters(counter)
  end

  defp assert_golden_transcript(messages, tool_name, tool_call_id) do
    assert Enum.map(messages, & &1.role) == ["user", "assistant", "user", "assistant"]

    parts = Enum.flat_map(messages, & &1.parts)

    assert Enum.count(parts, &match?(%Synapsis.Part.Text{content: "run the golden tool"}, &1)) ==
             1

    assert Enum.count(parts, fn
             %Synapsis.Part.ToolUse{
               tool: ^tool_name,
               tool_use_id: ^tool_call_id,
               input: %{"value" => "verified"},
               status: :completed
             } ->
               true

             _other ->
               false
           end) == 1

    assert Enum.count(parts, fn
             %Synapsis.Part.ToolResult{
               tool_use_id: ^tool_call_id,
               content: "golden tool result: verified",
               is_error: false
             } ->
               true

             _other ->
               false
           end) == 1

    assert Enum.count(parts, &match?(%Synapsis.Part.Text{content: "golden path complete"}, &1)) ==
             1
  end

  defp assert_counters(counter) do
    %{provider_requests: requests, tool_executions: tool_executions} = Agent.get(counter, & &1)

    assert length(requests) == 2
    assert tool_executions == 1

    [first_request, second_request] = requests
    assert Jason.encode!(first_request) =~ "run the golden tool"
    assert Jason.encode!(second_request) =~ "golden-call-1"
    assert Jason.encode!(second_request) =~ "golden tool result: verified"
  end

  defp wait_for(fun, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for(fun, deadline)
  end

  defp do_wait_for(fun, deadline) do
    case fun.() do
      {:ok, _value} = result ->
        result

      :retry ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(25)
          do_wait_for(fun, deadline)
        else
          flunk("condition did not become true before timeout")
        end
    end
  end

  defp restore_application_env(key, :missing), do: Application.delete_env(:synapsis_agent, key)
  defp restore_application_env(key, value), do: Application.put_env(:synapsis_agent, key, value)
end
