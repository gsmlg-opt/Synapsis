defmodule SynapsisPlugin.MCP do
  @moduledoc """
  MCP (Model Context Protocol) plugin implementation.

  Manages an MCP server process via Port (stdio) or HTTP.
  Discovers tools via `tools/list` and executes them via `tools/call`.
  """
  use Synapsis.Plugin
  require Logger

  @http_timeout_ms 15_000

  defstruct [
    :port,
    :transport,
    :url,
    :server_name,
    :command,
    :args,
    :env,
    :request_id,
    :pending,
    :buffer,
    :tools,
    :initialized,
    :server_info
  ]

  @impl Synapsis.Plugin
  def init(config) do
    transport = config[:transport] || config["transport"] || "stdio"

    cond do
      transport in ["http", "sse"] -> init_http(config, transport)
      transport == "stdio" -> init_stdio(config, transport)
      true -> {:error, {:unsupported_transport, transport}}
    end
  end

  defp init_stdio(config, transport) do
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
          transport: transport,
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

  defp init_http(config, transport) do
    server_name = config[:name] || config["name"]
    url = config[:url] || config["url"]
    env = config[:env] || config["env"] || %{}

    if is_nil(url) or url == "" do
      {:error, {:missing_url, server_name}}
    else
      state = %__MODULE__{
        port: nil,
        transport: transport,
        url: url,
        server_name: server_name,
        command: config[:command] || config["command"],
        args: config[:args] || config["args"] || [],
        env: env,
        request_id: 1,
        pending: %{},
        buffer: "",
        tools: [],
        initialized: false
      }

      with {:ok, server_info, state} <-
             request_http(state, "initialize", %{
               "protocolVersion" => "2024-11-05",
               "capabilities" => %{},
               "clientInfo" => %{"name" => "synapsis", "version" => "0.1.0"}
             }),
           {:ok, state} <- notify_http(state, "notifications/initialized"),
           {:ok, tools_result, state} <- request_http(state, "tools/list", %{}) do
        {:ok,
         %{
           state
           | initialized: true,
             server_info: server_info,
             tools: tools_result["tools"] || []
         }}
      else
        {:error, reason, _state} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
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
  def execute(tool_name, input, %__MODULE__{transport: transport} = state)
      when transport in ["http", "sse"] do
    case request_http(
           state,
           "tools/call",
           %{"name" => mcp_tool_name(tool_name), "arguments" => input}
         ) do
      {:ok, result, state} -> {:ok, extract_tool_content(result), state}
      {:error, reason, state} -> {:error, reason, state}
    end
  end

  def execute(tool_name, input, %__MODULE__{} = state) do
    # Extract the MCP tool name from the full name (mcp:server:tool)
    state =
      send_request(
        state,
        "tools/call",
        %{"name" => mcp_tool_name(tool_name), "arguments" => input},
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
    _e in [ArgumentError] -> :ok
  end

  def terminate(_reason, _state), do: :ok

  # Private helpers

  defp mcp_tool_name(tool_name) do
    case String.split(tool_name, ":", parts: 3) do
      [_mcp, _server, name] -> name
      _ -> tool_name
    end
  end

  defp request_http(state, method, params) do
    id = state.request_id
    state = %{state | request_id: id + 1}

    case post_http_json(state.url, %{
           "jsonrpc" => "2.0",
           "id" => id,
           "method" => method,
           "params" => params
         }) do
      {:ok, %{"result" => result}} ->
        {:ok, result, state}

      {:ok, %{"error" => %{"message" => message}}} ->
        {:error, message, state}

      {:ok, %{"error" => error}} ->
        {:error, inspect(error), state}

      {:ok, response} ->
        {:error, {:unexpected_response, response}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp notify_http(state, method, params \\ %{}) do
    body = %{"jsonrpc" => "2.0", "method" => method}
    body = if params == %{}, do: body, else: Map.put(body, "params", params)

    case post_http_json(state.url, body) do
      {:ok, _response} -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp post_http_json(url, body) do
    case Req.post(url,
           headers: [{"accept", "application/json, text/event-stream"}],
           json: body,
           receive_timeout: @http_timeout_ms
         ) do
      {:ok, %Req.Response{status: status, body: response_body}} when status in 200..299 ->
        decode_http_body(response_body)

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:http_error, status, response_body}}

      {:error, %Req.TransportError{} = error} ->
        {:error, Exception.message(error)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_http_body(body) when body in [nil, ""], do: {:ok, %{}}
  defp decode_http_body(body) when is_map(body), do: {:ok, body}

  defp decode_http_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, _} ->
        case decode_sse_json(body) do
          {:ok, decoded} -> {:ok, decoded}
          :error -> {:error, {:invalid_json_response, body}}
        end
    end
  end

  defp decode_sse_json(body) do
    json =
      body
      |> String.split("\n")
      |> Enum.find_value(fn line ->
        case String.trim(line) do
          "data: " <> json when json != "[DONE]" -> json
          _ -> nil
        end
      end)

    case json do
      nil -> :error
      json -> Jason.decode(json)
    end
  end

  defp handle_mcp_message(%{"id" => id, "result" => result}, state) do
    case Map.pop(state.pending, id) do
      {{:initialize, _from}, pending} ->
        if is_port(state.port) do
          case SynapsisPlugin.MCP.Protocol.encode_notification("notifications/initialized") do
            {:ok, notification} -> Port.command(state.port, notification)
            {:error, _} -> :ok
          end
        end

        state = %{state | pending: pending, initialized: true, server_info: result}
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
        GenServer.reply(from, {:error, error["message"] || "MCP tool call failed"})
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
        if is_port(state.port), do: Port.command(state.port, data)

      {:error, reason} ->
        Logger.warning("mcp_encode_failed", method: method, reason: inspect(reason))
    end

    from = Map.get(state, :_pending_from)

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
      %{"type" => type} -> "[unsupported content type: #{type}]"
      _ -> "[unsupported content format]"
    end)
    |> Enum.join("\n")
  end

  defp extract_tool_content(%{"content" => content}) when is_binary(content), do: content
  defp extract_tool_content(_result), do: "[no content in MCP response]"
end
