defmodule SynapsisWeb.AgentLive.OperatorInputProvenanceFunctionalTest do
  use SynapsisWeb.ConnCase, async: false

  import Synapsis.Agent.DaemonCase, only: [wait_for: 1]

  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Session.{PendingInputStore, Store, Worker}
  alias Synapsis.{Message, Part, Sessions}

  @moduletag :tmp_dir
  @moduletag timeout: 60_000
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="

  test "real LiveView sends retain trimmed text and queued PNG operator provenance", ctx do
    h = fixture(ctx.tmp_dir)
    id = h.session.id
    tag = h.tag
    route = ~p"/agent/agents/#{h.agent_name}/sessions/#{id}"
    assert {:ok, view, _html} = live(ctx.conn, route)

    send_chat(view, %{
      "request_id" => Ecto.UUID.generate(),
      "text" => "  First LiveView/聊天 É  ",
      "images" => []
    })

    assert_push_event(view, "clear_chat_input", %{})
    assert_receive {:operator_request, ^tag, 0, first_request, first_handler}, 5_000
    assert wire_messages(first_request) == [{"user", wire_parts("First LiveView/聊天 É", false)}]
    first = operator_context(id, "liveview")
    assert_custody(id, [{first, "First LiveView/聊天 É", false}])

    send_chat(view, %{
      "request_id" => Ecto.UUID.generate(),
      "text" => "  Second LiveView/image Δ  ",
      "images" => [%{"media_type" => "image/png", "data" => @png}]
    })

    assert_push_event(view, "clear_chat_input", %{})
    assert {:ok, pending} = PendingInputStore.list_result(id)
    assert [queued] = Enum.filter(pending, &(&1.status == "queued"))
    second = queued.input_provenance
    assert_operator_map(second, id, "liveview")
    assert queued.id == second["input_id"]
    assert queued.kind == "prompt"
    assert queued.content == "Second LiveView/image Δ"
    assert queued.image_parts == [image_part()]
    assert second["input_id"] != first["input_id"]

    send(first_handler, :complete_operator_request)
    assert_receive {:operator_request, ^tag, 1, second_request, second_handler}, 10_000

    assert wire_messages(second_request) == [
             {"user", wire_parts("First LiveView/聊天 É", false)},
             {"assistant", wire_parts("operator ingress reply 0", false)},
             {"user", wire_parts("Second LiveView/image Δ", true)}
           ]

    assert_root_context(id, second)
    expected = [{first, "First LiveView/聊天 É", false}, {second, "Second LiveView/image Δ", true}]
    assert_custody(id, expected)
    send(second_handler, :complete_operator_request)
    await_idle(id)
    assert_custody(id, expected)
    assert {:ok, consumed} = PendingInputStore.list_result(id)
    assert Enum.find(consumed, &(&1.id == second["input_id"])).status == "consumed"

    assert {:ok, reconnected, _html} = live(ctx.conn, route)
    assert render(reconnected) =~ "First LiveView"
    assert render(reconnected) =~ "Second LiveView"
    assert_custody(id, expected)
  end

  defp send_chat(view, params) do
    render(view)
    chat = :sys.get_state(view.pid).socket.assigns.react_chat

    render_hook(
      view,
      "chat.send",
      Map.merge(%{"id" => chat.id, "conversation_id" => chat.conversation_id}, params)
    )
  end

  defp fixture(root) do
    owner = self()
    tag = Ecto.UUID.generate()

    h =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    Gaoxy.Test.stub(h.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      handler = self()

      index =
        Agent.get_and_update(h.counter, fn state ->
          entries = state.provider_requests
          {length(entries), %{state | provider_requests: entries ++ [{request, handler}]}}
        end)

      send(owner, {:operator_request, tag, index, request, handler})

      receive do
        :complete_operator_request -> :ok
      after
        20_000 -> raise "ordinary operator fixture was not released"
      end

      DeterministicProvider.send_sse(conn, [
        DeterministicProvider.text_chunk("operator ingress reply #{index}"),
        DeterministicProvider.finish_chunk("stop")
      ])
    end)

    on_exit(fn ->
      if Process.alive?(h.counter) do
        for {_request, handler} <- Agent.get(h.counter, & &1.provider_requests),
            do: send(handler, :complete_operator_request)
      end

      SessionHarness.cleanup!(h)
    end)

    Map.put(h, :tag, tag)
  end

  defp operator_context(id, origin) do
    adapter = root_adapter(id)
    context = adapter.context[:input_context]
    assert_operator_map(context, id, origin)
    assert :sys.get_state(adapter.root).opts[:host_context][:input_context] == context
    context
  end

  defp assert_operator_map(context, id, origin) do
    assert is_map(context)
    assert {:ok, input_id} = Ecto.UUID.cast(context["input_id"])

    assert context == %{
             "version" => 1,
             "kind" => "operator",
             "trigger" => "user",
             "requester_id" => "synapsis:operator",
             "origin" => origin,
             "source_session_id" => id,
             "input_id" => input_id
           }
  end

  defp assert_root_context(id, expected) do
    adapter = root_adapter(id)
    assert adapter.context[:input_context] == expected
    assert :sys.get_state(adapter.root).opts[:host_context][:input_context] == expected
  end

  defp root_adapter(id) do
    assert {:ok, adapter} =
             wait_for(fn ->
               [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
               {_phase, data} = :sys.get_state(worker)

               if is_pid(data.runtime_pid) do
                 state = :sys.get_state(data.runtime_pid)
                 if is_pid(state.root), do: {:ok, state}, else: :retry
               else
                 :retry
               end
             end)

    adapter
  end

  defp assert_custody(id, expected) do
    ids = Enum.map(expected, fn {context, _, _} -> context["input_id"] end)
    live = Enum.filter(Sessions.get_messages(id), &(&1.id in ids))
    durable = Enum.filter(Message.list_by_session(id), &(&1.id in ids))
    assert Enum.map(live, & &1.id) == ids
    assert Enum.map(durable, & &1.id) == ids
    assert {:ok, turns} = Store.list_turns(id)
    selected = Enum.filter(turns, &(&1.id in ids))
    assert Enum.map(selected, & &1.id) == ids

    for {context, text, image?} <- expected do
      for message <- live ++ durable, message.id == context["input_id"] do
        assert message.role == "user"
        assert message.input_provenance == context
        assert message.parts == parts(text, image?)
      end

      turn =
        Enum.find(selected, &(&1.id == context["input_id"])) |> Jason.encode!() |> Jason.decode!()

      assert turn["role"] == "user"
      assert turn["input_provenance"] == context
      assert turn["parts"] == encoded_parts(text, image?)
    end
  end

  defp await_idle(id) do
    assert {:ok, :idle} =
             wait_for(fn ->
               case Worker.public_status(id) do
                 {:ok, %{runtime: %{active: false}}} -> {:ok, :idle}
                 _ -> :retry
               end
             end)
  end

  defp image_part, do: %Part.Image{media_type: "image/png", data: @png, path: nil}
  defp parts(text, false), do: [%Part.Text{content: text}]
  defp parts(text, true), do: [%Part.Text{content: text}, image_part()]
  defp encoded_parts(text, false), do: [%{"type" => "text", "text" => text}]

  defp encoded_parts(text, true),
    do:
      encoded_parts(text, false) ++
        [%{"type" => "image", "media_type" => "image/png", "data" => @png, "path" => nil}]

  defp wire_parts(text, false), do: [%{"type" => "text", "text" => text}]

  defp wire_parts(text, true),
    do:
      wire_parts(text, false) ++
        [%{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64," <> @png}}]

  defp wire_messages(request) do
    request["messages"]
    |> Enum.reject(&(&1["role"] == "system"))
    |> Enum.map(fn message ->
      content = message["content"]
      blocks = if is_binary(content), do: [%{"type" => "text", "text" => content}], else: content
      {message["role"], blocks}
    end)
  end
end
