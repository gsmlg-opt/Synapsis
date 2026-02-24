defmodule Synapsis.Session.SupervisorTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.Session.{DynamicSupervisor, Supervisor, Worker}
  alias Synapsis.Repo

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Initialize a bare git repo so the Worker's worktree setup succeeds
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
        slug: "sup-test-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert()

    {:ok, project: project, project_path: tmp_dir}
  end

  defp create_session(project) do
    {:ok, session} =
      %Synapsis.Session{}
      |> Synapsis.Session.changeset(%{
        project_id: project.id,
        provider: "anthropic",
        model: "claude-sonnet-4-20250514"
      })
      |> Repo.insert()

    session
  end

  defp allow_process(pid) do
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
  end

  describe "DynamicSupervisor.start_session/1" do
    test "starts a session process tree", %{project: project} do
      session = create_session(project)

      {:ok, sup_pid} = DynamicSupervisor.start_session(session.id)
      assert Process.alive?(sup_pid)

      # The Worker should be accessible via the session registry
      [{worker_pid, _}] = Registry.lookup(Synapsis.Session.Registry, session.id)
      assert Process.alive?(worker_pid)
      allow_process(worker_pid)

      # Worker should report idle status
      assert Worker.get_status(session.id) == :idle

      # Cleanup
      DynamicSupervisor.stop_session(session.id)
    end

    test "registers session supervisor in SupervisorRegistry", %{project: project} do
      session = create_session(project)

      {:ok, sup_pid} = DynamicSupervisor.start_session(session.id)

      [{found_pid, _}] = Registry.lookup(Synapsis.Session.SupervisorRegistry, session.id)
      assert found_pid == sup_pid

      # Cleanup
      DynamicSupervisor.stop_session(session.id)
    end
  end

  describe "DynamicSupervisor.stop_session/1" do
    test "stops a running session", %{project: project} do
      session = create_session(project)

      {:ok, sup_pid} = DynamicSupervisor.start_session(session.id)
      assert Process.alive?(sup_pid)

      ref = Process.monitor(sup_pid)
      assert :ok = DynamicSupervisor.stop_session(session.id)

      assert_receive {:DOWN, ^ref, :process, ^sup_pid, _reason}, 5_000

      # Supervisor should no longer be in the registry
      assert Registry.lookup(Synapsis.Session.SupervisorRegistry, session.id) == []
    end

    test "returns {:error, :not_found} for non-existent session" do
      bogus_id = Ecto.UUID.generate()
      assert {:error, :not_found} = DynamicSupervisor.stop_session(bogus_id)
    end
  end

  describe "DynamicSupervisor — concurrent sessions" do
    test "multiple sessions can run concurrently", %{project: project} do
      session_a = create_session(project)
      session_b = create_session(project)
      session_c = create_session(project)

      {:ok, sup_a} = DynamicSupervisor.start_session(session_a.id)
      {:ok, sup_b} = DynamicSupervisor.start_session(session_b.id)
      {:ok, sup_c} = DynamicSupervisor.start_session(session_c.id)

      assert Process.alive?(sup_a)
      assert Process.alive?(sup_b)
      assert Process.alive?(sup_c)

      # Each has its own Worker
      [{worker_a, _}] = Registry.lookup(Synapsis.Session.Registry, session_a.id)
      [{worker_b, _}] = Registry.lookup(Synapsis.Session.Registry, session_b.id)
      [{worker_c, _}] = Registry.lookup(Synapsis.Session.Registry, session_c.id)

      assert worker_a != worker_b
      assert worker_b != worker_c

      for pid <- [worker_a, worker_b, worker_c] do
        allow_process(pid)
      end

      # All report idle independently
      assert Worker.get_status(session_a.id) == :idle
      assert Worker.get_status(session_b.id) == :idle
      assert Worker.get_status(session_c.id) == :idle

      # Stopping one doesn't affect the others
      DynamicSupervisor.stop_session(session_b.id)
      :timer.sleep(100)

      assert Process.alive?(sup_a)
      refute Process.alive?(sup_b)
      assert Process.alive?(sup_c)

      # Cleanup
      DynamicSupervisor.stop_session(session_a.id)
      DynamicSupervisor.stop_session(session_c.id)
    end
  end

  describe "Supervisor.init/1" do
    test "returns :one_for_all strategy with Worker child" do
      session_id = Ecto.UUID.generate()

      {:ok, {sup_flags, children}} = Supervisor.init(session_id: session_id)

      assert sup_flags.strategy == :one_for_all

      child_modules = Enum.map(children, fn %{start: {mod, _, _}} -> mod end)
      assert Worker in child_modules
    end
  end

  describe "Supervisor.start_link/1" do
    test "requires session_id option" do
      assert_raise KeyError, ~r/key :session_id not found/, fn ->
        Supervisor.start_link([])
      end
    end

    test "starts and registers via SupervisorRegistry", %{project: project} do
      session = create_session(project)

      {:ok, pid} = Supervisor.start_link(session_id: session.id)
      assert Process.alive?(pid)

      [{found_pid, _}] = Registry.lookup(Synapsis.Session.SupervisorRegistry, session.id)
      assert found_pid == pid

      # The Worker child should be running
      [{worker_pid, _}] = Registry.lookup(Synapsis.Session.Registry, session.id)
      assert Process.alive?(worker_pid)

      # Cleanup — stop the supervisor (which stops the worker too)
      Elixir.Supervisor.stop(pid)
    end
  end
end
