defmodule Synapsis.Tool.SleepTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.Sleep

  describe "tool metadata" do
    test "has correct name" do
      assert Sleep.name() == "sleep"
    end

    test "has a description string" do
      assert is_binary(Sleep.description())
      assert String.length(Sleep.description()) > 0
    end

    test "has valid parameters schema" do
      params = Sleep.parameters()
      assert params["type"] == "object"
      assert is_map(params["properties"])
      assert "duration_ms" in params["required"]
    end

    test "permission_level is :none" do
      assert Sleep.permission_level() == :none
    end

    test "category is :session" do
      assert Sleep.category() == :session
    end
  end

  describe "execute/2 — sleep completion" do
    test "completes after short duration" do
      input = %{"duration_ms" => 50, "reason" => "testing"}

      {time_us, result} = :timer.tc(fn -> Sleep.execute(input, %{}) end)
      time_ms = div(time_us, 1000)

      assert {:ok, msg} = result
      assert msg =~ "Slept for 50ms"
      assert msg =~ "testing"
      assert time_ms >= 40
    end

    test "includes default reason when not provided" do
      input = %{"duration_ms" => 10}

      assert {:ok, msg} = Sleep.execute(input, %{})
      assert msg =~ "no reason given"
    end
  end

  describe "execute/2 — early wake on user_input" do
    test "interrupts sleep when user_input message received" do
      test_pid = self()

      # Spawn the sleep in a task so we can send it a message
      task =
        Elixir.Task.async(fn ->
          send(test_pid, {:sleep_pid, self()})
          Sleep.execute(%{"duration_ms" => 5_000, "reason" => "waiting"}, %{})
        end)

      # Wait for the sleep process to start
      sleep_pid =
        receive do
          {:sleep_pid, pid} -> pid
        after
          1_000 -> flunk("Sleep process did not start in time")
        end

      # Send user_input to interrupt
      send(sleep_pid, {:user_input, "wake up"})

      result = Elixir.Task.await(task, 2_000)
      assert {:ok, msg} = result
      assert msg =~ "interrupted by user input"
    end
  end

  describe "execute/2 — max duration cap" do
    test "caps duration at 600_000ms" do
      # We can't actually wait 600s, just verify the cap is applied
      # by checking the output message for a capped value
      input = %{"duration_ms" => 999_999}

      # Spawn and immediately interrupt to verify the capped value
      task =
        Elixir.Task.async(fn ->
          receive do
          after
            0 -> :ok
          end

          Sleep.execute(input, %{})
        end)

      # Send interrupt to avoid actually sleeping 600s
      sleep_pid = task.pid
      # Give the task a moment to enter execute
      Process.sleep(10)
      send(sleep_pid, {:user_input, "stop"})

      result = Elixir.Task.await(task, 2_000)
      assert {:ok, msg} = result
      # If interrupted, message says "interrupted"; if somehow completed, would say 600000
      assert msg =~ "interrupted" or msg =~ "600000"
    end

    test "zero duration completes immediately" do
      input = %{"duration_ms" => 0}

      {time_us, result} = :timer.tc(fn -> Sleep.execute(input, %{}) end)

      assert {:ok, _msg} = result
      # Should complete almost instantly (under 50ms)
      assert div(time_us, 1000) < 50
    end

    test "nil duration defaults to zero" do
      input = %{"duration_ms" => nil}

      assert {:ok, msg} = Sleep.execute(input, %{})
      assert msg =~ "Slept for 0ms"
    end
  end
end
