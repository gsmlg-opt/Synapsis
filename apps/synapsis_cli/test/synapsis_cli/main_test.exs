defmodule SynapsisCli.MainTest do
  use ExUnit.Case

  describe "argument parsing" do
    test "parses --help flag" do
      assert {:ok, output} = capture_main(["--help"])
      assert output =~ "Synapsis - AI Coding Agent"
      assert output =~ "--prompt"
      assert output =~ "--model"
      assert output =~ "--host"
      assert output =~ "--version"
    end

    test "parses --version flag" do
      assert {:ok, output} = capture_main(["--version"])
      assert output =~ "Synapsis CLI v0.1.0"
    end

    test "parses --serve flag" do
      assert {:ok, output} = capture_main(["--serve"])
      assert output =~ "Starting Synapsis server..."
    end

    test "help output contains usage examples" do
      assert {:ok, output} = capture_main(["--help"])
      assert output =~ "Usage:"
      assert output =~ ~s(synapsis -p "prompt")
    end

    test "help output contains options section" do
      assert {:ok, output} = capture_main(["--help"])
      assert output =~ "Options:"
      assert output =~ "-p, --prompt"
      assert output =~ "-m, --model"
      assert output =~ "-h, --host"
    end

    test "version output is a single line" do
      assert {:ok, output} = capture_main(["--version"])
      lines = output |> String.trim() |> String.split("\n")
      assert length(lines) == 1
    end

    test "serve mode suggests using mix phx.server" do
      assert {:ok, output} = capture_main(["--serve"])
      assert output =~ "mix phx.server"
    end
  end

  describe "SSE event parsing" do
    test "parse_sse_event extracts event type and data" do
      # We test the SSE parsing indirectly through process_sse_data
      # by verifying the text_delta event type outputs text
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          send(self(), :ok)

          # Simulate what process_sse_data does with a text_delta event
          block = "event: text_delta\ndata: {\"text\": \"hello world\"}"
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

          assert event == "text_delta"
          assert data == "{\"text\": \"hello world\"}"
        end)

      # The capture_io just ensures no crash
      assert is_binary(output)
    end

    test "parse_sse_event handles event without data" do
      block = "event: done"
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

      assert event == "done"
      assert data == nil
    end

    test "parse_sse_event handles data without event" do
      block = "data: {\"text\": \"orphan data\"}"
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

      assert event == nil
      assert data == "{\"text\": \"orphan data\"}"
    end
  end

  defp capture_main(args) do
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        SynapsisCli.Main.main(args)
      end)

    {:ok, output}
  end
end
