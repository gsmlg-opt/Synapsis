defmodule Synapsis.MCP.Client do
  @moduledoc "GenServer managing a single MCP server connection via stdio (Port)."
  use GenServer
  require Logger

  alias Synapsis.MCP.Protocol

  defstruct [
    :port,
    :server_name,
    :command,
    :args,
    :env,
    :request_id,
    :pending,
    :buffer,
    :tools,
    :initialized
  ]

  def start_link(opts) do
    server_name = Keyword.fetch!(opts, :server_name)
    name = {:via, Registry, {Synapsis.MCP.Registry, server_name}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def list_tools(server_name) do
    name = {:via, Registry, {Synapsis.MCP.Registry, server_name}}

    try do
      GenServer.call(name, :list_tools, 10_000)
    catch
      :exit, _ -> {:error, :not_running}
    end
  end

  def call_tool(server_name, tool_name, arguments) do
    name = {:via, Registry, {Synapsis.MCP.Registry, server_name}}

    try do
      GenServer.call(name, {:call_tool, tool_name, arguments}, 30_000)
    catch
      :exit, _ -> {:error, :not_running}
    end
  end

  @impl true
  def init(opts) do
    server_name = Keyword.fetch!(opts, :server_name)
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, %{})

    case System.find_executable(command) do
      nil ->
        Logger.warning("mcp_binary_not_found", server: server_name, command: command)
        {:stop, {:no_binary, command}}

      exe_path ->
        env_list = Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

        port =
          Port.open({:spawn_executable, exe_path}, [
            :binary,
            :exit_status,
            {:args, args},
            {:env, env_list}
          ])

        state = %__MODULE__{
          port: port,
          server_name: server_name,
          command: command,
          args: args,
          env: env,
          request_id: 1,
          pending: %{},
          buffer: "",
          tools: [],
          initialized: false
        }

        # Send initialize
        state =
          send_request(state, "initialize", %{
            "protocolVersion" => "2024-11-05",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "synapsis", "version" => "0.1.0"}
          })

        {:ok, state}
    end
  end

  @impl true
  def handle_call(:list_tools, _from, %{tools: tools} = state) do
    {:reply, {:ok, tools}, state}
  end

  def handle_call({:call_tool, tool_name, arguments}, from, state) do
    state =
      send_request(
        state,
        "tools/call",
        %{
          "name" => tool_name,
          "arguments" => arguments
        },
        from
      )

    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> data
    {messages, rest} = Protocol.decode_message(buffer)
    state = %{state | buffer: rest}

    state = Enum.reduce(messages, state, &handle_mcp_message/2)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.info("mcp_server_exited", server: state.server_name, status: status)
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp handle_mcp_message(%{"id" => id, "result" => result}, state) do
    case Map.pop(state.pending, id) do
      {{:initialize, _from}, pending} ->
        # Send initialized notification
        Port.command(state.port, Protocol.encode_notification("notifications/initialized"))

        # Discover tools
        state = %{state | pending: pending, initialized: true}
        send_request(state, "tools/list", %{})

      {{:tools_list, _from}, pending} ->
        tools = result["tools"] || []
        register_mcp_tools(state.server_name, tools)
        %{state | pending: pending, tools: tools}

      {{:tool_call, from}, pending} ->
        content = extract_tool_content(result)
        GenServer.reply(from, {:ok, content})
        %{state | pending: pending}

      {nil, _} ->
        state
    end
  end

  defp handle_mcp_message(%{"id" => id, "error" => error}, state) do
    case Map.pop(state.pending, id) do
      {{_type, from}, pending} when not is_nil(from) ->
        GenServer.reply(from, {:error, error["message"] || inspect(error)})
        %{state | pending: pending}

      _ ->
        state
    end
  end

  defp handle_mcp_message(_msg, state), do: state

  defp send_request(state, method, params, from \\ nil) do
    id = state.request_id
    data = Protocol.encode_request(id, method, params)
    Port.command(state.port, data)

    request_type =
      case method do
        "initialize" -> {:initialize, from}
        "tools/list" -> {:tools_list, from}
        "tools/call" -> {:tool_call, from}
        _ -> {:other, from}
      end

    %{state | request_id: id + 1, pending: Map.put(state.pending, id, request_type)}
  end

  defp register_mcp_tools(server_name, tools) do
    for tool <- tools do
      tool_def = %{
        name: "mcp:#{server_name}:#{tool["name"]}",
        description: tool["description"] || "",
        parameters: tool["inputSchema"] || %{},
        module: Synapsis.MCP.ToolProxy,
        timeout: 30_000,
        mcp_server: server_name,
        mcp_tool: tool["name"]
      }

      Synapsis.Tool.Registry.register(tool_def)
    end
  end

  defp extract_tool_content(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> text
      other -> inspect(other)
    end)
    |> Enum.join("\n")
  end

  defp extract_tool_content(%{"content" => content}) when is_binary(content), do: content
  defp extract_tool_content(result), do: inspect(result)
end
