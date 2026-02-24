defmodule SynapsisPlugin.MCP do
  @moduledoc """
  MCP (Model Context Protocol) plugin implementation.

  Manages an MCP server process via Port (stdio) or HTTP (SSE).
  Discovers tools via `tools/list` and executes them via `tools/call`.
  """
  use Synapsis.Plugin
  require Logger

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

  @impl Synapsis.Plugin
  def init(config) do
    server_name = config[:name] || config["name"]
    command = config[:command] || config["command"]
    args = config[:args] || config["args"] || []
    env = config[:env] || config["env"] || %{}

    case System.find_executable(to_string(command)) do
      nil ->
        Logger.warning("mcp_binary_not_found", server: server_name, command: command)
        {:error, {:no_binary, command}}

      exe_path ->
        env_list =
          Enum.map(env, fn {k, v} ->
            {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
          end)

        str_args = Enum.map(args, &to_string/1)

        port =
          Port.open({:spawn_executable, exe_path}, [
            :binary,
            :exit_status,
            {:args, str_args},
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

        # Send initialize request
        state =
          send_request(state, "initialize", %{
            "protocolVersion" => "2024-11-05",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "synapsis", "version" => "0.1.0"}
          })

        {:ok, state}
    end
  end

  @impl Synapsis.Plugin
  def tools(%__MODULE__{tools: tools, server_name: server_name}) do
    Enum.map(tools, fn tool ->
      %{
        name: "mcp:#{server_name}:#{tool["name"]}",
        description: tool["description"] || "",
        parameters: tool["inputSchema"] || %{}
      }
    end)
  end

  @impl Synapsis.Plugin
  def execute(tool_name, input, %__MODULE__{} = state) do
    # Extract the MCP tool name from the full name (mcp:server:tool)
    mcp_tool_name =
      case String.split(tool_name, ":", parts: 3) do
        [_mcp, _server, name] -> name
        _ -> tool_name
      end

    state =
      send_request(
        state,
        "tools/call",
        %{"name" => mcp_tool_name, "arguments" => input},
        :tool_call
      )

    {:async, state}
  end

  @impl Synapsis.Plugin
  def handle_info({port, {:data, data}}, %__MODULE__{port: port} = state) do
    buffer = state.buffer <> data
    {messages, rest} = SynapsisPlugin.MCP.Protocol.decode_message(buffer)
    state = %{state | buffer: rest}

    state = Enum.reduce(messages, state, &handle_mcp_message/2)
    {:ok, state}
  end

  def handle_info({port, {:exit_status, status}}, %__MODULE__{port: port} = state) do
    Logger.info("mcp_server_exited", server: state.server_name, status: status)
    {:ok, %{state | port: nil}}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl Synapsis.Plugin
  def terminate(_reason, %__MODULE__{port: port}) when is_port(port) do
    Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  # Private helpers

  defp handle_mcp_message(%{"id" => id, "result" => result}, state) do
    case Map.pop(state.pending, id) do
      {{:initialize, _from}, pending} ->
        case SynapsisPlugin.MCP.Protocol.encode_notification("notifications/initialized") do
          {:ok, notification} -> Port.command(state.port, notification)
          {:error, _} -> :ok
        end

        state = %{state | pending: pending, initialized: true}
        send_request(state, "tools/list", %{})

      {{:tools_list, _from}, pending} ->
        tools = result["tools"] || []
        %{state | pending: pending, tools: tools}

      {{:tool_call, from}, pending} ->
        content = extract_tool_content(result)

        if from do
          GenServer.reply(from, {:ok, content})
        end

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

  defp send_request(state, method, params, tag \\ nil) do
    id = state.request_id

    case SynapsisPlugin.MCP.Protocol.encode_request(id, method, params) do
      {:ok, data} ->
        Port.command(state.port, data)

      {:error, reason} ->
        Logger.warning("mcp_encode_failed", method: method, reason: inspect(reason))
    end

    from = state[:_pending_from]

    request_type =
      case tag || method do
        "initialize" -> {:initialize, from}
        "tools/list" -> {:tools_list, from}
        :tool_call -> {:tool_call, from}
        "tools/call" -> {:tool_call, from}
        _ -> {:other, from}
      end

    state = Map.delete(state, :_pending_from)
    %{state | request_id: id + 1, pending: Map.put(state.pending, id, request_type)}
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
