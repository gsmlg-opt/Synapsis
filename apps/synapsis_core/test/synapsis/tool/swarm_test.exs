defmodule Synapsis.Tool.SwarmTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.SendMessage
  alias Synapsis.Tool.Teammate
  alias Synapsis.Tool.TeamDelete

  @session_id "test-session-#{:erlang.unique_integer([:positive])}"

  setup do
    # Clean up process dictionary between tests
    Process.delete({:swarm_teammates, @session_id})
    :ok
  end

  describe "Teammate tool" do
    test "create returns teammate info with id, name, and status" do
      input = %{"action" => "create", "name" => "researcher", "prompt" => "You are a researcher."}
      {:ok, json} = Teammate.execute(input, %{session_id: @session_id})
      result = Jason.decode!(json)

      assert is_binary(result["id"])
      assert result["name"] == "researcher"
      assert result["status"] == "active"
      assert result["prompt"] == "You are a researcher."
    end

    test "list returns all created teammates" do
      {:ok, _} =
        Teammate.execute(
          %{"action" => "create", "name" => "alpha", "prompt" => "Alpha agent"},
          %{session_id: @session_id}
        )

      {:ok, _} =
        Teammate.execute(
          %{"action" => "create", "name" => "beta", "prompt" => "Beta agent"},
          %{session_id: @session_id}
        )

      {:ok, json} = Teammate.execute(%{"action" => "list"}, %{session_id: @session_id})
      result = Jason.decode!(json)

      assert length(result) == 2
      names = Enum.map(result, & &1["name"]) |> Enum.sort()
      assert names == ["alpha", "beta"]
    end

    test "get returns a specific teammate by name" do
      {:ok, _} =
        Teammate.execute(
          %{"action" => "create", "name" => "finder", "prompt" => "Find things"},
          %{session_id: @session_id}
        )

      {:ok, json} =
        Teammate.execute(%{"action" => "get", "name" => "finder"}, %{session_id: @session_id})

      result = Jason.decode!(json)
      assert result["name"] == "finder"
      assert result["prompt"] == "Find things"
    end

    test "get returns error for missing teammate" do
      {:error, msg} =
        Teammate.execute(
          %{"action" => "get", "name" => "nonexistent"},
          %{session_id: @session_id}
        )

      assert msg =~ "not found"
    end

    test "has correct permission_level and category" do
      assert Teammate.permission_level() == :none
      assert Teammate.category() == :swarm
    end

    test "returns error without session_id" do
      {:error, msg} = Teammate.execute(%{"action" => "list"}, %{})
      assert msg =~ "No session context"
    end
  end

  describe "SendMessage tool" do
    test "broadcasts message via PubSub" do
      to = "agent-receiver"
      topic = "swarm:#{@session_id}:#{to}"
      Phoenix.PubSub.subscribe(Synapsis.PubSub, topic)

      input = %{"to" => to, "content" => "Hello teammate", "type" => "request"}
      {:ok, json} = SendMessage.execute(input, %{session_id: @session_id, agent_id: "primary"})
      result = Jason.decode!(json)

      assert result["status"] == "sent"
      assert result["to"] == to
      assert is_binary(result["message_id"])

      assert_receive {:swarm_message, message}
      assert message.from == "primary"
      assert message.to == to
      assert message.content == "Hello teammate"
      assert message.type == "request"
    end

    test "has correct permission_level and category" do
      assert SendMessage.permission_level() == :none
      assert SendMessage.category() == :swarm
    end

    test "returns error without session_id" do
      {:error, msg} = SendMessage.execute(%{"to" => "x", "content" => "hi"}, %{})
      assert msg =~ "No session context"
    end
  end

  describe "TeamDelete tool" do
    test "dissolves team and clears all teammates" do
      {:ok, _} =
        Teammate.execute(
          %{"action" => "create", "name" => "worker1"},
          %{session_id: @session_id}
        )

      {:ok, _} =
        Teammate.execute(
          %{"action" => "create", "name" => "worker2"},
          %{session_id: @session_id}
        )

      {:ok, msg} = TeamDelete.execute(%{}, %{session_id: @session_id})
      assert msg =~ "2 teammate(s) terminated"

      # Verify list is now empty
      {:ok, json} = Teammate.execute(%{"action" => "list"}, %{session_id: @session_id})
      assert Jason.decode!(json) == []
    end

    test "has correct permission_level and category" do
      assert TeamDelete.permission_level() == :none
      assert TeamDelete.category() == :swarm
    end

    test "returns error without session_id" do
      {:error, msg} = TeamDelete.execute(%{}, %{})
      assert msg =~ "No session context"
    end
  end
end
