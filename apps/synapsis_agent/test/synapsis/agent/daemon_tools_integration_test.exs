defmodule Synapsis.Agent.DaemonToolsIntegrationTest do
  use Synapsis.Agent.DaemonCase, async: false

  @basic_tools ~w(
    file_read list_dir grep glob memory_search todo_read session_summarize skill tool_search
    agent_status agent_discover agent_inbox
  )

  defmodule CountingFileRead do
    use Synapsis.Tool

    def name, do: "file_read"
    def description, do: Synapsis.Tool.FileRead.description()
    def parameters, do: Synapsis.Tool.FileRead.parameters()
    def permission_level, do: :read

    def execute(input, context) do
      send(Application.fetch_env!(:synapsis_agent, :daemon_tool_test_owner), :file_read_executed)
      Synapsis.Tool.FileRead.execute(input, context)
    end
  end

  defmodule HangingFileRead do
    use Synapsis.Tool

    def name, do: "file_read"
    def description, do: "Hangs to exercise the existing tool timeout."
    def parameters, do: Synapsis.Tool.FileRead.parameters()
    def permission_level, do: :read

    def execute(_input, _context) do
      send(
        Application.fetch_env!(:synapsis_agent, :daemon_tool_test_owner),
        :hanging_tool_started
      )

      receive do
        :never -> {:ok, "unexpected"}
      end
    end
  end

  defmodule FailingPermission do
    def update_config(session_id, _attrs) do
      send(
        Application.fetch_env!(:synapsis_agent, :daemon_tool_test_owner),
        {:permission_setup_attempted, session_id}
      )

      {:error, :permission_store_down}
    end
  end

  @tag :tmp_dir
  test "default manual run exposes basic tools and executes file_read without approval", %{
    tmp_dir: tmp_dir
  } do
    File.write!(Path.join(tmp_dir, "safe.txt"), "daemon-safe-content")
    register_counting_file_read()

    {daemon, _task_supervisor} = start_test_daemon()

    {_bypass, provider_name, agent_name} =
      controlled_tool_provider(tmp_dir, "file_read", %{"path" => "safe.txt"})

    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, Daemon.topic())

    assert {:ok, queued} =
             Daemon.submit(daemon, "Read safe.txt", daemon_opts(agent_name, provider_name))

    assert_receive {:tool_provider_request, 1, first_request, request_pid}, 2_000
    send(request_pid, :respond)

    assert Enum.sort(tool_names(first_request)) == Enum.sort(@basic_tools)
    refute "bash" in tool_names(first_request)
    refute "file_write" in tool_names(first_request)
    refute "file_delete" in tool_names(first_request)

    assert {:ok, running} = wait_for_run(queued.id, "running")
    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{running.session_id}")

    assert :allowed =
             Synapsis.Tool.Permission.check("file_read", %{"path" => "safe.txt"}, %{
               session_id: running.session_id
             })

    assert :denied =
             Synapsis.Tool.Permission.check("file_delete", %{"path" => "safe.txt"}, %{
               session_id: running.session_id
             })

    assert_receive :file_read_executed, 2_000
    refute_receive :file_read_executed, 100
    refute_receive {"permission_requests", _payload}, 100

    assert_receive {:tool_provider_request, 2, second_request, _request_pid}, 2_000
    assert Jason.encode!(second_request) =~ "daemon-safe-content"
    assert {:ok, completed} = wait_for_run(queued.id, "completed")
    assert completed.summary == "daemon tool run complete"
    assert Process.alive?(Process.whereis(daemon))
  end

  @tag :tmp_dir
  test "a provider-invented tool outside the basic toolset is denied without approval", %{
    tmp_dir: tmp_dir
  } do
    target = Path.join(tmp_dir, "must-not-exist.txt")
    {daemon, _task_supervisor} = start_test_daemon()

    {_bypass, provider_name, agent_name} =
      controlled_tool_provider(tmp_dir, "file_write", %{
        "path" => "must-not-exist.txt",
        "content" => "not allowed"
      })

    assert {:ok, queued} =
             Daemon.submit(daemon, "Do not write", daemon_opts(agent_name, provider_name))

    assert_receive {:tool_provider_request, 1, first_request, request_pid}, 2_000
    send(request_pid, :respond)
    refute "file_write" in tool_names(first_request)

    assert {:ok, running} = wait_for_run(queued.id, "running")
    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{running.session_id}")

    assert_receive {:tool_provider_request, 2, second_request, _request_pid}, 2_000
    assert Jason.encode!(second_request) =~ "Tool denied"
    refute_receive {"permission_requests", _payload}, 100
    refute_receive {"permission_request", _payload}, 100
    refute File.exists?(target)
    assert {:ok, _completed} = wait_for_run(queued.id, "completed")
    assert Process.alive?(Process.whereis(daemon))
  end

  test "unknown and dangerous manual profiles are rejected before persistence" do
    {daemon, _task_supervisor} = start_test_daemon()
    {:ok, sessions_before} = Synapsis.Session.Store.list_metas()

    assert {:error, :invalid_options} =
             Daemon.submit(daemon, "unknown", %{tool_profile: "unrestricted"})

    assert {:error, :invalid_options} =
             Daemon.submit(daemon, "dangerous", %{tool_profile: "dangerous"})

    assert [] = Runs.list_recent()
    assert {:ok, ^sessions_before} = Synapsis.Session.Store.list_metas()
    assert Process.alive?(Process.whereis(daemon))
  end

  @tag :tmp_dir
  test "permission setup failure fails visibly without sending the prompt", %{tmp_dir: tmp_dir} do
    previous_owner = Application.get_env(:synapsis_agent, :daemon_tool_test_owner, :missing)
    Application.put_env(:synapsis_agent, :daemon_tool_test_owner, self())
    on_exit(fn -> restore_application_env(:daemon_tool_test_owner, previous_owner) end)

    bypass = Bypass.open()
    owner = self()

    Bypass.stub(bypass, "POST", "/v1/chat/completions", fn conn ->
      send(owner, :unexpected_provider_request)
      Plug.Conn.send_resp(conn, 500, "prompt must not be sent")
    end)

    {provider_name, agent_name} = register_provider_agent(tmp_dir, bypass)
    {daemon, _task_supervisor} = start_test_daemon(permission: FailingPermission)

    assert {:ok, queued} =
             Daemon.submit(daemon, "Do not send", daemon_opts(agent_name, provider_name))

    assert_receive {:permission_setup_attempted, session_id}, 2_000
    assert {:ok, failed} = wait_for_run(queued.id, "failed")
    assert failed.session_id == session_id
    assert failed.error =~ "permission_store_down"
    assert {:ok, %{id: ^session_id}} = Synapsis.Sessions.get(session_id)
    refute_receive :unexpected_provider_request, 100
    assert Process.alive?(Process.whereis(daemon))
  end

  @tag :tmp_dir
  test "explicit assistant_coding exposes write and execute tools without destructive tools", %{
    tmp_dir: tmp_dir
  } do
    {daemon, _task_supervisor} = start_test_daemon()

    {_bypass, provider_name, agent_name} =
      controlled_tool_provider(tmp_dir, "file_write", %{
        "path" => "coding-output.txt",
        "content" => "written by daemon"
      })

    opts =
      agent_name
      |> daemon_opts(provider_name)
      |> Map.put(:tool_profile, "assistant_coding")

    assert {:ok, queued} = Daemon.submit(daemon, "Write the coding output", opts)
    assert_receive {:tool_provider_request, 1, first_request, request_pid}, 2_000
    send(request_pid, :respond)

    assert {:ok, expected_tools} =
             Synapsis.Agent.Daemon.Toolsets.resolve("assistant_coding")

    assert Enum.sort(tool_names(first_request)) == Enum.sort(expected_tools)
    assert "bash" in tool_names(first_request)
    assert "file_write" in tool_names(first_request)
    refute "file_delete" in tool_names(first_request)

    assert {:ok, running} = wait_for_run(queued.id, "running")
    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{running.session_id}")

    assert :allowed =
             Synapsis.Tool.Permission.check("file_write", %{"path" => "coding-output.txt"}, %{
               session_id: running.session_id
             })

    assert_receive {:tool_provider_request, 2, second_request, _request_pid}, 2_000
    refute_receive {"permission_requests", _payload}, 100
    assert Jason.encode!(second_request) =~ "coding-output.txt"
    assert File.read!(Path.join(tmp_dir, "coding-output.txt")) == "written by daemon"
    assert {:ok, _completed} = wait_for_run(queued.id, "completed")
    assert Process.alive?(Process.whereis(daemon))
  end

  @tag :tmp_dir
  test "tool timeout is returned to the provider and the daemon remains alive", %{
    tmp_dir: tmp_dir
  } do
    register_hanging_file_read()
    {daemon, _task_supervisor} = start_test_daemon()

    {_bypass, provider_name, agent_name} =
      controlled_tool_provider(tmp_dir, "file_read", %{"path" => "never.txt"})

    assert {:ok, queued} =
             Daemon.submit(
               daemon,
               "Observe a tool timeout",
               daemon_opts(agent_name, provider_name)
             )

    assert_receive {:tool_provider_request, 1, _first_request, request_pid}, 2_000
    send(request_pid, :respond)
    assert_receive :hanging_tool_started, 2_000

    assert_receive {:tool_provider_request, 2, second_request, _request_pid}, 2_000
    assert Jason.encode!(second_request) =~ "Tool execution timed out"
    refute_receive {"permission_requests", _payload}, 100
    assert {:ok, _completed} = wait_for_run(queued.id, "completed")
    assert Process.alive?(Process.whereis(daemon))
  end

  defp register_counting_file_read do
    previous_owner = Application.get_env(:synapsis_agent, :daemon_tool_test_owner, :missing)
    Application.put_env(:synapsis_agent, :daemon_tool_test_owner, self())
    :ok = Synapsis.Tool.Registry.register_module("file_read", CountingFileRead, timeout: 5_000)

    on_exit(fn ->
      restore_application_env(:daemon_tool_test_owner, previous_owner)
      Synapsis.Tool.Builtin.register_all()
    end)
  end

  defp register_hanging_file_read do
    previous_owner = Application.get_env(:synapsis_agent, :daemon_tool_test_owner, :missing)
    Application.put_env(:synapsis_agent, :daemon_tool_test_owner, self())

    :ok =
      Synapsis.Tool.Registry.register_module("file_read", HangingFileRead,
        timeout: 25,
        max_retries: 0
      )

    on_exit(fn ->
      restore_application_env(:daemon_tool_test_owner, previous_owner)
      Synapsis.Tool.Builtin.register_all()
    end)
  end

  defp controlled_tool_provider(tmp_dir, tool_name, input) do
    owner = self()
    bypass = Bypass.open()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      request_number = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(owner, {:tool_provider_request, request_number, request, self()})

      case request_number do
        1 ->
          receive do
            :respond ->
              send_sse(conn, [
                tool_call_chunk(tool_name, "daemon-tool-call", input),
                finish_chunk("tool_calls")
              ])
          after
            5_000 -> Plug.Conn.send_resp(conn, 500, "test did not release tool response")
          end

        2 ->
          send_sse(conn, [text_chunk("daemon tool run complete"), finish_chunk("stop")])

        _unexpected ->
          Plug.Conn.send_resp(conn, 500, "unexpected provider request")
      end
    end)

    {provider_name, agent_name} = register_provider_agent(tmp_dir, bypass)
    {bypass, provider_name, agent_name}
  end

  defp tool_names(request) do
    Enum.map(request["tools"] || [], &get_in(&1, ["function", "name"]))
  end

  defp tool_call_chunk(tool_name, tool_call_id, input) do
    %{
      "id" => "daemon-tool-response",
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{
            "tool_calls" => [
              %{
                "index" => 0,
                "id" => tool_call_id,
                "type" => "function",
                "function" => %{"name" => tool_name, "arguments" => Jason.encode!(input)}
              }
            ]
          },
          "finish_reason" => nil
        }
      ]
    }
  end
end
