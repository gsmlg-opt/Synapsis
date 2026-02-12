defmodule Synapsis.Provider.Retry do
  @moduledoc "Exponential backoff retry for provider HTTP requests."

  @max_retries 3
  @backoff_base 1_000

  def with_retry(fun, retries \\ @max_retries) do
    case fun.() do
      {:ok, result} ->
        {:ok, result}

      {:error, %{status: status}} when status in [429, 500, 502, 503] and retries > 0 ->
        backoff = @backoff_base * (@max_retries - retries + 1)
        Process.sleep(backoff)
        with_retry(fun, retries - 1)

      {:error, %Req.TransportError{}} when retries > 0 ->
        backoff = @backoff_base * (@max_retries - retries + 1)
        Process.sleep(backoff)
        with_retry(fun, retries - 1)

      {:error, reason} ->
        {:error, reason}

      other ->
        other
    end
  end
end
