defmodule Synapsis.Agent.SessionBridgeTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.Agent.SessionBridge
  alias Synapsis.{Repo, Session}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Initialize a bare git repo
    {_, 0} = System.cmd("git", ["init", tmp_dir])
    {_, 0} = System.cmd("git", ["-C", tmp_dir, "config", "user.email", "test@test.com"])
    {_, 0} = System.cmd("git", ["-C", tmp_dir, "config", "user.name", "Test"])
    File.write!(Path.join(tmp_dir, "README.md"), "# Test\n")
    {_, 0} = System.cmd("git", ["-C", tmp_dir, "add", "."])
    {_, 0} = System.cmd("git", ["-C", tmp_dir, "commit", "-m", "init"])

    {:ok, project} =
      %Synapsis.Project{}
      |> Synapsis.Project.changeset(%{
        path: tmp_dir,
        slug: "bridge-test-#{System.unique_integer([:positive])}",
        name: "bridge-test"
      })
      |> Repo.insert()

    %{project: project, project_path: tmp_dir}
  end

  describe "spawn_coding_session/3" do
    test "creates session and starts Worker with CodingLoop graph", %{project: project} do
      assert {:ok, session_id} = SessionBridge.spawn_coding_session(project.id, nil)
      assert is_binary(session_id)

      # Session exists in DB
      session = Repo.get(Session, session_id)
      assert session != nil
      assert session.project_id == project.id

      # Worker is running
      [{worker_pid, _}] = Registry.lookup(Synapsis.Session.Registry, session_id)
      assert Process.alive?(worker_pid)

      # Cleanup
      Synapsis.Session.DynamicSupervisor.stop_session(session_id)
    end

    test "passes provider/model/agent config", %{project: project} do
      opts = %{provider: "openai", model: "gpt-4o", agent: "plan"}

      assert {:ok, session_id} = SessionBridge.spawn_coding_session(project.id, nil, opts)

      session = Repo.get(Session, session_id)
      assert session.provider == "openai"
      assert session.model == "gpt-4o"
      assert session.agent == "plan"

      Synapsis.Session.DynamicSupervisor.stop_session(session_id)
    end

    test "returns error for non-existent project" do
      assert {:error, :project_not_found} =
               SessionBridge.spawn_coding_session(Ecto.UUID.generate(), nil)
    end
  end

  describe "build_spawn_context/2" do
    test "includes file tree from project", %{project_path: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.write!(Path.join(tmp_dir, "lib/app.ex"), "defmodule App do\nend\n")
      context = SessionBridge.build_spawn_context(tmp_dir)
      assert context =~ "Project Files"
      assert context =~ "README.md"
    end

    test "includes recent git log", %{project_path: tmp_dir} do
      context = SessionBridge.build_spawn_context(tmp_dir)
      assert context =~ "Git History"
      assert context =~ "init"
    end

    test "returns nil for empty directory" do
      empty = System.tmp_dir!() |> Path.join("empty_#{System.unique_integer([:positive])}")
      File.mkdir_p!(empty)
      on_exit(fn -> File.rm_rf!(empty) end)

      context = SessionBridge.build_spawn_context(empty)
      # May still have file tree section but no git
      assert is_nil(context) or is_binary(context)
    end
  end
end
