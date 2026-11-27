defmodule Synapsis.Voice.DeviceCallRestorerTest do
  use ExUnit.Case, async: false

  alias Synapsis.Voice.DeviceCallRestorer

  test "boot repair monitors the owner and repairs immediately after owner loss" do
    test = self()
    first = spawn(fn -> Process.sleep(:infinity) end)
    second = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Enum.each([first, second], &Process.exit(&1, :kill)) end)
    owners = start_supervised!({Agent, fn -> [first, second] end})

    repair = fn ->
      owner = Agent.get_and_update(owners, fn [owner | rest] -> {owner, rest} end)
      send(test, {:restored, owner})
      {:ok, "fixed-session", owner}
    end

    restorer =
      start_supervised!({DeviceCallRestorer, name: __MODULE__, repair: repair, interval: 20})

    assert_receive {:restored, ^first}, 1_000
    wait_for_owner(restorer, first)
    refute_receive {:restored, _}, 60
    Process.exit(first, :kill)
    assert_receive {:restored, ^second}, 1_000
    wait_for_owner(restorer, second)
  end

  test "a failed boot read is retried and an inactive intent removes the monitor" do
    test = self()
    calls = start_supervised!({Agent, fn -> 0 end})

    repair = fn ->
      count = Agent.get_and_update(calls, &{&1, &1 + 1})
      send(test, {:repair, count})
      if count == 0, do: {:error, :storage_unavailable}, else: :inactive
    end

    restorer =
      start_supervised!({DeviceCallRestorer, name: __MODULE__, repair: repair, interval: 20})

    assert_receive {:repair, 0}, 1_000
    assert_receive {:repair, 1}, 1_000
    assert %{owner: nil} = :sys.get_state(restorer)
  end

  test "an explicit watch supersedes an older boot lookup" do
    test = self()
    owner = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(owner, :kill) end)

    repair = fn ->
      send(test, {:lookup_started, self()})

      receive do
        :release -> :inactive
      end
    end

    restorer = start_supervised!({DeviceCallRestorer, name: __MODULE__, repair: repair})
    assert_receive {:lookup_started, _}, 1_000
    task = :sys.get_state(restorer).task
    GenServer.cast(restorer, {:watch, "fixed-session", owner})
    wait_for_owner(restorer, owner)
    send(restorer, {task.ref, :inactive})
    assert %{owner: {"fixed-session", ^owner, _}, task: nil} = :sys.get_state(restorer)
  end

  defp wait_for_owner(restorer, owner, attempts \\ 50)

  defp wait_for_owner(restorer, owner, 0),
    do: assert(elem(:sys.get_state(restorer).owner, 1) == owner)

  defp wait_for_owner(restorer, owner, attempts) do
    case :sys.get_state(restorer).owner do
      {_, ^owner, _} ->
        :ok

      _ ->
        Process.sleep(10)
        wait_for_owner(restorer, owner, attempts - 1)
    end
  end
end
