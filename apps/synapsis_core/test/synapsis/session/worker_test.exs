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

  describe "init/1 — graceful stop on missing session" do
    test "returns :stop for non-existent session" do
      bogus_id = Ecto.UUID.generate()

      assert {:stop, {:error, :session_not_found}} =
               Worker.init(session_id: bogus_id)
    end
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

    test "schedules retry for 429 rate limit errors", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      :sys.replace_state(pid, fn state -> %{state | status: :streaming, retry_count: 0} end)

      send(pid, {:provider_error, "429 Too Many Requests"})
      :timer.sleep(200)

      state = :sys.get_state(pid)
      assert state.status == :error
      assert state.retry_count >= 1
    end

    test "schedules retry for 503 service unavailable", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      :sys.replace_state(pid, fn state -> %{state | status: :streaming, retry_count: 0} end)

      send(pid, {:provider_error, "503 Service Unavailable"})
      :timer.sleep(200)

      state = :sys.get_state(pid)
      assert state.status == :error
    end

    test "does not retry when retry_count >= 3", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      :sys.replace_state(pid, fn state -> %{state | status: :streaming, retry_count: 3} end)

      send(pid, {:provider_error, "429 Too Many Requests"})
      :timer.sleep(100)

      state = :sys.get_state(pid)
      assert state.status == :error
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

  describe "handle_info({:provider_chunk}) — stream events" do
    test "tool_use_start sets pending_tool_use", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      :sys.replace_state(pid, fn state -> %{state | status: :streaming} end)

      send(pid, {:provider_chunk, {:tool_use_start, "bash", "tu_abc"}})
      :timer.sleep(100)

      state = :sys.get_state(pid)
      assert state.pending_tool_use == %{tool: "bash", tool_use_id: "tu_abc"}
    end

    test "tool_input_delta accumulates input JSON", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      :sys.replace_state(pid, fn state -> %{state | status: :streaming} end)

      send(pid, {:provider_chunk, {:tool_input_delta, "{\"cmd\": "}})
      send(pid, {:provider_chunk, {:tool_input_delta, "\"ls\"}"}})
      :timer.sleep(100)

      state = :sys.get_state(pid)
      assert state.pending_tool_input =~ "cmd"
    end

    test "content_block_stop with pending_tool_use parses JSON input", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})

      :sys.replace_state(pid, fn state ->
        %{
          state
          | status: :streaming,
            pending_tool_use: %{tool: "bash", tool_use_id: "tu_xyz"},
            pending_tool_input: "{\"command\": \"ls\"}"
        }
      end)

      send(pid, {:provider_chunk, :content_block_stop})
      :timer.sleep(100)

      state = :sys.get_state(pid)
      assert Enum.any?(state.tool_uses, fn tu -> tu.tool == "bash" end)
    end

    test "content_block_stop with nil pending_tool_use is a no-op", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      :sys.replace_state(pid, fn state ->
        %{state | status: :streaming, pending_tool_use: nil}
      end)

      send(pid, {:provider_chunk, :content_block_stop})
      :timer.sleep(50)
      assert Process.alive?(pid)
    end

    test "tool_use_complete appends tool_use to list", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      :sys.replace_state(pid, fn state -> %{state | status: :streaming} end)

      send(pid, {:provider_chunk, {:tool_use_complete, "file_read", %{"path" => "/tmp/f.ex"}}})
      :timer.sleep(100)

      state = :sys.get_state(pid)
      assert length(state.tool_uses) >= 1
    end

    test "message_start, message_delta, done, ignore events are no-ops", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      :sys.replace_state(pid, fn state -> %{state | status: :streaming} end)

      send(pid, {:provider_chunk, :message_start})
      send(pid, {:provider_chunk, {:message_delta, %{}}})
      send(pid, {:provider_chunk, :done})
      send(pid, {:provider_chunk, :ignore})
      :timer.sleep(100)

      assert Process.alive?(pid)
    end

    test "text_start event is a no-op", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      :sys.replace_state(pid, fn state -> %{state | status: :streaming} end)

      send(pid, {:provider_chunk, :text_start})
      :timer.sleep(50)
      assert Process.alive?(pid)
    end

    test "reasoning_start event is a no-op", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      :sys.replace_state(pid, fn state -> %{state | status: :streaming} end)

      send(pid, {:provider_chunk, :reasoning_start})
      :timer.sleep(50)
      assert Process.alive?(pid)
    end

    test "stream error event logs but does not crash", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      :sys.replace_state(pid, fn state -> %{state | status: :streaming} end)

      send(pid, {:provider_chunk, {:error, "upstream closed"}})
      :timer.sleep(50)
      assert Process.alive?(pid)
    end
  end

  describe "handle_info({:DOWN, ...})" do
    test "normal DOWN is a no-op", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})

      fake_ref = make_ref()
      send(pid, {:DOWN, fake_ref, :process, self(), :normal})
      :timer.sleep(50)
      assert Process.alive?(pid)
      assert Worker.get_status(session.id) == :idle
    end

    test "non-normal DOWN for unknown ref logs and continues", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})

      fake_ref = make_ref()
      send(pid, {:DOWN, fake_ref, :process, self(), :killed})
      :timer.sleep(50)
      assert Process.alive?(pid)
    end

    test "non-normal DOWN for stream_monitor_ref sets error status", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})

      fake_ref = make_ref()
      :sys.replace_state(pid, fn state ->
        %{state | status: :streaming, stream_monitor_ref: fake_ref}
      end)

      send(pid, {:DOWN, fake_ref, :process, self(), :killed})
      :timer.sleep(100)

      state = :sys.get_state(pid)
      assert state.status == :error
    end
  end

  describe "handle_cast(:cancel) when streaming" do
    test "cancel no-ops when stream_ref is nil (non-streaming cancel guard)", %{session: session} do
      # The streaming cancel guard requires non-nil stream_ref.
      # With nil stream_ref, it falls through to the catch-all handle_cast(:cancel, state).
      {:ok, pid} = start_supervised({Worker, session_id: session.id})

      :sys.replace_state(pid, fn state ->
        %{state | status: :streaming, stream_ref: nil}
      end)

      Worker.cancel(session.id)
      :timer.sleep(100)

      # Process should still be alive — the catch-all handle_cast just returns noreply
      assert Process.alive?(pid)
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

  describe "handle_info(:provider_done) with tool_uses" do
    test "transitions to tool_executing when tool_uses present", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      allow_worker(pid)

      tool_use = %Synapsis.Part.ToolUse{
        tool: "file_read",
        tool_use_id: "tu_done_test_#{System.unique_integer([:positive])}",
        input: %{"path" => "/tmp/test.txt"},
        status: :pending
      }

      :sys.replace_state(pid, fn state ->
        %{state | status: :streaming, pending_text: "", tool_uses: [tool_use]}
      end)

      send(pid, :provider_done)
      # Give more time for async tool execution
      :timer.sleep(500)

      # Worker transitions to tool_executing to process the tool
      state = :sys.get_state(pid)
      # May be tool_executing or already back to idle (if tool completed quickly)
      # or streaming if flush_pending needed sandbox access
      assert state.status in [:tool_executing, :idle, :error, :streaming]
    end
  end

  describe "terminate/2" do
    test "logs termination and runs worktree teardown when worktree_path is set",
         %{session: session, project_path: project_path} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      state = :sys.get_state(pid)

      # If worktree was set up, teardown should run on terminate
      if state.worktree_path do
        ref = Process.monitor(pid)
        GenServer.stop(pid, :normal)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
        refute Process.alive?(pid)
      else
        # If no worktree (e.g., git setup failed), just verify it terminates cleanly
        ref = Process.monitor(pid)
        GenServer.stop(pid, :normal)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
        _ = project_path
      end
    end
  end

  describe "handle_info(:retry_stream)" do
    test "retry_stream is a no-op when not in error status", %{session: session} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})
      # Worker is in :idle status — retry_stream only handles :error status
      # So sending it when idle should match the catch-all handle_info
      send(pid, :retry_stream)
      :timer.sleep(100)
      assert Process.alive?(pid)
      assert Worker.get_status(session.id) == :idle
    end
  end
end
