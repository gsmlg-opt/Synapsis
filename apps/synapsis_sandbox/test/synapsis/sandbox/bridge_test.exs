defmodule Synapsis.Sandbox.BridgeTest do
  use ExUnit.Case, async: false

  alias Synapsis.Sandbox.Bridge, as: SandboxBridge

  defmodule EchoTool do
    use Synapsis.Tool

    @impl true
    def name, do: "sandbox_echo"

    @impl true
    def description, do: "Echoes sandbox input"

    @impl true
    def parameters, do: %{}

    @impl true
    def execute(input, _context), do: {:ok, %{"echo" => input["text"]}}
  end

  setup do
    on_exit(fn ->
      Synapsis.Tool.Registry.unregister("sandbox_echo")
    end)
  end

  @tag :tmp_dir
  test "eval sends a line-framed JSON-RPC request and returns the matching response", %{
    tmp_dir: tmp_dir
  } do
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    request_path = Path.join(tmp_dir, "eval-request.jsonl")

    script =
      write_sandbox!(tmp_dir, "eval_sandbox.exs", """
      line = IO.read(:line)
      File.write!(#{inspect(request_path)}, line)
      [id] = Regex.run(~r/"id"\\s*:\\s*(\\d+)/, line, capture: :all_but_first)
      IO.puts("{\\"jsonrpc\\":\\"2.0\\",\\"id\\":" <> id <> ",\\"result\\":{\\"value\\":\\"ok\\"}}")
      """)

    {:ok, pid} = SandboxBridge.start_link(command: script, context: %{}, output_pid: self())
    on_exit(fn -> stop_bridge(pid) end)

    assert {:ok, %{"value" => "ok"}} = SandboxBridge.eval(pid, %{"code" => "1 + 1"}, 1_000)

    assert {:ok, request} = eventually_read(request_path)
    decoded = Jason.decode!(request)

    assert %{
             "jsonrpc" => "2.0",
             "method" => "eval",
             "params" => %{"code" => "1 + 1"}
           } = decoded

    assert is_integer(decoded["id"])
  end

  @tag :tmp_dir
  test "sandbox requests are executed through the host tool pipeline and receive one response", %{
    tmp_dir: tmp_dir
  } do
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    response_path = Path.join(tmp_dir, "tool-response.jsonl")

    Synapsis.Tool.Registry.register_module("sandbox_echo", EchoTool, timeout: 1_000)

    script =
      write_sandbox!(tmp_dir, "reverse_tool_sandbox.exs", """
      IO.puts("{\\"jsonrpc\\":\\"2.0\\",\\"id\\":\\"tool-1\\",\\"method\\":\\"sandbox_echo\\",\\"params\\":{\\"text\\":\\"hello\\"}}")
      response = IO.read(:line)
      File.write!(#{inspect(response_path)}, response)
      """)

    {:ok, pid} = SandboxBridge.start_link(command: script, context: %{}, output_pid: self())
    on_exit(fn -> stop_bridge(pid) end)

    assert {:ok, response} = eventually_read(response_path)

    assert %{
             "jsonrpc" => "2.0",
             "id" => "tool-1",
             "result" => %{"echo" => "hello"}
           } = Jason.decode!(response)
  end

  test "start_link fails cleanly when the sandbox binary does not exist" do
    # proc_lib consumes the init-failure EXIT during sync start, but only a
    # trapping caller survives the exit signal to see the error tuple.
    Process.flag(:trap_exit, true)

    assert {:error, {:no_binary, "no-such-sandbox-binary-xyz"}} =
             SandboxBridge.start_link(command: "no-such-sandbox-binary-xyz", context: %{})
  end

  @tag :tmp_dir
  test "a second eval while one is in flight is rejected with :busy", %{tmp_dir: tmp_dir} do
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    script =
      write_sandbox!(tmp_dir, "slow_sandbox.exs", """
      _line = IO.read(:line)
      Process.sleep(10_000)
      """)

    {:ok, pid} = SandboxBridge.start_link(command: script, context: %{}, output_pid: self())
    on_exit(fn -> stop_bridge(pid) end)

    test_pid = self()

    spawn(fn ->
      send(test_pid, {:first_eval, SandboxBridge.eval(pid, %{"code" => "slow"}, 8_000)})
    end)

    # Wait until the first eval is registered as in flight.
    wait_until(fn -> :sys.get_state(pid).eval != nil end)

    assert {:error, :busy} = SandboxBridge.eval(pid, %{"code" => "second"}, 1_000)
  end

  @tag :tmp_dir
  test "an over-limit line fails the in-flight eval and stops the bridge", %{tmp_dir: tmp_dir} do
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    Process.flag(:trap_exit, true)

    script =
      write_sandbox!(tmp_dir, "overflow_sandbox.exs", """
      _line = IO.read(:line)
      IO.puts(String.duplicate("x", 4096))
      """)

    {:ok, pid} =
      SandboxBridge.start_link(command: script, context: %{}, output_pid: self(), line_limit: 64)

    assert {:error, :line_overflow} = SandboxBridge.eval(pid, %{"code" => "1"}, 5_000)
    assert_receive {:EXIT, ^pid, :line_overflow}, 1_000
  end

  @tag :tmp_dir
  test "sandbox exit mid-eval fails the eval and stops with the exit status", %{
    tmp_dir: tmp_dir
  } do
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    Process.flag(:trap_exit, true)

    script =
      write_sandbox!(tmp_dir, "crash_sandbox.exs", """
      _line = IO.read(:line)
      System.halt(3)
      """)

    {:ok, pid} = SandboxBridge.start_link(command: script, context: %{}, output_pid: self())

    assert {:error, {:sandbox_exited, 3}} = SandboxBridge.eval(pid, %{"code" => "1"}, 5_000)
    assert_receive {:EXIT, ^pid, {:sandbox_exited, 3}}, 1_000
  end

  @tag :tmp_dir
  test "eval timeout fails the caller and restarts the runtime", %{tmp_dir: tmp_dir} do
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    Process.flag(:trap_exit, true)

    script =
      write_sandbox!(tmp_dir, "hang_sandbox.exs", """
      _line = IO.read(:line)
      Process.sleep(10_000)
      """)

    {:ok, pid} = SandboxBridge.start_link(command: script, context: %{}, output_pid: self())

    assert {:error, :timeout} = SandboxBridge.eval(pid, %{"code" => "hang"}, 300)
    assert_receive {:EXIT, ^pid, :eval_timeout}, 1_000
  end

  @tag :tmp_dir
  test "responses split across writes and coalesced with console output are framed correctly",
       %{tmp_dir: tmp_dir} do
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    script =
      write_sandbox!(tmp_dir, "split_sandbox.exs", """
      line = IO.read(:line)
      [id] = Regex.run(~r/"id"\\s*:\\s*(\\d+)/, line, capture: :all_but_first)
      response = "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":" <> id <> ",\\"result\\":{\\"value\\":\\"split\\"}}"
      {first, rest} = String.split_at(response, 10)
      IO.write(first)
      Process.sleep(50)
      IO.write(rest <> "\\nconsole noise\\n")
      """)

    {:ok, pid} = SandboxBridge.start_link(command: script, context: %{}, output_pid: self())
    on_exit(fn -> stop_bridge(pid) end)

    assert {:ok, %{"value" => "split"}} = SandboxBridge.eval(pid, %{"code" => "1"}, 5_000)
    assert_receive {:sandbox_output, "console noise"}, 1_000
  end

  @tag :tmp_dir
  test "an unknown reverse tool gets exactly one JSON-RPC error response", %{tmp_dir: tmp_dir} do
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    response_path = Path.join(tmp_dir, "error-response.jsonl")

    script =
      write_sandbox!(tmp_dir, "unknown_tool_sandbox.exs", """
      IO.puts("{\\"jsonrpc\\":\\"2.0\\",\\"id\\":\\"t-1\\",\\"method\\":\\"no_such_tool_xyz\\",\\"params\\":{}}")
      response = IO.read(:line)
      File.write!(#{inspect(response_path)}, response)
      Process.sleep(200)
      """)

    {:ok, pid} = SandboxBridge.start_link(command: script, context: %{}, output_pid: self())
    on_exit(fn -> stop_bridge(pid) end)

    assert {:ok, response} = eventually_read(response_path)
    assert [_only_line] = String.split(String.trim(response), "\n")

    assert %{"jsonrpc" => "2.0", "id" => "t-1", "error" => %{"code" => -32_000}} =
             Jason.decode!(response)
  end

  @tag :tmp_dir
  test "console output is broadcast on the session PubSub topic", %{tmp_dir: tmp_dir} do
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    session_id = Ecto.UUID.generate()
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session_id}")

    script =
      write_sandbox!(tmp_dir, "console_sandbox.exs", """
      IO.puts("hello from sandbox")
      Process.sleep(200)
      """)

    {:ok, pid} = SandboxBridge.start_link(command: script, context: %{session_id: session_id})
    on_exit(fn -> stop_bridge(pid) end)

    assert_receive {"sandbox_output", %{line: "hello from sandbox"}}, 2_000
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts <= 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(25)
        wait_until(fun, attempts - 1)
    end
  end

  defp write_sandbox!(tmp_dir, name, body) do
    path = Path.join(tmp_dir, name)

    File.write!(path, """
    #!/usr/bin/env elixir
    #{body}
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp eventually_read(path, attempts \\ 30)
  defp eventually_read(path, attempts) when attempts <= 0, do: File.read(path)

  defp eventually_read(path, attempts) do
    case File.read(path) do
      {:ok, content} when content != "" ->
        {:ok, content}

      _ ->
        Process.sleep(25)
        eventually_read(path, attempts - 1)
    end
  end

  defp stop_bridge(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp stop_bridge(_pid), do: :ok
end
