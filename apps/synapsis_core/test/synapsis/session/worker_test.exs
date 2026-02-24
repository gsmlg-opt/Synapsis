defmodule Synapsis.Session.WorkerTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.Session.Worker
  alias Synapsis.Repo

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Initialize a bare git repo for worktree support
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
        slug: "worker-test-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert()

    {:ok, session} =
      %Synapsis.Session{}
      |> Synapsis.Session.changeset(%{
        project_id: project.id,
        provider: "anthropic",
        model: "claude-sonnet-4-20250514"
      })
      |> Repo.insert()

    {:ok, session: session, project_path: tmp_dir}
  end

  defp allow_worker(pid) do
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
  end

  describe "init/1 — worktree setup" do
    test "sets worktree_path when project is a git repo", %{session: session, project_path: pp} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})

      state = :sys.get_state(pid)

      assert state.worktree_path != nil
      assert File.exists?(state.worktree_path)
      assert String.starts_with?(state.worktree_path, pp)
    end

    test "worktree_path is nil for non-git project" do
      non_git_dir = System.tmp_dir!() |> Path.join("no-git-#{System.unique_integer()}")
      File.mkdir_p!(non_git_dir)

      {:ok, project} =
        %Synapsis.Project{}
        |> Synapsis.Project.changeset(%{
          path: non_git_dir,
          slug: "no-git-#{System.unique_integer([:positive])}"
        })
        |> Repo.insert()

      {:ok, session} =
        %Synapsis.Session{}
        |> Synapsis.Session.changeset(%{
          project_id: project.id,
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })
        |> Repo.insert()

      {:ok, pid} = start_supervised({Worker, session_id: session.id})

      state = :sys.get_state(pid)

      assert state.worktree_path == nil

      File.rm_rf!(non_git_dir)
    end
  end

  describe "handle_call(:get_status)" do
    test "returns :idle when freshly started", %{session: session} do
      {:ok, _pid} = start_supervised({Worker, session_id: session.id})
      assert Worker.get_status(session.id) == :idle
    end
  end

  describe "handle_call(:retry)" do
    test "returns {:error, :no_messages} when no messages exist", %{session: session} do
      {:ok, _pid} = start_supervised({Worker, session_id: session.id})
      assert {:error, :no_messages} = Worker.retry(session.id)
    end

    test "returns {:error, :not_idle} when status is streaming", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      :sys.replace_state(pid, fn state -> %{state | status: :streaming} end)
      assert {:error, :not_idle} = Worker.retry(session.id)
    end
  end

  describe "handle_call({:switch_agent})" do
    test "switches agent when idle and updates DB", %{session: session} do
      {:ok, _pid} = start_supervised({Worker, session_id: session.id})
      assert :ok = Worker.switch_agent(session.id, "plan")
      {:ok, updated} = Synapsis.Sessions.get(session.id)
      assert updated.agent == "plan"
    end

    test "returns {:error, :not_idle} when streaming", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      :sys.replace_state(pid, fn state -> %{state | status: :streaming} end)
      assert {:error, :not_idle} = Worker.switch_agent(session.id, "plan")
    end
  end

  describe "handle_call({:send_message}) when not idle" do
    test "returns {:error, :not_idle} when streaming", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      :sys.replace_state(pid, fn state -> %{state | status: :streaming} end)
      assert {:error, :not_idle} = Worker.send_message(session.id, "hello")
    end
  end

  describe "handle_cast({:deny_tool})" do
    test "inserts ToolResult with is_error: true when tool_executing", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      allow_worker(pid)

      tool_use_id = "tu_deny_#{System.unique_integer([:positive])}"

      tool_use = %Synapsis.Part.ToolUse{
        tool: "bash",
        tool_use_id: tool_use_id,
        input: %{"command" => "ls"},
        status: :pending
      }

      :sys.replace_state(pid, fn state ->
        %{state | status: :tool_executing, tool_uses: [tool_use]}
      end)

      Worker.deny_tool(session.id, tool_use_id)
      # Allow async GenServer cast to process
      :timer.sleep(200)

      import Ecto.Query

      msgs = Repo.all(from(m in Synapsis.Message, where: m.session_id == ^session.id))

      tool_results =
        Enum.flat_map(msgs, fn m ->
          Enum.filter(m.parts, &match?(%Synapsis.Part.ToolResult{}, &1))
        end)

      denied = Enum.find(tool_results, fn tr -> tr.tool_use_id == tool_use_id end)
      assert denied != nil
      assert denied.is_error == true
      assert denied.content =~ "denied"
    end

    test "no-ops when not tool_executing", %{session: session} do
      {:ok, _pid} = start_supervised({Worker, session_id: session.id})
      Worker.deny_tool(session.id, "nonexistent_id")
      :timer.sleep(50)
      assert Worker.get_status(session.id) == :idle
    end
  end

  describe "handle_cast({:approve_tool})" do
    test "no-ops when not tool_executing", %{session: session} do
      {:ok, _pid} = start_supervised({Worker, session_id: session.id})
      Worker.approve_tool(session.id, "nonexistent_id")
      :timer.sleep(50)
      assert Worker.get_status(session.id) == :idle
    end
  end

  describe "handle_info({:tool_result})" do
    test "persists ToolResult message to DB", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      allow_worker(pid)

      tool_use_id = "tu_result_#{System.unique_integer([:positive])}"

      tool_use = %Synapsis.Part.ToolUse{
        tool: "bash",
        tool_use_id: tool_use_id,
        input: %{"command" => "echo hi"},
        status: :pending
      }

      :sys.replace_state(pid, fn state ->
        %{state | status: :tool_executing, tool_uses: [tool_use]}
      end)

      send(pid, {:tool_result, tool_use_id, "output text", false})
      :timer.sleep(200)

      import Ecto.Query

      msgs = Repo.all(from(m in Synapsis.Message, where: m.session_id == ^session.id))

      tool_results =
        Enum.flat_map(msgs, fn m ->
          Enum.filter(m.parts, &match?(%Synapsis.Part.ToolResult{}, &1))
        end)

      result = Enum.find(tool_results, fn tr -> tr.tool_use_id == tool_use_id end)
      assert result != nil
      assert result.content == "output text"
      assert result.is_error == false
    end
  end

  describe "handle_info(:timeout)" do
    test "stops worker when idle", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      ref = Process.monitor(pid)
      send(pid, :timeout)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
    end

    test "continues (does not stop) when not idle", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      :sys.replace_state(pid, fn state -> %{state | status: :streaming} end)
      send(pid, :timeout)
      :timer.sleep(100)
      assert Process.alive?(pid)
    end
  end

  describe "handle_cast(:cancel)" do
    test "no-ops when status is idle", %{session: session} do
      {:ok, _pid} = start_supervised({Worker, session_id: session.id})
      Worker.cancel(session.id)
      :timer.sleep(50)
      assert Worker.get_status(session.id) == :idle
    end
  end

  describe "handle_info catch-all" do
    test "unknown messages ignored when idle", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      send(pid, :unexpected_random_message)
      :timer.sleep(50)
      assert Process.alive?(pid)
      assert Worker.get_status(session.id) == :idle
    end

    test "unknown messages ignored when not idle", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      :sys.replace_state(pid, fn state -> %{state | status: :streaming} end)
      send(pid, :unexpected_random_message)
      :timer.sleep(50)
      assert Process.alive?(pid)
    end
  end

  describe "handle_info({:provider_error})" do
    test "sets status to error on non-retriable provider error", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      :sys.replace_state(pid, fn state -> %{state | status: :streaming} end)
      send(pid, {:provider_error, "400 Bad Request"})
      :timer.sleep(100)
      assert :sys.get_state(pid).status == :error
    end
  end

  describe "handle_info({:provider_chunk})" do
    test "accumulates text deltas", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      :sys.replace_state(pid, fn state -> %{state | status: :streaming} end)
      send(pid, {:provider_chunk, {:text_delta, "hello"}})
      :timer.sleep(100)
      assert :sys.get_state(pid).pending_text =~ "hello"
    end

    test "accumulates reasoning deltas", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      :sys.replace_state(pid, fn state -> %{state | status: :streaming} end)
      send(pid, {:provider_chunk, {:reasoning_delta, "thinking"}})
      :timer.sleep(100)
      assert :sys.get_state(pid).pending_reasoning =~ "thinking"
    end
  end

  describe "handle_info(:provider_done) without tool_uses" do
    test "transitions to idle and persists assistant message", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      allow_worker(pid)

      :sys.replace_state(pid, fn state ->
        %{state | status: :streaming, pending_text: "response text", tool_uses: []}
      end)

      send(pid, :provider_done)
      :timer.sleep(300)

      assert :sys.get_state(pid).status == :idle

      import Ecto.Query

      msgs =
        Repo.all(
          from(m in Synapsis.Message,
            where: m.session_id == ^session.id and m.role == "assistant"
          )
        )

      assert length(msgs) > 0

      text_parts =
        Enum.flat_map(msgs, fn m ->
          Enum.filter(m.parts, &match?(%Synapsis.Part.Text{}, &1))
        end)

      assert Enum.any?(text_parts, fn p -> p.content == "response text" end)
    end
  end
end
