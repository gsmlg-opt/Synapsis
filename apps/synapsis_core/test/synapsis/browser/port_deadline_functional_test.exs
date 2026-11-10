defmodule Synapsis.Browser.PortDeadlineFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional
  alias Synapsis.Browser.PortSession

  @moduletag :tmp_dir
  @moduletag timeout: 60_000

  test "large outer watchdog supports short real helper actions and confirmed process cleanup", %{
    tmp_dir: directory
  } do
    root = Path.expand("../../../../..", __DIR__)

    broker =
      start_supervised!(
        {PortSession,
         owner_pid: self(),
         node_executable: System.find_executable("node"),
         helper_path: Path.join(root, "packages/tool-host/src/browser/stdio.mjs"),
         config: %{
           "profile" => "deadline",
           "executable" => "/run/current-system/sw/bin/chromium",
           "data_dir" => directory,
           "timeout_ms" => 15_000,
           "max_image_bytes" => 196_608
         }}
      )

    assert {:ok, %{"running" => false}} = PortSession.initialize(broker)
    port = :sys.get_state(broker).port
    assert {:os_pid, helper} = Port.info(port, :os_pid)
    assert {:ok, %{"running" => true}} = PortSession.call(broker, "start", %{}, 150_000)

    children =
      "/proc/#{helper}/task/#{helper}/children"
      |> File.read!()
      |> String.split()
      |> Enum.map(&String.to_integer/1)

    assert children != []

    assert {:ok, %{"targetId" => target}} =
             PortSession.call(broker, "open", %{"targetUrl" => "about:blank"}, 2_147_000_000)

    assert {:ok, %{"ok" => true}} =
             PortSession.call(
               broker,
               "act",
               %{"targetId" => target, "request" => %{"kind" => "wait", "timeMs" => 20}},
               75_005_000
             )

    assert :ok = PortSession.close(broker)
    for pid <- [helper | children], do: refute(File.exists?("/proc/#{pid}"))
  end
end
