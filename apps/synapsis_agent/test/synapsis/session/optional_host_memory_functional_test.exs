defmodule Synapsis.Session.OptionalHostMemoryFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional
  @moduletag :tmp_dir

  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.HostMemory
  alias Synapsis.Config.Store
  alias Synapsis.Memory.Settings
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.Worker

  setup do
    previous = Store.get(:memory, "default")
    host = Gaoxy.Test.open()
    online = start_supervised!({Agent, fn -> false end})

    assert {:ok, saved} =
             Settings.save(%{
               "backend" => "workspace",
               "host_agent" => %{
                 "enabled" => true,
                 "endpoint" => String.trim_trailing(Gaoxy.Test.url(host), "/"),
                 "agent_id" => "optional-memory"
               }
             })

    on_exit(fn ->
      case previous do
        {:ok, entry} -> Store.put(:memory, entry)
        {:error, :not_found} -> Store.delete(:memory, "default")
      end
    end)

    Gaoxy.Test.stub(host, "POST", "/memory/optional-memory/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Formata.JSON.decode!(body)

      if Agent.get(online, & &1) do
        result =
          case request["method"] do
            "initialize" ->
              %{instructions: "Shared memory is available."}

            "tools/list" ->
              %{
                tools:
                  Enum.map(HostMemory.names(), fn name ->
                    %{
                      name: name,
                      description: "Shared " <> name,
                      inputSchema: %{
                        type: "object",
                        properties: %{id: %{type: "string"}},
                        required: ["id"],
                        additionalProperties: false
                      }
                    }
                  end)
              }
          end

        Plug.Conn.resp(
          conn,
          200,
          Formata.JSON.encode!(%{jsonrpc: "2.0", id: request["id"], result: result})
        )
      else
        Plug.Conn.resp(conn, 503, "offline")
      end
    end)

    for hook <- ~w(session-start user-prompt-submit post-tool-use session-end) do
      Gaoxy.Test.stub(host, "POST", "/capture/v1/hooks/synapsis/" <> hook, fn conn ->
        Plug.Conn.resp(conn, 503, "offline")
      end)
    end

    %{host: host, online: online, saved: saved}
  end

  test "ordinary chat completes offline and the same session uses recovered host schemas next turn",
       %{tmp_dir: root} = ctx do
    h = harness(root)
    test = self()

    Gaoxy.Test.expect_once(ctx.host, "POST", "/memory/optional-memory/call/get", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Formata.JSON.decode!(body) == %{"id" => "record-a"}
      send(test, :recovered_memory_read)

      Plug.Conn.resp(
        conn,
        200,
        Formata.JSON.encode!(%{ok: true, result: %{record: %{id: "record-a"}}})
      )
    end)

    Gaoxy.Test.stub(h.provider.fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Formata.JSON.decode!(body)

      tool =
        Enum.find(request["tools"], &(&1["name"] == ToolName.encode("memory::get")))

      cond do
        Enum.any?(request["input"], &(&1["type"] == "function_call_output")) ->
          text(conn, "memory recovered")

        Formata.JSON.encode!(request["input"]) =~ "recover now" ->
          assert tool["parameters"]["required"] == ["id"]
          tool_call(conn, %{"id" => "record-a"})

        true ->
          assert tool["description"] =~ "temporarily unavailable"
          text(conn, "ordinary chat works")
      end
    end)

    assert :ok = Worker.send_message(h.session.id, "ordinary chat")
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    SessionHarness.await_waiting!(h.session.id)
    refute_received :recovered_memory_read

    Agent.update(ctx.online, fn _ -> true end)
    assert :ok = Worker.send_message(h.session.id, "recover now")
    assert_receive :recovered_memory_read, 15_000
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert {:ok, settings} = Settings.get()
    assert settings == ctx.saved
    assert Synapsis.AgentConfigs.get(h.agent_config.id).tools == ["memory::get"]
  end

  test "an unavailable memory tool returns an explicit error and the model still completes",
       %{tmp_dir: root} = ctx do
    h = harness(root)
    test = self()

    Gaoxy.Test.stub(h.provider.fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Formata.JSON.decode!(body)

      case Enum.find(request["input"], &(&1["type"] == "function_call_output")) do
        nil ->
          tool_call(conn, %{})

        result ->
          assert result["content"] =~ "temporarily unavailable"
          send(test, :availability_error_delivered)
          text(conn, "I can continue without shared memory")
      end
    end)

    assert :ok = Worker.send_message(h.session.id, "try memory then continue")
    assert_receive :availability_error_delivered, 15_000
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000

    refute Enum.any?(Gaoxy.Test.requests(ctx.host).entries, fn entry ->
             String.contains?(entry.path, "/call/")
           end)
  end

  defp harness(root) do
    h =
      SessionHarness.setup_session!(
        tmp_dir: root,
        tool_name: "memory::get",
        install_provider?: false
      )

    on_exit(fn -> SessionHarness.cleanup!(h) end)
    SessionHarness.ensure_running!(h.session.id)
    SessionHarness.subscribe!(h.session.id)
    h
  end

  defp text(conn, content) do
    DeterministicProvider.send_sse(conn, [
      DeterministicProvider.text_chunk(content),
      DeterministicProvider.finish_chunk("stop")
    ])
  end

  defp tool_call(conn, arguments) do
    DeterministicProvider.send_sse(conn, [
      DeterministicProvider.tool_call_chunk(
        ToolName.encode("memory::get"),
        "optional-get",
        arguments
      ),
      DeterministicProvider.finish_chunk("tool_calls")
    ])
  end
end
