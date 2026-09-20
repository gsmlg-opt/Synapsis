defmodule Synapsis.Provider.ProtocolCodecIntegrationTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.Adapter

  test "request preparation returns a tagged string-keyed wire map" do
    assert {:ok, %{"model" => "gpt-test", "messages" => []}} =
             Adapter.format_request([], [], %{
               model: "gpt-test",
               provider_type: "openai",
               provider_name: "primary",
               endpoint: "https://api.example/v1"
             })
  end

  test "legacy signed reasoning without a known origin fails preparation" do
    messages = [
      %{
        role: "assistant",
        parts: [%Synapsis.Part.Reasoning{content: "private", signature: "legacy-signature"}]
      }
    ]

    assert {:error, _error} =
             Adapter.format_request(messages, [], %{
               model: "claude-test",
               provider_type: "anthropic",
               provider_name: "primary",
               endpoint: "https://api.example"
             })
  end

  test "stream returns a cancellable pid and monitor reference" do
    bypass = Bypass.open()
    Bypass.down(bypass)

    request = %{"model" => "gpt-test", "messages" => [], "stream" => true}

    assert {:ok, %{pid: pid, ref: ref} = handle} =
             Adapter.stream(request, %{
               type: "openai",
               base_url: "http://localhost:#{bypass.port}",
               api_key: "test"
             })

    assert is_pid(pid)
    assert is_reference(ref)
    assert :ok = Adapter.cancel(handle)
    refute Process.alive?(pid)
  end
end
