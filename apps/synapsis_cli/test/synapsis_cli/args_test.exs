defmodule SynapsisCli.ArgsTest do
  @moduledoc "Tests for CLI argument parsing, aliases, command routing, and error handling."
  use ExUnit.Case

  import ExUnit.CaptureIO

  # ── Short aliases ──────────────────────────────────────────────────

  describe "short aliases" do
    test "-p alias routes to oneshot mode" do
      # Use Bypass to provide a server so we can verify -p triggers oneshot.
      bypass = Bypass.open()
      host = "http://localhost:#{bypass.port}"
      session_id = "alias-p-#{System.unique_integer([:positive])}"

      Bypass.expect_once(bypass, "POST", "/api/sessions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(%{"data" => %{"id" => session_id}}))
      end)

      Bypass.expect_once(bypass, "POST", "/api/sessions/#{session_id}/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        # Verify -p value was captured as the prompt
        assert decoded["content"] == "hello"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true}))
      end)

      Bypass.expect_once(bypass, "GET", "/api/sessions/#{session_id}/events", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, "event: done\ndata: \n\n")
      end)

      output =
        capture_io(fn ->
          SynapsisCli.Main.main(["-p", "hello", "--host", host])
        end)

      # Proves -p routed to oneshot mode (got a response from the server)
      assert is_binary(output)
    end

    test "-m alias is accepted without crash" do
      # -m requires a value; OptionParser strict mode consumes it.
      # Combined with --help so we don't hit the network.
      output =
        capture_io(fn ->
          SynapsisCli.Main.main(["-m", "gpt-4o", "--help"])
        end)

      assert output =~ "Synapsis - AI Coding Agent"
    end

    test "-h alias for --host is accepted without crash" do
      # -h sets host; combined with --help to avoid network
      output =
        capture_io(fn ->
          SynapsisCli.Main.main(["-h", "http://example.com", "--help"])
        end)

      assert output =~ "Synapsis - AI Coding Agent"
    end

    test "-s alias for --serve prints server message" do
      output =
        capture_io(fn ->
          SynapsisCli.Main.main(["-s"])
        end)

      assert output =~ "Starting Synapsis server..."
    end
  end

  # ── Command routing priority ───────────────────────────────────────

  describe "command routing priority" do
    test "--help takes precedence over --version" do
      output =
        capture_io(fn ->
          SynapsisCli.Main.main(["--help", "--version"])
        end)

      assert output =~ "Synapsis - AI Coding Agent"
      refute output =~ "Synapsis CLI v0.1.0"
    end

    test "--help takes precedence over --serve" do
      output =
        capture_io(fn ->
          SynapsisCli.Main.main(["--help", "--serve"])
        end)

      assert output =~ "Usage:"
      refute output =~ "Starting Synapsis server..."
    end

    test "--help takes precedence over --prompt" do
      output =
        capture_io(fn ->
          SynapsisCli.Main.main(["--help", "--prompt", "test"])
        end)

      assert output =~ "Synapsis - AI Coding Agent"
    end

    test "--version takes precedence over --serve" do
      output =
        capture_io(fn ->
          SynapsisCli.Main.main(["--version", "--serve"])
        end)

      assert output =~ "Synapsis CLI v0.1.0"
      refute output =~ "Starting Synapsis server..."
    end

    test "--version takes precedence over --prompt" do
      output =
        capture_io(fn ->
          SynapsisCli.Main.main(["--version", "--prompt", "hello"])
        end)

      assert output =~ "Synapsis CLI v0.1.0"
    end

    test "--serve takes precedence over --prompt" do
      output =
        capture_io(fn ->
          SynapsisCli.Main.main(["--serve", "--prompt", "hello"])
        end)

      assert output =~ "Starting Synapsis server..."
    end

    test "bare positional args route to oneshot mode" do
      # Use Bypass so we don't hit System.halt(1) on connection failure
      bypass = Bypass.open()
      host = "http://localhost:#{bypass.port}"
      session_id = "positional-#{System.unique_integer([:positive])}"

      Bypass.expect_once(bypass, "POST", "/api/sessions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(%{"data" => %{"id" => session_id}}))
      end)

      Bypass.expect_once(bypass, "POST", "/api/sessions/#{session_id}/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        # Positional args should be joined with spaces
        assert decoded["content"] == "explain this file"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true}))
      end)

      Bypass.expect_once(bypass, "GET", "/api/sessions/#{session_id}/events", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, "event: done\ndata: \n\n")
      end)

      output =
        capture_io(fn ->
          SynapsisCli.Main.main(["explain", "this", "file", "--host", host])
        end)

      assert is_binary(output)
    end
  end

  # ── Flag combinations ──────────────────────────────────────────────

  describe "flag combinations" do
    test "--model with --help still shows help (help wins)" do
      output =
        capture_io(fn ->
          SynapsisCli.Main.main(["--model", "claude-sonnet-4-20250514", "--help"])
        end)

      assert output =~ "Synapsis - AI Coding Agent"
    end

    test "--provider with --help still shows help" do
      output =
        capture_io(fn ->
          SynapsisCli.Main.main(["--provider", "anthropic", "--help"])
        end)

      assert output =~ "Synapsis - AI Coding Agent"
    end

    test "--host with --version still shows version" do
      output =
        capture_io(fn ->
          SynapsisCli.Main.main(["--host", "http://custom:9999", "--version"])
        end)

      assert output =~ "Synapsis CLI v0.1.0"
    end
  end

  # ── Invalid / unknown flags ────────────────────────────────────────

  describe "unknown and invalid flags" do
    test "unknown flag is ignored by strict parser (rest args)" do
      # OptionParser.parse with strict: discards unknown flags into the
      # third element (invalid). The rest list stays empty unless there
      # are positional args. Combined with --help to stay safe.
      output =
        capture_io(fn ->
          SynapsisCli.Main.main(["--unknown-flag", "--help"])
        end)

      # --help still fires because the unknown flag goes to invalid list
      assert output =~ "Synapsis - AI Coding Agent"
    end

    test "flag requiring value given without value falls to invalid" do
      # --prompt expects a string; when it's the last arg with no value,
      # OptionParser strict mode puts it in the invalid list. Combined
      # with --version so the version branch fires and we avoid network.
      output =
        capture_io(fn ->
          SynapsisCli.Main.main(["--version", "--prompt"])
        end)

      # --version fires first (higher priority), so no crash from missing value
      assert output =~ "Synapsis CLI v0.1.0"
    end

    test "--model without value does not crash" do
      # Similar to above: --model with no value goes to invalid
      output =
        capture_io(fn ->
          SynapsisCli.Main.main(["--model", "--help"])
        end)

      # --model consumes "--help" as its value, so help may not fire.
      # The key assertion is no crash.
      assert is_binary(output)
    end
  end

  # ── Help content completeness ──────────────────────────────────────

  describe "help content" do
    setup do
      output =
        capture_io(fn ->
          SynapsisCli.Main.main(["--help"])
        end)

      %{output: output}
    end

    test "lists all flag options", %{output: output} do
      assert output =~ "-p, --prompt"
      assert output =~ "-m, --model"
      assert output =~ "-h, --host"
      assert output =~ "--provider"
      assert output =~ "--serve"
      assert output =~ "--help"
      assert output =~ "--version"
    end

    test "includes usage section", %{output: output} do
      assert output =~ "Usage:"
    end

    test "includes options section", %{output: output} do
      assert output =~ "Options:"
    end

    test "includes examples section", %{output: output} do
      assert output =~ "Examples:"
    end

    test "examples reference known providers", %{output: output} do
      assert output =~ "anthropic"
      assert output =~ "openai"
    end

    test "examples reference known models", %{output: output} do
      assert output =~ "claude-sonnet-4-6"
      assert output =~ "gpt-4.1"
    end
  end

  # ── Version output ─────────────────────────────────────────────────

  describe "version output" do
    test "matches semver pattern" do
      output =
        capture_io(fn ->
          SynapsisCli.Main.main(["--version"])
        end)

      assert output =~ ~r/v\d+\.\d+\.\d+/
    end

    test "contains exactly one line" do
      output =
        capture_io(fn ->
          SynapsisCli.Main.main(["--version"])
        end)

      lines = output |> String.trim() |> String.split("\n")
      assert length(lines) == 1
    end

    test "starts with 'Synapsis CLI'" do
      output =
        capture_io(fn ->
          SynapsisCli.Main.main(["--version"])
        end)

      assert String.starts_with?(String.trim(output), "Synapsis CLI")
    end
  end

  # ── Serve mode ─────────────────────────────────────────────────────

  describe "serve mode" do
    test "prints startup message" do
      output =
        capture_io(fn ->
          SynapsisCli.Main.main(["--serve"])
        end)

      assert output =~ "Starting Synapsis server..."
    end

    test "suggests mix phx.server" do
      output =
        capture_io(fn ->
          SynapsisCli.Main.main(["--serve"])
        end)

      assert output =~ "mix phx.server"
    end

    test "prints exactly two lines" do
      output =
        capture_io(fn ->
          SynapsisCli.Main.main(["--serve"])
        end)

      lines = output |> String.trim() |> String.split("\n")
      assert length(lines) == 2
    end
  end
end
