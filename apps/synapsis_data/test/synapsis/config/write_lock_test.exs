defmodule Synapsis.Config.WriteLockTest do
  use ExUnit.Case, async: false

  alias Synapsis.Config.Store

  test "an expired absolute deadline never enters the callback" do
    deadline = System.monotonic_time(:millisecond) - 1

    assert {:error, :config_write_lock_unavailable} =
             Store.with_write_lock(fn -> flunk("expired callback executed") end,
               deadline: deadline
             )
  end

  test "contention is bounded by the original deadline and never executes late" do
    owner = self()

    holder =
      Task.async(fn ->
        Store.with_write_lock(fn ->
          send(owner, :lock_held)
          receive do: (:release -> :released)
        end)
      end)

    assert_receive :lock_held
    started = System.monotonic_time(:millisecond)

    assert {:error, :config_write_lock_unavailable} =
             Store.with_write_lock(fn -> flunk("contended callback executed") end,
               deadline: started + 30
             )

    assert System.monotonic_time(:millisecond) - started < 500
    send(holder.pid, :release)
    assert Task.await(holder) == :released
  end

  test "bounded locking remains reentrant and releases after a callback exception" do
    deadline = System.monotonic_time(:millisecond) + 1_000

    assert :nested =
             Store.with_write_lock(
               fn ->
                 Store.with_write_lock(fn -> :nested end, deadline: deadline)
               end,
               deadline: deadline
             )

    assert_raise RuntimeError, "lock exception", fn ->
      Store.with_write_lock(fn -> raise "lock exception" end, deadline: deadline)
    end

    assert :released = Store.with_write_lock(fn -> :released end, deadline: deadline)
  end

  test "invalid options never enter the callback and empty options preserve unbounded locking" do
    for opts <- [nil, :invalid, %{}, [deadline: nil], [deadline: 1, deadline: 2], [other: 1]] do
      assert {:error, :invalid_write_lock_options} =
               Store.with_write_lock(fn -> flunk("invalid options executed callback") end, opts)
    end

    assert :unchanged = Store.with_write_lock(fn -> :unchanged end, [])

    Store.with_write_lock(fn ->
      assert {:error, :config_write_lock_unavailable} =
               Store.with_write_lock(fn -> flunk("expired reentrant callback executed") end,
                 deadline: System.monotonic_time(:millisecond) - 1
               )
    end)
  end

  test "a dead bounded lock owner releases the existing global lock" do
    owner = self()

    holder =
      spawn(fn ->
        Store.with_write_lock(
          fn ->
            send(owner, :bounded_lock_held)
            receive do: (:release -> :released)
          end,
          deadline: System.monotonic_time(:millisecond) + 1_000
        )
      end)

    monitor = Process.monitor(holder)
    assert_receive :bounded_lock_held
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :killed}

    assert :released =
             Store.with_write_lock(fn -> :released end,
               deadline: System.monotonic_time(:millisecond) + 1_000
             )
  end
end
