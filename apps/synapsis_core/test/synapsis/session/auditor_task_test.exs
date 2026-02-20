defmodule Synapsis.Session.AuditorTaskTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.Session.{AuditorTask, Monitor}
  alias Synapsis.{FailedAttempt, Repo}

  setup do
    {:ok, project} =
      %Synapsis.Project{}
      |> Synapsis.Project.changeset(%{
        path: "/tmp/auditor_test_#{System.unique_integer([:positive])}",
        slug: "auditor-test-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert()

    {:ok, session} =
      %Synapsis.Session{}
      |> Synapsis.Session.changeset(%{
        project_id: project.id,
        provider: "anthropic",
        model: "test-model"
      })
      |> Repo.insert()

    {:ok, session: session}
  end

  describe "build_auditor_request/3" do
    test "assembles prompt with monitor summary", %{session: session} do
      monitor = Monitor.new()
      request = AuditorTask.build_auditor_request(session.id, monitor)

      assert request.system_prompt =~ "code review auditor"
      assert request.user_message =~ "Monitor State"
      assert request.user_message =~ "Iterations: 0"
      assert request.config.max_tokens == 1024
    end

    test "includes failure context when available", %{session: session} do
      # Insert a failed attempt
      %FailedAttempt{}
      |> FailedAttempt.changeset(%{
        session_id: session.id,
        attempt_number: 1,
        error_message: "Previous error"
      })
      |> Repo.insert!()

      monitor = Monitor.new()
      request = AuditorTask.build_auditor_request(session.id, monitor)
      assert request.user_message =~ "Previous error"
    end

    test "passes auditor provider/model config", %{session: session} do
      monitor = Monitor.new()

      request =
        AuditorTask.build_auditor_request(session.id, monitor,
          auditor_provider: "openai",
          auditor_model: "o1-mini"
        )

      assert request.config.provider == "openai"
      assert request.config.model == "o1-mini"
    end
  end

  describe "record_analysis/3" do
    test "persists auditor response as FailedAttempt", %{session: session} do
      response = """
      The agent kept running `mix test` with the same broken import.
      Lesson: Check that the module exists before importing it.
      Approach: Use `Code.ensure_loaded?/1` to verify module availability.
      """

      assert {:ok, fa} = AuditorTask.record_analysis(session.id, response)
      assert fa.attempt_number == 1
      assert fa.error_message =~ "kept running"
      assert fa.lesson != nil
      assert fa.triggered_by == "orchestrator_escalation"
    end

    test "increments attempt number", %{session: session} do
      %FailedAttempt{}
      |> FailedAttempt.changeset(%{
        session_id: session.id,
        attempt_number: 3,
        error_message: "old error"
      })
      |> Repo.insert!()

      {:ok, fa} = AuditorTask.record_analysis(session.id, "New error found")
      assert fa.attempt_number == 4
    end

    test "handles single-line response", %{session: session} do
      {:ok, fa} = AuditorTask.record_analysis(session.id, "Simple error message")
      assert fa.error_message == "Simple error message"
      assert fa.lesson == nil
    end

    test "records auditor model", %{session: session} do
      {:ok, fa} =
        AuditorTask.record_analysis(session.id, "Error occurred",
          auditor_model: "claude-opus-4-20250514"
        )

      assert fa.auditor_model == "claude-opus-4-20250514"
    end
  end

  describe "prepare_escalation/3" do
    test "returns assembled request", %{session: session} do
      monitor = Monitor.new()

      agent_config = %{
        "auditorProvider" => "anthropic",
        "auditorModel" => "claude-sonnet-4-20250514"
      }

      request = AuditorTask.prepare_escalation(session.id, monitor, agent_config)
      assert request.system_prompt =~ "auditor"
      assert request.config.model == "claude-sonnet-4-20250514"
    end
  end
end
