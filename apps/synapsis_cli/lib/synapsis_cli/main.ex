defmodule SynapsisCli.Main do
  @moduledoc "CLI entry point and argument parsing."

  @default_host "http://localhost:4000"

  def main(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        aliases: [p: :prompt, m: :model, h: :host, s: :serve],
        strict: [
          prompt: :string,
          model: :string,
          provider: :string,
          host: :string,
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

      opts[:prompt] ->
        run_oneshot(opts[:prompt], opts)

      rest != [] ->
        run_oneshot(Enum.join(rest, " "), opts)

      true ->
        run_interactive(opts)
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

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp send_message(host, session_id, content) do
    case Req.post("#{host}/api/sessions/#{session_id}/messages", json: %{content: content}) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{body: body}} -> IO.puts(:stderr, "Warning: #{inspect(body)}")
      {:error, reason} -> IO.puts(:stderr, "Error: #{inspect(reason)}")
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
      _ -> :ok
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

  defp print_help do
    IO.puts("""
    Synapsis - AI Coding Agent

    Usage:
      synapsis                     Start interactive session
      synapsis -p "prompt"         One-shot: send prompt, print response, exit
      synapsis "prompt"            Same as -p

    Options:
      -p, --prompt TEXT            Prompt to send (non-interactive mode)
      -m, --model MODEL            Model to use (server config default if omitted)
      --provider PROVIDER          Provider to use: anthropic, openai, google, local
      -h, --host URL               Server URL (default: http://localhost:4000)
      --serve                      Start server (delegates to mix phx.server)
      --help                       Show this help
      --version                    Show version

    Examples:
      synapsis -p "explain this file" --model claude-sonnet-4-20250514
      synapsis --provider openai --model gpt-4o
      synapsis -p "fix the bug" --provider anthropic
    """)
  end
end
