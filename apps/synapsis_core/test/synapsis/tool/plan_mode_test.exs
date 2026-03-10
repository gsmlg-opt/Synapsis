defmodule Synapsis.Tool.PlanModeTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.Tool.{EnterPlanMode, ExitPlanMode}

  setup do
    {:ok, project} =
      %Synapsis.Project{}
      |> Synapsis.Project.changeset(%{path: "/tmp/plan_mode_test", slug: "plan-mode-test"})
      |> Repo.insert()

    {:ok, session} =
      %Synapsis.Session{}
      |> Synapsis.Session.changeset(%{
        project_id: project.id,
        provider: "test",
        model: "test-model"
      })
      |> Repo.insert()

    %{session: session}
  end

  describe "EnterPlanMode" do
    test "has correct metadata" do
      assert EnterPlanMode.name() == "enter_plan_mode"
      assert EnterPlanMode.permission_level() == :none
      assert EnterPlanMode.category() == :session
      assert is_binary(EnterPlanMode.description())
      assert %{"type" => "object"} = EnterPlanMode.parameters()
    end

    test "broadcasts agent_mode_changed :plan and persists to DB", %{session: session} do
      topic = "session:#{session.id}"
      Phoenix.PubSub.subscribe(Synapsis.PubSub, topic)

      assert {:ok, msg} = EnterPlanMode.execute(%{}, %{session_id: session.id})
      assert msg =~ "plan mode"

      assert_receive {:agent_mode_changed, :plan}

      # Verify DB was updated
      updated = Repo.get!(Synapsis.Session, session.id)
      assert updated.agent == "plan"
    end

    test "returns error without session_id" do
      assert {:error, msg} = EnterPlanMode.execute(%{}, %{})
      assert is_binary(msg)
    end
  end

  describe "ExitPlanMode" do
    test "has correct metadata" do
      assert ExitPlanMode.name() == "exit_plan_mode"
      assert ExitPlanMode.permission_level() == :none
      assert ExitPlanMode.category() == :session
      assert is_binary(ExitPlanMode.description())
      assert %{"type" => "object"} = ExitPlanMode.parameters()
    end

    test "broadcasts agent_mode_changed :build and plan_submitted with plan text", %{
      session: session
    } do
      topic = "session:#{session.id}"
      Phoenix.PubSub.subscribe(Synapsis.PubSub, topic)

      plan_text = "1. Read codebase\n2. Implement feature\n3. Test"

      assert {:ok, msg} = ExitPlanMode.execute(%{"plan" => plan_text}, %{session_id: session.id})
      assert msg =~ "Exited plan mode"

      assert_receive {:plan_submitted, ^plan_text}
      assert_receive {:agent_mode_changed, :build}

      # Verify DB was updated
      updated = Repo.get!(Synapsis.Session, session.id)
      assert updated.agent == "build"
    end

    test "broadcasts with nil plan when no plan given", %{session: session} do
      topic = "session:#{session.id}"
      Phoenix.PubSub.subscribe(Synapsis.PubSub, topic)

      assert {:ok, _} = ExitPlanMode.execute(%{}, %{session_id: session.id})

      assert_receive {:plan_submitted, nil}
      assert_receive {:agent_mode_changed, :build}
    end

    test "returns error without session_id" do
      assert {:error, msg} = ExitPlanMode.execute(%{}, %{})
      assert is_binary(msg)
    end
  end
end
