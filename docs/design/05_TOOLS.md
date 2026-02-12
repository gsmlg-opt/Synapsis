# 05 — Tool System

## Built-in Tools

Mirrors OpenCode's tool set:

| Tool | Description | Permission | Timeout |
|------|-------------|------------|---------|
| `file_read` | Read file contents | auto | 5s |
| `file_edit` | Apply structured edits (search/replace) | ask | 10s |
| `file_write` | Write new file | ask | 10s |
| `bash` | Execute shell command | ask | 30s |
| `grep` | Ripgrep-style search | auto | 10s |
| `glob` | File pattern matching | auto | 5s |
| `diagnostics` | LSP diagnostics | auto | 5s |
| `fetch` | HTTP fetch (for docs) | ask | 15s |
| `mcp_tool` | Delegated MCP tool call | ask | 30s |

## Tool Execution Flow

```elixir
defmodule Synapsis.Tool.Executor do
  @doc "Execute a tool call with permission check, timeout, and sandboxing"
  def execute(tool_name, input, context) do
    tool = Synapsis.Tool.Registry.get!(tool_name)
    
    with :approved <- check_or_request_permission(tool, input, context),
         {:ok, result} <- run_with_timeout(tool, input, context) do
      {:ok, result}
    else
      :denied -> {:ok, %{error: "Tool use denied by user"}}
      {:error, :timeout} -> {:ok, %{error: "Tool execution timed out"}}
      {:error, reason} -> {:ok, %{error: inspect(reason)}}
    end
  end
  
  defp run_with_timeout(tool, input, context) do
    Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn ->
      tool.call(input, context)
    end)
    |> Task.yield(tool.timeout_ms) || Task.shutdown(task)
  end
end
```

## Bash Tool — Port-based

```elixir
defmodule Synapsis.Tool.Bash do
  @behaviour Synapsis.Tool.Behaviour

  def call(%{"command" => cmd}, %{project_path: cwd}) do
    port = Port.open({:spawn_executable, "/bin/sh"},
      [:binary, :exit_status, :stderr_to_stdout,
       args: ["-c", cmd],
       cd: cwd,
       env: sanitized_env()])
    
    collect_output(port, [], @timeout)
  end

  defp collect_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} -> collect_output(port, [data | acc], timeout)
      {^port, {:exit_status, 0}} -> {:ok, %{output: IO.iodata_to_binary(Enum.reverse(acc))}}
      {^port, {:exit_status, code}} -> {:ok, %{output: IO.iodata_to_binary(Enum.reverse(acc)), exit_code: code}}
    after
      timeout ->
        Port.close(port)
        {:error, :timeout}
    end
  end
end
```

## File Edit Tool — Structured Edits

```elixir
defmodule Synapsis.Tool.FileEdit do
  @behaviour Synapsis.Tool.Behaviour

  def call(%{"path" => path, "old_text" => old, "new_text" => new}, %{project_path: cwd}) do
    full_path = Path.join(cwd, path)
    content = File.read!(full_path)
    
    case String.split(content, old, parts: 2) do
      [before, after_text] ->
        new_content = before <> new <> after_text
        File.write!(full_path, new_content)
        {:ok, %{path: path, applied: true}}
      [_no_match] ->
        {:error, "old_text not found in file"}
    end
  end
end
```

## MCP Tool Delegation

MCP tools are discovered at startup from config and registered dynamically:

```elixir
defmodule Synapsis.MCP.Client do
  use GenServer

  # Each MCP server connection is a GenServer managing a Port (stdio) or HTTP (SSE)
  # Tools are registered in Synapsis.Tool.Registry with prefix "mcp:<server>:<tool>"
  
  def call_tool(server_name, tool_name, input) do
    GenServer.call(via(server_name), {:call_tool, tool_name, input})
  end
end
```
