defmodule Synapsis.Provider.RetryTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.Retry

  test "returns success immediately" do
    assert {:ok, :result} = Retry.with_retry(fn -> {:ok, :result} end)
  end

  test "returns error after max retries on 429" do
    counter = :counters.new(1, [:atomics])

    result =
      Retry.with_retry(
        fn ->
          :counters.add(counter, 1, 1)
          {:error, %{status: 429}}
        end,
        1
      )

    assert {:error, %{status: 429}} = result
    # Called twice: initial + 1 retry
    assert :counters.get(counter, 1) == 2
  end

  test "returns non-retryable error immediately" do
    counter = :counters.new(1, [:atomics])

    result =
      Retry.with_retry(fn ->
        :counters.add(counter, 1, 1)
        {:error, %{status: 400}}
      end)

    assert {:error, %{status: 400}} = result
    assert :counters.get(counter, 1) == 1
  end

  test "recovers on retry" do
    counter = :counters.new(1, [:atomics])

    result =
      Retry.with_retry(fn ->
        count = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)

        if count == 0 do
          {:error, %{status: 500}}
        else
          {:ok, :recovered}
        end
      end)

    assert {:ok, :recovered} = result
  end

  test "passes through non-error non-ok return values" do
    assert :unexpected = Retry.with_retry(fn -> :unexpected end)
  end
end
