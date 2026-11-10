defmodule Synapsis.Browser.PortSessionFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Browser.PortSession

  @moduletag :tmp_dir
  @moduletag timeout: 60_000

  test "dormant transport retains browser state and confirms both owned process exits", %{
    tmp_dir: directory
  } do
    {broker, fixture} = fixture(directory)
    assert :sys.get_state(broker).port == nil
    assert {:ok, %{"running" => false, "generation" => 0}} = PortSession.initialize(broker)
    port = :sys.get_state(broker).port
    {:os_pid, helper_pid} = Port.info(port, :os_pid)
    assert child_pids(helper_pid) == []

    assert {:ok, %{"running" => true, "generation" => 1}} = call(broker, "start")
    browser_pids = child_pids(helper_pid)
    assert browser_pids != []

    assert {:ok, %{"targetId" => target}} =
             call(broker, "open", %{"targetUrl" => Gaoxy.Test.url(fixture)})

    assert {:ok, %{"value" => "retained"}} =
             call(broker, "act", %{
               "targetId" => target,
               "request" => %{
                 "kind" => "evaluate",
                 "fn" => "() => { window.example = 'retained'; return window.example; }"
               }
             })

    assert {:ok, %{"value" => "retained"}} =
             call(broker, "act", %{
               "targetId" => target,
               "request" => %{"kind" => "evaluate", "fn" => "() => window.example"}
             })

    assert {:ok, %{"snapshot" => snapshot}} = call(broker, "snapshot", %{"targetId" => target})
    assert snapshot =~ "Port browser fixture"

    assert {:ok, %{"cleanup_confirmed" => true, "generation" => stopped_generation}} =
             call(broker, "stop")

    Enum.each(browser_pids, &assert_exited/1)

    assert {:ok, %{"running" => true, "generation" => reopened_generation}} =
             call(broker, "start")

    assert reopened_generation > stopped_generation
    reopened_pids = child_pids(helper_pid)
    assert reopened_pids != []
    assert :ok = PortSession.close(broker)
    assert_exited(helper_pid)
    Enum.each(reopened_pids, &assert_exited/1)
    assert :sys.get_state(broker).port == nil
    assert :ok = PortSession.close(broker)
  end

  test "cancel remains responsive during an action and synchronizes generation before reopening",
       %{
         tmp_dir: directory
       } do
    {broker, fixture} = fixture(directory)
    owner = self()

    Gaoxy.Test.stub(fixture, "GET", "/waiting", fn conn ->
      send(owner, :browser_waiting)
      Plug.Conn.resp(conn, 200, "ready")
    end)

    assert {:ok, _} = PortSession.initialize(broker)
    assert {:ok, _} = call(broker, "start")

    assert {:ok, %{"targetId" => target}} =
             call(broker, "open", %{"targetUrl" => Gaoxy.Test.url(fixture)})

    action =
      Task.async(fn ->
        call(broker, "act", %{
          "targetId" => target,
          "request" => %{
            "kind" => "evaluate",
            "fn" =>
              "async () => { await fetch('/waiting'); await new Promise(resolve => setTimeout(resolve, 30000)); }"
          }
        })
      end)

    assert_receive :browser_waiting, 5_000

    assert {:ok, %{"cancelled" => true, "cleanup_confirmed" => true, "generation" => generation}} =
             PortSession.cancel(broker)

    assert {:error, %{"class" => "cancelled", "cleanup" => %{"cleanup_confirmed" => true}}} =
             Task.await(action, 5_000)

    assert {:ok, %{"running" => false, "generation" => ^generation}} = call(broker, "status")
    assert {:ok, %{"running" => true}} = call(broker, "start")
    assert :ok = PortSession.close(broker)
  end

  defp fixture(directory) do
    fixture = Gaoxy.Test.open()

    Gaoxy.Test.stub(fixture, "GET", "/", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(
        200,
        "<!doctype html><html><body><h1>Port browser fixture</h1></body></html>"
      )
    end)

    Gaoxy.Test.stub(fixture, "GET", "/favicon.ico", &Plug.Conn.resp(&1, 204, ""))
    root = Path.expand("../../../../..", __DIR__)

    broker =
      start_supervised!(
        {PortSession,
         owner_pid: self(),
         node_executable: System.find_executable("node"),
         helper_path: Path.join(root, "packages/tool-host/src/browser/stdio.mjs"),
         config: %{
           "profile" => "functional",
           "executable" =>
             System.get_env("SYNAPSIS_TEST_CHROMIUM", "/run/current-system/sw/bin/chromium"),
           "data_dir" => directory,
           "timeout_ms" => 15_000,
           "max_image_bytes" => 196_608
         }}
      )

    {broker, fixture}
  end

  defp call(broker, action, args \\ %{}), do: PortSession.call(broker, action, args, 15_000)

  defp child_pids(pid) do
    "/proc/#{pid}/task/#{pid}/children"
    |> File.read!()
    |> String.split()
    |> Enum.map(&String.to_integer/1)
  end

  defp assert_exited(pid),
    do: refute(File.exists?("/proc/#{pid}"), "owned process #{pid} still exists")
end
