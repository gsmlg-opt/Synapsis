defmodule SynapsisCli.EventReplyFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias SynapsisCli.Main

  defmodule Output do
    use GenServer
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    def init(owner), do: {:ok, %{owner: owner, text: ""}}
    def handle_call(:text, _from, state), do: {:reply, state.text, state}

    def handle_info({:io_request, from, ref, request}, state) do
      text = render(request)
      send(state.owner, {:cli_output, text})
      send(from, {:io_reply, ref, :ok})
      {:noreply, %{state | text: state.text <> text}}
    end

    defp render({:put_chars, _encoding, module, function, args}),
      do: module |> apply(function, args) |> IO.iodata_to_binary()

    defp render({:put_chars, _encoding, chars}), do: IO.iodata_to_binary(chars)
    defp render({:put_chars, chars}), do: IO.iodata_to_binary(chars)
    defp render({:requests, requests}), do: Enum.map_join(requests, &render/1)
  end

  test "actual Main stream delays event text until committed output and preserves tool output" do
    fixture = fixture()
    scope = scope(fixture.id)
    raw = "HEARTBEAT_OK Ready🙂"
    first = envelope(scope, 1, "preview", %{text: "HEARTBEAT_", hidden: false, responses: []})
    cleared = envelope(scope, 2, "preview", %{text: "", hidden: true, responses: []})
    reconciled = envelope(scope, 3, "response", %{text: "Ready🙂", hidden: false, responses: []})

    committed =
      envelope(scope, 4, "committed", %{
        message_id: uuid(),
        response_index: 0,
        text: "Ready🙂",
        hidden: false,
        text_parts: [%{index: 0, text: "Ready🙂"}]
      })

    hidden =
      envelope(scope, 5, "committed", %{
        message_id: uuid(),
        response_index: 1,
        text: "",
        hidden: true,
        text_parts: [%{index: 0, text: ""}]
      })

    marker = "tool-visible-before-commit"

    install_stream(fixture, %{status: "streaming"}, fn conn ->
      before =
        frame("text_delta", %{text: "HEARTBEAT_", reply_presentation: first}) <>
          frame("text_delta", %{text: "OK Ready🙂", reply_presentation: cleared}) <>
          frame("reply_presentation", reconciled) <>
          frame("tool_result", %{content: marker, is_error: false})

      conn = chunk_split_utf8(conn, before, "🙂")
      send(fixture.owner, {:cli_held, self()})
      await_finish()

      conn =
        chunk!(
          conn,
          frame("reply_presentation", committed) <>
            frame("reply_presentation", committed) <>
            frame("reply_presentation", hidden) <>
            frame("reply_presentation", envelope(scope, 6, "closed", %{})) <>
            frame("done", %{})
        )

      conn
    end)

    output = start_supervised!({Output, self()})
    run_cli(fixture, output)
    assert_receive {:cli_held, handler}, 5_000
    on_exit(fn -> send(handler, :finish_cli) end)
    await_output(marker)
    expected_tool = IO.ANSI.green() <> marker <> IO.ANSI.reset() <> "\n"
    assert GenServer.call(output, :text) == expected_tool
    send(handler, :finish_cli)
    assert_receive {:cli_finished, :ok}, 5_000
    assert GenServer.call(output, :text) == expected_tool <> "Ready🙂\n"
    refute GenServer.call(output, :text) =~ raw
  end

  test "committed snapshot output and queued envelopes print each stored message once in order" do
    fixture = fixture()
    scope = scope(fixture.id)

    first = %{
      message_id: uuid(),
      response_index: 0,
      text: "Saved🙂",
      hidden: false,
      text_parts: [%{index: 0, text: "Saved🙂"}]
    }

    hidden = %{
      message_id: uuid(),
      response_index: 1,
      text: "",
      hidden: true,
      text_parts: [%{index: 0, text: ""}]
    }

    second = %{
      message_id: uuid(),
      response_index: 2,
      text: "Next",
      hidden: false,
      text_parts: [%{index: 0, text: "Next"}]
    }

    snapshot =
      envelope(scope, 10, "closed", %{
        text: "Saved🙂\n\nNext",
        hidden: false,
        responses: [],
        committed_messages: [first, hidden, second]
      })

    install_stream(fixture, %{status: "streaming", reply_presentation: snapshot}, fn conn ->
      bytes =
        frame("text_delta", %{
          text: "HEARTBEAT_OK",
          reply_presentation:
            envelope(scope, 2, "preview", %{text: "HEARTBEAT_OK", hidden: false, responses: []})
        }) <>
          frame("reply_presentation", envelope(scope, 6, "committed", first)) <>
          frame("reply_presentation", envelope(scope, 7, "committed", hidden)) <>
          frame("reply_presentation", envelope(scope, 9, "committed", second)) <>
          frame("reply_presentation", envelope(scope, 9, "committed", second)) <>
          frame("reply_presentation", envelope(scope, 10, "closed", %{})) <> frame("done", %{})

      chunk_split_utf8(conn, bytes, "HEARTBEAT_OK")
    end)

    output = start_supervised!({Output, self()})
    run_cli(fixture, output)
    assert_receive {:cli_finished, :ok}, 5_000
    assert GenServer.call(output, :text) == "Saved🙂\n\nNext\n"
  end

  test "ordinary literal marker reply still streams immediately through split UTF8 and SSE frames" do
    fixture = fixture()
    raw = "HEARTBEAT_OK ordinary 🌙"

    install_stream(fixture, %{status: "streaming"}, fn conn ->
      conn = chunk_split_utf8(conn, frame("text_delta", %{text: raw}), "🌙")
      send(fixture.owner, {:ordinary_held, self()})
      await_finish()
      chunk!(conn, frame("text_delta", %{text: "\nkept"}) <> frame("done", %{}))
    end)

    output = start_supervised!({Output, self()})
    run_cli(fixture, output)
    assert_receive {:ordinary_held, handler}, 5_000
    on_exit(fn -> send(handler, :finish_cli) end)
    await_output(raw)
    assert GenServer.call(output, :text) == raw
    send(handler, :finish_cli)
    assert_receive {:cli_finished, :ok}, 5_000
    assert GenServer.call(output, :text) == raw <> "\nkept\n"
  end

  test "idle event snapshot leaves the next ordinary request output unchanged" do
    fixture = fixture()
    old = closed_snapshot(fixture.id)

    install_stream(fixture, %{status: "waiting", reply_presentation: old}, fn conn ->
      chunk!(conn, frame("text_delta", %{text: "Next ordinary reply"}) <> frame("done", %{}))
    end)

    output = start_supervised!({Output, self()})
    run_cli(fixture, output)
    assert_receive {:cli_finished, :ok}, 5_000
    assert GenServer.call(output, :text) == "Next ordinary reply\n"
  end

  test "idle event snapshot leaves the request available for the newly selected event" do
    fixture = fixture()
    old = closed_snapshot(fixture.id)
    selected = scope(fixture.id)

    committed =
      envelope(selected, 2, "committed", %{
        message_id: uuid(),
        text: "New event reply",
        hidden: false
      })

    install_stream(fixture, %{status: "waiting", reply_presentation: old}, fn conn ->
      chunk!(
        conn,
        frame("text_delta", %{
          text: "HEARTBEAT_OK",
          reply_presentation: envelope(selected, 1, "preview", %{text: "", hidden: true})
        }) <>
          frame("reply_presentation", committed) <>
          frame("reply_presentation", envelope(selected, 3, "closed", %{})) <>
          frame("done", %{})
      )
    end)

    output = start_supervised!({Output, self()})
    run_cli(fixture, output)
    assert_receive {:cli_finished, :ok}, 5_000
    assert GenServer.call(output, :text) == "New event reply\n"
  end

  defp closed_snapshot(id) do
    envelope(scope(id), 3, "closed", %{
      committed_messages: [%{message_id: uuid(), text: "Earlier event reply", hidden: false}]
    })
  end

  defp fixture do
    http = Gaoxy.Test.open()
    id = uuid()
    state = start_supervised!({Agent, fn -> nil end})
    owner = self()

    Gaoxy.Test.expect_once(http, "POST", "/api/sessions", fn conn ->
      json(conn, 201, %{data: %{id: id}})
    end)

    Gaoxy.Test.expect_once(http, "POST", "/api/sessions/#{id}/messages", fn conn ->
      handler = Agent.get(state, & &1)
      assert is_pid(handler)
      send(handler, :submitted)
      json(conn, 200, %{ok: true})
    end)

    %{
      http: http,
      id: id,
      owner: owner,
      state: state,
      host: String.trim_trailing(Gaoxy.Test.url(http), "/")
    }
  end

  defp install_stream(fixture, initial, emit) do
    Gaoxy.Test.expect_once(fixture.http, "GET", "/api/sessions/#{fixture.id}/events", fn conn ->
      handler = self()
      Agent.update(fixture.state, fn _ -> handler end)

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      conn = chunk!(conn, frame("session_state", initial))

      receive do
        :submitted -> emit.(conn)
      after
        5_000 -> flunk("CLI did not submit after subscribing")
      end
    end)
  end

  defp run_cli(fixture, output) do
    start_supervised!(
      {Task,
       fn ->
         Process.group_leader(self(), output)

         send(
           fixture.owner,
           {:cli_finished, Main.run(["--prompt", "ordinary caller", "--host", fixture.host])}
         )
       end}
    )
  end

  defp await_output(marker, seen \\ "") do
    if String.contains?(seen, marker) do
      :ok
    else
      receive do
        {:cli_output, text} -> await_output(marker, seen <> text)
      after
        5_000 -> flunk("CLI output did not reach #{inspect(marker)}")
      end
    end
  end

  defp await_finish do
    receive do
      :finish_cli -> :ok
    after
      10_000 -> flunk("CLI commit gate was not released")
    end
  end

  defp chunk_split_utf8(conn, bytes, symbol) do
    {offset, _} = :binary.match(bytes, symbol)
    split = offset + div(byte_size(symbol), 2)
    <<first::binary-size(split), rest::binary>> = bytes
    conn |> chunk!(first) |> chunk!(rest)
  end

  defp chunk!(conn, bytes) do
    assert {:ok, conn} = Plug.Conn.chunk(conn, bytes)
    conn
  end

  defp frame(event, data), do: "event: #{event}\r\ndata: #{Jason.encode!(data)}\r\n\r\n"

  defp json(conn, status, data),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(data))

  defp uuid do
    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12)>> =
      :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    Enum.join([a, b, c, d, e], "-")
  end

  defp scope(id),
    do: %{
      version: 1,
      policy: "manual_event_message",
      session_id: id,
      occurrence_id: uuid(),
      run_id: "event-run"
    }

  defp envelope(scope, revision, phase, fields),
    do: Map.merge(scope, Map.merge(fields, %{revision: revision, phase: phase}))
end
