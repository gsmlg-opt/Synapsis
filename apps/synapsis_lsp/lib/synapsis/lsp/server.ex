defmodule Synapsis.LSP.Server do
  @moduledoc "GenServer managing a single LSP server process via Port."
  use GenServer
  require Logger

  alias Synapsis.LSP.Protocol

  defstruct [
    :port,
    :language,
    :root_path,
    :request_id,
    :pending,
    :buffer,
    :initialized,
    :diagnostics
  ]

  def start_link(opts) do
    language = Keyword.fetch!(opts, :language)
    root_path = Keyword.fetch!(opts, :root_path)
    name = {:via, Registry, {Synapsis.LSP.Registry, {language, root_path}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def get_diagnostics(language, root_path) do
    name = {:via, Registry, {Synapsis.LSP.Registry, {language, root_path}}}

    try do
      GenServer.call(name, :get_diagnostics, 5_000)
    catch
      :exit, _ -> {:error, :not_running}
    end
  end

  @impl true
  def init(opts) do
    language = Keyword.fetch!(opts, :language)
    root_path = Keyword.fetch!(opts, :root_path)
    cmd = lsp_command(language)

    case cmd do
      nil ->
        {:stop, {:no_lsp_binary, language}}

      {executable, args} ->
        case System.find_executable(executable) do
          nil ->
            Logger.info("lsp_binary_not_found", language: language, executable: executable)
            {:stop, {:no_lsp_binary, executable}}

          exe_path ->
            port =
              Port.open({:spawn_executable, exe_path}, [
                :binary,
                :exit_status,
                {:args, args},
                {:cd, root_path}
              ])

            state = %__MODULE__{
              port: port,
              language: language,
              root_path: root_path,
              request_id: 1,
              pending: %{},
              buffer: "",
              initialized: false,
              diagnostics: %{}
            }

            send_initialize(state)
            {:ok, state}
        end
    end
  end

  @impl true
  def handle_call(:get_diagnostics, _from, state) do
    {:reply, {:ok, state.diagnostics}, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> data
    state = process_buffer(%{state | buffer: buffer})
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.info("lsp_server_exited", language: state.language, status: status)
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

  defp process_buffer(state) do
    case Protocol.decode_message(state.buffer) do
      {:ok, msg, rest} ->
        state = handle_lsp_message(msg, %{state | buffer: rest})
        process_buffer(state)

      :incomplete ->
        state

      {:error, _} ->
        state
    end
  end

  defp handle_lsp_message(%{"id" => id, "result" => _result}, state) do
    case Map.pop(state.pending, id) do
      {:initialize, pending} ->
        send_initialized(state)
        %{state | pending: pending, initialized: true}

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

    send_request(state, "initialize", params)
  end

  defp send_initialized(state) do
    data = Protocol.encode_notification("initialized", %{})
    Port.command(state.port, data)
  end

  defp send_request(state, method, params) do
    id = state.request_id
    data = Protocol.encode_request(id, method, params)
    Port.command(state.port, data)
    %{state | request_id: id + 1, pending: Map.put(state.pending, id, method)}
  end

  defp lsp_command("elixir"), do: {"elixir-ls", ["--stdio"]}
  defp lsp_command("typescript"), do: {"typescript-language-server", ["--stdio"]}
  defp lsp_command("go"), do: {"gopls", ["serve"]}
  defp lsp_command(_), do: nil
end
