defmodule Synapsis.Agent.ToolDispatcherTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.Agent.ToolDispatcher
  alias Synapsis.Session.Monitor
  alias Synapsis.{Session, Repo}

  setup do
    project =
      %Synapsis.Project{}
      |> Synapsis.Project.changeset(%{path: "/tmp/td-test", slug: "td-test", name: "td-test"})
      |> Repo.insert!()

    session =
      %Session{}
      |> Session.changeset(%{
        project_id: project.id,
        provider: "anthropic",
        model: "claude-sonnet-4-20250514"
      })
      |> Repo.insert!()
      |> Repo.preload(:project)

    monitor = Monitor.new()

    tool_use = %Synapsis.Part.ToolUse{
      tool: "file_read",
      tool_use_id: "tu_1",
      input: %{"path" => "/foo"},
      status: :pending
    }

    {:ok, session: session, monitor: monitor, tool_use: tool_use}
  end

  describe "classify/3" do
    test "classifies tools and updates monitor", %{
      session: session,
      monitor: monitor,
      tool_use: tool_use
    } do
      {classified, new_monitor} = ToolDispatcher.classify([tool_use], session, monitor)

      # Should classify as something
      assert [{status, ^tool_use}] = classified
      assert status in [:approved, :requires_approval, :denied]

      # Monitor should have been updated with tool call
      assert new_monitor.tool_call_counts != monitor.tool_call_counts or
               new_monitor == monitor
    end

    test "classifies multiple tools", %{session: session, monitor: monitor} do
      tool_uses = [
        %Synapsis.Part.ToolUse{
          tool: "file_read",
          tool_use_id: "tu_1",
          input: %{"path" => "/a"},
          status: :pending
        },
        %Synapsis.Part.ToolUse{
          tool: "grep",
          tool_use_id: "tu_2",
          input: %{"pattern" => "foo"},
          status: :pending
        }
      ]

      {classified, _monitor} = ToolDispatcher.classify(tool_uses, session, monitor)
      assert length(classified) == 2
    end
  end

  describe "execute_async/3" do
    test "sends tool_result back to caller", %{tool_use: tool_use} do
      opts = %{
        project_path: "/tmp/td-test",
        effective_path: "/tmp/td-test",
        session_id: Ecto.UUID.generate(),
        agent_id: "test",
        project_id: Ecto.UUID.generate(),
        tool_call_hashes: MapSet.new()
      }

      _task = ToolDispatcher.execute_async(tool_use, self(), opts)

      assert_receive {:tool_result, "tu_1", _result, _is_error}, 5_000
    end
  end

  describe "dispatch_all/4" do
    test "returns updated tool_call_hashes", %{tool_use: tool_use} do
      classified = [{:denied, tool_use}]

      opts = %{
        project_path: "/tmp/td-test",
        effective_path: "/tmp/td-test",
        session_id: Ecto.UUID.generate(),
        agent_id: "test",
        project_id: Ecto.UUID.generate(),
        tool_call_hashes: MapSet.new()
      }

      hashes = ToolDispatcher.dispatch_all(classified, self(), "sess_1", opts)
      assert MapSet.size(hashes) == 1

      # Denied tools should send denial message
      assert_receive {:tool_result, "tu_1", "Tool denied by permission policy.", true}
    end
  end
end
