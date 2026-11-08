defmodule Synapsis.Memory.SessionSummaryTest do
  use ExUnit.Case, async: false

  alias Synapsis.Memory.SessionSummary
  alias Synapsis.Provider.{Adapter, Registry}
  alias Synapsis.Session.Store

  setup do
    assert Code.ensure_loaded?(SessionSummary),
           "bounded session summary domain is not implemented"

    :ok = Store.ensure_started()
    id = Ecto.UUID.generate()
    provider = "summary-fixture-#{System.unique_integer([:positive])}"
    fixture = Gaoxy.Test.open()

    :ok =
      Registry.register(provider, %{
        type: "openai",
        api_key: "fixture",
        base_url: Gaoxy.Test.url(fixture),
        default_model: "summary-fixture"
      })

    :ok = Store.put_meta(id, %{id: id, provider: provider, model: "session-model"})

    on_exit(fn ->
      Store.delete_session(id)
      Registry.unregister(provider)
    end)

    %{session_id: id, provider: provider, fixture: fixture}
  end

  test "heuristics preserve full, reversed recent and exclusive range without persistence", ctx do
    messages =
      for index <- 1..12,
          do:
            "message-#{String.pad_leading(to_string(index), 2, "0")} architecture context decision"

    put_messages(ctx, messages)
    before = Synapsis.Memory.list_semantic()

    for {selection, count, first} <- [
          {%{}, 12, "message-01"},
          {%{"scope" => "recent"}, 10, "message-12"},
          {%{"scope" => "range", "message_range" => [1, 3]}, 2, "message-02"}
        ] do
      args = Map.merge(selection, %{"focus" => "architecture", "use_llm" => false})
      assert {:ok, result} = SessionSummary.summarize(ctx.session_id, args)
      assert result.source == "durable_session"
      assert result.message_count == count
      assert [%{kind: "fact", summary: summary} | _] = result.candidates
      assert String.starts_with?(summary, first)
    end

    assert Synapsis.Memory.list_semantic() == before
    assert length(Synapsis.Message.list_by_session(ctx.session_id)) == 12
  end

  test "kinds restrict heuristic facts and provider results", ctx do
    put_messages(ctx, List.duplicate("architecture design decisions and operational lessons", 5))

    assert {:ok, %{candidates: [%{kind: "decision"}]}} =
             SessionSummary.summarize(ctx.session_id, %{
               "focus" => "architecture",
               "kinds" => ["decision"],
               "use_llm" => false
             })

    candidates = [candidate("fact"), candidate("decision")]
    response(ctx.fixture, candidates)

    assert {:ok,
            %{extraction: "llm", candidates: [%{kind: "decision", title: "Reviewed design"}]}} =
             SessionSummary.summarize(ctx.session_id, %{"kinds" => ["decision"]})
  end

  test "default LLM uses session provider and falls back on malformed candidate fields", ctx do
    put_messages(ctx, List.duplicate("architecture context and reviewed design", 5))
    owner = self()

    invalid = [
      %{"kind" => "invented"},
      %{"title" => %{secret: "untrusted"}},
      %{"summary" => 99},
      %{"tags" => "untrusted"},
      %{"importance" => 2.0}
    ]

    queue = start_supervised!({Agent, fn -> invalid end})

    Gaoxy.Test.stub(ctx.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:summary_request, Jason.decode!(body)})
      patch = Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)
      stream_response(conn, [Map.merge(candidate("fact"), patch)])
    end)

    for _ <- invalid do
      assert {:ok, %{extraction: "heuristic", candidates: [_ | _]}} =
               SessionSummary.summarize(ctx.session_id, %{})

      assert_receive {:summary_request, request}
      assert request["model"] == "summary-fixture"
      assert request["stream"] == true
    end
  end

  test "unavailable providers and empty sessions retain safe fallback results", ctx do
    Registry.unregister(ctx.provider)

    assert {:ok, %{candidates: [], message: "No messages to summarize"}} =
             SessionSummary.summarize(ctx.session_id, %{})

    put_messages(ctx, List.duplicate("architecture context and reviewed design", 5))

    assert {:ok, %{extraction: "heuristic", candidates: [_ | _]}} =
             SessionSummary.summarize(ctx.session_id, %{})
  end

  test "closed bounded inputs and transcripts fail before HTTP", ctx do
    for args <- [
          %{"session_id" => Ecto.UUID.generate()},
          %{"provider" => "other"},
          %{"scope" => "unknown"},
          %{"scope" => "range"},
          %{"scope" => "range", "message_range" => [0, -1]},
          %{"message_range" => [0, 1, 2]},
          %{"kinds" => ["invented"]},
          %{"focus" => String.duplicate("x", 513)},
          %{"use_llm" => "true"}
        ] do
      assert {:error, :invalid_input} = SessionSummary.summarize(ctx.session_id, args)
    end

    assert {:error, :invalid_context} = SessionSummary.summarize("/root/researcher:1", %{})

    assert {:error, :transcript_limit} =
             SessionSummary.summarize(ctx.session_id, %{"use_llm" => false},
               messages: [
                 %{
                   role: "user",
                   parts: [%Synapsis.Part.Text{content: String.duplicate("x", 131_073)}]
                 }
               ]
             )

    assert {:error, :message_limit} =
             SessionSummary.summarize(ctx.session_id, %{"use_llm" => false},
               messages: List.duplicate(%{role: "user", parts: []}, 201)
             )
  end

  test "deadline stops the real provider task and HTTP stream", ctx do
    interrupted_completion(ctx, :timeout)
  end

  test "caller death stops the real provider task and HTTP stream", ctx do
    interrupted_completion(ctx, :owner_death)
  end

  defp interrupted_completion(ctx, mode) do
    put_messages(ctx, [String.duplicate("architecture context ", 5)])
    owner = self()

    Gaoxy.Test.stub(ctx.fixture, "POST", "/v1/chat/completions", fn conn ->
      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      send(owner, :summary_http_started)
      await_disconnect(conn, owner, System.monotonic_time(:millisecond) + 3_000)
    end)

    caller =
      spawn(fn ->
        receive do
          :go ->
            opts =
              if mode == :timeout,
                do: [deadline: System.monotonic_time(:millisecond) + 500],
                else: []

            send(owner, {:summary_finished, SessionSummary.summarize(ctx.session_id, %{}, opts)})
        end
      end)

    :erlang.trace_pattern({Adapter, :stream, 3}, [{:_, [], [{:return_trace}]}], [:local])
    :erlang.trace(caller, true, [:call, :procs, :set_on_spawn, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace_pattern({Adapter, :stream, 3}, false, [:local])
      Process.exit(caller, :kill)
    end)

    send(caller, :go)

    assert_receive {:trace, _worker, :return_from, {Adapter, :stream, 3},
                    {:ok, %{pid: provider}}},
                   1_000

    on_exit(fn -> Process.exit(provider, :kill) end)
    monitor = Process.monitor(provider)
    assert_receive :summary_http_started, 1_000

    if mode == :owner_death do
      Process.exit(caller, :kill)
    else
      assert_receive {:summary_finished, {:error, :timeout}}, 1_500
    end

    assert_receive {:DOWN, ^monitor, :process, ^provider, _}, 1_000
    assert_receive :summary_http_disconnected, 1_000
  end

  defp await_disconnect(conn, owner, deadline) do
    case Gaoxy.HTTP.poll_connection(conn, 0) do
      {:error, reason, conn} when reason in [:closed, :econnreset] ->
        send(owner, :summary_http_disconnected)
        conn

      {:pending, conn} ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do: (:release -> conn), after: (10 -> await_disconnect(conn, owner, deadline))
        else
          conn
        end
    end
  end

  defp put_messages(ctx, texts) do
    turns =
      Enum.map(
        texts,
        &%{id: Ecto.UUID.generate(), role: "user", parts: [%{type: "text", text: &1}]}
      )

    :ok =
      Store.commit_turns(ctx.session_id, 0, turns, %{id: ctx.session_id, provider: ctx.provider})
  end

  defp candidate(kind),
    do: %{
      "kind" => kind,
      "title" => "Reviewed design",
      "summary" => "Keep ownership explicit.",
      "tags" => ["design"],
      "importance" => 0.7
    }

  defp response(fixture, candidates),
    do: Gaoxy.Test.stub(fixture, "POST", "/v1/chat/completions", &stream_response(&1, candidates))

  defp stream_response(conn, candidates) do
    chunk = %{
      "id" => "summary",
      "choices" => [%{"index" => 0, "delta" => %{"content" => Jason.encode!(candidates)}}]
    }

    finish = %{
      "id" => "summary",
      "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
    }

    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_resp(
      200,
      "data: #{Jason.encode!(chunk)}\n\ndata: #{Jason.encode!(finish)}\n\ndata: [DONE]\n\n"
    )
  end
end
