defmodule SynapsisServer.SessionIngressProvenanceFunctionalTest do
  use SynapsisServer.ConnCase, async: false
  @moduletag :functional

  require Phoenix.ChannelTest
  import Synapsis.Agent.DaemonCase, only: [wait_for: 1]

  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Session.{DynamicSupervisor, InputContext, PendingInputStore, Store, Worker}
  alias Synapsis.{Message, Part, Sessions}

  @moduletag :tmp_dir
  @moduletag timeout: 60_000
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="

  test "REST text and queued image retain operator custody through a normal fresh Worker", ctx do
    h = fixture(ctx.tmp_dir)
    id = h.session.id

    submit = fn payload ->
      response =
        ctx.conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> post("/api/sessions/#{id}/messages", Jason.encode!(payload))

      assert json_response(response, 200) == %{"status" => "ok"}
    end

    exercise_ingress(h, "rest", submit)
  end

  test "channel join and actual pushes retain direct and queued image operator custody", ctx do
    h = fixture(ctx.tmp_dir)
    assert {:ok, socket} = Phoenix.ChannelTest.connect(SynapsisServer.UserSocket, %{})

    assert {:ok, %{messages: []}, socket} =
             Phoenix.ChannelTest.join(socket, "session:#{h.session.id}", %{})

    submit = fn payload ->
      ref = Phoenix.ChannelTest.push(socket, "session:message", payload)
      Phoenix.ChannelTest.assert_reply(ref, :ok, %{}, 5_000)
    end

    exercise_ingress(h, "channel", submit)
  end

  test "ordinary old and context-aware Sessions map sends preserve identical PNG preparation",
       ctx do
    old = fixture(ctx.tmp_dir)
    fresh = fixture(ctx.tmp_dir)
    path = image_path(ctx.tmp_dir)
    payload = %{content: "Read this PNG/É", images: [path]}
    old_tag = old.tag
    fresh_tag = fresh.tag

    assert :ok = Sessions.send_message(old.session.id, payload)
    assert_receive {:operator_request, ^old_tag, 0, old_request, old_handler}, 5_000
    send(old_handler, :complete_operator_request)
    await_idle(old.session.id)

    assert {:ok, context} =
             InputContext.capture_operator(fresh.session.id, %{
               requester_id: "synapsis:operator",
               origin: "rest"
             })

    assert :ok = Sessions.send_message(fresh.session.id, payload, context)
    assert_receive {:operator_request, ^fresh_tag, 0, fresh_request, fresh_handler}, 5_000
    assert_root_context(fresh.session.id, context)
    assert wire_messages(old_request) == [{"user", wire_parts("Read this PNG/É", true)}]
    assert wire_messages(fresh_request) == wire_messages(old_request)
    send(fresh_handler, :complete_operator_request)
    await_idle(fresh.session.id)

    old_user = Enum.find(Message.list_by_session(old.session.id), &(&1.role == "user"))

    new_user =
      Enum.find(Message.list_by_session(fresh.session.id), &(&1.id == context["input_id"]))

    assert old_user.parts == parts("Read this PNG/É", true)
    assert new_user.parts == old_user.parts
    assert_custody(fresh.session.id, [{context, "Read this PNG/É", true}])
    assert File.read!(path) == Base.decode64!(@png)
  end

  defp exercise_ingress(h, origin, submit) do
    id = h.session.id
    tag = h.tag
    path = image_path(h.tmp_dir)
    first_text = "First #{origin}/聊天 É"
    second_text = "Second #{origin}/image Δ"

    submit.(%{"content" => first_text})
    assert_receive {:operator_request, ^tag, 0, first_request, first_handler}, 5_000
    assert wire_messages(first_request) == [{"user", wire_parts(first_text, false)}]
    first = operator_context(id, origin)
    assert_custody(id, [{first, first_text, false}])

    submit.(%{"content" => second_text, "images" => [path]})
    assert {:ok, pending} = PendingInputStore.list_result(id)
    assert [queued] = Enum.filter(pending, &(&1.status == "queued"))
    second = queued.input_provenance
    assert_operator_map(second, id, origin)
    assert queued.id == second["input_id"]
    assert queued.kind == "prompt"
    assert queued.content == second_text
    assert queued.image_parts == [image_part()]
    assert second["input_id"] != first["input_id"]

    send(first_handler, :complete_operator_request)
    assert_receive {:operator_request, ^tag, 1, second_request, second_handler}, 10_000

    assert wire_messages(second_request) == [
             {"user", wire_parts(first_text, false)},
             {"assistant", wire_parts("operator ingress reply 0", false)},
             {"user", wire_parts(second_text, true)}
           ]

    assert_root_context(id, second)
    expected = [{first, first_text, false}, {second, second_text, true}]
    assert_custody(id, expected)
    send(second_handler, :complete_operator_request)
    await_idle(id)
    assert_custody(id, expected)
    assert {:ok, consumed} = PendingInputStore.list_result(id)
    assert Enum.find(consumed, &(&1.id == second["input_id"])).status == "consumed"

    [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    monitor = Process.monitor(old_worker)
    assert :ok = DynamicSupervisor.stop_session(id)
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, _}, 5_000
    assert :ok = Sessions.ensure_running(id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    assert new_worker != old_worker
    assert Process.alive?(new_worker)
    assert_custody(id, expected)

    submit.(%{"content" => "Recall both completed inputs"})
    assert_receive {:operator_request, ^tag, 2, replay, replay_handler}, 10_000
    third = operator_context(id, origin)
    assert third["input_id"] not in [first["input_id"], second["input_id"]]

    assert wire_messages(replay) == [
             {"user", wire_parts(first_text, false)},
             {"assistant", wire_parts("operator ingress reply 0", false)},
             {"user", wire_parts(second_text, true)},
             {"assistant", wire_parts("operator ingress reply 1", false)},
             {"user", wire_parts("Recall both completed inputs", false)}
           ]

    send(replay_handler, :complete_operator_request)
    await_idle(id)
    assert_custody(id, expected ++ [{third, "Recall both completed inputs", false}])
    assert File.read!(path) == Base.decode64!(@png)
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

  defp image_path(root) do
    path = Path.join(root, "operator-input.png")
    File.write!(path, Base.decode64!(@png))
    path
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
