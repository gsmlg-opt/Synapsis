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
    {opts, rest, _} =
      OptionParser.parse(args,
        aliases: [p: :prompt, m: :model, h: :host, s: :serve],
        strict: [
          prompt: :string,
          model: :string,
          provider: :string,
          host: :string,
          credential_env: :string,
          serve: :boolean,
          help: :boolean,
          version: :boolean
        ]
      )

    cond do
      opts[:help] ->
        print_help()

      opts[:version] ->
        IO.puts("Synapsis CLI v0.1.0")

      opts[:serve] ->
        IO.puts("Starting Synapsis server...")
        IO.puts("Run `mix phx.server` from the project root instead.")

      match?(["agent", _ | _], rest) or match?(["heartbeat", _ | _], rest) or
        match?(["dream", _ | _], rest) or match?(["schedule", _ | _], rest) or
          match?(["backplane", _ | _], rest) ->
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

  defp run_daemon_command(["agent", "status"], host, _opts),
    do: api_get(host, "/api/agent/daemon/status")

  defp run_daemon_command(["agent", "runs"], host, _opts), do: api_get(host, "/api/agent/runs")

  defp run_daemon_command(["agent", "run"], _host, _opts),
    do: {:error, {:usage, "synapsis agent run <prompt>"}}

  defp run_daemon_command(["agent", "run" | prompt], host, _opts) do
    case prompt |> Enum.join(" ") |> String.trim() do
      "" -> {:error, {:usage, "synapsis agent run <prompt>"}}
      text -> api_post(host, "/api/agent/runs", %{prompt: text})
    end
  end

  defp run_daemon_command(["agent", "cancel", id], host, _opts),
    do: api_post(host, "/api/agent/runs/#{id}/cancel", %{})

  defp run_daemon_command(["heartbeat", "run"], host, _opts),
    do: api_post(host, "/api/agent/heartbeat/trigger", %{})

  defp run_daemon_command(["heartbeat", "run", name], host, _opts),
    do: api_post(host, "/api/agent/heartbeat/trigger", %{name: name})

  defp run_daemon_command(["dream", "run"], host, _opts),
    do: api_post(host, "/api/agent/dream/trigger", %{})

  defp run_daemon_command(["schedule", "list"], host, _opts),
    do: api_get(host, "/api/agent/routines?kind=schedule")

  defp run_daemon_command(["schedule", "run", name], host, _opts) do
    with {:ok, id} <- resolve_name(host, "/api/agent/routines?kind=schedule", name) do
      api_post(host, "/api/agent/routines/#{id}/trigger", %{})
    end
  end

  defp run_daemon_command(["backplane", "list"], host, _opts),
    do: api_get(host, "/api/backplane/connections")

  defp run_daemon_command(["backplane", "add", name, endpoint], host, opts) do
    with {:ok, credential} <- credential_from_env(opts[:credential_env]) do
      body = %{name: name, endpoint: endpoint} |> put_if_present(:credential, credential)
      api_post(host, "/api/backplane/connections", body)
    end
  end

  defp run_daemon_command(["backplane", "test", name], host, _opts) do
    with {:ok, id} <- resolve_name(host, "/api/backplane/connections", name) do
      api_post(host, "/api/backplane/connections/#{id}/test", %{})
    end
  end

  defp run_daemon_command(["backplane", "sync", name], host, _opts) do
    with {:ok, id} <- resolve_name(host, "/api/backplane/connections", name) do
      api_post(host, "/api/backplane/connections/#{id}/refresh", %{})
    end
  end

  defp run_daemon_command(_, _host, _opts), do: {:error, :usage}

  defp api_get(host, path) do
    with {:ok, status, body} <- api_request(:get, host, path, nil) do
      print_api_response(status, body)
    end
  end

  defp api_post(host, path, body) do
    with {:ok, status, response} <- api_request(:post, host, path, body) do
      print_api_response(status, response)
    end
  end

  defp api_request(:get, host, path, _body),
    do: normalize_api_response(Req.get("#{host}#{path}", receive_timeout: 30_000, retry: false))

  defp api_request(:post, host, path, body),
    do:
      normalize_api_response(
        Req.post("#{host}#{path}", json: body, receive_timeout: 30_000, retry: false)
      )

  defp normalize_api_response({:ok, %{status: status, body: body}}) when status in 200..299,
    do: {:ok, status, body}

  defp normalize_api_response({:ok, %{status: status}}), do: {:error, {:http_error, status}}
  defp normalize_api_response({:error, _reason}), do: {:error, :connection_failed}

  defp print_api_response(status, body) do
    IO.puts(Jason.encode!(%{status: status, data: body}))
    :ok
  end

  defp resolve_name(host, path, name) do
    with {:ok, _status, body} <- api_request(:get, host, path, nil),
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

  defp run_oneshot(prompt, opts) do
    host = opts[:host] || @default_host

    # Create session
    case create_session(host, opts) do
      {:ok, session_id} ->
        # Send message and stream response via SSE
        send_message(host, session_id, prompt)
        stream_sse(host, session_id)

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{reason}")
        System.halt(1)
    end
  end

  defp run_interactive(opts) do
    host = opts[:host] || @default_host

    case create_session(host, opts) do
      {:ok, session_id} ->
        IO.puts("Synapsis session started. Type your message (Ctrl+D to exit).")
        IO.puts("")
        interactive_loop(host, session_id)

      {:error, reason} ->
        IO.puts(:stderr, "Error connecting to server: #{reason}")
        IO.puts(:stderr, "Make sure the server is running: mix phx.server")
        System.halt(1)
    end
  end

  defp interactive_loop(host, session_id) do
    case IO.gets("> ") do
      :eof ->
        IO.puts("\nGoodbye.")

      {:error, _} ->
        IO.puts("\nGoodbye.")

      input ->
        prompt = String.trim(input)

        if prompt != "" do
          send_message(host, session_id, prompt)
          stream_sse(host, session_id)
          IO.puts("")
        end

        interactive_loop(host, session_id)
    end
  end

  defp create_session(host, opts) do
    body =
      %{project_path: File.cwd!()}
      |> put_if_present(:provider, opts[:provider])
      |> put_if_present(:model, opts[:model])

    # When neither provider nor model is specified, let the server choose
    # based on its config (sends body without provider/model keys)

    case Req.post("#{host}/api/sessions", json: body) do
      {:ok, %{status: 201, body: %{"data" => %{"id" => id}}}} ->
        {:ok, id}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, _reason} ->
        {:error, "connection failed"}
    end
  end

  defp send_message(host, session_id, content) do
    case Req.post("#{host}/api/sessions/#{session_id}/messages", json: %{content: content}) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{body: _body}} -> IO.puts(:stderr, "Warning: unexpected response")
      {:error, _reason} -> IO.puts(:stderr, "Error: message send failed")
    end
  end

  defp stream_sse(host, session_id) do
    url = "#{host}/api/sessions/#{session_id}/events"

    try do
      Req.get!(url,
        headers: [{"accept", "text/event-stream"}],
        receive_timeout: 300_000,
        into: fn {:data, data}, acc ->
          process_sse_data(data)
          {:cont, acc}
        end
      )
    rescue
      _e in [Req.TransportError, RuntimeError, Jason.DecodeError] -> :ok
    end
  end

  defp process_sse_data(data) do
    data
    |> String.split("\n\n", trim: true)
    |> Enum.each(fn block ->
      case parse_sse_event(block) do
        {"text_delta", payload} ->
          case Jason.decode(payload) do
            {:ok, %{"text" => text}} -> IO.write(text)
            _ -> :ok
          end

        {"reasoning", payload} ->
          case Jason.decode(payload) do
            {:ok, %{"text" => text}} -> IO.write(IO.ANSI.light_black() <> text <> IO.ANSI.reset())
            _ -> :ok
          end

        {"tool_use", payload} ->
          case Jason.decode(payload) do
            {:ok, %{"tool" => tool}} ->
              IO.puts("\n#{IO.ANSI.cyan()}[tool: #{tool}]#{IO.ANSI.reset()}")

            _ ->
              :ok
          end

        {"tool_result", payload} ->
          case Jason.decode(payload) do
            {:ok, %{"content" => content, "is_error" => is_error}} ->
              color = if is_error, do: IO.ANSI.red(), else: IO.ANSI.green()
              IO.puts("#{color}#{String.slice(content, 0, 500)}#{IO.ANSI.reset()}")

            _ ->
              :ok
          end

        {"error", payload} ->
          case Jason.decode(payload) do
            {:ok, %{"message" => msg}} ->
              IO.puts(:stderr, "\n#{IO.ANSI.red()}Error: #{msg}#{IO.ANSI.reset()}")

            _ ->
              :ok
          end

        {"done", _} ->
          IO.puts("")

        {"session_status", payload} ->
          case Jason.decode(payload) do
            {:ok, %{"status" => "idle"}} -> :done
            _ -> :ok
          end

        _ ->
          :ok
      end
    end)
  end

  defp parse_sse_event(block) do
    lines = String.split(block, "\n", trim: true)

    event =
      Enum.find_value(lines, fn
        "event: " <> event -> event
        _ -> nil
      end)

    data =
      Enum.find_value(lines, fn
        "data: " <> data -> data
        _ -> nil
      end)

    {event, data || ""}
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp error_message({:http_error, status}), do: "HTTP #{status}"
  defp error_message({:usage, usage}), do: "Usage: #{usage}"
  defp error_message(:usage), do: "invalid command; run synapsis --help"
  defp error_message(:connection_failed), do: "connection failed"
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
      synapsis backplane add <name> <endpoint> [--credential-env VAR]
      synapsis backplane test <name>
      synapsis backplane sync <name>

    Options:
      -p, --prompt TEXT            Prompt to send (non-interactive mode)
      -m, --model MODEL            Model to use (server config default if omitted)
      --provider PROVIDER          Provider to use: anthropic, openai, google, local
      -h, --host URL               Server URL (default: http://localhost:4657)
      --credential-env VAR         Read a Backplane credential from VAR
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
