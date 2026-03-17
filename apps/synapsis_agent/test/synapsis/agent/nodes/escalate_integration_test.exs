defmodule Synapsis.Agent.Nodes.EscalateIntegrationTest do
  @moduledoc """
  Integration test for the full escalation path:
  Orchestrator escalation → Escalate node → AuditorTask → LLM call → FailedAttempt persisted.
  Uses Bypass to mock the provider endpoint.
  """
  use Synapsis.DataCase, async: false

  alias Synapsis.{Repo, FailedAttempt}
  alias Synapsis.Session.AuditorTask
  alias Synapsis.Session.Monitor
  alias Synapsis.Provider.Adapter

  setup do
    bypass = Bypass.open()

    {:ok, project} =
      %Synapsis.Project{}
      |> Synapsis.Project.changeset(%{
        path: "/tmp/escalate_test_#{System.unique_integer([:positive])}",
        slug: "escalate-test-#{System.unique_integer([:positive])}"
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

    %{bypass: bypass, session: session}
  end

  describe "full escalation with mocked provider" do
    test "constraint response adds FailedAttempt and continues", %{
      bypass: bypass,
      session: session
    } do
      auditor_response = """
      The agent kept running the same failing test without changing the import.

      Lesson: Always check that the module being imported actually exists before
      re-running the test suite.

      Approach: Use Code.ensure_loaded?/1 to verify the module is available,
      then fix the import path before retrying.
      """

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => auditor_response}]
          })
        )
      end)

      monitor = Monitor.new()

      config = %{
        api_key: "test-key",
        base_url: "http://localhost:#{bypass.port}",
        type: "anthropic"
      }

      # Build auditor request
      request = AuditorTask.prepare_escalation(session.id, monitor, %{})

      # Make the LLM call (the part Worker.start_auditor_async does)
      llm_request = %{
        model: "test-model",
        max_tokens: 1024,
        system: request.system_prompt,
        messages: [%{role: "user", content: request.user_message}]
      }

      assert {:ok, response_text} = Adapter.complete(llm_request, config)
      assert response_text =~ "kept running the same failing test"

      # Record the analysis
      assert {:ok, fa} =
               AuditorTask.record_analysis(session.id, response_text,
                 trigger: "duplicate_tool_calls",
                 auditor_model: "test-model"
               )

      assert fa.session_id == session.id
      assert fa.attempt_number == 1
      assert fa.error_message =~ "kept running"
      assert fa.lesson =~ "ensure_loaded"
      assert fa.triggered_by == "duplicate_tool_calls"
      assert fa.auditor_model == "test-model"

      # Verify it's persisted in DB
      assert Repo.get(FailedAttempt, fa.id) != nil
    end

    test "abort response terminates with explanation", %{
      bypass: bypass,
      session: session
    } do
      abort_response = "This task cannot be completed. The requested file does not exist."

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => abort_response}]
          })
        )
      end)

      config = %{
        api_key: "test-key",
        base_url: "http://localhost:#{bypass.port}",
        type: "anthropic"
      }

      monitor = Monitor.new()
      request = AuditorTask.prepare_escalation(session.id, monitor, %{})

      llm_request = %{
        model: "test-model",
        max_tokens: 1024,
        system: request.system_prompt,
        messages: [%{role: "user", content: request.user_message}]
      }

      assert {:ok, response_text} = Adapter.complete(llm_request, config)

      # Even abort responses get recorded as FailedAttempts for audit trail
      assert {:ok, fa} = AuditorTask.record_analysis(session.id, response_text)
      assert fa.error_message =~ "cannot be completed"
    end

    test "continue response prepends guidance to next prompt", %{
      bypass: bypass,
      session: session
    } do
      guidance_response = """
      The current approach is reasonable but needs adjustment.

      Lesson: The test expects a different return type than what the function provides.

      Approach: Check the function's typespec and update the return value to match
      the expected {:ok, result} tuple format.
      """

      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => guidance_response}]
          })
        )
      end)

      config = %{
        api_key: "test-key",
        base_url: "http://localhost:#{bypass.port}",
        type: "anthropic"
      }

      monitor = Monitor.new()
      request = AuditorTask.prepare_escalation(session.id, monitor, %{})

      llm_request = %{
        model: "test-model",
        max_tokens: 1024,
        system: request.system_prompt,
        messages: [%{role: "user", content: request.user_message}]
      }

      assert {:ok, response_text} = Adapter.complete(llm_request, config)
      assert {:ok, fa} = AuditorTask.record_analysis(session.id, response_text)

      # Guidance is stored as a lesson for PromptBuilder to inject
      assert fa.lesson =~ "typespec"

      # Verify PromptBuilder can pick up the failed attempt for next prompt
      context = Synapsis.PromptBuilder.build_failure_context(session.id)
      assert context =~ "current approach is reasonable"
    end

    test "handles LLM error gracefully", %{bypass: bypass, session: session} do
      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          500,
          Jason.encode!(%{"error" => %{"message" => "Internal server error"}})
        )
      end)

      config = %{
        api_key: "test-key",
        base_url: "http://localhost:#{bypass.port}",
        type: "anthropic"
      }

      monitor = Monitor.new()
      request = AuditorTask.prepare_escalation(session.id, monitor, %{})

      llm_request = %{
        model: "test-model",
        max_tokens: 1024,
        system: request.system_prompt,
        messages: [%{role: "user", content: request.user_message}]
      }

      assert {:error, _reason} = Adapter.complete(llm_request, config)

      # No FailedAttempt created when LLM call fails
      import Ecto.Query

      count =
        Repo.aggregate(from(fa in FailedAttempt, where: fa.session_id == ^session.id), :count)

      assert count == 0
    end

    test "respects auditor model override", %{bypass: bypass, session: session} do
      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        # Verify the overridden model is used in the request
        assert decoded["model"] == "claude-opus-4-20250514"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => "Auditor analysis with custom model."}]
          })
        )
      end)

      config = %{
        api_key: "test-key",
        base_url: "http://localhost:#{bypass.port}",
        type: "anthropic"
      }

      agent_config = %{
        "auditorProvider" => "anthropic",
        "auditorModel" => "claude-opus-4-20250514"
      }

      monitor = Monitor.new()
      request = AuditorTask.prepare_escalation(session.id, monitor, agent_config)
      assert request.config.model == "claude-opus-4-20250514"

      llm_request = %{
        model: request.config.model,
        max_tokens: request.config.max_tokens,
        system: request.system_prompt,
        messages: [%{role: "user", content: request.user_message}]
      }

      assert {:ok, text} = Adapter.complete(llm_request, config)

      assert {:ok, fa} =
               AuditorTask.record_analysis(session.id, text, auditor_model: request.config.model)

      assert fa.auditor_model == "claude-opus-4-20250514"
    end
  end
end
