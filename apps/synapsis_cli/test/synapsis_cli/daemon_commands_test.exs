defmodule SynapsisCli.DaemonCommandsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SynapsisCli.Main

  test "agent status calls the daemon status route and reports non-2xx as an error" do
    bypass = Bypass.open()
    host = "http://localhost:#{bypass.port}"

    Bypass.expect_once(bypass, "GET", "/api/agent/daemon/status", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(503, Jason.encode!(%{"error" => "not ready"}))
    end)

    output =
      capture_io(fn ->
        assert {:error, {:http_error, 503}} = Main.run(["agent", "status", "--host", host])
      end)

    assert output == ""
  end

  test "heartbeat run sends only its optional stored-routine name" do
    bypass = Bypass.open()
    host = "http://localhost:#{bypass.port}"

    Bypass.expect_once(bypass, "POST", "/api/agent/heartbeat/trigger", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"name" => "health-check"} = Jason.decode!(body)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(201, Jason.encode!(%{"data" => %{"id" => "run-id"}}))
    end)

    output =
      capture_io(fn ->
        assert :ok = Main.run(["heartbeat", "run", "health-check", "--host", host])
      end)

    assert output =~ "run-id"
  end

  test "dream run uses the stored-dream selector endpoint" do
    bypass = Bypass.open()
    host = "http://localhost:#{bypass.port}"

    Bypass.expect_once(bypass, "POST", "/api/agent/dream/trigger", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{} = Jason.decode!(body)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(201, Jason.encode!(%{"data" => %{"id" => "dream-run"}}))
    end)

    assert capture_io(fn -> assert :ok = Main.run(["dream", "run", "--host", host]) end) =~
             "dream-run"
  end

  test "schedule run resolves one exact name to its stable ID before triggering" do
    bypass = Bypass.open()
    host = "http://localhost:#{bypass.port}"
    routine_id = "c7aac594-48a9-4c79-90e4-fda3eadd2484"

    Bypass.expect_once(bypass, "GET", "/api/agent/routines", fn conn ->
      assert conn.query_string == "kind=schedule"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "data" => [
            %{"id" => routine_id, "name" => "nightly", "kind" => "schedule"},
            %{
              "id" => "7071e888-4ee4-4c98-9afb-1fbb869f344c",
              "name" => "weekly",
              "kind" => "schedule"
            }
          ]
        })
      )
    end)

    Bypass.expect_once(bypass, "POST", "/api/agent/routines/#{routine_id}/trigger", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(201, Jason.encode!(%{"data" => %{"id" => "schedule-run"}}))
    end)

    assert capture_io(fn ->
             assert :ok = Main.run(["schedule", "run", "nightly", "--host", host])
           end) =~ "schedule-run"
  end

  test "backplane add creates a keyless connection without inventing a credential" do
    bypass = Bypass.open()
    host = "http://localhost:#{bypass.port}"

    Bypass.expect_once(bypass, "POST", "/api/backplane/connections", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert %{"name" => "local", "endpoint" => "http://backplane.internal"} =
               decoded = Jason.decode!(body)

      refute Map.has_key?(decoded, "credential")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(201, Jason.encode!(%{"data" => %{"id" => "connection-id"}}))
    end)

    assert capture_io(fn ->
             assert :ok =
                      Main.run([
                        "backplane",
                        "add",
                        "local",
                        "http://backplane.internal",
                        "--host",
                        host
                      ])
           end) =~ "connection-id"
  end

  test "backplane test resolves one exact connection name to its stable ID" do
    bypass = Bypass.open()
    host = "http://localhost:#{bypass.port}"
    connection_id = "e76af13e-f4c3-4ff4-bb9d-41bb1dd2440f"

    Bypass.expect_once(bypass, "GET", "/api/backplane/connections", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "data" => [
            %{"id" => connection_id, "name" => "production"},
            %{"id" => "other", "name" => "staging"}
          ]
        })
      )
    end)

    Bypass.expect_once(
      bypass,
      "POST",
      "/api/backplane/connections/#{connection_id}/test",
      fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"data" => %{"ok" => true}}))
      end
    )

    assert capture_io(fn ->
             assert :ok = Main.run(["backplane", "test", "production", "--host", host])
           end) =~ ~s("ok":true)
  end

  test "backplane sync resolves its name and rejects ambiguous matches" do
    bypass = Bypass.open()
    host = "http://localhost:#{bypass.port}"
    connection_id = "49259943-c9e2-43e3-b782-cf6cc252921b"

    Bypass.expect_once(bypass, "GET", "/api/backplane/connections", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"data" => [%{"id" => connection_id, "name" => "production"}]})
      )
    end)

    Bypass.expect_once(
      bypass,
      "POST",
      "/api/backplane/connections/#{connection_id}/refresh",
      fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"data" => %{"status" => "ready"}}))
      end
    )

    assert capture_io(fn ->
             assert :ok = Main.run(["backplane", "sync", "production", "--host", host])
           end) =~ ~s("status":"ready")

    ambiguous = Bypass.open()
    ambiguous_host = "http://localhost:#{ambiguous.port}"

    Bypass.expect_once(ambiguous, "GET", "/api/backplane/connections", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "data" => [
            %{"id" => "first", "name" => "duplicate"},
            %{"id" => "second", "name" => "duplicate"}
          ]
        })
      )
    end)

    assert capture_io(fn ->
             assert {:error, {:ambiguous_name, "duplicate"}} =
                      Main.run(["backplane", "sync", "duplicate", "--host", ambiguous_host])
           end) == ""
  end

  test "backplane add reads an optional credential from the named environment variable only" do
    bypass = Bypass.open()
    host = "http://localhost:#{bypass.port}"
    env_name = "SYNAPSIS_TEST_BACKPLANE_CREDENTIAL_#{System.unique_integer([:positive])}"
    secret = "secret-value-that-must-not-be-printed"
    System.put_env(env_name, secret)
    on_exit(fn -> System.delete_env(env_name) end)

    Bypass.expect_once(bypass, "POST", "/api/backplane/connections", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"credential" => ^secret} = Jason.decode!(body)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(201, Jason.encode!(%{"data" => %{"id" => "secure-connection"}}))
    end)

    output =
      capture_io(fn ->
        assert :ok =
                 Main.run([
                   "backplane",
                   "add",
                   "secure",
                   "https://backplane.internal",
                   "--credential-env",
                   env_name,
                   "--host",
                   host
                 ])
      end)

    assert output =~ "secure-connection"
    refute output =~ secret

    missing_env = "#{env_name}_MISSING"

    assert capture_io(fn ->
             assert {:error, {:missing_credential_env, ^missing_env}} =
                      Main.run([
                        "backplane",
                        "add",
                        "missing",
                        "https://backplane.internal",
                        "--credential-env",
                        missing_env,
                        "--host",
                        host
                      ])
           end) == ""
  end

  test "invalid credential options fail before creating a Backplane connection" do
    bypass = Bypass.open()
    host = "http://localhost:#{bypass.port}"
    owner = self()

    Bypass.stub(bypass, "POST", "/api/backplane/connections", fn conn ->
      send(owner, {:unexpected_request, conn.method, conn.request_path})
      json(conn, 201, %{"data" => %{"id" => "unexpected"}})
    end)

    assert capture_io(fn ->
             assert {:error, :usage} =
                      Main.run([
                        "backplane",
                        "add",
                        "secure",
                        "https://backplane.internal",
                        "--host",
                        host,
                        "--credential-env"
                      ])
           end) == ""

    refute_receive {:unexpected_request, _method, _path}, 50
  end

  test "client certificate and key are required as a pair" do
    assert {:error, :mtls_pair_required} =
             Main.run([
               "agent",
               "status",
               "--host",
               "https://synapsis.example.com",
               "--client-cert",
               "/tmp/client.pem"
             ])

    assert {:error, :mtls_pair_required} =
             Main.run([
               "agent",
               "status",
               "--host",
               "https://synapsis.example.com",
               "--client-key",
               "/tmp/client.key"
             ])
  end

  test "mTLS options use the Req and Finch transport option contract" do
    options =
      Main.request_options(
        [
          client_cert: "/secure/client.pem",
          client_key: "/secure/client.key",
          ca_cert: "/secure/ca.pem"
        ],
        12_345
      )

    assert options[:receive_timeout] == 12_345
    assert options[:request_timeout] == 12_345
    assert options[:retry] == false

    assert options[:connect_options][:transport_opts] == [
             certfile: "/secure/client.pem",
             keyfile: "/secure/client.key",
             cacertfile: "/secure/ca.pem"
           ]

    assert %Req.Request{} = Req.new([url: "https://synapsis.example.com"] ++ options)
  end

  test "does not send a Backplane credential over non-loopback plaintext HTTP" do
    env_name = "SYNAPSIS_TEST_REMOTE_CREDENTIAL_#{System.unique_integer([:positive])}"
    secret = "must-never-cross-plaintext"
    System.put_env(env_name, secret)
    on_exit(fn -> System.delete_env(env_name) end)

    output =
      capture_io(fn ->
        assert {:error, :plaintext_credential_forbidden} =
                 Main.run([
                   "backplane",
                   "add",
                   "remote",
                   "https://backplane.internal",
                   "--credential-env",
                   env_name,
                   "--host",
                   "http://synapsis.example.com:4657"
                 ])
      end)

    refute output =~ secret

    assert {:error, :plaintext_credential_forbidden} =
             Main.run([
               "backplane",
               "add",
               "remote-backplane",
               "http://backplane.example.com",
               "--credential-env",
               env_name,
               "--host",
               "http://127.0.0.1:4657"
             ])
  end

  test "bare daemon command namespaces return usage without starting a session" do
    bypass = Bypass.open()
    host = "http://localhost:#{bypass.port}"
    owner = self()

    Bypass.stub(bypass, "POST", "/api/sessions", fn conn ->
      send(owner, {:unexpected_session_request, conn.method, conn.request_path})
      json(conn, 201, %{"data" => %{"id" => "unexpected-session"}})
    end)

    Bypass.stub(bypass, "POST", "/api/sessions/unexpected-session/messages", fn conn ->
      json(conn, 200, %{})
    end)

    Bypass.stub(bypass, "GET", "/api/sessions/unexpected-session/events", fn conn ->
      Plug.Conn.resp(conn, 200, "")
    end)

    for namespace <- ~w(agent heartbeat dream schedule backplane) do
      assert capture_io(fn ->
               assert {:error, :usage} = Main.run([namespace, "--host", host])
             end) == ""
    end

    refute_receive {:unexpected_session_request, _method, _path}, 50
  end

  test "manual run rejects a missing prompt before making an HTTP request" do
    assert capture_io(fn ->
             assert {:error, {:usage, "synapsis agent run <prompt>"}} =
                      Main.run(["agent", "run", "--host", "http://localhost:1"])
           end) == ""
  end

  test "manual, list, cancel, schedule-list, and backplane-list commands use exact routes" do
    bypass = Bypass.open()
    host = "http://localhost:#{bypass.port}"

    Bypass.expect_once(bypass, "POST", "/api/agent/runs", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"prompt" => "inspect deployment"} = Jason.decode!(body)
      json(conn, 201, %{"data" => %{"id" => "manual-run"}})
    end)

    Bypass.expect_once(bypass, "GET", "/api/agent/runs", fn conn ->
      json(conn, 200, %{"data" => []})
    end)

    Bypass.expect_once(bypass, "POST", "/api/agent/runs/manual-run/cancel", fn conn ->
      json(conn, 200, %{"data" => %{"id" => "manual-run", "status" => "cancelled"}})
    end)

    Bypass.expect_once(bypass, "GET", "/api/agent/routines", fn conn ->
      assert conn.query_string == "kind=schedule"
      json(conn, 200, %{"data" => []})
    end)

    Bypass.expect_once(bypass, "GET", "/api/backplane/connections", fn conn ->
      json(conn, 200, %{"data" => []})
    end)

    commands = [
      ["agent", "run", "inspect", "deployment"],
      ["agent", "runs"],
      ["agent", "cancel", "manual-run"],
      ["schedule", "list"],
      ["backplane", "list"]
    ]

    Enum.each(commands, fn command ->
      capture_io(fn -> assert :ok = Main.run(command ++ ["--host", host]) end)
    end)
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end
end
