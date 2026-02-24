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

  test "retries and recovers from Req.TransportError" do
    counter = :counters.new(1, [:atomics])

    result =
      Retry.with_retry(fn ->
        count = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)

        if count == 0 do
          {:error, %Req.TransportError{reason: :econnrefused}}
        else
          {:ok, :recovered}
        end
      end)

    assert {:ok, :recovered} = result
    assert :counters.get(counter, 1) == 2
  end

  test "503 status is retryable" do
    counter = :counters.new(1, [:atomics])

    result =
      Retry.with_retry(fn ->
        count = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)

        if count == 0 do
          {:error, %{status: 503}}
        else
          {:ok, :recovered}
        end
      end)

    assert {:ok, :recovered} = result
    assert :counters.get(counter, 1) == 2
  end

  test "502 status is retryable" do
    counter = :counters.new(1, [:atomics])

    result =
      Retry.with_retry(fn ->
        count = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)

        if count == 0 do
          {:error, %{status: 502}}
        else
          {:ok, :recovered}
        end
      end)

    assert {:ok, :recovered} = result
    assert :counters.get(counter, 1) == 2
  end

  test "TransportError with 0 retries returns error immediately" do
    counter = :counters.new(1, [:atomics])

    result =
      Retry.with_retry(
        fn ->
          :counters.add(counter, 1, 1)
          {:error, %Req.TransportError{reason: :econnrefused}}
        end,
        0
      )

    assert {:error, %Req.TransportError{}} = result
    # Only called once (no retries since retries == 0)
    assert :counters.get(counter, 1) == 1
  end

  test "non-status-map error returns immediately without retry" do
    counter = :counters.new(1, [:atomics])

    result =
      Retry.with_retry(fn ->
        :counters.add(counter, 1, 1)
        {:error, :custom_error_atom}
      end)

    assert {:error, :custom_error_atom} = result
    assert :counters.get(counter, 1) == 1
  end

  test "retry with custom max_retries of 2 exhausts and returns error" do
    counter = :counters.new(1, [:atomics])

    result =
      Retry.with_retry(
        fn ->
          :counters.add(counter, 1, 1)
          {:error, %{status: 429}}
        end,
        2
      )

    assert {:error, %{status: 429}} = result
    # Called 3 times: initial + 2 retries
    assert :counters.get(counter, 1) == 3
  end

  test "retry with custom max_retries of 2 recovers on last attempt" do
    counter = :counters.new(1, [:atomics])

    result =
      Retry.with_retry(
        fn ->
          count = :counters.get(counter, 1)
          :counters.add(counter, 1, 1)

          if count < 2 do
            {:error, %{status: 500}}
          else
            {:ok, :recovered_on_third}
          end
        end,
        2
      )

    assert {:ok, :recovered_on_third} = result
    assert :counters.get(counter, 1) == 3
  end

  test "401 status is not retryable" do
    counter = :counters.new(1, [:atomics])

    result =
      Retry.with_retry(fn ->
        :counters.add(counter, 1, 1)
        {:error, %{status: 401}}
      end)

    assert {:error, %{status: 401}} = result
    assert :counters.get(counter, 1) == 1
  end

  test "403 status is not retryable" do
    counter = :counters.new(1, [:atomics])

    result =
      Retry.with_retry(fn ->
        :counters.add(counter, 1, 1)
        {:error, %{status: 403}}
      end)

    assert {:error, %{status: 403}} = result
    assert :counters.get(counter, 1) == 1
  end

  test "400 status is not retryable even with retries remaining" do
    counter = :counters.new(1, [:atomics])

    result =
      Retry.with_retry(
        fn ->
          :counters.add(counter, 1, 1)
          {:error, %{status: 400}}
        end,
        5
      )

    assert {:error, %{status: 400}} = result
    assert :counters.get(counter, 1) == 1
  end

  test "retry exhaustion with default max_retries on 500" do
    counter = :counters.new(1, [:atomics])

    result =
      Retry.with_retry(fn ->
        :counters.add(counter, 1, 1)
        {:error, %{status: 500}}
      end)

    assert {:error, %{status: 500}} = result
    # Default max_retries is 3: initial + 3 retries = 4 calls
    assert :counters.get(counter, 1) == 4
  end

  test "retry exhaustion with TransportError returns the error" do
    counter = :counters.new(1, [:atomics])

    result =
      Retry.with_retry(
        fn ->
          :counters.add(counter, 1, 1)
          {:error, %Req.TransportError{reason: :timeout}}
        end,
        2
      )

    assert {:error, %Req.TransportError{reason: :timeout}} = result
    # initial + 2 retries = 3 calls
    assert :counters.get(counter, 1) == 3
  end

  test "successful response on first try does not invoke retries" do
    counter = :counters.new(1, [:atomics])

    result =
      Retry.with_retry(
        fn ->
          :counters.add(counter, 1, 1)
          {:ok, %{body: "response data"}}
        end,
        3
      )

    assert {:ok, %{body: "response data"}} = result
    assert :counters.get(counter, 1) == 1
  end

  test "mixed retryable errors before success" do
    counter = :counters.new(1, [:atomics])

    result =
      Retry.with_retry(
        fn ->
          count = :counters.get(counter, 1)
          :counters.add(counter, 1, 1)

          case count do
            0 -> {:error, %{status: 429}}
            1 -> {:error, %{status: 502}}
            _ -> {:ok, :finally_worked}
          end
        end,
        3
      )

    assert {:ok, :finally_worked} = result
    assert :counters.get(counter, 1) == 3
  end

  test "TransportError followed by non-retryable error stops immediately" do
    counter = :counters.new(1, [:atomics])

    result =
      Retry.with_retry(
        fn ->
          count = :counters.get(counter, 1)
          :counters.add(counter, 1, 1)

          case count do
            0 -> {:error, %Req.TransportError{reason: :econnrefused}}
            _ -> {:error, %{status: 401}}
          end
        end,
        3
      )

    assert {:error, %{status: 401}} = result
    assert :counters.get(counter, 1) == 2
  end

  test "error with string reason is not retryable" do
    counter = :counters.new(1, [:atomics])

    result =
      Retry.with_retry(fn ->
        :counters.add(counter, 1, 1)
        {:error, "something went wrong"}
      end)

    assert {:error, "something went wrong"} = result
    assert :counters.get(counter, 1) == 1
  end

  test "retries = 0 with retryable status returns error after single call" do
    counter = :counters.new(1, [:atomics])

    result =
      Retry.with_retry(
        fn ->
          :counters.add(counter, 1, 1)
          {:error, %{status: 503}}
        end,
        0
      )

    assert {:error, %{status: 503}} = result
    assert :counters.get(counter, 1) == 1
  end
end
