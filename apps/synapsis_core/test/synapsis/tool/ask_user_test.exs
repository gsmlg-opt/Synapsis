defmodule Synapsis.Tool.AskUserTest do
  use ExUnit.Case

  alias Synapsis.Tool.AskUser

  describe "tool metadata" do
    test "has correct name" do
      assert AskUser.name() == "ask_user"
    end

    test "has correct permission level" do
      assert AskUser.permission_level() == :none
    end

    test "has correct category" do
      assert AskUser.category() == :interaction
    end

    test "has description" do
      assert is_binary(AskUser.description())
    end

    test "parameters require question" do
      params = AskUser.parameters()
      assert params["type"] == "object"
      assert "question" in params["required"]
      assert Map.has_key?(params["properties"], "question")
      assert Map.has_key?(params["properties"], "options")
    end
  end

  describe "sub-agent denial" do
    test "returns error when parent_agent is set" do
      context = %{session_id: "s1", parent_agent: self()}
      result = AskUser.execute(%{"question" => "test?"}, context)
      assert {:error, "Sub-agents cannot interact with the user directly"} = result
    end
  end

  describe "missing session" do
    test "returns error when session_id is nil" do
      result = AskUser.execute(%{"question" => "test?"}, %{})
      assert {:error, "No session context available for user interaction"} = result
    end
  end

  describe "question broadcast" do
    test "broadcasts question to session topic" do
      session_id = "test-session-#{System.unique_integer([:positive])}"

      # Subscribe to the session topic to capture the broadcast
      Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session_id}")

      # Run execute in a separate task so it doesn't block this process
      task =
        Task.async(fn ->
          AskUser.execute(%{"question" => "What color?"}, %{session_id: session_id})
        end)

      # Wait for the broadcast
      assert_receive {:ask_user, ref, %{question: "What color?", options: nil}}, 1_000

      # Now respond via the response topic to unblock the task
      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "ask_user_response:#{session_id}",
        {:user_response, ref, "Blue"}
      )

      assert {:ok, "Blue"} = Task.await(task, 2_000)
    end

    test "broadcasts question with options" do
      session_id = "test-session-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session_id}")

      options = [
        %{"label" => "Yes", "description" => "Approve"},
        %{"label" => "No", "description" => "Reject"}
      ]

      task =
        Task.async(fn ->
          AskUser.execute(
            %{"question" => "Continue?", "options" => options},
            %{session_id: session_id}
          )
        end)

      assert_receive {:ask_user, ref, %{question: "Continue?", options: ^options}}, 1_000

      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "ask_user_response:#{session_id}",
        {:user_response, ref, "Yes"}
      )

      assert {:ok, "Yes"} = Task.await(task, 2_000)
    end
  end

  describe "blocking and response" do
    test "blocks until user responds" do
      session_id = "test-session-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session_id}")

      task =
        Task.async(fn ->
          AskUser.execute(%{"question" => "Ready?"}, %{session_id: session_id})
        end)

      # Verify the task is still running (blocked)
      assert_receive {:ask_user, ref, _}, 1_000
      refute Task.yield(task, 100)

      # Send response to unblock
      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "ask_user_response:#{session_id}",
        {:user_response, ref, "Yes, ready!"}
      )

      assert {:ok, "Yes, ready!"} = Task.await(task, 2_000)
    end

    test "only responds to matching ref" do
      session_id = "test-session-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session_id}")

      task =
        Task.async(fn ->
          AskUser.execute(%{"question" => "Pick one"}, %{session_id: session_id})
        end)

      assert_receive {:ask_user, ref, _}, 1_000

      # Send response with wrong ref - should NOT unblock
      wrong_ref = make_ref()

      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "ask_user_response:#{session_id}",
        {:user_response, wrong_ref, "wrong"}
      )

      # Task should still be blocked
      refute Task.yield(task, 200)

      # Send correct response
      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "ask_user_response:#{session_id}",
        {:user_response, ref, "correct"}
      )

      assert {:ok, "correct"} = Task.await(task, 2_000)
    end
  end
end
