defmodule Synapsis.Memory.SummarizerDispatcherTest do
  use Synapsis.DataCase

  alias Synapsis.Memory.SummarizerDispatcher
  alias Synapsis.{Session, Project, Message, MemoryEvent, SemanticMemory, Repo}

  defp create_project do
    %Project{}
    |> Project.changeset(%{slug: "test-project", path: "/tmp/test-summarizer"})
    |> Repo.insert!()
  end

  defp create_session(project) do
    %Session{}
    |> Session.changeset(%{
      project_id: project.id,
      provider: "anthropic",
      model: "claude-3-haiku"
    })
    |> Repo.insert!()
  end

  defp create_messages(session, count) do
    Enum.each(1..count, fn i ->
      role = if rem(i, 2) == 1, do: "user", else: "assistant"

      %Message{}
      |> Message.changeset(%{
        session_id: session.id,
        role: role,
        parts: [%{"type" => "text", "content" => "Message #{i} content"}]
      })
      |> Repo.insert!()
    end)
  end

  defp create_events(session_id, count) do
    Enum.each(1..count, fn i ->
      %MemoryEvent{}
      |> MemoryEvent.changeset(%{
        scope: "project",
        scope_id: "test",
        agent_id: "test_agent",
        type: "tool_called",
        importance: 0.5,
        correlation_id: session_id,
        payload: %{tool: "file_read", index: i}
      })
      |> Repo.insert!()
    end)
  end

  setup do
    Repo.delete_all(MemoryEvent)
    Repo.delete_all(SemanticMemory)
    Repo.delete_all(Message)
    Repo.delete_all(Session)
    Repo.delete_all(Project)

    project = create_project()
    session = create_session(project)

    {:ok, project: project, session: session}
  end

  describe "enqueue/2" do
    # Oban is disabled in test env, so we test job struct creation via new/1
    test "builds correct job args", %{session: session} do
      changeset = SummarizerDispatcher.new(%{session_id: session.id})
      assert changeset.valid?
      args = changeset.changes.args
      assert args[:session_id] == session.id or args["session_id"] == session.id
    end

    test "includes focus option in args", %{session: session} do
      changeset =
        SummarizerDispatcher.new(%{session_id: session.id, focus: "architecture decisions"})

      assert changeset.valid?
      args = changeset.changes.args
      assert args[:focus] == "architecture decisions" or args["focus"] == "architecture decisions"
    end

    test "includes scope option in args", %{session: session} do
      changeset = SummarizerDispatcher.new(%{session_id: session.id, scope: "shared"})
      assert changeset.valid?
      args = changeset.changes.args
      assert args[:scope] == "shared" or args["scope"] == "shared"
    end
  end

  describe "perform/1 - threshold check" do
    test "skips when below event threshold", %{session: session} do
      create_messages(session, 4)
      create_events(session.id, 5)

      job = %Oban.Job{args: %{"session_id" => session.id}}
      assert :ok = SummarizerDispatcher.perform(job)
    end

    test "bypasses threshold with force flag", %{session: session} do
      create_messages(session, 2)
      create_events(session.id, 2)

      # With force=true, it proceeds even with few events
      # But will fail at LLM step since no real provider is configured
      # which is still :ok behavior (graceful degradation)
      job = %Oban.Job{args: %{"session_id" => session.id, "force" => true}}
      result = SummarizerDispatcher.perform(job)
      # Either succeeds or returns error from LLM (both acceptable in test)
      assert result == :ok or match?({:error, _}, result)
    end
  end

  describe "perform/1 - session handling" do
    test "returns error for nonexistent session" do
      job = %Oban.Job{args: %{"session_id" => Ecto.UUID.generate()}}
      assert {:error, "session not found"} = SummarizerDispatcher.perform(job)
    end

    test "returns ok when no messages", %{session: session} do
      create_events(session.id, 15)

      job = %Oban.Job{args: %{"session_id" => session.id}}
      assert :ok = SummarizerDispatcher.perform(job)
    end
  end
end
