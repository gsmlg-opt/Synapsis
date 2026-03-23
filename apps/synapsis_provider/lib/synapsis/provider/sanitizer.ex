defmodule SynapsisProvider.Sanitizer do
  @moduledoc ~S"""
  Sanitizes HTTP request/response metadata for debug display.
  Redacts sensitive headers using an allowlist approach — only known-safe
  headers pass through verbatim; everything else shows `...#{last4}`.
  """

  @safe_headers MapSet.new([
    "content-type",
    "accept",
    "user-agent",
    "x-request-id",
    "anthropic-version",
    "anthropic-beta",
    "openai-organization",
    "x-stainless-arch",
    "x-stainless-os",
    "x-stainless-lang",
    "x-stainless-runtime",
    "x-stainless-runtime-version",
    "retry-after",
    "x-ratelimit-limit-requests",
    "x-ratelimit-limit-tokens",
    "x-ratelimit-remaining-requests",
    "x-ratelimit-remaining-tokens",
    "x-ratelimit-reset-requests",
    "x-ratelimit-reset-tokens",
    "content-length",
    "transfer-encoding"
  ])

  @spec redact_headers([{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def redact_headers(headers) when is_list(headers) do
    Enum.map(headers, fn {key, value} ->
      normalized = String.downcase(key)

      if MapSet.member?(@safe_headers, normalized) do
        {key, value}
      else
        {key, redact_value(value)}
      end
    end)
  end

  def redact_headers(_), do: []

  @spec sanitize_request(map()) :: map()
  def sanitize_request(metadata) do
    %{
      request_id: metadata.request_id,
      method: metadata.method,
      url: metadata.url,
      headers: redact_headers(metadata.headers),
      body: metadata.body,
      provider: metadata.provider,
      model: metadata.model,
      timestamp: DateTime.utc_now()
    }
  end

  @spec sanitize_response(map(), map()) :: map()
  def sanitize_response(metadata, measurements) do
    %{
      request_id: metadata.request_id,
      status: metadata.status,
      headers: redact_headers(metadata[:headers] || []),
      body: metadata.body,
      complete: metadata.complete,
      error: metadata[:error],
      duration_ms: System.convert_time_unit(measurements.duration, :native, :millisecond),
      timestamp: DateTime.utc_now()
    }
  end

  defp redact_value(value) when is_binary(value) and byte_size(value) >= 4 do
    last4 = String.slice(value, -4, 4)
    "...#{last4}"
  end

  defp redact_value(_), do: "..."
end
