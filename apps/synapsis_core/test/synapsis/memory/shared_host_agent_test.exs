defmodule Synapsis.Memory.SharedHostAgentTest do
  use ExUnit.Case, async: false

  alias Synapsis.Memory.HostAgent

  setup do
    server = Gaoxy.Test.open()

    source = %{
      id: "backplane-host",
      endpoint: String.trim_trailing(Gaoxy.Test.url(server), "/"),
      agent_id: "synapsis"
    }

    %{server: server, source: source}
  end

  test "initialize uses the actual app version and returns only bounded instructions", ctx do
    owner = self()

    Gaoxy.Test.expect_once(ctx.server, "POST", "/memory/synapsis/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Formata.JSON.decode!(body)
      send(owner, {:initialize, payload})

      Plug.Conn.resp(
        conn,
        200,
        Formata.JSON.encode!(%{
          jsonrpc: "2.0",
          id: payload["id"],
          result: %{instructions: "Search memory before exploration."}
        })
      )
    end)

    assert {:ok, "Search memory before exploration."} = HostAgent.instructions(ctx.source)
    assert_receive {:initialize, %{"method" => "initialize", "params" => params}}
    assert params["clientInfo"]["version"] == to_string(Application.spec(:synapsis_core, :vsn))
    assert params["clientInfo"]["name"] == "synapsis"
  end

  test "search uses current route and preserves provenance without inventing authority", ctx do
    record = %{
      "id" => "record-a",
      "content" => "Use Concord",
      "kind" => "fact",
      "observed_at" => "2026-11-18T00:00:00Z",
      "provenance" => %{"host" => "other-host", "agent" => "codex"}
    }

    expect_call(ctx, "search", %{"query" => "Concord", "limit" => 3}, %{
      results: [record],
      offline: true,
      source: "local"
    })

    assert {:ok, public} = HostAgent.search(ctx.source, "Concord", limit: 3)
    assert public.results == [record]
    assert public.offline
    assert public.host_source == "local"
    refute Map.has_key?(public, :authority)
    refute Map.has_key?(public, :consistency)
  end

  test "five supported direct methods retain their exact payload including provenance", ctx do
    for {name, arguments} <- [
          {"memory::search",
           %{"query" => "deploy", "host" => "other-host", "kind" => "procedure"}},
          {"memory::get", %{"id" => "host-local:42"}},
          {"memory::recent", %{"agent" => "codex"}},
          {"memory::remember",
           %{
             "content" => "Use Concord",
             "session_id" => "session-a",
             "subjects" => [%{"type" => "repo", "key" => "Synapsis"}]
           }},
          {"memory::forget", %{"id" => "host-local:42", "reason" => "outdated"}}
        ] do
      expect_call(ctx, String.replace_prefix(name, "memory::", ""), arguments, %{echo: arguments})
      assert {:ok, %{"echo" => ^arguments}} = HostAgent.call(ctx.source, name, arguments)
    end
  end

  test "unknown and retired methods are rejected without HTTP", ctx do
    for name <- ["memory::recall", "memory::slot_write", "other", nil] do
      assert {:error, :invalid_input} = HostAgent.call(ctx.source, name, %{})
    end

    assert Gaoxy.Test.requests(ctx.server).entries == []
  end

  test "shared calls retain fixed not-found errors and do not retry transport failures", ctx do
    Gaoxy.Test.expect_once(ctx.server, "POST", "/memory/synapsis/call/get", fn conn ->
      Plug.Conn.resp(conn, 404, Formata.JSON.encode!(%{ok: false, error: "not_found"}))
    end)

    assert {:error, :not_found} = HostAgent.call(ctx.source, "memory::get", %{"id" => "missing"})

    Gaoxy.Test.expect_once(ctx.server, "POST", "/memory/synapsis/call/remember", fn conn ->
      Plug.Conn.resp(conn, 503, "private failure details")
    end)

    assert {:error, :unavailable} =
             HostAgent.call(ctx.source, "memory::remember", %{"content" => "durable"})

    assert length(Gaoxy.Test.requests(ctx.server).entries) == 2
  end

  test "expired deadlines, invalid transport overrides and excessive input cause no HTTP", ctx do
    for opts <- [
          [deadline: System.monotonic_time(:millisecond) - 1],
          [timeout: 0],
          [url: "http://other"]
        ] do
      assert {:error, _} = HostAgent.call(ctx.source, "memory::search", %{"query" => "q"}, opts)
    end

    assert {:error, :invalid_input} =
             HostAgent.call(ctx.source, "memory::remember", %{
               "content" => String.duplicate("x", 65_537)
             })

    assert Gaoxy.Test.requests(ctx.server).entries == []
  end

  test "modern reads preserve empty success but reject malformed or unbounded record lists",
       ctx do
    expect_call(ctx, "search", %{"query" => "q", "limit" => 5}, %{results: []})
    assert {:ok, %{results: [], offline: false}} = HostAgent.search(ctx.source, "q")
  end

  test "modern reads reject malformed records", ctx do
    expect_call(ctx, "search", %{"query" => "q", "limit" => 5}, %{
      results: [%{content: "missing id"}]
    })

    assert {:error, :malformed_result} = HostAgent.search(ctx.source, "q")
  end

  test "modern reads reject lists exceeding the requested limit", ctx do
    expect_call(ctx, "search", %{"query" => "q", "limit" => 1}, %{
      results: [%{id: "a", content: "a"}, %{id: "b", content: "b"}]
    })

    assert {:error, :malformed_result} = HostAgent.search(ctx.source, "q", limit: 1)
  end

  test "shared calls inherit the bounded HTTP reader's raw and public size limits", ctx do
    Gaoxy.Test.expect_once(ctx.server, "POST", "/memory/synapsis/call/search", fn conn ->
      Plug.Conn.resp(conn, 200, String.duplicate("x", 262_145))
    end)

    assert {:error, :response_limit} =
             HostAgent.call(ctx.source, "memory::search", %{"query" => "q"})
  end

  test "shared calls enforce the public output size limit", ctx do
    expect_call(ctx, "search", %{"query" => "q"}, %{
      results: [%{content: String.duplicate("x", 65_537)}]
    })

    assert {:error, :output_limit} =
             HostAgent.call(ctx.source, "memory::search", %{"query" => "q"})
  end

  test "MCP result correlation and complete five-tool inventory are required", ctx do
    Gaoxy.Test.expect_once(ctx.server, "POST", "/memory/synapsis/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Formata.JSON.decode!(body)

      Plug.Conn.resp(
        conn,
        200,
        Formata.JSON.encode!(%{jsonrpc: "2.0", id: request["id"], result: %{tools: []}})
      )
    end)

    assert {:error, :malformed_result} = HostAgent.catalog(ctx.source)
  end

  test "MCP results must correlate with the actual request ID", ctx do
    Gaoxy.Test.expect_once(ctx.server, "POST", "/memory/synapsis/mcp", fn conn ->
      Plug.Conn.resp(
        conn,
        200,
        Formata.JSON.encode!(%{jsonrpc: "2.0", id: "foreign", result: %{instructions: "foreign"}})
      )
    end)

    assert {:error, :malformed_result} = HostAgent.instructions(ctx.source)
  end

  defp expect_call(ctx, method, arguments, result) do
    Gaoxy.Test.expect_once(ctx.server, "POST", "/memory/synapsis/call/" <> method, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Formata.JSON.decode!(body) == arguments
      Plug.Conn.resp(conn, 200, Formata.JSON.encode!(%{ok: true, result: result}))
    end)
  end
end
