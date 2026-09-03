defmodule Synapsis.Agent.TestSupport.DeterministicProviderTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.DeterministicProvider

  @moduletag :tmp_dir

  test "success scenario returns streamed text over Bypass" do
    harness = DeterministicProvider.start!(scenario: :success, text: "hello-det")
    on_exit(fn -> DeterministicProvider.stop(harness) end)

    assert {:ok, body} = post_chat(harness.base_url)
    assert body =~ "hello-det"
    assert body =~ "[DONE]"
  end

  test "streamed_success emits multiple text deltas" do
    harness =
      DeterministicProvider.start!(
        scenario: :streamed_success,
        stream_chunks: ["a", "b", "c"]
      )

    on_exit(fn -> DeterministicProvider.stop(harness) end)

    assert {:ok, body} = post_chat(harness.base_url)
    assert body =~ "a"
    assert body =~ "b"
    assert body =~ "c"
  end

  test "provider_failure returns HTTP 500" do
    harness = DeterministicProvider.start!(scenario: :provider_failure)
    on_exit(fn -> DeterministicProvider.stop(harness) end)

    assert {:ok, %{status: 500}} = post_chat_raw(harness.base_url)
  end

  test "timeout returns HTTP 408" do
    harness = DeterministicProvider.start!(scenario: :timeout)
    on_exit(fn -> DeterministicProvider.stop(harness) end)

    assert {:ok, %{status: 408}} = post_chat_raw(harness.base_url)
  end

  test "malformed_tool_request emits invalid tool arguments JSON" do
    harness =
      DeterministicProvider.start!(
        scenario: :malformed_tool_request,
        tool_name: "det_tool"
      )

    on_exit(fn -> DeterministicProvider.stop(harness) end)

    assert {:ok, body} = post_chat(harness.base_url)
    assert body =~ "{not-json"
  end

  test "multi_turn_tool_result returns tool call then text" do
    harness =
      DeterministicProvider.start!(
        scenario: :multi_turn_tool_result,
        tool_name: "det_tool",
        tool_call_id: "call-1",
        text: "after-tool"
      )

    on_exit(fn -> DeterministicProvider.stop(harness) end)

    assert {:ok, first} =
             post_chat(harness.base_url, messages: [%{"role" => "user", "content" => "go"}])

    assert first =~ "det_tool"
    assert first =~ "call-1"

    assert {:ok, second} =
             post_chat(harness.base_url,
               messages: [
                 %{"role" => "user", "content" => "go"},
                 %{"role" => "tool", "content" => "result", "tool_call_id" => "call-1"}
               ]
             )

    assert second =~ "after-tool"
  end

  defp post_chat(base_url, opts \\ []) do
    case post_chat_raw(base_url, opts) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      other -> other
    end
  end

  defp post_chat_raw(base_url, opts \\ []) do
    messages = Keyword.get(opts, :messages, [%{"role" => "user", "content" => "hi"}])

    Req.post("#{base_url}/v1/chat/completions",
      json: %{
        "model" => "test",
        "stream" => true,
        "messages" => messages
      }
    )
  end
end
