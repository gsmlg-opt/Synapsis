defmodule Synapsis.Memory.HostAgentTest do
  use ExUnit.Case, async: false

  alias Synapsis.Memory.HostAgent

  setup do
    server = Gaoxy.Test.open()

    source = %{
      id: "local-host",
      endpoint: String.trim_trailing(Gaoxy.Test.url(server), "/"),
      agent_id: "synapsis"
    }

    %{server: server, source: source}
  end

  test "posts only query and limit to the host recall route and preserves real IDs", ctx do
    parent = self()

    Gaoxy.Test.expect_once(ctx.server, "POST", "/memory/synapsis/call/recall", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:request, Jason.decode!(body), conn.req_headers})

      reply(
        conn,
        online([%{"id" => "record-1", "content" => "Use Concord", "secret" => "hidden"}])
      )
    end)

    assert {:ok, %{hits: [record], source: source, mode: "online"}} =
             HostAgent.recall(ctx.source, "Concord", limit: 3)

    assert record.memory_id == "record-1"
    assert record.content == "Use Concord"

    assert record.citation == %{
             source_id: "local-host",
             endpoint: ctx.source.endpoint,
             memory_id: "record-1"
           }

    assert source == %{id: "local-host", endpoint: ctx.source.endpoint, partition: "host_default"}
    refute inspect(record) =~ "hidden"
    assert_receive {:request, %{"query" => "Concord", "limit" => 3} = body, headers}
    assert map_size(body) == 2

    refute Enum.any?(headers, fn {name, _} -> name in ["authorization", "cookie", "x-api-key"] end)
  end

  test "host HTTP never inherits unrelated default authorization or cookies", ctx do
    defaults = [
      auth: {:bearer, "unrelated-default-token"},
      headers: [{"cookie", "unrelated-session=secret"}, {"x-api-key", "unrelated-api-key"}]
    ]

    set_req_defaults(defaults)
    parent = self()

    Gaoxy.Test.expect_once(ctx.server, "POST", "/memory/synapsis/call/recall", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:clean_request, conn.req_headers, Jason.decode!(body)})
      reply(conn, online([]))
    end)

    assert {:ok, %{hits: []}} = HostAgent.recall(ctx.source, "q")
    assert_receive {:clean_request, headers, %{"query" => "q", "limit" => 5}}

    refute Enum.any?(headers, fn {name, _} -> name in ["authorization", "cookie", "x-api-key"] end)

    assert Application.fetch_env(:req, :default_options) == {:ok, defaults}
  end

  for hook <- [:adapter, :plugin, :finch_request] do
    @hook hook
    test "host HTTP bypasses global #{hook} hooks while reaching the real fixture", ctx do
      parent = self()

      defaults =
        case @hook do
          :adapter ->
            [
              adapter: fn request ->
                send(parent, {:inherited_global_hook, :adapter})
                Req.Finch.run(request)
              end
            ]

          :plugin ->
            [
              plugins: [
                fn request ->
                  send(parent, {:inherited_global_hook, :plugin})
                  request
                end
              ]
            ]

          :finch_request ->
            [
              finch_request: fn request, _finch_request, _finch_name, _finch_options ->
                send(parent, {:inherited_global_hook, :finch_request})
                request |> Req.Request.delete_option(:finch_request) |> Req.Finch.run()
              end
            ]
        end

      set_req_defaults(defaults)

      Gaoxy.Test.expect_once(ctx.server, "POST", "/memory/synapsis/call/recall", fn conn ->
        send(parent, :actual_host_http)
        reply(conn, online([]))
      end)

      assert {:ok, %{hits: []}} = HostAgent.recall(ctx.source, "q")
      assert_receive :actual_host_http
      refute_receive {:inherited_global_hook, _}
      assert Application.fetch_env(:req, :default_options) == {:ok, defaults}
    end
  end

  test "only literal HTTP loopback endpoints and exact trusted source fields are accepted", ctx do
    for endpoint <- [
          "http://localhost:4222",
          "https://127.0.0.1:4222",
          "http://127.1:4222",
          "http://2130706433",
          "http://127.0.0.2:4222",
          "http://example.com",
          "http://user:secret@127.0.0.1:4222",
          "http://127.0.0.1:4222/",
          "http://127.0.0.1:4222/path",
          "http://127.0.0.1:4222?query=x",
          "http://127.0.0.1:4222#fragment",
          "http://127.0.0.1:0",
          "http://127.0.0.1:65536",
          "http://127.0.0.1:bad",
          "http://127.0.0.1:"
        ] do
      assert {:error, :invalid_source} =
               HostAgent.validate_source(%{ctx.source | endpoint: endpoint})
    end

    for key <- [:token, :project_id, :session_id, :memory_access_id, :scope, :authority] do
      assert {:error, :invalid_source} =
               HostAgent.validate_source(Map.put(ctx.source, key, "secret"))
    end

    for id <- [nil, "../outside", "x/y", "", String.duplicate("a", 129)] do
      assert {:error, :invalid_source} = HostAgent.validate_source(%{ctx.source | id: id})
      assert {:error, :invalid_source} = HostAgent.validate_source(%{ctx.source | agent_id: id})
    end

    for endpoint <- [
          "http://127.0.0.1",
          "http://127.0.0.1:4222",
          "http://[::1]",
          "http://[::1]:4222"
        ] do
      assert :ok = HostAgent.validate_source(%{ctx.source | endpoint: endpoint})
    end

    assert {:error, :invalid_source} = HostAgent.validate_source(nil)
  end

  test "invalid arguments and transport option overrides fail before HTTP", ctx do
    for query <- [nil, "", <<255>>, String.duplicate("é", 1025)] do
      assert {:error, :invalid_input} = HostAgent.recall(ctx.source, query)
    end

    for opts <- [
          [limit: 0],
          [limit: 21],
          [limit: 1.0],
          [scope: "shared"],
          [agent_id: "other"],
          [headers: [{"authorization", "secret"}]],
          [timeout: 0],
          [timeout: 10_001],
          [deadline: "tomorrow"],
          [limit: 1, limit: 2]
        ] do
      assert {:error, :invalid_input} = HostAgent.recall(ctx.source, "query", opts)
    end
  end

  test "empty success is explicit and outages never become empty results", ctx do
    Gaoxy.Test.expect_once(
      ctx.server,
      "POST",
      "/memory/synapsis/call/recall",
      &reply(&1, online([]))
    )

    assert {:ok, %{hits: [], history_available: true}} = HostAgent.recall(ctx.source, "absent")
    Gaoxy.Test.close(ctx.server)
    assert {:error, :unavailable} = HostAgent.recall(ctx.source, "absent", timeout: 200)
  end

  test "preserves offline and provisional state and normalized record metadata", ctx do
    record = %{
      "id" => "pending-1",
      "content" => "pending insight",
      "provisional" => true,
      "authority" => "provisional",
      "canonical_id" => nil,
      "metadata" => %{"secret" => "hidden"}
    }

    state = %{
      "mode" => "offline",
      "authority" => "provisional",
      "consistency" => "provisional_only",
      "stale" => true,
      "history_available" => false,
      "pending_operations" => 1,
      "hits" => [record],
      "results" => [record],
      "upserts" => [record],
      "source" => "provisional_commands",
      "as_of" => nil,
      "partition_revision" => nil,
      "last_sync_age_seconds" => nil,
      "overlay_truncated" => false
    }

    Gaoxy.Test.expect_once(ctx.server, "POST", "/memory/synapsis/call/recall", &reply(&1, state))
    assert {:ok, public} = HostAgent.recall(ctx.source, "insight")
    assert public.mode == "offline"
    assert public.authority == "provisional"
    assert public.consistency == "provisional_only"
    assert public.stale
    refute public.history_available
    assert public.pending_operations == 1
    assert [%{provisional: true, authority: "provisional", memory_id: "pending-1"}] = public.hits
    refute inspect(public) =~ "secret"
  end

  test "accepts canonical mirror and online provisional overlay states", _ctx do
    for state <- [
          Map.merge(online([]), %{
            "mode" => "offline",
            "consistency" => "bounded_stale",
            "stale" => true
          }),
          Map.merge(online([]), %{
            "authority" => "canonical_with_provisional",
            "consistency" => "read_your_writes",
            "pending_operations" => 1
          }),
          Map.merge(online([]), %{
            "mode" => "offline",
            "authority" => "canonical_with_provisional",
            "consistency" => "bounded_stale",
            "pending_operations" => 1,
            "stale" => true
          })
        ] do
      ctx = fixture()

      Gaoxy.Test.expect_once(
        ctx.server,
        "POST",
        "/memory/synapsis/call/recall",
        &reply(&1, state)
      )

      assert {:ok, _} = HostAgent.recall(ctx.source, "q")
    end
  end

  test "rejects malformed envelopes and domain errors without leaking payloads", _ctx do
    for {body, reason} <- [
          {"not-json secret", :invalid_json},
          {Jason.encode!(%{"ok" => false, "error" => "token-secret"}), :host_error},
          {Jason.encode!(%{"result" => online([])}), :malformed_result},
          {Jason.encode!(%{"ok" => true, "result" => []}), :malformed_result},
          {Jason.encode!(%{"ok" => "true", "result" => online([])}), :malformed_result}
        ] do
      ctx = fixture()

      Gaoxy.Test.expect_once(
        ctx.server,
        "POST",
        "/memory/synapsis/call/recall",
        &Plug.Conn.resp(&1, 200, body)
      )

      assert {:error, ^reason} = HostAgent.recall(ctx.source, "q")
    end
  end

  test "rejects malformed or contradictory state and records", _ctx do
    invalid = [
      Map.delete(online([]), "mode"),
      Map.put(online([]), "pending_operations", -1),
      Map.put(online([]), "stale", true),
      Map.put(online([]), "history_available", false),
      Map.put(online([]), "authority", "untrusted"),
      Map.put(online([]), "consistency", "eventual"),
      Map.put(online([]), "pending_operations", 1),
      Map.put(online([]), "overlay_truncated", "false"),
      Map.put(online([]), "partition_revision", -1),
      Map.put(online([]), "last_sync_age_seconds", "old"),
      Map.put(online([]), "as_of", "yesterday"),
      Map.put(online([]), "hits", %{}),
      online([%{"id" => "../bad", "content" => "c"}]),
      online([%{"id" => "one", "content" => 2}]),
      online([%{"id" => "one", "memory_id" => "two", "content" => "c"}]),
      online([%{"content" => "c"}]),
      online([%{"id" => "one", "content" => "c", "provisional" => "true"}]),
      online([
        %{"id" => "one", "content" => "c", "authority" => "provisional", "provisional" => false}
      ]),
      online([%{"id" => "one", "content" => "c", "confidence" => "high"}]),
      online([%{"id" => "one", "content" => "c"}, %{"id" => "one", "content" => "c"}]),
      Map.put(online([]), "results", [%{"id" => "other", "content" => "disagrees"}]),
      online(Enum.map(1..6, &%{"id" => "r-#{&1}", "content" => "c"}))
    ]

    for state <- invalid do
      ctx = fixture()

      Gaoxy.Test.expect_once(
        ctx.server,
        "POST",
        "/memory/synapsis/call/recall",
        &reply(&1, state)
      )

      assert {:error, :malformed_result} = HostAgent.recall(ctx.source, "q")
    end
  end

  test "accepts upstream disputed lifecycle and mirror metadata, rejecting unknown lifecycle",
       ctx do
    state =
      Map.merge(
        online([
          %{
            "canonical_id" => "canonical-one",
            "memory_type" => "semantic",
            "content" => "disputed insight",
            "content_hash" => "sha256:" <> String.duplicate("a", 64),
            "confidence" => 0.8,
            "lifecycle_state" => "disputed",
            "tags" => ["storage"],
            "metadata" => %{},
            "source_refs" => [],
            "server_revision" => 7,
            "edge_expires_at" => nil
          }
        ]),
        %{
          "mode" => "offline",
          "consistency" => "bounded_stale",
          "stale" => true,
          "source" => "edge_mirror",
          "overlay_truncated" => true,
          "partition_revision" => 7,
          "last_sync_age_seconds" => 12,
          "as_of" => "2026-10-23T12:00:00Z",
          "acknowledged_operations" => 1
        }
      )

    Gaoxy.Test.expect_once(ctx.server, "POST", "/memory/synapsis/call/recall", &reply(&1, state))
    assert {:ok, public} = HostAgent.recall(ctx.source, "q")

    assert [
             %{
               lifecycle_state: "disputed",
               memory_id: "canonical-one",
               canonical_id: "canonical-one",
               citation: citation
             }
           ] = public.hits

    assert citation == %{
             source_id: "local-host",
             endpoint: ctx.source.endpoint,
             memory_id: "canonical-one"
           }

    assert public.overlay_truncated
    assert public.partition_revision == 7
    assert public.last_sync_age_seconds == 12
    assert public.as_of == "2026-10-23T12:00:00Z"
    assert public.acknowledged_operations == 1
    assert public.host_source == "edge_mirror"

    ctx = fixture()

    Gaoxy.Test.expect_once(
      ctx.server,
      "POST",
      "/memory/synapsis/call/recall",
      &reply(&1, online([%{"id" => "one", "content" => "c", "lifecycle_state" => "verified"}]))
    )

    assert {:error, :malformed_result} = HostAgent.recall(ctx.source, "q")
  end

  test "normalizes mixed upstream corpus without conflating local and canonical identities",
       ctx do
    records = [
      %{
        "canonical_id" => "mirror-one",
        "content" => "mirror insight",
        "lifecycle_state" => "disputed"
      },
      %{
        "id" => "v2-one",
        "content" => "canonical pipeline insight",
        "kind" => "memory",
        "final_score" => 0.7
      },
      %{"memory_id" => "legacy-one", "content" => "legacy insight"},
      %{
        "id" => "local-one",
        "memory_id" => "local-one",
        "canonical_id" => "remote-one",
        "content" => "local pending insight",
        "authority" => "provisional",
        "provisional" => true
      }
    ]

    state =
      Map.merge(online(records), %{
        "authority" => "canonical_with_provisional",
        "consistency" => "read_your_writes",
        "pending_operations" => 1
      })

    Gaoxy.Test.expect_once(ctx.server, "POST", "/memory/synapsis/call/recall", &reply(&1, state))
    assert {:ok, %{hits: hits}} = HostAgent.recall(ctx.source, "insight")
    assert Enum.map(hits, & &1.memory_id) == ["mirror-one", "v2-one", "legacy-one", "local-one"]

    assert Enum.map(hits, & &1.citation.memory_id) == [
             "mirror-one",
             "v2-one",
             "legacy-one",
             "local-one"
           ]

    assert List.last(hits).canonical_id == "remote-one"
    assert List.last(hits).provisional
  end

  test "canonical fallback never hides null or malformed preferred identity aliases", _ctx do
    for record <- [
          %{"canonical_id" => nil},
          %{"canonical_id" => "../invalid"},
          %{"id" => nil, "canonical_id" => "valid"},
          %{"memory_id" => nil, "canonical_id" => "valid"},
          %{"id" => "", "canonical_id" => "valid"},
          %{"id" => "../invalid", "canonical_id" => "valid"},
          %{"id" => "valid", "memory_id" => nil, "canonical_id" => "valid"},
          %{"id" => "first", "memory_id" => "second", "canonical_id" => "canonical"}
        ] do
      ctx = fixture()

      Gaoxy.Test.expect_once(
        ctx.server,
        "POST",
        "/memory/synapsis/call/recall",
        &reply(&1, online([Map.put(record, "content", "insight")]))
      )

      assert {:error, :malformed_result} = HostAgent.recall(ctx.source, "q")
    end
  end

  test "memory_id variant preserves identity and whitelist excludes ownership fields", ctx do
    record = %{
      "memory_id" => "one",
      "content" => "text",
      "project" => "not authority",
      "agent_id" => "not isolation"
    }

    Gaoxy.Test.expect_once(
      ctx.server,
      "POST",
      "/memory/synapsis/call/recall",
      &reply(&1, online([record]))
    )

    assert {:ok, %{hits: [%{memory_id: "one"} = hit]}} = HostAgent.recall(ctx.source, "q")
    refute Map.has_key?(hit, :project)
    refute Map.has_key?(hit, :agent_id)
  end

  test "HTTP errors and redirects are fixed codes with no retries or forwarding", _ctx do
    for {status, reason} <- [
          {301, :redirect},
          {307, :redirect},
          {401, :unauthorized},
          {403, :unauthorized},
          {500, :unavailable},
          {503, :unavailable},
          {404, :http_error}
        ] do
      ctx = fixture()

      Gaoxy.Test.expect_once(ctx.server, "POST", "/memory/synapsis/call/recall", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "http://127.0.0.1:1/secret")
        |> Plug.Conn.resp(status, "secret")
      end)

      assert {:error, ^reason} = HostAgent.recall(ctx.source, "q")
    end
  end

  test "raw streamed response is bounded before decode and public output has a separate budget",
       ctx do
    Gaoxy.Test.expect_once(ctx.server, "POST", "/memory/synapsis/call/recall", fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce_while(1..70, conn, fn _, conn ->
        case Plug.Conn.chunk(conn, String.duplicate("x", 4096)) do
          {:ok, conn} -> {:cont, conn}
          {:error, _} -> {:halt, conn}
        end
      end)
    end)

    assert {:error, :response_limit} = HostAgent.recall(ctx.source, "q")

    ctx = fixture()

    Gaoxy.Test.expect_once(
      ctx.server,
      "POST",
      "/memory/synapsis/call/recall",
      &reply(&1, online([%{"id" => "one", "content" => String.duplicate("x", 66_000)}]))
    )

    assert {:error, :output_limit} = HostAgent.recall(ctx.source, "q")
  end

  test "deadline covers drip-fed data and expired deadlines start no request", ctx do
    assert {:error, :timeout} =
             HostAgent.recall(ctx.source, "q", deadline: System.monotonic_time(:millisecond) - 1)

    Gaoxy.Test.expect_once(ctx.server, "POST", "/memory/synapsis/call/recall", fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce_while(1..12, conn, fn _, conn ->
        Process.sleep(15)

        case Plug.Conn.chunk(conn, " ") do
          {:ok, conn} -> {:cont, conn}
          {:error, _} -> {:halt, conn}
        end
      end)
    end)

    started = System.monotonic_time(:millisecond)
    assert {:error, :timeout} = HostAgent.recall(ctx.source, "q", timeout: 70)
    assert System.monotonic_time(:millisecond) - started < 500
  end

  test "owner loss and deadline kill even suspended HTTP workers", ctx do
    Code.ensure_loaded!(Req)
    :erlang.trace_pattern({Req, :request, 1}, true, [:local])
    on_exit(fn -> :erlang.trace_pattern({Req, :request, 1}, false, [:local]) end)

    for trigger <- [:owner_loss, :deadline] do
      parent = self()

      caller =
        spawn(fn ->
          receive do
            :go -> send(parent, {:result, HostAgent.recall(ctx.source, "q", timeout: 200)})
          end
        end)

      :erlang.trace(caller, true, [:call, :procs, :set_on_spawn, {:tracer, self()}])
      on_exit(fn -> Process.exit(caller, :kill) end)
      send(caller, :go)
      assert_receive {:trace, worker, :call, {Req, :request, _}}, 1000
      :erlang.suspend_process(worker)
      on_exit(fn -> Process.exit(worker, :kill) end)
      monitor = Process.monitor(worker)
      if trigger == :owner_loss, do: Process.exit(caller, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 600
      if trigger == :deadline, do: assert_receive({:result, {:error, :timeout}}, 500)
    end
  end

  defp set_req_defaults(options) do
    previous = Application.fetch_env(:req, :default_options)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:req, :default_options, value)
        :error -> Application.delete_env(:req, :default_options)
      end
    end)

    Req.default_options(options)
  end

  defp fixture do
    server = Gaoxy.Test.open()

    %{
      server: server,
      source: %{
        id: "local-host",
        endpoint: String.trim_trailing(Gaoxy.Test.url(server), "/"),
        agent_id: "synapsis"
      }
    }
  end

  defp online(hits) do
    %{
      "mode" => "online",
      "authority" => "canonical",
      "consistency" => "canonical",
      "stale" => false,
      "history_available" => true,
      "pending_operations" => 0,
      "hits" => hits,
      "results" => hits
    }
  end

  defp reply(conn, result),
    do: Plug.Conn.resp(conn, 200, Jason.encode!(%{"ok" => true, "result" => result}))
end
