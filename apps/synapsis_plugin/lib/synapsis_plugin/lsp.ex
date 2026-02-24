defmodule SynapsisPlugin.LSP do
  @moduledoc """
  LSP (Language Server Protocol) plugin implementation.

  Manages an LSP server process via Port (stdio), collects diagnostics,
  and exposes LSP capabilities as tools.
  """
  use Synapsis.Plugin
  require Logger

  defstruct [
    :port,
    :language,
    :root_path,
    :request_id,
    :pending,
    :buffer,
    :initialized,
    :diagnostics,
    :pending_requests
  ]

  @lsp_tools [
    %{
      name: "lsp_diagnostics",
      description: "Get current diagnostics (errors, warnings) from language servers.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "File path to get diagnostics for (optional)"
          }
        },
        "required" => []
      }
    },
    %{
      name: "lsp_definition",
      description: "Go to definition of a symbol.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "File path"},
          "line" => %{"type" => "integer", "description" => "Line number (0-indexed)"},
          "character" => %{"type" => "integer", "description" => "Character offset (0-indexed)"}
        },
        "required" => ["path", "line", "character"]
      }
    },
    %{
      name: "lsp_references",
      description: "Find all references to a symbol.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "File path"},
          "line" => %{"type" => "integer", "description" => "Line number (0-indexed)"},
          "character" => %{"type" => "integer", "description" => "Character offset (0-indexed)"}
        },
        "required" => ["path", "line", "character"]
      }
    },
    %{
      name: "lsp_hover",
      description: "Get hover information for a symbol.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "File path"},
          "line" => %{"type" => "integer", "description" => "Line number (0-indexed)"},
          "character" => %{"type" => "integer", "description" => "Character offset (0-indexed)"}
        },
        "required" => ["path", "line", "character"]
      }
    },
    %{
      name: "lsp_symbols",
      description: "List symbols in a document.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "File path"}
        },
        "required" => ["path"]
      }
    }
  ]

  @impl Synapsis.Plugin
  def init(config) do
    language = config[:name] || config["name"] || config[:language] || config["language"]
    root_path = config[:root_path] || config["root_path"]

    case lsp_command(language) do
      nil ->
        {:error, {:no_lsp_for_language, language}}

      {executable, args} ->
        case System.find_executable(executable) do
          nil ->
            Logger.info("lsp_binary_not_found", language: language, executable: executable)
            {:error, {:no_lsp_binary, executable}}

          exe_path ->
            port =
              Port.open({:spawn_executable, exe_path}, [
                :binary,
                :exit_status,
                {:args, args},
                {:cd, root_path || "."}
              ])

            state = %__MODULE__{
              port: port,
              language: language,
              root_path: root_path || ".",
              request_id: 1,
              pending: %{},
              buffer: "",
              initialized: false,
              diagnostics: %{},
              pending_requests: %{}
            }

            state = send_initialize(state)
            {:ok, state}
        end
    end
  end

  @impl Synapsis.Plugin
  def tools(_state), do: @lsp_tools

  @impl Synapsis.Plugin
  def execute("lsp_diagnostics", input, state) do
    filtered =
      case input["path"] do
        nil ->
          state.diagnostics

        path ->
          uri = "file://#{Path.expand(path, state.root_path)}"
          Map.take(state.diagnostics, [uri])
      end

    if map_size(filtered) == 0 do
      {:ok, "No diagnostics found.", state}
    else
      result =
        filtered
        |> Enum.flat_map(fn {uri, diags} ->
          file = String.replace_prefix(uri, "file://", "")

          Enum.map(diags, fn d ->
            line = get_in(d, ["range", "start", "line"]) || 0
            severity = severity_label(d["severity"])
            "#{file}:#{line + 1}: #{severity}: #{d["message"]}"
          end)
        end)
        |> Enum.join("\n")

      {:ok, result, state}
    end
  end

  def execute("lsp_definition", input, state) do
    state = send_lsp_request(state, "textDocument/definition", position_params(input, state))
    {:async, state}
  end

  def execute("lsp_references", input, state) do
    params =
      position_params(input, state)
      |> Map.put("context", %{"includeDeclaration" => true})

    state = send_lsp_request(state, "textDocument/references", params)
    {:async, state}
  end

  def execute("lsp_hover", input, state) do
    state = send_lsp_request(state, "textDocument/hover", position_params(input, state))
    {:async, state}
  end

  def execute("lsp_symbols", input, state) do
    uri = "file://#{Path.expand(input["path"], state.root_path)}"
    params = %{"textDocument" => %{"uri" => uri}}
    state = send_lsp_request(state, "textDocument/documentSymbol", params)
    {:async, state}
  end

  def execute(tool_name, _input, state) do
    {:error, "Unknown LSP tool: #{tool_name}", state}
  end

  @impl Synapsis.Plugin
  def handle_effect(:file_changed, %{path: path}, state) when is_port(state.port) do
    uri = "file://#{Path.expand(to_string(path), state.root_path)}"

    case File.read(Path.expand(to_string(path), state.root_path)) do
      {:ok, content} ->
        case SynapsisPlugin.LSP.Protocol.encode_notification("textDocument/didChange", %{
               "textDocument" => %{"uri" => uri, "version" => 1},
               "contentChanges" => [%{"text" => content}]
             }) do
          {:ok, notification} -> Port.command(state.port, notification)
          {:error, _} -> :ok
        end
        {:ok, state}

      {:error, _} ->
        {:ok, state}
    end
  end

  def handle_effect(_effect, _payload, state), do: {:ok, state}

  @impl Synapsis.Plugin
  def handle_info({port, {:data, data}}, %__MODULE__{port: port} = state) do
    buffer = state.buffer <> data
    state = process_buffer(%{state | buffer: buffer})
    {:ok, state}
  end

  def handle_info({port, {:exit_status, status}}, %__MODULE__{port: port} = state) do
    Logger.info("lsp_server_exited", language: state.language, status: status)
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

  defp process_buffer(state) do
    case SynapsisPlugin.LSP.Protocol.decode_message(state.buffer) do
      {:ok, msg, rest} ->
        state = handle_lsp_message(msg, %{state | buffer: rest})
        process_buffer(state)

      :incomplete ->
        state

      {:error, _} ->
        state
    end
  end

  defp handle_lsp_message(%{"id" => id, "result" => result}, state) do
    case Map.pop(state.pending, id) do
      {:initialize, pending} ->
        send_initialized(state)
        %{state | pending: pending, initialized: true}

      {{method, from}, pending} ->
        formatted = format_lsp_result(method, result)

        if from do
          GenServer.reply(from, {:ok, formatted})
        end

        %{state | pending: pending}

      {_request, pending} ->
        %{state | pending: pending}
    end
  end

  defp handle_lsp_message(
         %{"method" => "textDocument/publishDiagnostics", "params" => params},
         state
       ) do
    uri = params["uri"]
    diagnostics = params["diagnostics"] || []
    %{state | diagnostics: Map.put(state.diagnostics, uri, diagnostics)}
  end

  defp handle_lsp_message(_msg, state), do: state

  defp send_initialize(state) do
    params = %{
      "processId" => System.pid() |> String.to_integer(),
      "rootUri" => "file://#{state.root_path}",
      "capabilities" => %{
        "textDocument" => %{
          "publishDiagnostics" => %{"relatedInformation" => true}
        }
      }
    }

    send_lsp_raw_request(state, "initialize", params, :initialize)
  end

  defp send_initialized(state) do
    case SynapsisPlugin.LSP.Protocol.encode_notification("initialized", %{}) do
      {:ok, data} -> Port.command(state.port, data)
      {:error, _} -> :ok
    end
  end

  defp send_lsp_request(state, method, params) do
    from = state[:_pending_from]
    state = Map.delete(state, :_pending_from)
    send_lsp_raw_request(state, method, params, {method, from})
  end

  defp send_lsp_raw_request(state, method, params, tag) do
    id = state.request_id

    case SynapsisPlugin.LSP.Protocol.encode_request(id, method, params) do
      {:ok, data} ->
        Port.command(state.port, data)

      {:error, reason} ->
        Logger.warning("lsp_encode_failed", method: method, reason: inspect(reason))
    end

    %{state | request_id: id + 1, pending: Map.put(state.pending, id, tag)}
  end

  defp position_params(input, state) do
    uri = "file://#{Path.expand(input["path"], state.root_path)}"

    %{
      "textDocument" => %{"uri" => uri},
      "position" => %{
        "line" => input["line"] || 0,
        "character" => input["character"] || 0
      }
    }
  end

  defp format_lsp_result("textDocument/definition", result) when is_list(result) do
    result
    |> Enum.map(fn loc ->
      file = String.replace_prefix(loc["uri"] || "", "file://", "")
      line = get_in(loc, ["range", "start", "line"]) || 0
      "#{file}:#{line + 1}"
    end)
    |> Enum.join("\n")
  end

  defp format_lsp_result("textDocument/definition", %{"uri" => uri, "range" => range}) do
    file = String.replace_prefix(uri, "file://", "")
    line = get_in(range, ["start", "line"]) || 0
    "#{file}:#{line + 1}"
  end

  defp format_lsp_result("textDocument/references", result) when is_list(result) do
    result
    |> Enum.map(fn loc ->
      file = String.replace_prefix(loc["uri"] || "", "file://", "")
      line = get_in(loc, ["range", "start", "line"]) || 0
      "#{file}:#{line + 1}"
    end)
    |> Enum.join("\n")
  end

  defp format_lsp_result("textDocument/hover", %{"contents" => contents})
       when is_binary(contents) do
    contents
  end

  defp format_lsp_result("textDocument/hover", %{"contents" => %{"value" => value}}) do
    value
  end

  defp format_lsp_result("textDocument/documentSymbol", result) when is_list(result) do
    result
    |> Enum.map(fn sym ->
      name = sym["name"] || "?"
      kind = symbol_kind(sym["kind"])
      line = get_in(sym, ["range", "start", "line"]) || 0
      "#{name} (#{kind}) line #{line + 1}"
    end)
    |> Enum.join("\n")
  end

  defp format_lsp_result(_method, nil), do: "No results."
  defp format_lsp_result(_method, result), do: inspect(result)

  defp severity_label(1), do: "error"
  defp severity_label(2), do: "warning"
  defp severity_label(3), do: "info"
  defp severity_label(4), do: "hint"
  defp severity_label(_), do: "unknown"

  defp symbol_kind(1), do: "file"
  defp symbol_kind(2), do: "module"
  defp symbol_kind(5), do: "class"
  defp symbol_kind(6), do: "method"
  defp symbol_kind(12), do: "function"
  defp symbol_kind(13), do: "variable"
  defp symbol_kind(_), do: "symbol"

  defp lsp_command("elixir"), do: {"elixir-ls", ["--stdio"]}
  defp lsp_command("typescript"), do: {"typescript-language-server", ["--stdio"]}
  defp lsp_command("go"), do: {"gopls", ["serve"]}
  defp lsp_command(_), do: nil
end
