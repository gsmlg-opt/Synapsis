defmodule Synapsis.Session.WorkerTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Session
  alias Synapsis.Session.PendingInputStore
  alias Synapsis.Session.Worker
  alias Synapsis.Session.Worker.Persistence
  alias Synapsis.{Message, Part}

  # ADR-006 C4: sessions live in the Concord-backed Session.Store, not Ecto.
  defp build_session(attrs) do
    %Session{}
    |> Session.changeset(
      Map.merge(
        %{
          provider: "anthropic",
          model: "test-model",
          agent: "main",
          config: %{"subagents" => false}
        },
        attrs
      )
    )
    |> Ecto.Changeset.apply_changes()
    |> Map.put(:id, Ecto.UUID.generate())
  end

  defp persist_session(attrs) do
    session = build_session(attrs)
    :ok = Session.Store.put_meta(session.id, Session.to_meta(session))
    session
  end

  test "model switches are rejected in every active legacy state" do
    state = %Worker{session_id: "busy", session: build_session(%{})}
    from = {self(), make_ref()}

    for status <- [:generating, :executing_tools, :awaiting_approval, :busy, :query_loop] do
      assert {:keep_state_and_data, actions} =
               Worker.handle_event(
                 {:call, from},
                 {:switch_model, "google", "gemini"},
                 status,
                 state
               )

      assert {:reply, from, {:error, :session_busy}} in actions
    end
  end

  # --- A2: tool execution robustness ---

  # --- ADR-008: explicit session states ---

  describe "derive_state/1" do
    defp base_data do
      %Worker{
        session_id: "test",
        engine_node: :receive,
        engine_state: %{awaiting_input: true},
        engine_ctx: %{},
        epoch: 1
      }
    end

    test ":idle when the engine is parked at :receive" do
      assert Worker.derive_state(base_data()) == :idle
    end

    test ":generating when a provider stream is in flight" do
      assert Worker.derive_state(%{base_data() | stream_ref: make_ref()}) == :generating
    end

    test ":executing_tools when tool tasks are outstanding" do
      assert Worker.derive_state(%{base_data() | pending_tool_count: 2}) == :executing_tools
    end

    test ":awaiting_approval when permission decisions are pending" do
      data = %{base_data() | pending_approvals: MapSet.new(["tool-1"])}
      assert Worker.derive_state(data) == :awaiting_approval
    end

    test ":awaiting_approval wins over :generating (approval blocks the turn)" do
      data = %{
        base_data()
        | pending_approvals: MapSet.new(["tool-1"]),
          stream_ref: make_ref()
      }

      assert Worker.derive_state(data) == :awaiting_approval
    end

    test ":busy when the engine waits on a non-input node" do
      data = %{base_data() | engine_node: :llm_stream, engine_state: %{}}
      assert Worker.derive_state(data) == :busy
    end

    test ":query_loop when an assistant-mode turn is running" do
      task = %Task{ref: make_ref(), pid: self(), owner: self(), mfa: {__MODULE__, :noop, 0}}
      data = %{base_data() | execution_mode: :query_loop, query_loop_task: task}
      assert Worker.derive_state(data) == :query_loop
    end
  end

  describe "busy-prompt policy (harness ADR-0006)" do
    test "steer_message/2 public API exists" do
      assert function_exported?(Worker, :steer_message, 2)
    end
  end

  describe "user image persistence" do
    test "persists an image-only prompt without an empty text part" do
      session = persist_session(%{status: "idle"})
      image = %Part.Image{media_type: "image/png", data: "base64data", path: nil}

      assert :ok = Persistence.persist_user_message(session.id, "   ", [image])

      assert [
               %Message{
                 role: "user",
                 parts: [%Part.Image{media_type: "image/png", data: "base64data"}]
               }
             ] = Message.list_by_session(session.id)
    end

    test "persists nonblank text before image parts" do
      session = persist_session(%{status: "idle"})
      image = %Part.Image{media_type: "image/png", data: "base64data", path: nil}

      assert :ok = Persistence.persist_user_message(session.id, "describe", [image])

      assert [
               %Message{
                 role: "user",
                 parts: [
                   %Part.Text{content: "describe"},
                   %Part.Image{media_type: "image/png", data: "base64data"}
                 ]
               }
             ] = Message.list_by_session(session.id)
    end

    test "Sessions.send_message/3 accepts canonical image parts" do
      session = persist_session(%{status: "idle"})
      image = %Part.Image{media_type: "image/png", data: "base64data", path: nil}
      assert :ok = Synapsis.Sessions.ensure_running(session.id)
      assert [{pid, _}] = Registry.lookup(Synapsis.Session.Registry, session.id)

      :ok = await_worker_idle(pid)

      :sys.replace_state(pid, fn {:idle, data} ->
        {:generating, %{data | stream_ref: make_ref(), engine_node: :llm_stream}}
      end)

      assert :ok = Synapsis.Sessions.send_message(session.id, "describe", [image])

      assert [
               %{
                 content: "describe",
                 image_parts: [%Part.Image{media_type: "image/png", data: "base64data"}]
               }
             ] = PendingInputStore.queued_prompts(session.id)

      assert Message.list_by_session(session.id) == []
    end
  end

  describe "regenerate" do
    test "truncates the transcript to before the target assistant message" do
      session = persist_session(%{status: "idle"})
      {:ok, _q1} = Message.append(session.id, text_message("user", "q1"))
      {:ok, _a1} = Message.append(session.id, text_message("assistant", "a1"))
      {:ok, _q2} = Message.append(session.id, text_message("user", "q2"))
      {:ok, a2} = Message.append(session.id, text_message("assistant", "a2"))

      assert {:ok, "q2"} = Persistence.truncate_to_regenerate(session.id, a2.id)

      assert [
               %Message{role: "user", parts: [%Part.Text{content: "q1"}]},
               %Message{role: "assistant", parts: [%Part.Text{content: "a1"}]},
               %Message{role: "user", parts: [%Part.Text{content: "q2"}]}
             ] = Message.list_by_session(session.id)
    end

    test "regenerating an earlier reply discards every later turn" do
      session = persist_session(%{status: "idle"})
      {:ok, _q1} = Message.append(session.id, text_message("user", "q1"))
      {:ok, a1} = Message.append(session.id, text_message("assistant", "a1"))
      {:ok, _q2} = Message.append(session.id, text_message("user", "q2"))
      {:ok, _a2} = Message.append(session.id, text_message("assistant", "a2"))

      assert {:ok, "q1"} = Persistence.truncate_to_regenerate(session.id, a1.id)

      assert [%Message{role: "user", parts: [%Part.Text{content: "q1"}]}] =
               Message.list_by_session(session.id)
    end

    test "rejects a non-assistant target without mutating the transcript" do
      session = persist_session(%{status: "idle"})
      {:ok, q1} = Message.append(session.id, text_message("user", "q1"))
      {:ok, _a1} = Message.append(session.id, text_message("assistant", "a1"))

      assert {:error, :not_assistant_message} =
               Persistence.truncate_to_regenerate(session.id, q1.id)

      assert [%Message{role: "user"}, %Message{role: "assistant"}] =
               Message.list_by_session(session.id)
    end

    test "rejects an unknown message id" do
      session = persist_session(%{status: "idle"})
      {:ok, _a1} = Message.append(session.id, text_message("assistant", "a1"))

      assert {:error, :message_not_found} =
               Persistence.truncate_to_regenerate(session.id, Ecto.UUID.generate())
    end

    test "rejects when no user message precedes the target" do
      session = persist_session(%{status: "idle"})
      {:ok, a1} = Message.append(session.id, text_message("assistant", "a1"))

      assert {:error, :no_user_context} =
               Persistence.truncate_to_regenerate(session.id, a1.id)
    end
  end

  describe "session checkpoints" do
  end

  defp text_message(role, content) do
    %Message{role: role, parts: [%Part.Text{content: content}], token_count: 1}
  end

  # The Worker briefly reconciles its durable input queue after boot.
  defp await_worker_idle(pid, attempts \\ 200) do
    case :sys.get_state(pid) do
      {:idle, _data} ->
        :ok

      _busy when attempts > 0 ->
        Process.sleep(10)
        await_worker_idle(pid, attempts - 1)

      {state, _data} ->
        flunk("session worker stayed #{inspect(state)}")
    end
  end
end
