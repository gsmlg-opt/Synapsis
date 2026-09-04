defmodule SynapsisCli.Main do
  @moduledoc "CLI entry point and argument parsing."

  @default_host "http://localhost:4657"

  def main(args) do
    case run(args) do
      {:error, reason} ->
        IO.puts(:stderr, "Error: #{error_message(reason)}")
        System.halt(1)

      _success ->
        :ok
    end
  end

  @doc "Runs a CLI invocation without halting the VM, for embedding and tests."
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        aliases: [p: :prompt, m: :model, h: :host, s: :serve],
        strict: [
          prompt: :string,
          model: :string,
          provider: :string,
          host: :string,
          credential_env: :string,
          trust_mcp_annotations: :boolean,
          client_cert: :string,
          client_key: :string,
          ca_cert: :string,
          serve: :boolean,
          help: :boolean,
          version: :boolean
        ]
      )

    cond do
      opts[:help] || opts[:version] -> dispatch(opts, rest)
      invalid != [] -> {:error, :usage}
      true -> with :ok <- validate_client_credentials(opts), do: dispatch(opts, rest)
    end
  end

  defp dispatch(opts, rest) do
    cond do
      opts[:help] ->
        print_help()

      opts[:version] ->
        IO.puts("Synapsis CLI v0.1.0")

      opts[:serve] ->
        IO.puts("Starting Synapsis server...")
        IO.puts("Run `mix phx.server` from the project root instead.")

      match?([namespace | _] when namespace in ~w(agent heartbeat dream schedule backplane), rest) ->
        run_daemon_command(rest, opts[:host] || @default_host, opts)

      match?(["code" | _], rest) ->
        prompt = rest |> Enum.drop(1) |> Enum.join(" ")

        if prompt == "" do
          {:error, {:usage, "synapsis code <prompt>"}}
        else
          run_oneshot(prompt, Keyword.put(opts, :mode, "code"))
        end

      opts[:prompt] ->
        run_oneshot(opts[:prompt], opts)

      rest != [] ->
        run_oneshot(Enum.join(rest, " "), opts)

      true ->
        run_interactive(opts)
    end
  end

  defp run_daemon_command(["agent", "status"], host, opts),
    do: api_get(host, "/api/agent/daemon/status", opts)

  defp run_daemon_command(["agent", "runs"], host, opts),
    do: api_get(host, "/api/agent/runs", opts)

  defp run_daemon_command(["agent", "run"], _host, _opts),
    do: {:error, {:usage, "synapsis agent run <prompt>"}}

  defp run_daemon_command(["agent", "run" | prompt], host, opts) do
    case prompt |> Enum.join(" ") |> String.trim() do
      "" -> {:error, {:usage, "synapsis agent run <prompt>"}}
      text -> api_post(host, "/api/agent/runs", %{prompt: text}, opts)
    end
  end

  defp run_daemon_command(["agent", "cancel", id], host, opts),
    do: api_post(host, "/api/agent/runs/#{id}/cancel", %{}, opts)

  defp run_daemon_command(["heartbeat", "run"], host, opts),
    do: api_post(host, "/api/agent/heartbeat/trigger", %{}, opts)

  defp run_daemon_command(["heartbeat", "run", name], host, opts),
    do: api_post(host, "/api/agent/heartbeat/trigger", %{name: name}, opts)

  defp run_daemon_command(["dream", "run"], host, opts),
    do: api_post(host, "/api/agent/dream/trigger", %{}, opts)

  defp run_daemon_command(["schedule", "list"], host, opts),
    do: api_get(host, "/api/agent/routines?kind=schedule", opts)

  defp run_daemon_command(["schedule", "run", name], host, opts) do
    with {:ok, id} <- resolve_name(host, "/api/agent/routines?kind=schedule", name, opts) do
      api_post(host, "/api/agent/routines/#{id}/trigger", %{}, opts)
    end
  end

  defp run_daemon_command(["backplane", "list"], host, opts),
    do: api_get(host, "/api/backplane/connections", opts)

  defp run_daemon_command(["backplane", "add", name, endpoint], host, opts) do
    with :ok <- allow_credential_transport(host, opts[:credential_env]),
         :ok <- allow_credential_transport(endpoint, opts[:credential_env]),
         {:ok, credential} <- credential_from_env(opts[:credential_env]) do
      body = %{name: name, endpoint: endpoint} |> put_if_present(:credential, credential)

      body =
        if opts[:trust_mcp_annotations] do
          Map.put(body, :connection_options, %{"trust_mcp_annotations" => true})
        else
          body
        end

      api_post(host, "/api/backplane/connections", body, opts)
    end
  end

  defp run_daemon_command(["backplane", "test", name], host, opts) do
    with {:ok, id} <- resolve_name(host, "/api/backplane/connections", name, opts) do
      api_post(host, "/api/backplane/connections/#{id}/test", %{}, opts)
    end
  end

  defp run_daemon_command(["backplane", "sync", name], host, opts) do
    with {:ok, id} <- resolve_name(host, "/api/backplane/connections", name, opts) do
      api_post(host, "/api/backplane/connections/#{id}/refresh", %{}, opts)
    end
  end

  defp run_daemon_command(_, _host, _opts), do: {:error, :usage}

  defp api_get(host, path, opts) do
    with {:ok, status, body} <- api_request(:get, host, path, nil, opts) do
      print_api_response(status, body)
    end
  end

  defp api_post(host, path, body, opts) do
    with {:ok, status, response} <- api_request(:post, host, path, body, opts) do
      print_api_response(status, response)
    end
  end

  defp api_request(:get, host, path, _body, opts),
    do: normalize_api_response(Req.get("#{host}#{path}", request_options(opts, 30_000)))

  defp api_request(:post, host, path, body, opts),
    do:
      normalize_api_response(
        Req.post("#{host}#{path}", [json: body] ++ request_options(opts, 30_000))
      )

  defp normalize_api_response({:ok, %{status: status, body: body}}) when status in 200..299,
    do: {:ok, status, body}

  defp normalize_api_response({:ok, %{status: status}}), do: {:error, {:http_error, status}}
  defp normalize_api_response({:error, _reason}), do: {:error, :connection_failed}

  defp print_api_response(status, body) do
    IO.puts(Jason.encode!(%{status: status, data: body}))
    :ok
  end

  defp resolve_name(host, path, name, opts) do
    with {:ok, _status, body} <- api_request(:get, host, path, nil, opts),
         {:ok, entries} <- response_entries(body) do
      case Enum.filter(entries, &(entry_value(&1, "name") == name)) do
        [entry] -> entry_id(entry)
        [] -> {:error, {:name_not_found, name}}
        [_first, _second | _rest] -> {:error, {:ambiguous_name, name}}
      end
    end
  end

  defp response_entries(%{"data" => entries}) when is_list(entries), do: {:ok, entries}
  defp response_entries(%{data: entries}) when is_list(entries), do: {:ok, entries}
  defp response_entries(_body), do: {:error, :invalid_response}

  defp entry_id(entry) do
    case entry_value(entry, "id") do
      id when is_binary(id) and id != "" -> {:ok, id}
      _invalid -> {:error, :invalid_response}
    end
  end

  defp entry_value(entry, key),
    do: Map.get(entry, key, Map.get(entry, String.to_existing_atom(key)))

  defp credential_from_env(nil), do: {:ok, nil}

  defp credential_from_env(name) when is_binary(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, {:missing_credential_env, name}}
    end
  end

  defp validate_client_credentials(opts) do
    case {opts[:client_cert], opts[:client_key]} do
      {nil, nil} -> :ok
      {cert, key} when is_binary(cert) and is_binary(key) -> :ok
      _incomplete_pair -> {:error, :mtls_pair_required}
    end
  end

  defp allow_credential_transport(_host, nil), do: :ok

  defp allow_credential_transport(host, _credential_env) do
    case URI.parse(host) do
      %URI{scheme: scheme, host: hostname} when is_binary(scheme) and is_binary(hostname) ->
        case {String.downcase(scheme), loopback_host?(hostname)} do
          {"https", _loopback?} -> :ok
          {"http", true} -> :ok
          _insecure_or_unsupported -> {:error, :plaintext_credential_forbidden}
        end

      _invalid ->
        {:error, :plaintext_credential_forbidden}
    end
  end

  defp loopback_host?(hostname) do
    String.downcase(hostname) == "localhost" or
      case :inet.parse_address(String.to_charlist(hostname)) do
        {:ok, {127, _b, _c, _d}} -> true
        {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
        _other -> false
      end
  end

  @doc false
  def request_options(opts, timeout) do
    base = [receive_timeout: timeout, request_timeout: timeout, retry: false]

    transport_options =
      []
      |> put_keyword_if_present(:certfile, opts[:client_cert])
      |> put_keyword_if_present(:keyfile, opts[:client_key])
      |> put_keyword_if_present(:cacertfile, opts[:ca_cert])

    if transport_options == [] do
      base
    else
      base ++ [connect_options: [transport_opts: transport_options]]
    end
  end

  defp run_oneshot(prompt, opts) do
    host = opts[:host] || @default_host

    with {:ok, session_id} <- create_session(host, opts),
         {:ok, stream} <- open_sse(host, session_id, opts) do
      case send_message(host, session_id, prompt, opts) do
        :ok -> consume_sse(stream)
        {:error, _reason} = error -> cancel_sse(stream, error)
      end
    end
  end

  defp run_interactive(opts) do
    host = opts[:host] || @default_host

    with {:ok, session_id} <- create_session(host, opts) do
      IO.puts("Synapsis session started. Type your message (Ctrl+D to exit).")
      IO.puts("")
      interactive_loop(host, session_id, opts)
    end
  end

  defp interactive_loop(host, session_id, opts) do
    case IO.gets("> ") do
      :eof ->
        IO.puts("\nGoodbye.")
        :ok

      {:error, _} ->
        IO.puts("\nGoodbye.")
        :ok

      input ->
        prompt = String.trim(input)

        case submit_and_stream(host, session_id, prompt, opts) do
          :ok -> interactive_loop(host, session_id, opts)
          {:error, _reason} = error -> error
        end
    end
  end

  defp submit_and_stream(_host, _session_id, "", _opts), do: :ok

  defp submit_and_stream(host, session_id, prompt, opts) do
    with {:ok, stream} <- open_sse(host, session_id, opts) do
      case send_message(host, session_id, prompt, opts) do
        :ok -> consume_sse(stream)
        {:error, _reason} = error -> cancel_sse(stream, error)
      end
    end
  end

  defp create_session(host, opts) do
    body =
      %{project_path: File.cwd!()}
      |> put_if_present(:provider, opts[:provider])
      |> put_if_present(:model, opts[:model])

    # When neither provider nor model is specified, let the server choose
    # based on its config (sends body without provider/model keys)

    case Req.post("#{host}/api/sessions", [json: body] ++ request_options(opts, 30_000)) do
      {:ok, %{status: 201, body: %{"data" => %{"id" => id}}}} ->
        {:ok, id}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, _reason} ->
        {:error, :connection_failed}
    end
  end

  defp send_message(host, session_id, content, opts) do
    request_opts = [json: %{content: content}] ++ request_options(opts, 30_000)

    case Req.post("#{host}/api/sessions/#{session_id}/messages", request_opts) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, _reason} -> {:error, :connection_failed}
    end
  end

  defp open_sse(host, session_id, opts) do
    url = "#{host}/api/sessions/#{session_id}/events"
    owner = self()
    request_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result = stream_sse_request(url, opts, owner, request_ref)
        send(owner, {request_ref, :complete, result})
      end)

    receive do
      {^request_ref, :ready} ->
        {:ok, %{pid: pid, monitor_ref: monitor_ref, request_ref: request_ref}}

      {^request_ref, :complete, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        {:error, :connection_failed}
    after
      300_000 ->
        Process.exit(pid, :shutdown)
        Process.demonitor(monitor_ref, [:flush])
        {:error, :connection_failed}
    end
  end

  defp stream_sse_request(url, opts, owner, request_ref) do
    initial_state = %{buffer: <<>>, ready?: false, terminal: nil}

    into = fn {:data, data}, {request, response} ->
      state = Req.Response.get_private(response, :synapsis_cli_sse, initial_state)

      {directive, state} =
        case response_error(response) do
          nil -> process_sse_chunk(data, state, owner, request_ref)
          error -> {:halt, %{state | terminal: error}}
        end

      response = Req.Response.put_private(response, :synapsis_cli_sse, state)
      {directive, {request, response}}
    end

    request_opts =
      [headers: [{"accept", "text/event-stream"}], into: into] ++
        request_options(opts, 300_000)

    case Req.get(url, request_opts) do
      {:ok, response} -> stream_result(response, initial_state)
      {:error, _reason} -> {:error, :connection_failed}
    end
  end

  defp process_sse_chunk(data, state, owner, request_ref) do
    buffer = state.buffer <> data
    ready? = state.ready? or next_sse_frame(buffer) != :more

    if ready? and not state.ready?, do: send(owner, {request_ref, :ready})

    case consume_sse_chunk(buffer) do
      {:continue, buffer} -> {:cont, %{state | buffer: buffer, ready?: ready?}}
      {:halt, result} -> {:halt, %{state | buffer: <<>>, ready?: ready?, terminal: result}}
    end
  end

  defp stream_result(response, initial_state) do
    state = Req.Response.get_private(response, :synapsis_cli_sse, initial_state)

    case state.terminal || response_error(response) do
      nil -> {:error, :sse_closed_before_terminal}
      result -> result
    end
  end

  defp response_error(%{status: status}) when status not in 200..299,
    do: {:error, {:http_error, status}}

  defp response_error(response) do
    if event_stream_response?(response), do: nil, else: {:error, :invalid_sse_response}
  end

  defp event_stream_response?(response) do
    response
    |> Req.Response.get_header("content-type")
    |> Enum.any?(&String.starts_with?(String.downcase(&1), "text/event-stream"))
  end

  defp cancel_sse(stream, result) do
    Process.exit(stream.pid, :shutdown)

    receive do
      {:DOWN, monitor_ref, :process, pid, _reason}
      when monitor_ref == stream.monitor_ref and pid == stream.pid ->
        :ok
    after
      1_000 -> Process.demonitor(stream.monitor_ref, [:flush])
    end

    result
  end

  defp consume_sse(stream) do
    receive do
      {request_ref, :complete, result} when request_ref == stream.request_ref ->
        Process.demonitor(stream.monitor_ref, [:flush])
        result

      {:DOWN, monitor_ref, :process, pid, _reason}
      when monitor_ref == stream.monitor_ref and pid == stream.pid ->
        {:error, :connection_failed}
    after
      300_000 -> cancel_sse(stream, {:error, :connection_failed})
    end
  end

  defp consume_sse_chunk(buffer) do
    case next_sse_frame(buffer) do
      :more ->
        {:continue, buffer}

      {:ok, frame, rest} ->
        case process_sse_event(parse_sse_event(frame)) do
          :continue -> consume_sse_chunk(rest)
          {:halt, result} -> {:halt, result}
        end
    end
  end

  defp next_sse_frame(buffer) do
    delimiters = ["\r\n\r\n", "\n\n"]

    case :binary.match(buffer, delimiters) do
      :nomatch ->
        :more

      {index, length} ->
        <<frame::binary-size(index), _delimiter::binary-size(length), rest::binary>> = buffer
        {:ok, frame, rest}
    end
  end

  defp parse_sse_event(block) do
    lines = block |> :binary.replace("\r\n", "\n", [:global]) |> :binary.split("\n", [:global])

    event =
      Enum.find_value(lines, fn
        "event:" <> event -> trim_optional_space(event)
        _ -> nil
      end)

    data =
      lines
      |> Enum.flat_map(fn
        "data:" <> data -> [trim_optional_space(data)]
        _ -> []
      end)
      |> Enum.join("\n")

    {event, data}
  end

  defp trim_optional_space(<<" ", rest::binary>>), do: rest
  defp trim_optional_space(value), do: value

  defp process_sse_event({"text_delta", payload}) do
    case Jason.decode(payload) do
      {:ok, %{"text" => text}} when is_binary(text) -> IO.write(text)
      _invalid -> :ok
    end

    :continue
  end

  defp process_sse_event({"reasoning", payload}) do
    case Jason.decode(payload) do
      {:ok, %{"text" => text}} when is_binary(text) ->
        IO.write(IO.ANSI.light_black() <> text <> IO.ANSI.reset())

      _invalid ->
        :ok
    end

    :continue
  end

  defp process_sse_event({"tool_use", payload}) do
    case Jason.decode(payload) do
      {:ok, %{"tool" => tool}} when is_binary(tool) ->
        IO.puts("\n#{IO.ANSI.cyan()}[tool: #{tool}]#{IO.ANSI.reset()}")

      _invalid ->
        :ok
    end

    :continue
  end

  defp process_sse_event({"tool_result", payload}) do
    case Jason.decode(payload) do
      {:ok, %{"content" => content, "is_error" => is_error}} when is_binary(content) ->
        color = if is_error, do: IO.ANSI.red(), else: IO.ANSI.green()
        IO.puts("#{color}#{String.slice(content, 0, 500)}#{IO.ANSI.reset()}")

      _invalid ->
        :ok
    end

    :continue
  end

  defp process_sse_event({"error", payload}) do
    case Jason.decode(payload) do
      {:ok, %{"message" => message}} when is_binary(message) ->
        IO.puts(:stderr, "\n#{IO.ANSI.red()}Error: #{message}#{IO.ANSI.reset()}")
        {:halt, {:error, {:sse_error, message}}}

      _invalid ->
        {:halt, {:error, :invalid_sse_response}}
    end
  end

  defp process_sse_event({"done", _payload}) do
    IO.puts("")
    {:halt, :ok}
  end

  defp process_sse_event({"session_status", payload}) do
    case Jason.decode(payload) do
      {:ok, %{"status" => "idle"}} -> {:halt, :ok}
      _other -> :continue
    end
  end

  defp process_sse_event(_event), do: :continue

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
  defp put_keyword_if_present(keyword, _key, nil), do: keyword
  defp put_keyword_if_present(keyword, key, value), do: keyword ++ [{key, value}]

  defp error_message({:http_error, status}), do: "HTTP #{status}"
  defp error_message({:sse_error, message}), do: message
  defp error_message({:usage, usage}), do: "Usage: #{usage}"
  defp error_message(:usage), do: "invalid command; run synapsis --help"
  defp error_message(:connection_failed), do: "connection failed"
  defp error_message(:invalid_sse_response), do: "invalid event stream response"
  defp error_message(:sse_closed_before_terminal), do: "event stream closed before completion"

  defp error_message(:mtls_pair_required),
    do: "--client-cert and --client-key must be used together"

  defp error_message(:plaintext_credential_forbidden),
    do: "refusing to send a Backplane credential over non-loopback plaintext HTTP"

  defp error_message(reason), do: inspect(reason)

  defp print_help do
    IO.puts("""
    Synapsis - AI Coding Agent

    Usage:
      synapsis                     Start interactive session
      synapsis -p "prompt"         One-shot: send prompt, print response, exit
      synapsis "prompt"            Same as -p

    Daemon commands:
      synapsis agent status
      synapsis agent run <prompt>
      synapsis agent runs
      synapsis agent cancel <run-id>
      synapsis heartbeat run [name]
      synapsis dream run
      synapsis schedule list
      synapsis schedule run <name>
      synapsis backplane list
      synapsis backplane add <name> <endpoint> [--credential-env VAR] [--trust-mcp-annotations]
      synapsis backplane test <name>
      synapsis backplane sync <name>

    Options:
      -p, --prompt TEXT            Prompt to send (non-interactive mode)
      -m, --model MODEL            Model to use (server config default if omitted)
      --provider PROVIDER          Provider to use: anthropic, openai, google, local
      -h, --host URL               Server URL (default: http://localhost:4657)
      --credential-env VAR         Read a Backplane credential from VAR
      --trust-mcp-annotations      Trust read-only hints for autonomous MCP use
      --client-cert PATH           Client certificate for mTLS
      --client-key PATH            Client private key for mTLS (required with certificate)
      --ca-cert PATH               Custom server CA certificate
      --serve                      Start server (delegates to mix phx.server)
      --help                       Show this help
      --version                    Show version

    Examples:
      synapsis -p "explain this file" --model claude-sonnet-4-6
      synapsis --provider openai --model gpt-4.1
      synapsis -p "fix the bug" --provider anthropic
    """)
  end
end
