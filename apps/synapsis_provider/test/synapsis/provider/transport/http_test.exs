defmodule Synapsis.Provider.Transport.HTTPTest do
  use ExUnit.Case

  alias Synapsis.Provider.Transport.HTTP, as: Transport

  setup do
    server = Gaoxy.Test.open()
    %{server: server, url: String.trim_trailing(Gaoxy.Test.url(server), "/")}
  end

  test "collects chunked JSON through the bounded reader", %{server: server, url: url} do
    Gaoxy.Test.expect_once(server, "GET", "/models", fn conn ->
      conn =
        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_chunked(200)

      {:ok, conn} = Plug.Conn.chunk(conn, ~s({"data":))
      {:ok, conn} = Plug.Conn.chunk(conn, ~s([{"id":"fixture"}]}))
      conn
    end)

    assert {:ok, %{status: 200, body: %{"data" => [%{"id" => "fixture"}]}}} =
             Transport.json(url <> "/models", timeout: 1_000)
  end

  test "bounds a declared-length response before retaining its body", %{server: server, url: url} do
    Gaoxy.Test.expect_once(server, "GET", "/large", fn conn ->
      Plug.Conn.send_resp(conn, 200, String.duplicate("x", 128))
    end)

    assert {:error, :response_too_large} =
             Transport.request(url <> "/large", timeout: 1_000, max_bytes: 16)
  end

  test "bounds decompressed response bytes", %{server: server, url: url} do
    Gaoxy.Test.expect_once(server, "GET", "/compressed", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-encoding", "gzip")
      |> Plug.Conn.send_resp(200, :zlib.gzip(String.duplicate("x", 1024)))
    end)

    assert {:error, :response_too_large} =
             Transport.request(url <> "/compressed", timeout: 1_000, max_bytes: 16)
  end

  test "does not follow a creation redirect or forward its authorization", %{
    server: server,
    url: url
  } do
    owner = self()

    Gaoxy.Test.expect_once(server, "POST", "/create", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", url <> "/redirected")
      |> Plug.Conn.send_resp(307, "")
    end)

    Gaoxy.Test.stub(server, "POST", "/redirected", fn conn ->
      send(owner, :redirect_followed)
      Plug.Conn.send_resp(conn, 200, "unexpected")
    end)

    assert {:ok, %{status: 307}} =
             Transport.request(url <> "/create",
               method: :post,
               headers: [{"authorization", "Bearer fixture"}],
               body: "{}",
               timeout: 1_000
             )

    refute_received :redirect_followed
  end

  test "does not retry a failed creation response", %{server: server, url: url} do
    Gaoxy.Test.expect_once(server, "POST", "/create", fn conn ->
      Plug.Conn.send_resp(conn, 503, "unavailable")
    end)

    assert {:ok, %{status: 503, body: "unavailable"}} =
             Transport.request(url <> "/create", method: :post, body: "{}", timeout: 1_000)
  end

  test "one deadline bounds drip-fed body chunks", %{server: server, url: url} do
    Gaoxy.Test.expect_once(server, "GET", "/slow", fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce_while(1..20, conn, fn _, conn ->
        Process.sleep(15)

        case Plug.Conn.chunk(conn, "x") do
          {:ok, conn} -> {:cont, conn}
          {:error, _reason} -> {:halt, conn}
        end
      end)
    end)

    assert {:error, %HTTP.RequestError{reason: :timeout}} =
             Transport.request(url <> "/slow", timeout: 60)
  end

  test "cancelling the caller closes the peer before response headers" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(listener)
    owner = self()
    before = MapSet.new(Task.Supervisor.children(:http_fetch_task_supervisor))

    acceptor =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)
        :ok = read_request_headers(socket)
        :ok = :inet.setopts(socket, packet: :raw)
        send(owner, :request_waiting)
        send(owner, {:peer_read, :gen_tcp.recv(socket, 0, 2_000)})
        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(acceptor), do: Process.exit(acceptor, :kill)
    end)

    {:ok, caller} =
      Task.Supervisor.start_child(Synapsis.Provider.TaskSupervisor, fn ->
        Transport.request("http://127.0.0.1:#{port}/cancel", timeout: 30_000)
      end)

    on_exit(fn ->
      if Process.alive?(caller), do: Process.exit(caller, :kill)
    end)

    assert_receive :request_waiting, 1_000

    requests =
      Task.Supervisor.children(:http_fetch_task_supervisor)
      |> Enum.reject(&MapSet.member?(before, &1))

    assert requests != []
    monitors = Enum.map(requests, &{&1, Process.monitor(&1)})
    Process.exit(caller, :kill)

    assert_receive {:peer_read, {:error, :closed}}, 2_000

    for {pid, ref} <- monitors do
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    end
  end

  test "cancelling the caller releases transport tasks while waiting for body", %{
    server: server,
    url: url
  } do
    owner = self()
    before = MapSet.new(Task.Supervisor.children(:http_fetch_task_supervisor))

    Gaoxy.Test.expect_once(server, "GET", "/cancel", fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)
      send(owner, {:request_waiting, self()})

      receive do
        :release -> conn
      after
        5_000 -> conn
      end
    end)

    {:ok, caller} =
      Task.Supervisor.start_child(Synapsis.Provider.TaskSupervisor, fn ->
        Transport.request(url <> "/cancel", timeout: 30_000)
      end)

    assert_receive {:request_waiting, handler}, 1_000
    on_exit(fn -> send(handler, :release) end)

    requests =
      Task.Supervisor.children(:http_fetch_task_supervisor)
      |> Enum.reject(&MapSet.member?(before, &1))

    assert requests != []
    monitors = Enum.map(requests, &{&1, Process.monitor(&1)})
    Process.exit(caller, :kill)

    for {pid, ref} <- monitors do
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    end

    send(handler, :release)
  end

  defp read_request_headers(socket) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, :http_eoh} -> :ok
      {:ok, _header} -> read_request_headers(socket)
      {:error, _reason} = error -> error
    end
  end
end
