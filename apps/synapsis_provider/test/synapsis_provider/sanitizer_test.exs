defmodule SynapsisProvider.SanitizerTest do
  use ExUnit.Case, async: true

  alias SynapsisProvider.Sanitizer

  describe "redact_headers/1" do
    test "passes safe headers through verbatim" do
      headers = [
        {"content-type", "application/json"},
        {"accept", "text/event-stream"},
        {"user-agent", "Synapsis/0.1"},
        {"anthropic-version", "2023-06-01"}
      ]

      assert Sanitizer.redact_headers(headers) == headers
    end

    test "redacts authorization header with last 4 chars" do
      headers = [{"authorization", "Bearer sk-ant-api03-abcdefxyz"}]
      assert [{"authorization", "...fxyz"}] = Sanitizer.redact_headers(headers)
    end

    test "redacts x-api-key with last 4 chars" do
      headers = [{"x-api-key", "sk-ant-api03-longkey"}]
      assert [{"x-api-key", "...gkey"}] = Sanitizer.redact_headers(headers)
    end

    test "redacts api-key header" do
      headers = [{"api-key", "a1b2c3d4e5"}]
      assert [{"api-key", "...d4e5"}] = Sanitizer.redact_headers(headers)
    end

    test "redacts x-goog-api-key" do
      headers = [{"x-goog-api-key", "AIzaSyBlong"}]
      assert [{"x-goog-api-key", "...long"}] = Sanitizer.redact_headers(headers)
    end

    test "redacts unknown headers with last 4 chars" do
      headers = [{"x-custom-secret", "mysecretvalue123"}]
      assert [{"x-custom-secret", "...e123"}] = Sanitizer.redact_headers(headers)
    end

    test "handles short values (< 4 chars) with ..." do
      headers = [{"authorization", "ab"}]
      assert [{"authorization", "..."}] = Sanitizer.redact_headers(headers)
    end

    test "handles empty header list" do
      assert [] = Sanitizer.redact_headers([])
    end

    test "case-insensitive header matching" do
      headers = [{"Content-Type", "application/json"}]
      assert [{"Content-Type", "application/json"}] = Sanitizer.redact_headers(headers)
    end

    test "preserves header key casing" do
      headers = [{"Authorization", "Bearer sk-long-key-value"}]
      [{key, _}] = Sanitizer.redact_headers(headers)
      assert key == "Authorization"
    end

    test "handles non-list input" do
      assert [] = Sanitizer.redact_headers(nil)
      assert [] = Sanitizer.redact_headers("not a list")
    end
  end

  describe "sanitize_request/1" do
    test "includes all required fields and redacts headers" do
      metadata = %{
        request_id: "req-123",
        method: :post,
        url: "https://api.anthropic.com/v1/messages",
        headers: [
          {"content-type", "application/json"},
          {"x-api-key", "sk-ant-longkey123"}
        ],
        body: %{model: "claude-sonnet-4-6"},
        provider: :anthropic,
        model: "claude-sonnet-4-6"
      }

      result = Sanitizer.sanitize_request(metadata)

      assert result.request_id == "req-123"
      assert result.method == :post
      assert result.url == "https://api.anthropic.com/v1/messages"
      assert result.provider == :anthropic
      assert result.model == "claude-sonnet-4-6"
      assert result.body == %{model: "claude-sonnet-4-6"}
      assert %DateTime{} = result.timestamp

      # Headers should be redacted
      assert [{"content-type", "application/json"}, {"x-api-key", "...y123"}] = result.headers
    end
  end

  describe "sanitize_response/1" do
    test "includes all required fields and converts duration" do
      metadata = %{
        request_id: "req-123",
        status: 200,
        headers: [{"content-type", "application/json"}],
        body: ~s({"id":"msg_01","content":[]}),
        complete: true,
        error: nil
      }

      # Use native time units for duration
      duration_native = System.convert_time_unit(3400, :millisecond, :native)
      measurements = %{duration: duration_native}

      result = Sanitizer.sanitize_response(metadata, measurements)

      assert result.request_id == "req-123"
      assert result.status == 200
      assert result.complete == true
      assert result.error == nil
      assert result.duration_ms >= 3399 and result.duration_ms <= 3401
      assert %DateTime{} = result.timestamp
    end

    test "includes error when present" do
      metadata = %{
        request_id: "req-456",
        status: 0,
        headers: [],
        body: nil,
        complete: false,
        error: %{reason: :timeout, message: "Connection timed out"}
      }

      measurements = %{duration: 0}

      result = Sanitizer.sanitize_response(metadata, measurements)

      assert result.complete == false
      assert result.error == %{reason: :timeout, message: "Connection timed out"}
    end
  end
end
