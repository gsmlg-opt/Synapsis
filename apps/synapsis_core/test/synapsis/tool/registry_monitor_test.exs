defmodule Synapsis.Tool.RegistryMonitorTest do
  use ExUnit.Case, async: false

  alias Synapsis.Tool.Registry

  test "process-registered tools are purged when the owner dies" do
    name = "mon_tool_#{System.unique_integer([:positive])}"

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    :ok = Registry.register_process(name, owner, description: "x", parameters: %{})
    assert {:ok, _} = Registry.lookup(name)

    ref = Process.monitor(owner)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^owner, _}, 1_000

    Process.sleep(50)
    assert {:error, :not_found} = Registry.lookup(name)
  end
end
