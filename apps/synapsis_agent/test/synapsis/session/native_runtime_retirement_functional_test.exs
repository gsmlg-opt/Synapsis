defmodule Synapsis.Session.NativeRuntimeRetirementFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Agent.TestSupport.{AbortableHTTP, DeterministicProvider, SessionHarness}
  alias Synapsis.Session.Worker

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    %{harness: harness, id: harness.session.id}
  end

  test "queued and sequential prompts use the same native conversation history", ctx do
    owner = self()

    Gaoxy.Test.stub(ctx.harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {index, request, conn} = record_request(conn, ctx.harness.counter)
      send(owner, {:provider_request, index, request, self()})

      if index == 0 do
        {:released, conn} = AbortableHTTP.await(conn, :complete_first, 10_000, owner)
        complete(conn, "First response")
      else
        complete(conn, "Response #{index + 1}")
      end
    end)

    assert :ok = Worker.send_message(ctx.id, "First prompt")
    assert_receive {:provider_request, 0, first, first_handler}, 5_000
    assert user_texts(first) == ["First prompt"]
    assert :ok = Worker.send_message(ctx.id, "Queued prompt")
    send(first_handler, :complete_first)

    assert_receive {:provider_request, 1, second, _}, 10_000
    assert user_texts(second) == ["First prompt", "Queued prompt"]
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    await_waiting(ctx.id)

    assert :ok = Worker.send_message(ctx.id, "Sequential prompt")
    assert_receive {:provider_request, 2, third, _}, 5_000
    assert user_texts(third) == ["First prompt", "Queued prompt", "Sequential prompt"]
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    await_waiting(ctx.id)
    assert Worker.snapshot(ctx.id).error == nil
  end

  test "normal cancellation before adapter startup and during a turn allows another prompt",
       ctx do
    owner = self()

    Gaoxy.Test.stub(ctx.harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {index, request, conn} = record_request(conn, ctx.harness.counter)
      send(owner, {:provider_request, index, request, self()})

      if index == 0 do
        {_outcome, conn} = AbortableHTTP.await(conn, :release_cancelled, 10_000, owner)
        conn
      else
        complete(conn, "After cancellation")
      end
    end)

    assert :ok = Worker.cancel(ctx.id)
    await_waiting(ctx.id)
    assert :ok = Worker.send_message(ctx.id, "Cancel this prompt")
    assert_receive {:provider_request, 0, _, handler}, 5_000
    assert :ok = Worker.cancel(ctx.id)
    await_waiting(ctx.id)
    send(handler, :release_cancelled)
    assert Worker.snapshot(ctx.id).error == nil

    assert :ok = Worker.send_message(ctx.id, "Continue after cancellation")
    assert_receive {:provider_request, 1, request, _}, 5_000
    assert List.last(user_texts(request)) == "Continue after cancellation"
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    await_waiting(ctx.id)
    assert Worker.snapshot(ctx.id).error == nil
  end

  test "retry regenerate and checkpoints retain their native unsupported replies", ctx do
    Gaoxy.Test.stub(ctx.harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      complete(conn, "Ordinary response")
    end)

    assert_unsupported(ctx.id)
    assert :ok = Worker.send_message(ctx.id, "Ordinary prompt")
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    await_waiting(ctx.id)
    assert_unsupported(ctx.id)
    assert Worker.snapshot(ctx.id).error == nil
  end

  defp assert_unsupported(id) do
    assert {:error, :retry_unavailable_with_subagents} = Worker.retry(id)
    assert {:error, :regenerate_unavailable_with_subagents} = Worker.regenerate(id, "reply")
    assert {:error, :checkpoint_unavailable_with_subagents} = Worker.push_checkpoint(id)
    assert {:error, :checkpoint_unavailable_with_subagents} = Worker.rollback_checkpoint(id)
  end

  defp record_request(conn, counter) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)

    index =
      Agent.get_and_update(counter, fn state ->
        {length(state.provider_requests),
         %{state | provider_requests: state.provider_requests ++ [request]}}
      end)

    {index, request, conn}
  end

  defp complete(conn, text) do
    DeterministicProvider.send_sse(conn, [
      DeterministicProvider.text_chunk(text),
      DeterministicProvider.finish_chunk("stop")
    ])
  end

  defp user_texts(request) do
    for %{"role" => "user", "content" => content} <- request["messages"] do
      Enum.map_join(content, fn %{"type" => "text", "text" => text} -> text end)
    end
  end

  defp await_waiting(id), do: await_waiting(id, System.monotonic_time(:millisecond) + 5_000)

  defp await_waiting(id, deadline) do
    case Worker.get_status(id) do
      :waiting ->
        :ok

      _ ->
        assert System.monotonic_time(:millisecond) < deadline
        Process.sleep(10)
        await_waiting(id, deadline)
    end
  end
end
